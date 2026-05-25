/**
 * Cloud Functions for ClearRent notifications.
 *
 * Listens for new docs in the `notifications` collection and sends FCM
 * pushes to all of the recipient's stored tokens. Stale tokens are removed
 * lazily on send failure.
 */

import {setGlobalOptions} from "firebase-functions";
import {
  onDocumentCreated,
  onDocumentUpdated,
} from "firebase-functions/v2/firestore";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {defineSecret} from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {createHash} from "node:crypto";
import {getAuth} from "firebase-admin/auth";

initializeApp();
setGlobalOptions({maxInstances: 10, region: "us-central1"});

// Paystack secret key, stored in Google Secret Manager. Set via:
//   firebase functions:secrets:set PAYSTACK_SECRET_KEY
// Functions that need it bind it via `secrets: [paystackSecret]`.
const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

interface NotificationDoc {
  userId?: string;
  title?: string;
  body?: string;
  payload?: Record<string, string>;
}

export const onNotificationCreated = onDocumentCreated(
  "notifications/{notificationId}",
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("No snapshot on notification create event");
      return;
    }

    const notif = snap.data() as NotificationDoc;
    const {userId, title, body, payload} = notif;

    if (!userId || !title || !body) {
      logger.error("Notification doc missing required fields", {
        notificationId: event.params.notificationId,
        hasUserId: !!userId,
        hasTitle: !!title,
        hasBody: !!body,
      });
      return;
    }

    const db = getFirestore();
    const userSnap = await db.collection("users").doc(userId).get();
    if (!userSnap.exists) {
      logger.warn("Recipient user doc not found", {userId});
      return;
    }

    const tokens = (userSnap.get("fcmTokens") as string[] | undefined) ?? [];
    if (tokens.length === 0) {
      logger.info("User has no FCM tokens, skipping push", {userId});
      return;
    }

    // Stringify payload values — FCM data must be string-only.
    const data: Record<string, string> = {};
    if (payload) {
      for (const [k, v] of Object.entries(payload)) {
        data[k] = typeof v === "string" ? v : JSON.stringify(v);
      }
    }

    // Include the notification doc ID so the client can mark it read
    // when the user taps it.
    data.notificationId = event.params.notificationId;

    // Per-type grouping. Chat messages collapse per conversation
    // (Android tag + iOS thread-id) so a burst of messages from one
    // conversation shows as a single replaced banner, not a stack.
    // Other types stack naturally (one notification per event).
    const type = data.type as string | undefined;
    const conversationId = data.conversationId as string | undefined;
    let androidConfig;
    let apnsConfig;
    if (type === "chat_message" && conversationId) {
      const tag = `chat_${conversationId}`;
      androidConfig = {notification: {tag}};
      apnsConfig = {payload: {aps: {"thread-id": tag}}};
    }

    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {title, body},
      data,
      ...(androidConfig ? {android: androidConfig} : {}),
      ...(apnsConfig ? {apns: apnsConfig} : {}),
    });

    logger.info("FCM send complete", {
      userId,
      successCount: response.successCount,
      failureCount: response.failureCount,
    });

    // Identify and remove invalid tokens.
    const invalidTokens: string[] = [];
    response.responses.forEach((resp, idx) => {
      if (resp.success) return;
      const code = resp.error?.code;
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token" ||
        code === "messaging/invalid-argument"
      ) {
        invalidTokens.push(tokens[idx]);
      } else if (resp.error) {
        logger.warn("FCM send error (token retained)", {
          token: tokens[idx].slice(0, 12),
          code,
          message: resp.error.message,
        });
      }
    });

    if (invalidTokens.length > 0) {
      await db.collection("users").doc(userId).update({
        fcmTokens: FieldValue.arrayRemove(...invalidTokens),
      });
      logger.info("Removed invalid FCM tokens", {
        userId,
        count: invalidTokens.length,
      });
    }
  },
);

/**
 * Helper: write a notification doc with a deterministic ID.
 * Used for idempotent creates from event triggers — avoids
 * duplicate pushes when a Firestore trigger re-fires for the
 * same event.
 *
 * @param {string} notifId Deterministic notification doc ID.
 * @param {object} data Notification fields (userId, title, body,
 *   payload, type).
 * @return {Promise<boolean>} True if written, false if a doc
 *   with that ID already existed.
 */
async function writeNotificationOnce(
  notifId: string,
  data: {
    userId: string;
    title: string;
    body: string;
    payload: Record<string, string>;
    type: string;
  },
): Promise<boolean> {
  const db = getFirestore();
  const ref = db.collection("notifications").doc(notifId);
  try {
    await ref.create({
      ...data,
      read: false,
      readAt: null,
      createdAt: FieldValue.serverTimestamp(),
    });
    return true;
  } catch (err) {
    const code = (err as {code?: number | string})?.code;
    // Firestore admin SDK throws ALREADY_EXISTS for duplicate create.
    if (code === 6 || code === "already-exists") {
      logger.info("Notification already exists, skipping", {notifId});
      return false;
    }
    throw err;
  }
}

/**
 * Notify the handler when a new inspection request is created.
 *
 * Skipped when status is "pendingPayment" — the tenant hasn't
 * committed payment yet, so we don't ping the handler for an
 * unconverted request. The handler will be notified by the
 * request-update trigger when status advances to "pending" or
 * "pendingVerification".
 *
 * Recipient: the agent (if agent-handled) or the landlord (if self-
 * handled). The non-handler party is intentionally not pushed — the
 * in-app activity feed surfaces it for them.
 */
export const onInspectionRequestCreated = onDocumentCreated(
  "inspection_requests/{requestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("No snapshot on inspection_requests create event");
      return;
    }

    const requestId = event.params.requestId;
    const data = snap.data();
    const status = data.status as string | undefined;

    if (status === "pendingPayment") {
      logger.info("Skipping notification — pendingPayment", {requestId});
      return;
    }

    const agentId = data.agentId as string | null | undefined;
    const landlordId = data.landlordId as string | undefined;
    const tenantName =
      (data.tenantName as string | undefined) ?? "Someone";
    const propertyTitle =
      (data.propertyTitle as string | undefined) ?? "your property";

    const recipientId = agentId ?? landlordId;
    if (!recipientId) {
      logger.error("No recipient on inspection request", {requestId});
      return;
    }

    const route = agentId ?
      "/agent/inspections" :
      "/landlord/inspections";

    await writeNotificationOnce(
      `req_${requestId}_created_${recipientId}`,
      {
        userId: recipientId,
        type: "inspection_request",
        title: "New Inspection Request",
        body: `${tenantName} wants to inspect ${propertyTitle}`,
        payload: {
          route,
          initialTab: "0",
          param_requestId: requestId,
        },
      },
    );

    logger.info("Inspection-request-created notification queued", {
      requestId,
      recipientId,
      isAgent: !!agentId,
    });
  },
);

/**
 * Notify the right parties when an inspection request changes state.
 *
 * Diffs before vs after on the inspection_requests doc and emits one
 * notification per state transition we care about. Each notification
 * uses a deterministic ID so retried trigger invocations don't push
 * twice. See the per-case comments for which transition each block
 * handles.
 *
 * @param {object} event Firestore update event with before/after.
 * @return {Promise<void>}
 */
export const onInspectionRequestUpdated = onDocumentUpdated(
  "inspection_requests/{requestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("No snapshot on inspection_requests update event");
      return;
    }

    const requestId = event.params.requestId;
    const before = snap.before.data();
    const after = snap.after.data();

    const beforeStatus = before.status as string | undefined;
    const afterStatus = after.status as string | undefined;
    const statusChanged = beforeStatus !== afterStatus;

    const agentId = after.agentId as string | null | undefined;
    const landlordId = after.landlordId as string | undefined;
    const tenantId = after.tenantId as string | undefined;
    const tenantName =
      (after.tenantName as string | undefined) ?? "Someone";
    const agentName =
      (after.agentName as string | undefined) ?? "Agent";
    const landlordName =
      (after.landlordName as string | undefined) ?? "Landlord";
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "your property";
    const wasOverridden = after.wasOverridden === true;

    const tenantRoute = "/tenant/inspections";
    const agentRoute = "/agent/inspections";
    const landlordRoute = "/landlord/inspections";

    // ---- Status: pendingPayment → pending / pendingVerification ----
    // Deferred Batch A push: handler wasn't notified at create time
    // because payment hadn't arrived. Now it has — push them.
    if (
      statusChanged &&
      beforeStatus === "pendingPayment" &&
      (afterStatus === "pending" ||
        afterStatus === "pendingVerification")
    ) {
      const recipientId = agentId ?? landlordId;
      if (recipientId) {
        const route = agentId ? agentRoute : landlordRoute;
        await writeNotificationOnce(
          `req_${requestId}_paymentReceived_${recipientId}`,
          {
            userId: recipientId,
            type: "inspection_request",
            title: "New Inspection Request",
            body: `${tenantName} wants to inspect ${propertyTitle}`,
            payload: {
              route,
              initialTab: "0",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Status: → approved (regular, not override) ----
    // Tenant gets pushed. Agent overrides covered by the next block.
    if (
      statusChanged &&
      afterStatus === "approved" &&
      (beforeStatus === "pending" ||
        beforeStatus === "pendingVerification") &&
      tenantId
    ) {
      await writeNotificationOnce(
        `req_${requestId}_approved_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_approved",
          title: "Inspection Approved",
          body: `Your inspection for ${propertyTitle} was approved`,
          payload: {
            route: tenantRoute,
            initialTab: "1",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Status: declinedByAgent → approved (landlord override) ----
    // Tenant only (agent intentionally not notified per design).
    if (
      statusChanged &&
      beforeStatus === "declinedByAgent" &&
      afterStatus === "approved" &&
      tenantId
    ) {
      await writeNotificationOnce(
        `req_${requestId}_overrideApproved_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_approved",
          title: "Inspection Approved",
          body:
            `Good news — your inspection for ${propertyTitle} was ` +
            "approved",
          payload: {
            route: tenantRoute,
            initialTab: "1",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Status: pending → declinedByAgent ----
    // Landlord gets pushed (override window opens).
    if (
      statusChanged &&
      beforeStatus === "pending" &&
      afterStatus === "declinedByAgent" &&
      landlordId
    ) {
      await writeNotificationOnce(
        `req_${requestId}_agentDeclined_${landlordId}`,
        {
          userId: landlordId,
          type: "agent_declined",
          title: "Agent Declined Inspection",
          body:
            `${agentName} declined inspection for ${propertyTitle}. ` +
            "You have 12 hours to override.",
          payload: {
            route: landlordRoute,
            initialTab: "0",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Status: declinedByAgent → declined (final decline) ----
    // Tenant gets pushed. Refund auto-processed by service.
    if (
      statusChanged &&
      beforeStatus === "declinedByAgent" &&
      afterStatus === "declined" &&
      tenantId
    ) {
      await writeNotificationOnce(
        `req_${requestId}_finalDeclined_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_declined",
          title: "Inspection Declined",
          body:
            `Your inspection for ${propertyTitle} was declined. ` +
            "A refund is being processed.",
          payload: {
            route: tenantRoute,
            initialTab: "2",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Status: pending → declined (landlord-handled decline) ----
    // Tenant gets pushed.
    if (
      statusChanged &&
      beforeStatus === "pending" &&
      afterStatus === "declined" &&
      tenantId
    ) {
      await writeNotificationOnce(
        `req_${requestId}_declined_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_declined",
          title: "Inspection Declined",
          body:
            `Your inspection for ${propertyTitle} was declined by ` +
            "the landlord.",
          payload: {
            route: tenantRoute,
            initialTab: "2",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Status: approved → declined (landlord override of approval) ----
    // Tenant + agent both notified. Refund auto-processed.
    if (
      statusChanged &&
      beforeStatus === "approved" &&
      afterStatus === "declined" &&
      wasOverridden
    ) {
      if (tenantId) {
        await writeNotificationOnce(
          `req_${requestId}_overrideDeclined_${tenantId}`,
          {
            userId: tenantId,
            type: "inspection_declined",
            title: "Inspection Declined",
            body:
              `Your inspection for ${propertyTitle} was declined by ` +
              "the landlord. A refund is being processed.",
            payload: {
              route: tenantRoute,
              initialTab: "2",
              param_requestId: requestId,
            },
          },
        );
      }
      if (agentId) {
        await writeNotificationOnce(
          `req_${requestId}_overrideDeclined_${agentId}`,
          {
            userId: agentId,
            type: "landlord_override",
            title: "Landlord Override",
            body:
              "Landlord declined the inspection you approved for " +
              `${propertyTitle}`,
            payload: {
              route: agentRoute,
              initialTab: "2",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Status: → completed ----
    // Tenant only — review prompt. Landlord/agent see it in feed.
    if (
      statusChanged &&
      afterStatus === "completed" &&
      tenantId
    ) {
      await writeNotificationOnce(
        `req_${requestId}_completed_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_completed",
          title: "Inspection Complete",
          body:
            `How was your inspection of ${propertyTitle}? ` +
            "Tap to leave a rating.",
          payload: {
            route: tenantRoute,
            initialTab: "2",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Field: tenantOnWay false → true ----
    // Notify the handler(s). Tenant just tapped "I'm on my way."
    if (
      before.tenantOnWay !== true &&
      after.tenantOnWay === true
    ) {
      const recipients: string[] = [];
      if (agentId) {
        recipients.push(agentId);
        if (landlordId) recipients.push(landlordId);
      } else if (landlordId) {
        recipients.push(landlordId);
      }
      for (const rid of recipients) {
        const route = rid === agentId ? agentRoute : landlordRoute;
        await writeNotificationOnce(
          `req_${requestId}_tenantOnWay_${rid}`,
          {
            userId: rid,
            type: "tenant_on_way",
            title: "Tenant On the Way",
            body: `${tenantName} is on the way to ${propertyTitle}`,
            payload: {
              route,
              initialTab: "1",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Field: handlerOnWay false → true ----
    // Notify tenant. Body uses agent name if agent-handled, else
    // landlord name.
    if (
      before.handlerOnWay !== true &&
      after.handlerOnWay === true &&
      tenantId
    ) {
      const handlerName = agentId ? agentName : landlordName;
      await writeNotificationOnce(
        `req_${requestId}_handlerOnWay_${tenantId}`,
        {
          userId: tenantId,
          type: "handler_on_way",
          title: "Your Inspection Host Is On the Way",
          body: `${handlerName} is on the way to ${propertyTitle}`,
          payload: {
            route: tenantRoute,
            initialTab: "1",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Field: tenantArrived false → true ----
    // Notify the handler(s). Self-handled = landlord. Agent-handled
    // = agent + landlord (matches existing activity-feed pattern).
    if (
      before.tenantArrived !== true &&
      after.tenantArrived === true
    ) {
      const recipients: string[] = [];
      if (agentId) {
        recipients.push(agentId);
        if (landlordId) recipients.push(landlordId);
      } else if (landlordId) {
        recipients.push(landlordId);
      }
      for (const rid of recipients) {
        const route = rid === agentId ? agentRoute : landlordRoute;
        await writeNotificationOnce(
          `req_${requestId}_tenantArrived_${rid}`,
          {
            userId: rid,
            type: "tenant_arrived",
            title: "Tenant Arrived",
            body: `${tenantName} arrived at ${propertyTitle}`,
            payload: {
              route,
              initialTab: "1",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Field: handlerArrived false → true ----
    // Notify tenant. Body uses agent name if agent-handled, else
    // landlord name.
    if (
      before.handlerArrived !== true &&
      after.handlerArrived === true &&
      tenantId
    ) {
      const handlerName = agentId ? agentName : landlordName;
      await writeNotificationOnce(
        `req_${requestId}_handlerArrived_${tenantId}`,
        {
          userId: tenantId,
          type: "handler_arrived",
          title: "Your Inspection Host Arrived",
          body: `${handlerName} arrived at ${propertyTitle}`,
          payload: {
            route: tenantRoute,
            initialTab: "1",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Field: met false → true (by tenant) ----
    // Notify the handler(s) so they know to complete the inspection.
    // We only push when metBy is 'tenant' — when the handler marks
    // met themselves, the tenant is right there with them and the
    // next push (inspection_completed) follows soon after anyway.
    if (
      before.met !== true &&
      after.met === true &&
      after.metBy === "tenant"
    ) {
      const recipients: string[] = [];
      if (agentId) {
        recipients.push(agentId);
        if (landlordId) recipients.push(landlordId);
      } else if (landlordId) {
        recipients.push(landlordId);
      }
      for (const rid of recipients) {
        const route = rid === agentId ? agentRoute : landlordRoute;
        await writeNotificationOnce(
          `req_${requestId}_met_${rid}`,
          {
            userId: rid,
            type: "inspection_met",
            title: "Tenant Confirmed Meeting",
            body:
              `${tenantName} confirms meeting you. ` +
              "You can now complete the inspection.",
            payload: {
              route,
              initialTab: "1",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Field: tenantRated false → true ----
    // Notify the rated user only (agent or landlord per the
    // ratedUserId field set by rateInspection).
    if (
      before.tenantRated !== true &&
      after.tenantRated === true
    ) {
      const ratedUserId = after.ratedUserId as string | undefined;
      const rating = after.tenantRating as number | undefined;
      const ratedUserType =
        after.ratedUserType as string | undefined;
      if (ratedUserId && rating !== undefined) {
        const route = ratedUserType === "agent" ?
          agentRoute :
          landlordRoute;
        await writeNotificationOnce(
          `req_${requestId}_rated_${ratedUserId}`,
          {
            userId: ratedUserId,
            type: "new_rating",
            title: "New Rating Received",
            body:
              `${tenantName} rated you ${rating} stars for ` +
              propertyTitle,
            payload: {
              route,
              initialTab: "2",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ============ RESCHEDULE TRANSITIONS ============
    // The reschedule side-channel uses the `rescheduleProposal` map.
    // Decline is NOT handled here — declineReschedule flips status
    // to "declined", which is already covered by the status diff
    // blocks above.

    const beforeProposal =
      before.rescheduleProposal as Record<string, unknown> | null;
    const afterProposal =
      after.rescheduleProposal as Record<string, unknown> | null;
    const beforeCount = (before.rescheduleCount as number) ?? 0;
    const afterCount = (after.rescheduleCount as number) ?? 0;

    /**
     * Format a Firestore Timestamp into a short date string like
     * "Sat, Nov 23" for use in notification bodies.
     *
     * @param {object} ts Firestore Timestamp object.
     * @return {string} Formatted date.
     */
    const fmtDate = (ts: {toDate: () => Date}): string => {
      const d = ts.toDate();
      const weekdays =
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
      const months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
      ];
      return `${weekdays[d.getDay()]}, ` +
        `${months[d.getMonth()]} ${d.getDate()}`;
    };

    /**
     * Map a role to that role's inspections route.
     *
     * @param {string} role 'tenant' | 'agent' | 'landlord'.
     * @return {string} Deep-link route.
     */
    const routeFor = (role: string): string => {
      if (role === "tenant") return tenantRoute;
      if (role === "agent") return agentRoute;
      return landlordRoute;
    };

    /**
     * Display name for a given proposer role.
     *
     * @param {string} role The proposer role.
     * @return {string} Display name.
     */
    const nameFor = (role: string): string => {
      if (role === "tenant") return tenantName;
      if (role === "agent") return agentName;
      return landlordName;
    };

    /**
     * IDs of the parties on the receiver side of a proposal made by
     * `proposerRole`. Tenant proposals go to the handler(s); handler
     * proposals go to the tenant.
     *
     * @param {string} proposerRole The role that made the proposal.
     * @return {Array<{id: string, role: string}>} Recipients.
     */
    const receiversFor = (
      proposerRole: string,
    ): Array<{id: string; role: string}> => {
      if (proposerRole === "tenant") {
        // Handler side. Agent if agent-handled, else landlord.
        if (agentId) return [{id: agentId, role: "agent"}];
        if (landlordId) return [{id: landlordId, role: "landlord"}];
        return [];
      }
      // Handler proposed → notify tenant.
      if (tenantId) return [{id: tenantId, role: "tenant"}];
      return [];
    };

    // ---- Reschedule: proposed (null → object) ----
    if (beforeProposal == null && afterProposal != null) {
      const proposerRole = afterProposal.proposedBy as string;
      const reason = afterProposal.reason as string;
      const proposedAt =
        afterProposal.proposedAt as {toDate: () => Date};
      const proposedDate =
        afterProposal.proposedDate as {toDate: () => Date};
      const timeDisplay =
        afterProposal.proposedTimeDisplay as string;
      const proposedAtMs = proposedAt.toDate().getTime();
      const proposerName = nameFor(proposerRole);

      for (const r of receiversFor(proposerRole)) {
        await writeNotificationOnce(
          `req_${requestId}_resched_proposed_` +
            `${proposedAtMs}_${r.id}`,
          {
            userId: r.id,
            type: "reschedule_proposed",
            title: "Reschedule Proposed",
            body:
              `${proposerName} proposed ${fmtDate(proposedDate)} ` +
              `${timeDisplay}. Reason: ${reason}`,
            payload: {
              route: routeFor(r.role),
              initialTab: "1",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Reschedule: counter-proposed (object → object, role flips) ----
    if (
      beforeProposal != null &&
      afterProposal != null &&
      beforeProposal.proposedBy !== afterProposal.proposedBy
    ) {
      const proposerRole = afterProposal.proposedBy as string;
      const reason = afterProposal.reason as string;
      const proposedAt =
        afterProposal.proposedAt as {toDate: () => Date};
      const proposedDate =
        afterProposal.proposedDate as {toDate: () => Date};
      const timeDisplay =
        afterProposal.proposedTimeDisplay as string;
      const proposedAtMs = proposedAt.toDate().getTime();
      const proposerName = nameFor(proposerRole);

      for (const r of receiversFor(proposerRole)) {
        await writeNotificationOnce(
          `req_${requestId}_resched_countered_` +
            `${proposedAtMs}_${r.id}`,
          {
            userId: r.id,
            type: "reschedule_countered",
            title: "Reschedule Counter-proposed",
            body:
              `${proposerName} proposed ${fmtDate(proposedDate)} ` +
              `${timeDisplay} instead. Reason: ${reason}`,
            payload: {
              route: routeFor(r.role),
              initialTab: "1",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ---- Reschedule: approved (object → null, count incremented) ----
    if (
      beforeProposal != null &&
      afterProposal == null &&
      afterCount > beforeCount
    ) {
      const proposerRole = beforeProposal.proposedBy as string;
      const proposerId = beforeProposal.proposedByUserId as string;
      const proposedAt =
        beforeProposal.proposedAt as {toDate: () => Date};
      const proposedDate =
        beforeProposal.proposedDate as {toDate: () => Date};
      const timeDisplay =
        beforeProposal.proposedTimeDisplay as string;
      const proposedAtMs = proposedAt.toDate().getTime();

      // The approver is whoever isn't the proposer. Notify the
      // proposer that their proposal was approved.
      await writeNotificationOnce(
        `req_${requestId}_resched_approved_` +
          `${proposedAtMs}_${proposerId}`,
        {
          userId: proposerId,
          type: "reschedule_approved",
          title: "Reschedule Approved",
          body:
            `Your reschedule to ${fmtDate(proposedDate)} ` +
            `${timeDisplay} was approved.`,
          payload: {
            route: routeFor(proposerRole),
            initialTab: "1",
            param_requestId: requestId,
          },
        },
      );
    }

    // ---- Reschedule: abandoned (object → null, count unchanged,
    //      status still approved) ----
    if (
      beforeProposal != null &&
      afterProposal == null &&
      afterCount === beforeCount &&
      afterStatus === "approved"
    ) {
      const proposerRole = beforeProposal.proposedBy as string;
      const proposedAt =
        beforeProposal.proposedAt as {toDate: () => Date};
      const proposedAtMs = proposedAt.toDate().getTime();
      const proposerName = nameFor(proposerRole);

      for (const r of receiversFor(proposerRole)) {
        await writeNotificationOnce(
          `req_${requestId}_resched_abandoned_` +
            `${proposedAtMs}_${r.id}`,
          {
            userId: r.id,
            type: "reschedule_abandoned",
            title: "Reschedule Abandoned",
            body:
              `${proposerName} dropped their reschedule proposal. ` +
              "Original date stands.",
            payload: {
              route: routeFor(r.role),
              initialTab: "1",
              param_requestId: requestId,
            },
          },
        );
      }
    }

    // ============ HANDLER CANCEL ============
    // Fires when an agent or landlord cancels an inspection on the
    // tenant's behalf via handlerCancelRequest. Tenant gets pushed.
    // Tenant-side cancels do not set cancelledBy, so this filter
    // cleanly excludes them.
    if (
      beforeStatus !== "cancelled" &&
      afterStatus === "cancelled" &&
      tenantId
    ) {
      const cancelledBy = after.cancelledBy as string | undefined;
      if (cancelledBy === "agent" || cancelledBy === "landlord") {
        const reason =
          (after.cancellationReason as string | undefined) ?? "";
        await writeNotificationOnce(
          `req_${requestId}_handlerCancelled_${tenantId}`,
          {
            userId: tenantId,
            type: "inspection_cancelled",
            title: "Inspection Cancelled",
            body: reason.length > 0 ?
              `Your inspection for ${propertyTitle} was cancelled. ` +
                `Reason: ${reason}. Refund processing.` :
              `Your inspection for ${propertyTitle} was cancelled. ` +
                "Refund processing.",
            payload: {
              route: tenantRoute,
              initialTab: "2",
              param_requestId: requestId,
            },
          },
        );
        logger.info("Handler-cancel notification queued", {
          requestId,
          cancelledBy,
          tenantId,
        });
      }
    }

    logger.info("Inspection-request-updated processed", {
      requestId,
      beforeStatus,
      afterStatus,
      tenantArrivedChanged:
        before.tenantArrived !== after.tenantArrived,
      handlerArrivedChanged:
        before.handlerArrived !== after.handlerArrived,
      ratedChanged: before.tenantRated !== after.tenantRated,
    });
  },
);

/**
 * Notify recipients when a new chat message is sent.
 *
 * Pushes every participant of the parent conversation except the
 * sender. Body is the message text (truncated to 100 chars), or
 * "📷 Image" for image-only messages. Idempotent via deterministic
 * notification ID per recipient.
 *
 * Sends `conversationId` in the payload. Both the chat route and
 * foreground suppression read it (suppression has a route → key
 * lookup that maps `/chat` to `conversationId`).
 *
 * @param {object} event Firestore create event for the message doc.
 * @return {Promise<void>}
 */
export const onChatMessageCreated = onDocumentCreated(
  "conversations/{conversationId}/messages/{messageId}",
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("No snapshot on chat message create event");
      return;
    }

    const conversationId = event.params.conversationId;
    const messageId = event.params.messageId;
    const message = snap.data();

    const senderId = message.senderId as string | undefined;
    const senderName =
      (message.senderName as string | undefined) ?? "Someone";
    const text = (message.text as string | undefined) ?? "";
    const imageUrl = message.imageUrl as string | undefined;

    if (!senderId) {
      logger.error("Message missing senderId", {messageId});
      return;
    }

    // Fetch parent conversation for participant list.
    const db = getFirestore();
    const convoSnap = await db
      .collection("conversations")
      .doc(conversationId)
      .get();

    if (!convoSnap.exists) {
      logger.error("Parent conversation not found", {
        conversationId,
        messageId,
      });
      return;
    }

    const convo = convoSnap.data() ?? {};
    const participants =
      (convo.participants as string[] | undefined) ?? [];

    if (participants.length === 0) {
      logger.warn("Conversation has no participants", {
        conversationId,
      });
      return;
    }

    // Build the push body: text (truncated), or image fallback.
    let body: string;
    if (text.trim().length > 0) {
      body = text.length > 100 ? `${text.substring(0, 100)}…` : text;
    } else if (imageUrl) {
      body = "📷 Image";
    } else {
      body = "New message";
    }

    // Push every non-sender participant.
    const recipients = participants.filter((p) => p !== senderId);

    for (const rid of recipients) {
      await writeNotificationOnce(`msg_${messageId}_${rid}`, {
        userId: rid,
        type: "chat_message",
        title: senderName,
        body,
        payload: {
          route: "/chat",
          conversationId,
        },
      });
    }

    logger.info("Chat-message notification(s) queued", {
      conversationId,
      messageId,
      senderId,
      recipientCount: recipients.length,
    });
  },
);

// ============================================================
// PAYSTACK CALLABLE FUNCTIONS
// Server-side proxies for Paystack API calls that need the secret
// key. Each function authenticates the caller via Firebase Auth
// and forwards to the Paystack REST API.
// ============================================================

interface ResolveAccountInput {
  accountNumber: string;
  bankCode: string;
}

interface PaystackResolveResponse {
  status: boolean;
  message?: string;
  data?: {
    account_number?: string;
    account_name?: string;
    bank_id?: number;
  };
}

/**
 * Resolves an account number + bank code to the registered account
 * name via Paystack's /bank/resolve endpoint.
 *
 * Returns: { accountName: string } on success.
 * Throws: HttpsError with code 'invalid-argument', 'unauthenticated',
 *   'not-found', or 'internal' on failure.
 */
export const resolveAccount = onCall(
  {
    secrets: [paystackSecret],
    timeoutSeconds: 30,
    enforceAppCheck: false,
  },
  async (request) => {
    // 1. Auth check — only signed-in users may call this.
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to resolve account names.",
      );
    }

    // 2. Validate input.
    const data = request.data as Partial<ResolveAccountInput>;
    const accountNumber = data?.accountNumber;
    const bankCode = data?.bankCode;

    if (typeof accountNumber !== "string" ||
        accountNumber.trim().length !== 10) {
      throw new HttpsError(
        "invalid-argument",
        "accountNumber must be a 10-digit string.",
      );
    }
    if (typeof bankCode !== "string" || bankCode.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "bankCode must be a non-empty string.",
      );
    }

    // 3. Call Paystack.
    const url =
      "https://api.paystack.co/bank/resolve" +
      `?account_number=${encodeURIComponent(accountNumber)}` +
      `&bank_code=${encodeURIComponent(bankCode)}`;

    try {
      const resp = await fetch(url, {
        method: "GET",
        headers: {
          "Authorization": `Bearer ${paystackSecret.value()}`,
          "Content-Type": "application/json",
        },
      });

      if (!resp.ok) {
        // Paystack returns 422 for "could not resolve" — surface
        // as not-found so the client can show a friendly message.
        if (resp.status === 422 || resp.status === 404) {
          throw new HttpsError(
            "not-found",
            "Account could not be resolved. " +
              "Check the number and bank.",
          );
        }
        logger.warn("Paystack resolve non-OK response", {
          status: resp.status,
          uid: request.auth.uid,
        });
        throw new HttpsError(
          "internal",
          "Could not reach Paystack right now. Try again.",
        );
      }

      const body = (await resp.json()) as PaystackResolveResponse;
      if (body.status !== true || !body.data?.account_name) {
        throw new HttpsError(
          "not-found",
          "Account could not be resolved. " +
            "Check the number and bank.",
        );
      }

      return {accountName: body.data.account_name};
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      logger.error("Paystack resolve failed", {
        error: err instanceof Error ? err.message : String(err),
        uid: request.auth.uid,
      });
      throw new HttpsError(
        "internal",
        "Could not reach Paystack right now. Try again.",
      );
    }
  },
);
// ─────────────────────────────────────────────────────────────────────────────
// lookupEmailByPhone
//
// Looks up a user's email address by phone number so the client can complete
// a phone+password sign-in flow. This replaces a direct, unauthenticated
// Firestore query against the `users` collection (which previously required
// `allow list: if true` — see security audit finding F1.1).
//
// Because this CF is callable by unauthenticated clients (the user is in the
// process of signing in), it would otherwise be a phone-enumeration oracle.
// Three layers of defense apply:
//   1. Per-IP rate limit on total lookups in a rolling window.
//   2. Per-IP cap on distinct phone numbers queried in a rolling window.
//   3. App Check enforcement (currently disabled — see TODO).
//
// IP addresses are SHA-256-hashed before storage so we don't retain raw IPs
// (NDPA hygiene). The hashed values are the document IDs in /_rate_limits.
//
// TODO: set enforceAppCheck: true once AAB is uploaded to Play Console and
// Play Integrity attestation works. Tracking: parking lot Item 30.
// ─────────────────────────────────────────────────────────────────────────────

// Tuning knobs. Treat as starting values; adjust based on observed traffic.
const RL_WINDOW_MS = 60 * 60 * 1000; // 1 hour
const RL_MAX_LOOKUPS_PER_WINDOW = 30; // total per IP per window
const RL_MAX_DISTINCT_PHONES = 5; // distinct phones per IP per window

interface LookupEmailByPhoneInput {
  phone?: unknown;
}

interface RateLimitDoc {
  windowStart: Timestamp;
  totalLookups: number;
  distinctPhones: string[];
}

/**
 * Normalize a Nigerian phone number to local format (e.g. "09060237734").
 * Accepts inputs in local, E.164, or subscriber-only form.
 * @param {string} raw The user-supplied phone string.
 * @return {string | null} The normalized local-format number, or null if
 *   the input cannot be parsed as a Nigerian mobile number.
 */
function normalizeNigerianPhone(raw: string): string | null {
  const digits = raw.replace(/[\s\-()+]/g, "");
  if (!/^\d+$/.test(digits)) return null;

  let subscriber: string;
  if (digits.length === 11 && digits.startsWith("0")) {
    subscriber = digits.slice(1);
  } else if (digits.length === 13 && digits.startsWith("234")) {
    subscriber = digits.slice(3);
  } else if (digits.length === 10) {
    subscriber = digits;
  } else {
    return null;
  }

  if (!/^[789]\d{9}$/.test(subscriber)) return null;
  return "0" + subscriber;
}

/**
 * SHA-256 hash of a string, hex-encoded. Used so raw IPs are never stored.
 * @param {string} input The string to hash.
 * @return {string} Hex-encoded SHA-256 digest.
 */
function sha256Hex(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

/**
 * Extract the caller IP, preferring x-forwarded-for first hop.
 * @param {object} req The Firebase Functions raw request object.
 * @return {string} The caller IP, or "unknown" if not determinable.
 */
function extractIp(
  req: {
    ip?: string;
    headers?: Record<string, string | string[] | undefined>;
  },
): string {
  const fwd = req.headers?.["x-forwarded-for"];
  if (typeof fwd === "string" && fwd.length > 0) {
    return fwd.split(",")[0].trim();
  }
  if (Array.isArray(fwd) && fwd.length > 0) {
    return String(fwd[0]).split(",")[0].trim();
  }
  return req.ip ?? "unknown";
}

/**
 * Atomically check and update the per-IP rate-limit doc.
 * @param {string} ipHash SHA-256 hash of the caller IP.
 * @param {string} phone Normalized phone number being queried.
 * @return {Promise<string | null>} A reason string if rate-limited, or null
 *   if the request is within limits.
 */
async function checkRateLimit(
  ipHash: string,
  phone: string,
): Promise<string | null> {
  const db = getFirestore();
  const ref = db.collection("_rate_limits").doc(ipHash);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();

    let windowStart: number;
    let totalLookups: number;
    let distinctPhones: string[];

    if (!snap.exists) {
      windowStart = now;
      totalLookups = 0;
      distinctPhones = [];
    } else {
      const data = snap.data() as RateLimitDoc;
      const startMs = data.windowStart.toMillis();
      if (now - startMs > RL_WINDOW_MS) {
        windowStart = now;
        totalLookups = 0;
        distinctPhones = [];
      } else {
        windowStart = startMs;
        totalLookups = data.totalLookups ?? 0;
        distinctPhones = data.distinctPhones ?? [];
      }
    }

    if (totalLookups >= RL_MAX_LOOKUPS_PER_WINDOW) {
      return "Too many lookups from this device. Try again later.";
    }
    const alreadySeen = distinctPhones.includes(phone);
    if (!alreadySeen && distinctPhones.length >= RL_MAX_DISTINCT_PHONES) {
      return "Too many distinct numbers from this device. " +
        "Try again later.";
    }

    tx.set(ref, {
      windowStart: Timestamp.fromMillis(windowStart),
      totalLookups: totalLookups + 1,
      distinctPhones: alreadySeen ?
        distinctPhones :
        [...distinctPhones, phone],
    });
    return null;
  });
}

/**
 * Look up a user's email by phone number for phone+password sign-in.
 * Rate-limited per IP. Returns { email } on success.
 */
export const lookupEmailByPhone = onCall(
  {
    timeoutSeconds: 15,
    enforceAppCheck: false, // TODO: enable post-AAB upload (Item 30)
  },
  async (request) => {
    const data = request.data as Partial<LookupEmailByPhoneInput>;
    const rawPhone = data?.phone;
    if (typeof rawPhone !== "string" || rawPhone.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "phone must be a non-empty string.",
      );
    }
    const phone = normalizeNigerianPhone(rawPhone);
    if (phone === null) {
      throw new HttpsError(
        "invalid-argument",
        "phone is not a valid Nigerian mobile number.",
      );
    }

    const ip = extractIp(request.rawRequest);
    const ipHash = sha256Hex(ip);
    let rlReason: string | null;
    try {
      rlReason = await checkRateLimit(ipHash, phone);
    } catch (err) {
      logger.error("Rate-limit check failed", {
        error: err instanceof Error ? err.message : String(err),
        ipHash,
      });
      throw new HttpsError(
        "internal",
        "Could not process request right now. Try again.",
      );
    }
    if (rlReason !== null) {
      logger.warn("lookupEmailByPhone rate-limited", {ipHash});
      throw new HttpsError("resource-exhausted", rlReason);
    }

    try {
      const snap = await getFirestore()
        .collection("users")
        .where("phone", "==", phone)
        .limit(1)
        .get();

      if (snap.empty) {
        throw new HttpsError(
          "not-found",
          "No account found with this phone number.",
        );
      }

      const email = snap.docs[0].data().email as unknown;
      if (typeof email !== "string" || email.length === 0) {
        throw new HttpsError(
          "failed-precondition",
          "No email linked to this account. Contact support.",
        );
      }

      return {email};
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      logger.error("lookupEmailByPhone Firestore failed", {
        error: err instanceof Error ? err.message : String(err),
        ipHash,
      });
      throw new HttpsError(
        "internal",
        "Could not process request right now. Try again.",
      );
    }
  },
)

// ─────────────────────────────────────────────────────────────────────────────
// setAdminClaim
//
// Grants or revokes the admin / superAdmin custom claim on a target user.
// Caller must hold the superAdmin claim — admins cannot promote each other
// or escalate themselves. The bootstrap superAdmin is set out-of-band via
// the local scripts/bootstrap-superadmin.ts script (never via this CF).
//
// Input:
//   { targetUid: string, role: "admin" | "superAdmin" | null }
//   - "admin" / "superAdmin" grants the named claim.
//   - null revokes both claims from the target.
//
// Side effect: the affected user's existing ID token is stale until they
// call getIdToken(true) or sign in again. Surface this to the caller in
// the admin-management UI (when we build it).
// ─────────────────────────────────────────────────────────────────────────────

interface SetAdminClaimInput {
  targetUid?: unknown;
  role?: unknown;
}

export const setAdminClaim = onCall(
  {
    timeoutSeconds: 15,
    enforceAppCheck: false,
  },
  async (request) => {
    // 1. Auth check.
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required.",
      );
    }

    // 2. Caller must be superAdmin. Read from the token, not Firestore —
    //    Firestore could be stale or spoofed; the token is signed by Auth.
    const callerClaims = request.auth.token ?? {};
    if (callerClaims.superAdmin !== true) {
      logger.warn("setAdminClaim called by non-superAdmin", {
        callerUid: request.auth.uid,
      });
      throw new HttpsError(
        "permission-denied",
        "Only super admins can change admin status.",
      );
    }

    // 3. Validate input.
    const data = request.data as SetAdminClaimInput;
    const targetUid = data.targetUid;
    const role = data.role;

    if (typeof targetUid !== "string" || targetUid.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "targetUid must be a non-empty string.",
      );
    }
    if (role !== "admin" && role !== "superAdmin" && role !== null) {
      throw new HttpsError(
        "invalid-argument",
        "role must be 'admin', 'superAdmin', or null.",
      );
    }

    // 4. Block self-demotion of the last superAdmin. Trivial guard against
    //    "I accidentally demoted myself and now no one can grant claims."
    //    Counts users with superAdmin === true via listUsers; bounded by
    //    the small expected admin population.
    if (targetUid === request.auth.uid && role !== "superAdmin") {
      const auth = getAuth();
      let superAdminCount = 0;
      let pageToken: string | undefined;
      do {
        const page = await auth.listUsers(1000, pageToken);
        for (const u of page.users) {
          if ((u.customClaims as Record<string, unknown> | undefined)
            ?.superAdmin === true) {
            superAdminCount++;
          }
        }
        pageToken = page.pageToken;
      } while (pageToken);

      if (superAdminCount <= 1) {
        throw new HttpsError(
          "failed-precondition",
          "Cannot demote the last super admin. " +
            "Promote another user first.",
        );
      }
    }

    // 5. Apply the claim. Merge with existing so we don't clobber other
    //    metadata Firebase Auth may have set.
    const auth = getAuth();
    const target = await auth.getUser(targetUid);
    const existing = (target.customClaims ?? {}) as Record<string, unknown>;

    let next: Record<string, unknown>;
    if (role === null) {
      // Revoke both admin claims, keep anything else.
      const {admin: _a, superAdmin: _sa, ...rest} = existing;
      next = rest;
    } else if (role === "admin") {
      next = {...existing, admin: true, superAdmin: false};
    } else {
      // role === "superAdmin"
      next = {...existing, admin: false, superAdmin: true};
    }

    await auth.setCustomUserClaims(targetUid, next);

    logger.info("Admin claim updated", {
      callerUid: request.auth.uid,
      targetUid,
      role,
    });

    return {success: true, targetUid, role};
  },
)

// ─────────────────────────────────────────────────────────────────────────────
// creditInspectionEarnings
//
// Firestore trigger on inspection_requests/{requestId} update. When an
// inspection's status transitions to "completed" for the first time, credits
// the handler (agent if agent-handled, else landlord) with ₦7,000 — the flat
// handler fee under the current pricing model. Sets earningsCredited: true
// on the inspection doc to make the operation idempotent.
//
// This closes F1.4. Previously the mobile client wrote directly to user docs
// to credit earnings, and the Firestore rule was too permissive (any
// authenticated user could update earnings fields on any user). After this
// CF ships and the corresponding rule lockdown deploys, clients cannot write
// to earnings fields at all — credit flows exclusively through this trigger.
//
// Idempotency: the transaction reads earningsCredited first; if already true,
// exits as no-op. This makes the trigger safe against re-firing.
// ─────────────────────────────────────────────────────────────────────────────

// Flat handler fee per inspection. Mirrors InspectionPricing.handlerEarnings
// in the mobile codebase. Keep in sync with lib/core/utils/inspection_pricing.dart.
const HANDLER_EARNINGS = 7000;

export const creditInspectionEarnings = onDocumentUpdated(
  "inspection_requests/{requestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("No snapshot on inspection_requests update event");
      return;
    }

    const requestId = event.params.requestId;
    const before = snap.before.data();
    const after = snap.after.data();

    // Only act on the transition into "completed". Other status changes
    // and field updates are ignored.
    if (before.status === "completed" || after.status !== "completed") {
      return;
    }

    // Determine handler. Agent if assigned, else landlord (self-handled).
    const agentId = after.agentId as string | null | undefined;
    const landlordId = after.landlordId as string | undefined;
    const handlerId = agentId ?? landlordId;
    const handlerIsAgent = !!agentId;

    if (!handlerId) {
      logger.error("Inspection completed but no handler", {
        requestId,
      });
      return;
    }

    const db = getFirestore();
    const inspectionRef = db.collection("inspection_requests").doc(requestId);
    const handlerRef = db.collection("users").doc(handlerId);

    try {
      await db.runTransaction(async (tx) => {
        const inspectionSnap = await tx.get(inspectionRef);
        if (!inspectionSnap.exists) {
          logger.warn("Inspection vanished mid-transaction", {requestId});
          return;
        }

        const current = inspectionSnap.data();
        if (current?.earningsCredited === true) {
          // Already credited on a prior trigger fire. No-op.
          return;
        }

        // Build the handler update. Agents track totalInspections too;
        // landlord-handled completions do not.
        const handlerUpdate: Record<string, unknown> = {
          totalEarnings: FieldValue.increment(HANDLER_EARNINGS),
          pendingEarnings: FieldValue.increment(HANDLER_EARNINGS),
          completedInspections: FieldValue.increment(1),
        };
        if (handlerIsAgent) {
          handlerUpdate.totalInspections = FieldValue.increment(1);
        }

        tx.update(handlerRef, handlerUpdate);
        tx.update(inspectionRef, {
          earningsCredited: true,
          earningsCreditedAt: FieldValue.serverTimestamp(),
          earningsAmount: HANDLER_EARNINGS,
        });
      });

      logger.info("Inspection earnings credited", {
        requestId,
        handlerId,
        handlerIsAgent,
        amount: HANDLER_EARNINGS,
      });
    } catch (err) {
      // Don't throw — we don't want the trigger to retry indefinitely on
      // permanent errors. Logged for admin investigation.
      logger.error("Failed to credit inspection earnings", {
        requestId,
        handlerId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },
)
;
