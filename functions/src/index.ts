/**
 * Cloud Functions for ClearRent notifications.
 *
 * Listens for new docs in the `notifications` collection and sends FCM
 * pushes to all of the recipient's stored tokens. Stale tokens are removed
 * lazily on send failure.
 */

import {setGlobalOptions} from "firebase-functions";
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";
import {onCall, onRequest, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {defineSecret} from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {createHash, createHmac, timingSafeEqual} from "node:crypto";
import {getAuth} from "firebase-admin/auth";
import {writeNotificationOnce} from "./notification_helpers";

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

export {nudgeInspectionParty} from "./inspection_admin_ops";

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
 * Slot-holding statuses — mirror of InspectionService._slotHoldingStatuses
 * on the Dart side. A request in any of these states reserves
 * its (handler, date, slot) tuple against new bookings.
 */
const SLOT_HOLDING_STATUSES = [
  "pendingPayment",
  "pendingVerification",
  "pending",
  "declinedByAgent",
  "approved",
];

/**
 * Server-side conflict guard. If the newly-created inspection
 * request collides with an already-active inspection for the same
 * handler on the same date+slot, decline+refund the new doc and
 * notify the tenant.
 *
 * The collision is resolved in favour of the EARLIER createdAt —
 * the new doc is the one rejected.
 *
 * Returns true if the new doc was conflict-declined (caller should
 * skip its own logic).
 */
async function rejectIfSlotConflict(
  requestId: string,
  data: FirebaseFirestore.DocumentData,
): Promise<boolean> {
  const db = getFirestore();
  const agentId = data.agentId as string | null | undefined;
  const landlordId = data.landlordId as string | undefined;
  const requestedTs = data.requestedDate as Timestamp | undefined;
  const requestedSlot = data.requestedTimeSlot as string | undefined;
  const tenantId = data.tenantId as string | undefined;
  const propertyTitle =
    (data.propertyTitle as string | undefined) ?? "the property";
  const propertyId = data.propertyId as string | undefined;
  const createdAt = data.createdAt as Timestamp | undefined;

  if (!requestedTs || !requestedSlot || !landlordId) {
    return false;
  }

  // Handler key — agent if agent-handled, else landlord.
  const handlerField = agentId ? "agentId" : "landlordId";
  const handlerId = agentId ?? landlordId;

  const requestedDate = requestedTs.toDate();
  const y = requestedDate.getFullYear();
  const m = requestedDate.getMonth();
  const d = requestedDate.getDate();

  const snap = await db
    .collection("inspection_requests")
    .where(handlerField, "==", handlerId)
    .where("status", "in", SLOT_HOLDING_STATUSES)
    .where("requestedTimeSlot", "==", requestedSlot)
    .get();

  // Look for any other doc on the same calendar day. Filter in
  // memory to avoid needing a Timestamp range index.
  let conflict: FirebaseFirestore.QueryDocumentSnapshot | null = null;
  for (const doc of snap.docs) {
    if (doc.id === requestId) continue;
    const other = doc.data();
    const otherTs = other.requestedDate as Timestamp | undefined;
    if (!otherTs) continue;
    const ot = otherTs.toDate();
    if (ot.getFullYear() !== y) continue;
    if (ot.getMonth() !== m) continue;
    if (ot.getDate() !== d) continue;

    // Tiebreaker: keep the earlier-created doc, reject the newer.
    // Fall back to lexicographic id if createdAt is missing/equal.
    const otherCreated = other.createdAt as Timestamp | undefined;
    const newerMillis = createdAt ? createdAt.toMillis() : 0;
    const otherMillis = otherCreated ? otherCreated.toMillis() : 0;
    if (otherMillis < newerMillis) {
      conflict = doc;
      break;
    }
    if (otherMillis === newerMillis && doc.id < requestId) {
      conflict = doc;
      break;
    }
  }

  if (!conflict) return false;

  logger.info("Slot conflict detected — declining new request", {
    requestId,
    conflictWith: conflict.id,
    handlerField,
    handlerId,
    requestedSlot,
  });

  const wasPaid = data.paymentStatus === "paid";
  const update: Record<string, unknown> = {
    status: "declined",
    declineSource: "system_slot_conflict",
    declineReason:
      "This slot was just taken by another tenant. " +
      "Please pick a different time.",
    declinedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (wasPaid) {
    update.paymentStatus = "refunded";
    update.refundedAt = FieldValue.serverTimestamp();
    update.refundReason = "Slot conflict — automatic refund";
  }
  await db.collection("inspection_requests").doc(requestId).update(update);

  // Notify the tenant directly. The existing update-trigger decline
  // notifications are skipped for system_slot_conflict (see the
  // guard in onInspectionRequestUpdated).
  if (tenantId) {
    await writeNotificationOnce(
      `req_${requestId}_slotConflict_${tenantId}`,
      {
        userId: tenantId,
        type: "inspection_declined",
        title: "Slot Just Taken",
        body:
          `Your inspection slot for ${propertyTitle} was just booked ` +
          "by someone else. Please pick a different time" +
          (wasPaid ? " — refund processing." : "."),
        payload: {
          route: "/tenant/inspections",
          initialTab: "2",
          param_requestId: requestId,
        },
      },
    );
  }

  // Activity feed entry mirroring _processRefund's activity write.
  if (tenantId) {
    await db.collection("activities").add({
      userId: tenantId,
      landlordId: tenantId,
      type: "inspection_declined",
      title: "Slot Conflict",
      message:
        `Your inspection request for ${propertyTitle} was declined ` +
        "because the slot had just been booked. " +
        (wasPaid ? "Your payment is being refunded." : ""),
      subtitle:
        `Your inspection request for ${propertyTitle} was declined ` +
        "because the slot had just been booked.",
      relatedId: requestId,
      propertyId: propertyId,
      isRead: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  }

  return true;
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

    // Slot conflict check — if the new request collides with an
    // existing booking on the same handler/date/slot, decline it
    // here and exit. Skip the handler notification below since the
    // request is being rejected. Wrapped so a query failure (e.g.
    // missing index) degrades to "no conflict protection" rather
    // than killing the handler notification below.
    let conflicted = false;
    try {
      conflicted = await rejectIfSlotConflict(requestId, data);
    } catch (err) {
      logger.error("Slot conflict check failed — proceeding", {
        requestId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
    if (conflicted) return;

    // Collusion-analytics capture (Phase 3): denormalize the handler identity
    // onto the inspection so admin analytics can group by the tenant↔handler
    // PAIR. The handler is the assigned agent, or the landlord when
    // self-handled. Stamped here (server-authoritative) before the
    // pendingPayment early-return so EVERY inspection carries it.
    const stampAgentId = data.agentId as string | null | undefined;
    const handlerId =
      (stampAgentId ?? (data.landlordId as string | undefined)) ?? null;
    const handlerType = stampAgentId ? "agent" : "landlord";
    if (handlerId && data.handlerId !== handlerId) {
      try {
        await snap.ref.update({handlerId, handlerType});
      } catch (e) {
        logger.error("Failed to stamp handlerId", {
          requestId,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }

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
 * Notify an agent when a landlord assigns them to handle a property's
 * inspections. Prompts them to reach out to the landlord, visit the unit, and
 * help get it viewing-ready. Fires only when assignedAgentId actually changes
 * to a (new) agent — ordinary edits that leave the agent unchanged are ignored.
 *
 * @param {object} event Firestore update event with before/after.
 * @return {Promise<void>}
 */
export const onPropertyAgentAssigned = onDocumentUpdated(
  "properties/{propertyId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const beforeAgent =
      (before.assignedAgentId as string | null | undefined) ?? null;
    const afterAgent =
      (after.assignedAgentId as string | null | undefined) ?? null;
    // Only on a newly-assigned (or changed) agent — not removals or no-ops.
    if (!afterAgent || afterAgent === beforeAgent) return;

    const propertyId = event.params.propertyId;
    const propertyTitle =
      (after.title as string | undefined) ?? "a property";

    await writeNotificationOnce(
      `property_${propertyId}_agent_${afterAgent}`,
      {
        userId: afterAgent,
        type: "agent_assigned",
        title: "You've been assigned a property",
        body:
          `You're now handling inspections for ${propertyTitle}. Visit the ` +
          `property and confirm it's ready — tenants can't book inspections ` +
          `until you do.`,
        payload: {route: `/agent/property/${propertyId}`},
      },
    );

    logger.info("Agent-assigned notification queued", {
      propertyId,
      agentId: afterAgent,
    });
  },
);

/**
 * Notify the landlord when a tenant reports an issue on their property.
 * The client writes the issue (and an in-app activity); this turns it into a
 * real push + deep-link to the landlord's issues for that property.
 *
 * @param {object} event Firestore create event for issues/{issueId}.
 * @return {Promise<void>}
 */
export const onIssueCreated = onDocumentCreated(
  "issues/{issueId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data();

    const landlordId = data.landlordId as string | undefined;
    if (!landlordId) {
      logger.warn("Issue has no landlordId", {issueId: event.params.issueId});
      return;
    }
    const tenantName = (data.tenantName as string | undefined) ?? "A tenant";
    const propertyTitle =
      (data.propertyTitle as string | undefined) ?? "your property";
    const category = (data.category as string | undefined) ?? "maintenance";
    const propertyId = (data.propertyId as string | undefined) ?? "";

    await writeNotificationOnce(
      `issue_${event.params.issueId}_${landlordId}`,
      {
        userId: landlordId,
        type: "issue_reported",
        title: "New issue reported",
        body: `${tenantName} reported a ${category} issue at ${propertyTitle}.`,
        payload: {
          route: "/landlord/issues",
          ...(propertyId ? {propertyId} : {}),
        },
      },
    );

    logger.info("Issue-reported notification queued", {
      issueId: event.params.issueId,
      landlordId,
    });
  },
);

/**
 * Push the right party when an issue's status changes — completes the
 * report → working → fixed → confirm/dispute loop with phone pings + deep
 * links. Landlord moves drive tenant notifications; the tenant's confirm /
 * dispute drives a landlord notification.
 *
 * @param {object} event Firestore update event for issues/{issueId}.
 * @return {Promise<void>}
 */
export const onIssueUpdated = onDocumentUpdated(
  "issues/{issueId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    const from = before.status as string | undefined;
    const to = after.status as string | undefined;
    if (!to || from === to) return; // only on a real status change

    const issueId = event.params.issueId;
    const tenantId = after.tenantId as string | undefined;
    const landlordId = after.landlordId as string | undefined;
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "your property";
    const category = (after.category as string | undefined) ?? "maintenance";
    const propertyId = (after.propertyId as string | undefined) ?? "";

    const tenantRoute = {route: "/tenant/issue-history"};
    const landlordRoute = {
      route: "/landlord/issues",
      ...(propertyId ? {propertyId} : {}),
    };

    let userId: string | undefined;
    let title = "";
    let body = "";
    let payload: Record<string, string> = {};

    if (to === "in_progress" && from === "pending_confirmation") {
      userId = landlordId; // tenant disputed the fix
      title = "Tenant says it's not fixed";
      body = `${propertyTitle}: the tenant reports the ${category} issue ` +
        "isn't resolved.";
      payload = {...landlordRoute, initialTab: "1"}; // → In Progress tab
    } else if (to === "in_progress") {
      userId = tenantId; // landlord acknowledged
      title = "Issue acknowledged";
      body = `Your landlord is working on the ${category} issue at ` +
        `${propertyTitle}.`;
      payload = tenantRoute;
    } else if (to === "pending_confirmation") {
      userId = tenantId; // landlord marked fixed → confirm/dispute
      title = "Fix ready — please confirm";
      body = `Your landlord says the ${category} issue at ${propertyTitle} ` +
        "is fixed. Confirm or dispute.";
      payload = tenantRoute;
    } else if (to === "resolved" && from === "pending_confirmation") {
      userId = landlordId; // tenant confirmed
      title = "Issue confirmed resolved";
      body = `The tenant confirmed the ${category} issue at ${propertyTitle} ` +
        "is fixed.";
      payload = {...landlordRoute, initialTab: "3"}; // → Resolved tab
    } else if (to === "resolved") {
      userId = tenantId;
      title = "Issue resolved";
      body = `Your ${category} issue at ${propertyTitle} was marked resolved.`;
      payload = tenantRoute;
    } else if (to === "open" && from === "resolved") {
      userId = tenantId; // landlord re-opened
      title = "Issue re-opened";
      body = `Your landlord re-opened the ${category} issue at ` +
        `${propertyTitle}.`;
      payload = tenantRoute;
    } else {
      return;
    }

    if (!userId) return;
    await writeNotificationOnce(
      `issue_${issueId}_${from}_${to}_${userId}`,
      {userId, type: "issue_updated", title, body, payload},
    );
    logger.info("Issue-updated notification queued", {issueId, from, to});
  },
);

/**
 * Notify the right party on an active_rental's agreement lifecycle and on a
 * tenancy ending. Previously these events were "notified" only via dead
 * client-side `activities` writes (keyed on a field nothing reads), so no push
 * ever went out. This makes the Cloud Function the single source.
 *
 * Covers: agreement ready-for-review (→ tenant), accepted (→ landlord),
 * disputed (→ landlord), finalized (→ tenant); rental ended by tenant
 * (→ landlord), ended by landlord (→ tenant); tenant contests an end
 * (→ landlord). Dedup IDs include the doc's `updatedAt` revision so a real
 * re-cycle (e.g. dispute → re-upload → dispute again) still notifies, while a
 * retried trigger for the same write does not double-send.
 *
 * @param {object} event Firestore update event for active_rentals/{rentalId}.
 * @return {Promise<void>}
 */
export const onActiveRentalUpdated = onDocumentUpdated(
  "active_rentals/{rentalId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const rentalId = event.params.rentalId;
    const tenantId = after.tenantId as string | undefined;
    const landlordId = after.landlordId as string | undefined;
    const tenantName =
      (after.tenantName as string | undefined) ?? "Your tenant";
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "your property";
    const propertyId = (after.propertyId as string | undefined) ?? "";
    // Stable per-write revision: idempotent across retries of the same event,
    // distinct across genuinely new writes (so re-cycles re-notify).
    const rev =
      after.updatedAt instanceof Timestamp ? after.updatedAt.toMillis() : 0;

    const tenantDocsRoute = {route: "/tenant/documents"};
    const tenantRentalsRoute = {route: "/tenant/my-rentals"};
    const landlordAgreementsRoute = {
      route: "/landlord/agreements",
      ...(propertyId ? {propertyId} : {}),
    };
    const landlordRentalsRoute = {
      route: "/landlord/rentals",
      ...(propertyId ? {propertyId} : {}),
    };

    // ── Agreement lifecycle (agreementStatus transitions) ──
    const agrBefore = before.agreementStatus as string | undefined;
    const agrAfter = after.agreementStatus as string | undefined;
    if (agrAfter && agrAfter !== agrBefore) {
      let uid: string | undefined;
      let type = "";
      let title = "";
      let body = "";
      let payload: Record<string, string> = {};
      if (agrAfter === "pending_review") {
        uid = tenantId;
        type = "agreement_uploaded";
        title = "Agreement ready for review";
        body =
          `Your landlord sent the tenancy agreement for ${propertyTitle}. ` +
          "Review it, then accept or raise concerns.";
        payload = tenantDocsRoute;
      } else if (agrAfter === "accepted") {
        uid = landlordId;
        type = "agreement_accepted";
        title = "Tenant accepted the agreement";
        body =
          `${tenantName} accepted the tenancy agreement for ` +
          `${propertyTitle}. You can now finalize it.`;
        payload = landlordAgreementsRoute;
      } else if (agrAfter === "disputed") {
        uid = landlordId;
        type = "agreement_disputed";
        const reason = (after.tenantDisputeReason as string | undefined) ?? "";
        title = "Tenant raised concerns";
        body =
          `${tenantName} raised concerns about the agreement for ` +
          `${propertyTitle}${reason ? `: "${reason}"` : "."}`;
        payload = landlordAgreementsRoute;
      } else if (agrAfter === "finalized") {
        uid = tenantId;
        type = "agreement_finalized";
        title = "Agreement finalized";
        body =
          `Your tenancy agreement for ${propertyTitle} is finalized. For ` +
          "full legal protection, consider stamping it at your local tax " +
          "office (LIRS/SIRS).";
        payload = tenantDocsRoute;
      }
      if (uid && title) {
        await writeNotificationOnce(
          `rental_${rentalId}_agr_${agrAfter}_${rev}`,
          {userId: uid, type, title, body, payload},
        );
      }
    } else {
      // Bare agreement upload (agreementUrl set without an agreementStatus —
      // e.g. confirming a rental with an attached agreement). Guarded by the
      // `else` so it can't double-fire with the pending_review branch above.
      const urlBefore = (before.agreementUrl as string | undefined) ?? "";
      const urlAfter = (after.agreementUrl as string | undefined) ?? "";
      if (!urlBefore && urlAfter && tenantId) {
        await writeNotificationOnce(
          `rental_${rentalId}_agrurl_${rev}`,
          {
            userId: tenantId,
            type: "agreement_uploaded",
            title: "Tenancy agreement ready",
            body:
              `Your landlord attached the tenancy agreement for ` +
              `${propertyTitle}. Open Documents to view it.`,
            payload: tenantDocsRoute,
          },
        );
      }
    }

    // ── Rental end (status transitions) ──
    const stBefore = before.status as string | undefined;
    const stAfter = after.status as string | undefined;
    if (stAfter && stAfter !== stBefore) {
      const endReason = (after.endReason as string | undefined) ?? "";
      if (stAfter === "ended_by_tenant" && landlordId) {
        await writeNotificationOnce(
          `rental_${rentalId}_ended_tenant_${rev}`,
          {
            userId: landlordId,
            type: "rental_ended",
            title: "Tenant moved out",
            body:
              `${tenantName} ended their tenancy for ${propertyTitle}` +
              `${endReason ? `: "${endReason}"` : "."}`,
            payload: landlordRentalsRoute,
          },
        );
      } else if (stAfter === "ended_by_landlord" && tenantId) {
        await writeNotificationOnce(
          `rental_${rentalId}_ended_landlord_${rev}`,
          {
            userId: tenantId,
            type: "rental_ended",
            title: "Tenancy ended by landlord",
            body:
              `Your landlord marked your tenancy for ${propertyTitle} as ` +
              `ended${endReason ? `: "${endReason}"` : "."} You can add your ` +
              "account of what happened.",
            payload: tenantRentalsRoute,
          },
        );
      }
    }

    // ── Tenant contests a landlord-ended rental ──
    if (
      after.tenantContested === true &&
      before.tenantContested !== true &&
      landlordId
    ) {
      const statement =
        (after.tenantContestStatement as string | undefined) ?? "";
      await writeNotificationOnce(
        `rental_${rentalId}_contested_${rev}`,
        {
          userId: landlordId,
          type: "rental_end_contested",
          title: "Tenant contested the tenancy end",
          body:
            `${tenantName} added their account of the ended tenancy for ` +
            `${propertyTitle}${statement ? `: "${statement}"` : "."}`,
          payload: landlordRentalsRoute,
        },
      );
    }

    logger.info("Active-rental notification check done", {rentalId});
  },
);

/**
 * Populate the landlord (and agent) earnings ledger when a completed rent
 * payment is recorded. The `transactions` collection powers the landlord
 * Earnings screen, but nothing ever wrote to it — so earnings always read
 * empty. Payout amounts are recomputed from the authoritative
 * `rental_interests` doc rather than trusting the client-written payment
 * fields. Deterministic doc IDs keep it idempotent if the trigger retries.
 *
 * Two rows per rent payment: a landlord row (carries `landlordId`, so the
 * Earnings screen's `where(landlordId == me)` reads it) and — when there's an
 * agent — an agent row (keyed by `agentId` only, so it never shows in the
 * landlord's earnings; readable by the agent per the transactions rules).
 *
 * @param {object} event Firestore create event for payments/{reference}.
 * @return {Promise<void>}
 */
export const onRentPaymentRecorded = onDocumentCreated(
  "payments/{reference}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const pay = snap.data();
    const reference = event.params.reference;

    // Only completed *rent* payments generate earnings rows.
    if (pay.type !== "rent" || pay.status !== "completed") return;

    const db = getFirestore();

    // SECURITY (H2): money and the identities that receive it are derived
    // ONLY from the authoritative rental_interest — NEVER from the
    // client-written payment doc. A tampered client can forge a `payments`
    // doc (type:rent, status:completed) with arbitrary landlordId/landlordPayout;
    // trusting those fields would mint a fabricated earnings row. So if the
    // payment carries no rentalInterestId, or the rental_interest is missing,
    // we write NO earnings rows rather than fall back to client figures.
    const riId = pay.rentalInterestId as string | undefined;
    if (!riId) {
      logger.warn("Rent payment has no rentalInterestId — no earnings written", {
        reference,
      });
      return;
    }
    const riSnap = await db.collection("rental_interests").doc(riId).get();
    if (!riSnap.exists) {
      logger.warn("rental_interest not found — no earnings written", {
        reference,
        riId,
      });
      return;
    }
    const ri = riSnap.data() as Record<string, unknown>;

    const landlordId = ri.landlordId as string | undefined;
    const agentId = ri.agentId as string | undefined;
    const tenantId = (ri.tenantId ?? "") as string;
    const tenantName = (ri.tenantName ?? "Your tenant") as string;
    const propertyId = (ri.propertyId ?? "") as string;
    const propertyTitle = (ri.propertyTitle ?? "your property") as string;
    const landlordPayout = Number(ri.landlordPayout ?? 0);
    const agentPayout = Number(ri.agentPayout ?? 0);

    const base = {
      reference,
      type: "rent",
      tenantId,
      tenantName,
      propertyId,
      propertyTitle,
      status: "completed",
    };

    const writeOnce = async (
      id: string,
      data: Record<string, unknown>,
    ): Promise<void> => {
      try {
        await db.collection("transactions").doc(id).create({
          ...base,
          ...data,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        const code = (err as {code?: number | string})?.code;
        if (code === 6 || code === "already-exists") {
          logger.info("Transaction already exists, skipping", {id});
          return;
        }
        throw err;
      }
    };

    if (landlordId && landlordPayout > 0) {
      await writeOnce(`txn_${reference}_landlord`, {
        landlordId,
        role: "landlord",
        amount: landlordPayout,
      });
    }

    if (agentId && agentPayout > 0) {
      await writeOnce(`txn_${reference}_agent`, {
        agentId,
        role: "agent",
        amount: agentPayout,
      });
    }

    logger.info("Rent earnings ledger written", {reference, landlordId, agentId});
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
/**
 * Notify the landlord the moment a tenant *pays to rent* (rental interest
 * reaches payment_verified). Before this, a paid applicant produced no push
 * and no Recent-Activities entry — the landlord only found it by digging into
 * Inspections → History. Sends a push (deep-linking to where they accept) and
 * writes a Recent-Activities row. Both are idempotent on trigger retries.
 *
 * @param {object} event Update event for rental_interests/{interestId}.
 * @return {Promise<void>}
 */
export const onRentalInterestPaid = onDocumentUpdated(
  "rental_interests/{interestId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only on the transition INTO payment_verified.
    if (before.status === "payment_verified") return;
    if (after.status !== "payment_verified") return;

    const interestId = event.params.interestId;
    const landlordId = after.landlordId as string | undefined;
    if (!landlordId) return;
    const tenantId = (after.tenantId as string | undefined) ?? "";
    const tenantName = (after.tenantName as string | undefined) ?? "A tenant";
    const propertyId = (after.propertyId as string | undefined) ?? "";
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "your property";

    // Push + bell inbox.
    await writeNotificationOnce(
      `interest_${interestId}_paid_${landlordId}`,
      {
        userId: landlordId,
        type: "rental_interest_paid",
        title: "Tenant paid to rent your property",
        body:
          `${tenantName} has paid to rent ${propertyTitle}. ` +
          "Review and accept them as your tenant.",
        payload: {
          route: "/landlord/inspections",
          initialTab: "2",
          ...(propertyId ? {propertyId} : {}),
        },
      },
    );

    // Recent-Activities feed (read by the landlordId field). Deterministic ID
    // so a retry doesn't create a duplicate row. Uses the `payment` type for a
    // money icon / green accent.
    try {
      await getFirestore()
        .collection("activities")
        .doc(`interest_${interestId}_paid`)
        .create({
          landlordId,
          type: "payment",
          title: "New tenant paid to rent",
          subtitle:
            `${tenantName} paid to rent ${propertyTitle}. ` +
            "Accept them in Inspections → History.",
          propertyId,
          actorId: tenantId,
          actorName: tenantName,
          isRead: false,
          createdAt: FieldValue.serverTimestamp(),
        });
    } catch (err) {
      const code = (err as {code?: number | string})?.code;
      if (code !== 6 && code !== "already-exists") {
        logger.warn("Failed to write rental-interest activity", {interestId});
      }
    }

    logger.info("Rental-interest-paid notification queued", {
      interestId,
      landlordId,
    });
  },
);

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

    // ── Inspection-day arrival pushes ──
    // The client flips these flags on the doc (and writes the in-app activity);
    // turn each false→true transition into an FCM push so the other party is
    // alerted in real time. Deduped by a deterministic id per transition.
    const flipped = (k: string): boolean =>
      before[k] !== true && after[k] === true;
    const handlerId = agentId ?? landlordId;
    const handlerRoute = agentId ? agentRoute : landlordRoute;
    const handlerName = agentId ? agentName : landlordName;
    const arrivalPayload = (route: string) => ({
      route,
      initialTab: "1",
      param_requestId: requestId,
    });

    if (flipped("tenantOnWay") && handlerId) {
      await writeNotificationOnce(
        `insp_${requestId}_tenant_onway_${handlerId}`,
        {
          userId: handlerId,
          type: "inspection_arrival",
          title: "Tenant on the way",
          body: `${tenantName} is on the way to ${propertyTitle} for the inspection.`,
          payload: arrivalPayload(handlerRoute),
        },
      );
    }
    if (flipped("tenantArrived") && handlerId) {
      await writeNotificationOnce(
        `insp_${requestId}_tenant_arrived_${handlerId}`,
        {
          userId: handlerId,
          type: "inspection_arrival",
          title: "Tenant has arrived",
          body: `${tenantName} has arrived at ${propertyTitle} for the inspection.`,
          payload: arrivalPayload(handlerRoute),
        },
      );
    }
    if (flipped("handlerOnWay") && tenantId) {
      await writeNotificationOnce(
        `insp_${requestId}_handler_onway_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_arrival",
          title: "Handler on the way",
          body: `${handlerName} is on the way to ${propertyTitle} for your inspection.`,
          payload: arrivalPayload(tenantRoute),
        },
      );
    }
    if (flipped("handlerArrived") && tenantId) {
      await writeNotificationOnce(
        `insp_${requestId}_handler_arrived_${tenantId}`,
        {
          userId: tenantId,
          type: "inspection_arrival",
          title: "Handler has arrived",
          body: `${handlerName} has arrived at ${propertyTitle} for your inspection.`,
          payload: arrivalPayload(tenantRoute),
        },
      );
    }

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
    // Tenant gets pushed. Skipped when the decline came from the
    // server-side slot-conflict guard — that path emits its own
    // tenant notification with accurate wording.
    if (
      statusChanged &&
      beforeStatus === "pending" &&
      afterStatus === "declined" &&
      tenantId &&
      after.declineSource !== "system_slot_conflict"
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
      const agentHandled = !!agentId;
      const recipients: string[] = [];
      if (agentHandled) {
        recipients.push(agentId as string);
        if (landlordId) recipients.push(landlordId);
      } else if (landlordId) {
        recipients.push(landlordId);
      }
      for (const rid of recipients) {
        // The party who actually met the tenant (the agent when agent-handled,
        // otherwise the landlord) gets the "complete the inspection" prompt.
        // On an agent-handled inspection the landlord wasn't there, so they get
        // an accurate FYI instead of the wrong "confirms meeting you".
        const isLandlordFyi = agentHandled && rid === landlordId;
        const route = rid === agentId ? agentRoute : landlordRoute;
        await writeNotificationOnce(
          `req_${requestId}_met_${rid}`,
          {
            userId: rid,
            type: "inspection_met",
            title: isLandlordFyi
              ? "Inspection Underway"
              : "Tenant Confirmed Meeting",
            body: isLandlordFyi
              ? `${tenantName} has met ${agentName} for the inspection at ` +
                `${propertyTitle}.`
              : `${tenantName} confirms meeting you. ` +
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
    // M4: enforced — the Flutter app sends Play Integrity App Check tokens.
    enforceAppCheck: true,
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
        // Paystack rate-limits /bank/resolve per integration. Surface 429
        // as resource-exhausted so the client says "slow down" rather than
        // "service unavailable" — the endpoint is up, just throttled.
        if (resp.status === 429) {
          logger.warn("Paystack resolve rate-limited (429)", {
            uid: request.auth.uid,
          });
          throw new HttpsError(
            "resource-exhausted",
            "Too many lookups in a short time. " +
              "Please wait a moment and try again.",
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
// PAYSTACK TRANSACTION PROXIES
//
// initializePayment / verifyPayment / refundPayment move the Paystack secret
// key off the mobile client (was hardcoded in paystack_service.dart) into
// Secret Manager. The client now calls these callables instead of hitting
// api.paystack.co directly with a Bearer secret.
//
// These intentionally preserve the exact request/response shape the old
// client code used, so PaystackService and its four call sites need no
// behavioural change. Server-authoritative writes to the `payments`
// collection are a separate, later hardening step — these functions do NOT
// write Firestore; the client still records payments for now.
// ─────────────────────────────────────────────────────────────────────────────

interface InitializePaymentInput {
  amount?: unknown; // Naira (not kobo) — matches old client contract.
  type?: unknown;
  metadata?: Record<string, unknown>;
}

const PAYSTACK_CALLBACK_URL = "https://verealtytech.com/payment/callback";

/**
 * Generate a payment reference server-side. Mirrors the old client format
 * CR_<TYPE>_<millis>_<8hex> so existing reference parsing/lookups still work.
 * @param {string} type Payment type (verification, inspection, listing, rent).
 * @return {string} The generated reference.
 */
function generatePaymentReference(type: string): string {
  const rand = createHash("sha256")
    .update(`${Date.now()}_${Math.random()}`)
    .digest("hex")
    .slice(0, 8);
  return `CR_${type.toUpperCase()}_${Date.now()}_${rand}`;
}

export const initializePayment = onCall(
  {
    secrets: [paystackSecret],
    timeoutSeconds: 30,
    // M4: enforced — the Flutter app sends Play Integrity App Check tokens.
    enforceAppCheck: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to start a payment.",
      );
    }
    const uid = request.auth.uid;
    const email = request.auth.token?.email as string | undefined;
    if (!email || email.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "No email on your account. Update your profile and try again.",
      );
    }

    const data = request.data as InitializePaymentInput;
    const amount = data.amount;
    const type = data.type;
    if (typeof amount !== "number" || !(amount > 0)) {
      throw new HttpsError(
        "invalid-argument",
        "amount must be a positive number (in Naira).",
      );
    }
    if (typeof type !== "string" || type.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "type must be a non-empty string.",
      );
    }

    const reference = generatePaymentReference(type);
    const amountInKobo = Math.round(amount * 100);

    // Reproduce the metadata block the client used to build, including the
    // custom_fields Paystack displays on the dashboard. Caller metadata is
    // merged last so per-payment fields (propertyId, accountType, etc.) are
    // preserved exactly as before.
    const callerMetadata =
      (data.metadata && typeof data.metadata === "object") ?
        data.metadata :
        {};
    const fullMetadata = {
      userId: uid,
      paymentType: type,
      custom_fields: [
        {
          display_name: "Payment Type",
          variable_name: "payment_type",
          value: type,
        },
        {
          display_name: "User ID",
          variable_name: "user_id",
          value: uid,
        },
      ],
      ...callerMetadata,
    };

    try {
      const resp = await fetch(
        "https://api.paystack.co/transaction/initialize",
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${paystackSecret.value()}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            email,
            amount: amountInKobo,
            reference,
            currency: "NGN",
            metadata: fullMetadata,
            callback_url: PAYSTACK_CALLBACK_URL,
          }),
        },
      );

      const body = (await resp.json()) as {
        status?: boolean;
        message?: string;
        data?: {authorization_url?: string; access_code?: string};
      };

      if (resp.ok && body.status === true && body.data?.authorization_url) {
        return {
          authorizationUrl: body.data.authorization_url,
          accessCode: body.data.access_code ?? "",
          reference,
        };
      }

      logger.warn("Paystack initialize non-OK", {
        status: resp.status,
        message: body.message,
        uid,
      });
      throw new HttpsError(
        "internal",
        body.message ?? "Failed to initialize payment.",
      );
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      logger.error("Paystack initialize failed", {
        error: err instanceof Error ? err.message : String(err),
        uid,
      });
      throw new HttpsError(
        "internal",
        "Network error reaching Paystack. Please try again.",
      );
    }
  },
);

interface VerifyPaymentInput {
  reference?: unknown;
}

export const verifyPayment = onCall(
  {
    secrets: [paystackSecret],
    timeoutSeconds: 30,
    // M4: enforced — the Flutter app sends Play Integrity App Check tokens.
    enforceAppCheck: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to verify a payment.",
      );
    }
    const data = request.data as VerifyPaymentInput;
    const reference = data.reference;
    if (typeof reference !== "string" || reference.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "reference must be a non-empty string.",
      );
    }

    try {
      const resp = await fetch(
        "https://api.paystack.co/transaction/verify/" +
          encodeURIComponent(reference),
        {
          method: "GET",
          headers: {
            "Authorization": `Bearer ${paystackSecret.value()}`,
            "Content-Type": "application/json",
          },
        },
      );

      const body = (await resp.json()) as {
        status?: boolean;
        message?: string;
        data?: {
          status?: string;
          amount?: number;
          paid_at?: string | null;
          gateway_response?: string | null;
        };
      };

      if (resp.ok && body.status === true && body.data) {
        const tx = body.data;
        const txStatus = tx.status ?? "failed";
        const amountInKobo = typeof tx.amount === "number" ? tx.amount : 0;
        return {
          success: txStatus === "success",
          status: txStatus,
          reference,
          amountPaid: amountInKobo / 100,
          paidAt: tx.paid_at ?? null,
          gatewayResponse: tx.gateway_response ?? "",
        };
      }

      logger.warn("Paystack verify non-OK", {
        status: resp.status,
        message: body.message,
        uid: request.auth.uid,
      });
      return {
        success: false,
        status: "failed",
        reference,
        error: body.message ?? "Verification failed.",
      };
    } catch (err) {
      logger.error("Paystack verify failed", {
        error: err instanceof Error ? err.message : String(err),
        uid: request.auth.uid,
      });
      throw new HttpsError(
        "internal",
        "Network error during verification. Please try again.",
      );
    }
  },
);

interface RefundPaymentInput {
  reference?: unknown;
  reason?: unknown;
}

export const refundPayment = onCall(
  {
    secrets: [paystackSecret],
    timeoutSeconds: 30,
    // M4: enforced — the Flutter app sends Play Integrity App Check tokens.
    enforceAppCheck: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const data = request.data as RefundPaymentInput;
    const reference = data.reference;
    if (typeof reference !== "string" || reference.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "reference must be a non-empty string.",
      );
    }
    const reason =
      typeof data.reason === "string" && data.reason.length > 0 ?
        data.reason :
        "ClearRent refund";

    try {
      const resp = await fetch("https://api.paystack.co/refund", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${paystackSecret.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({transaction: reference, merchant_note: reason}),
      });
      const body = (await resp.json()) as {
        status?: boolean;
        message?: string;
      };

      if (resp.ok && body.status === true) {
        return {success: true};
      }
      logger.warn("Paystack refund non-OK", {
        status: resp.status,
        message: body.message,
        uid: request.auth.uid,
      });
      return {success: false, error: body.message ?? "Refund failed."};
    } catch (err) {
      logger.error("Paystack refund failed", {
        error: err instanceof Error ? err.message : String(err),
        uid: request.auth.uid,
      });
      throw new HttpsError(
        "internal",
        "Network error during refund. Please try again.",
      );
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// paystackWebhook (G6 — server-authoritative payment record)
//
// Closes the gap where every payment was CLIENT-recorded: if the app died,
// went offline, or was tampered with after a charge, the money moved but no
// record existed. Paystack POSTs each event here; we verify the signature and
// reconcile a server-authoritative `payments/{reference}` doc:
//   • record present  → stamp the gateway-authoritative amount/status and flag
//                        any mismatch against what the client wrote.
//   • record MISSING   → create it (source: "webhook") + needsReconciliation so
//                        admin can complete whatever downstream effect (the
//                        verification submit / inspection create) the client
//                        never got to.
//
// Signature: HMAC-SHA512 of the RAW request body with the Paystack secret key,
// compared to the `x-paystack-signature` header. This is the ONLY auth (App
// Check can't apply — the caller is Paystack, not our app), so it runs before
// any work and rejects anything that doesn't match.
//
// SETUP: register the deployed URL as the webhook in the Paystack dashboard
// (Settings → API Keys & Webhooks), for BOTH test and live modes. The
// PAYSTACK_SECRET_KEY secret must match the mode of the keys in use.
// ─────────────────────────────────────────────────────────────────────────────

interface PaystackChargeData {
  reference?: string;
  amount?: number; // kobo
  status?: string;
  paid_at?: string | null;
  metadata?: {userId?: string; paymentType?: string} & Record<string, unknown>;
  customer?: {email?: string};
}

export const paystackWebhook = onRequest(
  {secrets: [paystackSecret], timeoutSeconds: 30},
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("Method Not Allowed");
      return;
    }

    // Verify the HMAC-SHA512 signature over the raw body BEFORE trusting a byte.
    const signature = req.get("x-paystack-signature") ?? "";
    const raw = req.rawBody; // Buffer of the exact bytes Paystack signed
    const expected = createHmac("sha512", paystackSecret.value())
      .update(raw)
      .digest("hex");
    const sigBuf = Buffer.from(signature, "utf8");
    const expBuf = Buffer.from(expected, "utf8");
    if (
      sigBuf.length !== expBuf.length ||
      !timingSafeEqual(sigBuf, expBuf)
    ) {
      logger.warn("Paystack webhook: signature mismatch — rejected");
      res.status(401).send("Invalid signature");
      return;
    }

    const event = req.body as {event?: string; data?: PaystackChargeData};
    const eventType = event.event ?? "";
    const data = event.data ?? {};
    const reference = data.reference;

    // Ack anything we don't act on (Paystack retries non-2xx).
    if (eventType !== "charge.success" || !reference) {
      res.status(200).send("ignored");
      return;
    }

    try {
      await reconcilePaystackCharge(reference, data);
      res.status(200).send("ok");
    } catch (err) {
      logger.error("Paystack webhook reconcile failed", {
        reference,
        error: err instanceof Error ? err.message : String(err),
      });
      // 500 → Paystack retries; our handler is idempotent, so a retry is safe.
      res.status(500).send("error");
    }
  },
);

/**
 * Idempotently reconcile a successful charge into payments/{reference}.
 * @param {string} reference Paystack transaction reference (= payments doc id).
 * @param {PaystackChargeData} data The webhook event's `data` block.
 * @return {Promise<void>}
 */
async function reconcilePaystackCharge(
  reference: string,
  data: PaystackChargeData,
): Promise<void> {
  const db = getFirestore();
  const amountNaira =
    typeof data.amount === "number" ? data.amount / 100 : 0;
  const gatewayStatus = data.status ?? "success";
  const paidAt = data.paid_at ?? null;
  const meta = data.metadata ?? {};
  const userId = meta.userId ?? null;
  const paymentType = meta.paymentType ?? null;
  const email = data.customer?.email ?? null;

  const ref = db.collection("payments").doc(reference);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = FieldValue.serverTimestamp();

    // Gateway-authoritative fields — never sourced from the client.
    const authoritative = {
      reference,
      gatewayStatus,
      gatewayAmount: amountNaira,
      gatewayPaidAt: paidAt,
      webhookVerified: true,
      webhookEvent: "charge.success",
      webhookReceivedAt: now,
      updatedAt: now,
    };

    if (!snap.exists) {
      // The client never recorded this charge. Create the record so no real
      // payment goes untracked, and flag it for admin to finish the flow.
      tx.set(ref, {
        ...authoritative,
        userId,
        userEmail: email,
        type: paymentType,
        amount: amountNaira,
        status: "completed",
        source: "webhook",
        clientRecorded: false,
        needsReconciliation: true,
        createdAt: now,
      });
      logger.warn("Paystack webhook created a MISSING payment record", {
        reference,
        paymentType,
        userId,
      });
      return;
    }

    // Reconcile against what the client wrote; flag an amount discrepancy so a
    // tampered/underpaid client record is visible to admin.
    const existing = snap.data() ?? {};
    const clientAmount =
      typeof existing.amount === "number" ? existing.amount : null;
    const amountMismatch =
      clientAmount !== null && Math.abs(clientAmount - amountNaira) > 0.5;

    tx.set(
      ref,
      {
        ...authoritative,
        clientRecorded: true,
        amountMismatch,
        ...(amountMismatch ? {clientAmount} : {}),
      },
      {merge: true},
    );
    if (amountMismatch) {
      logger.warn("Paystack webhook: client/gateway amount mismatch", {
        reference,
        clientAmount,
        gatewayAmount: amountNaira,
      });
    }
  });
}

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
    const phoneLocal = normalizeNigerianPhone(rawPhone);
    if (phoneLocal === null) {
      throw new HttpsError(
        "invalid-argument",
        "phone is not a valid Nigerian mobile number.",
      );
    }
    // All users.phone values are stored in E.164 (enforced at every
    // write site via phone_utils.dart phoneToE164, and backfilled
    // via scripts/backfill-phone-e164.ts).
    const phoneE164 = "+234" + phoneLocal.slice(1);

    const ip = extractIp(request.rawRequest);
    const ipHash = sha256Hex(ip);
    let rlReason: string | null;
    try {
      rlReason = await checkRateLimit(ipHash, phoneLocal);
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
        .where("phone", "==", phoneE164)
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

/**
 * Daily lease-lifecycle sweep (08:00 Africa/Lagos).
 *
 * For both `active_rentals` and `tenancy_links`, this:
 *  1. Sends lease-end reminders at T-30, T-7 and T-1 days. Reminder notif IDs
 *     are deterministic (`lease_reminder_T{n}_{docId}`), so `writeNotificationOnce`
 *     dedups them — a given threshold fires exactly once even across daily runs.
 *  2. Flips active-ish docs whose `leaseEndDate` has passed to `grace_locked`
 *     (server is the source of truth for this transition) and sends a one-time
 *     `lease_ended_{docId}` notification.
 *
 * Scale note: reads all active docs daily (Approach 1). Fine at launch scale;
 * switch to leaseEndDate range queries + composite indexes at high volume.
 *
 * Docs with no `leaseEndDate` (legacy links) are skipped — they never expire.
 */
export const leaseLifecycleSweep = onSchedule(
  {schedule: "0 8 * * *", timeZone: "Africa/Lagos"},
  async () => {
    const db = getFirestore();
    const now = Date.now();
    const dayMs = 24 * 60 * 60 * 1000;

    // Reminder thresholds in days before lease end.
    const thresholds = [30, 7, 1];

    let remindersSent = 0;
    let locked = 0;

    /**
     * Process one collection's active-ish docs.
     * @param {string} collection Firestore collection name.
     * @param {string[]} activeStatuses Statuses considered "live" (lockable).
     * @param {boolean} isLinked Whether this is the tenancy_links collection.
     */
    async function sweepCollection(
      collection: string,
      activeStatuses: string[],
      isLinked: boolean,
    ): Promise<void> {
      const snap = await db
        .collection(collection)
        .where("status", "in", activeStatuses)
        .get();

      for (const doc of snap.docs) {
        const data = doc.data();
        const leaseEndTs = data.leaseEndDate as Timestamp | undefined;
        if (!leaseEndTs) continue; // legacy/no-term — never expires

        const leaseEndMs = leaseEndTs.toMillis();
        const tenantId = data.tenantId as string | undefined;
        if (!tenantId) continue;

        const propertyTitle =
          (data.propertyTitle as string | undefined) ?? "your rental";
        const daysLeft = Math.ceil((leaseEndMs - now) / dayMs);

        // ── Already lapsed → lock + one-time ended notice ──
        if (leaseEndMs <= now) {
          if (data.status !== "grace_locked") {
            await doc.ref.update({
              status: "grace_locked",
              updatedAt: FieldValue.serverTimestamp(),
            });
            locked++;
          }
          const wrote = await writeNotificationOnce(
            `lease_ended_${doc.id}`,
            {
              userId: tenantId,
              title: "Lease ended — action needed",
              body: isLinked ?
                `Your lease for ${propertyTitle} has ended. Pay rent to ` +
                  "continue, or move out." :
                `Your lease for ${propertyTitle} has ended. Renew to keep ` +
                  "your dashboard active.",
              payload: {
                type: "lease_ended",
                rentalId: doc.id,
                source: isLinked ? "linked" : "active",
              },
              type: "lease_ended",
            },
          );
          if (wrote) remindersSent++;
          continue;
        }

        // ── Upcoming → threshold reminders ──
        for (const t of thresholds) {
          // Fire when the doc is within this threshold's day (daysLeft === t).
          if (daysLeft === t) {
            const wrote = await writeNotificationOnce(
              `lease_reminder_T${t}_${doc.id}`,
              {
                userId: tenantId,
                title: t === 1 ?
                  "Lease ends tomorrow" :
                  `Lease ends in ${t} days`,
                body: isLinked ?
                  `Your lease for ${propertyTitle} ends in ${t} ` +
                    `day${t === 1 ? "" : "s"}. Pay rent to continue or plan ` +
                    "your move." :
                  `Your lease for ${propertyTitle} ends in ${t} ` +
                    `day${t === 1 ? "" : "s"}. Renew to avoid interruption.`,
                payload: {
                  type: "lease_reminder",
                  rentalId: doc.id,
                  daysLeft: String(t),
                  source: isLinked ? "linked" : "active",
                },
                type: "lease_reminder",
              },
            );
            if (wrote) remindersSent++;
          }
        }
      }
    }

    try {
      await sweepCollection(
        "active_rentals",
        ["active", "expiring_soon"],
        false,
      );
      await sweepCollection(
        "tenancy_links",
        ["confirmed", "expiring_soon"],
        true,
      );
      logger.info("leaseLifecycleSweep complete", {remindersSent, locked});
    } catch (err) {
      logger.error("leaseLifecycleSweep failed", {
        error: err instanceof Error ? err.message : String(err),
      });
      throw err;
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

// ─────────────────────────────────────────────────────────────────────────────
// Property occupancy sync (server-authoritative)
//
// currentTenantsCount and isAvailable are owned exclusively by these
// triggers. A property's occupancy = the number of currently-confirmed
// tenancy_links PLUS the number of active_rentals in an occupying state
// (active or expiring_soon). Either source changing recomputes the total.
//
// Recompute-from-source (not increment) makes it self-healing — it can't
// drift. Moving the write server-side also closes the category-2 permission
// gap: a tenant accepting a link can't write to the landlord's property doc
// directly, and now doesn't need to.
//
// A property can legitimately hold BOTH a rental tenant (inspection → paid
// rent) and a directly-linked pre-existing tenant, so both sources must be
// summed — neither may clobber the other.
// ─────────────────────────────────────────────────────────────────────────────

// active_rental statuses that occupy a slot. expired/terminated free it.
// grace_locked still occupies — the tenant may still be living there while
// they decide to renew or move out; the slot frees only on actual move-out.
const OCCUPYING_RENTAL_STATUSES = ["active", "expiring_soon", "grace_locked"];

/**
 * Recompute currentTenantsCount + isAvailable for one property from both
 * occupancy sources and write the result. Admin SDK — bypasses rules.
 *
 * @param {string} propertyId The property to recompute.
 * @return {Promise<void>}
 */
async function recomputePropertyOccupancy(propertyId: string): Promise<void> {
  const db = getFirestore();
  const propertyRef = db.collection("properties").doc(propertyId);

  const propertySnap = await propertyRef.get();
  if (!propertySnap.exists) {
    logger.warn("Property not found for occupancy recompute", {propertyId});
    return;
  }
  const maxTenants =
    (propertySnap.get("maxTenants") as number | undefined) ?? 1;

  // Count confirmed tenancy links.
  const linksSnap = await db
    .collection("tenancy_links")
    .where("propertyId", "==", propertyId)
    .where("status", "==", "confirmed")
    .get();

  // Count occupying active rentals.
  const rentalsSnap = await db
    .collection("active_rentals")
    .where("propertyId", "==", propertyId)
    .where("status", "in", OCCUPYING_RENTAL_STATUSES)
    .get();

  const total = linksSnap.size + rentalsSnap.size;

  const update: Record<string, unknown> = {
    currentTenantsCount: total,
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (total >= maxTenants) {
    update.isAvailable = false;
  } else if (total <= 0) {
    update.isAvailable = true;
  }
  // Partial occupancy (0 < total < max): leave isAvailable as-is, so a
  // landlord's manual "unavailable" toggle isn't overridden.

  await propertyRef.update(update);

  logger.info("Property occupancy recomputed", {
    propertyId,
    confirmedLinks: linksSnap.size,
    occupyingRentals: rentalsSnap.size,
    total,
    maxTenants,
  });
}

export const onTenancyLinkOccupancyChange = onDocumentUpdated(
  "tenancy_links/{linkId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const before = snap.before.data();
    const after = snap.after.data();

    // Only recompute when confirmed-ness changed.
    const wasConfirmed = before.status === "confirmed";
    const isConfirmed = after.status === "confirmed";
    if (wasConfirmed === isConfirmed) return;

    const propertyId = after.propertyId as string | undefined;
    if (!propertyId) {
      logger.warn("tenancy_link has no propertyId", {
        linkId: event.params.linkId,
      });
      return;
    }
    try {
      await recomputePropertyOccupancy(propertyId);
    } catch (err) {
      logger.error("Occupancy recompute failed (link change)", {
        propertyId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },
);

export const onActiveRentalCreatedOccupancy = onDocumentCreated(
  "active_rentals/{rentalId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const propertyId = snap.data().propertyId as string | undefined;
    if (!propertyId) return;
    try {
      await recomputePropertyOccupancy(propertyId);
    } catch (err) {
      logger.error("Occupancy recompute failed (rental create)", {
        propertyId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },
);

export const onActiveRentalStatusOccupancy = onDocumentUpdated(
  "active_rentals/{rentalId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const before = snap.before.data();
    const after = snap.after.data();

    // Only recompute when occupying-ness changed.
    const wasOccupying =
      OCCUPYING_RENTAL_STATUSES.includes(before.status as string);
    const isOccupying =
      OCCUPYING_RENTAL_STATUSES.includes(after.status as string);
    if (wasOccupying === isOccupying) return;

    const propertyId = after.propertyId as string | undefined;
    if (!propertyId) return;
    try {
      await recomputePropertyOccupancy(propertyId);
    } catch (err) {
      logger.error("Occupancy recompute failed (rental status change)", {
        propertyId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },
)

// ─────────────────────────────────────────────────────────────────────────────
// setVerificationExempt
//
// Grants/revokes the verificationExempt custom claim on a target user and
// mirrors it to their user doc. Exempt accounts bypass the email-verification
// nudge — intended ONLY for test accounts with non-deliverable emails.
// Caller must be superAdmin. Strip these before launch; logs every change.
// ─────────────────────────────────────────────────────────────────────────────

interface SetVerificationExemptInput {
  targetUid?: unknown;
  exempt?: unknown;
}

export const setVerificationExempt = onCall(
  {timeoutSeconds: 15, enforceAppCheck: false},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    if ((request.auth.token ?? {}).superAdmin !== true) {
      logger.warn("setVerificationExempt called by non-superAdmin", {
        callerUid: request.auth.uid,
      });
      throw new HttpsError(
        "permission-denied",
        "Only super admins can set verification exemptions.",
      );
    }

    const data = request.data as SetVerificationExemptInput;
    const targetUid = data.targetUid;
    const exempt = data.exempt;
    if (typeof targetUid !== "string" || targetUid.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument", "targetUid must be a non-empty string.");
    }
    if (typeof exempt !== "boolean") {
      throw new HttpsError("invalid-argument", "exempt must be a boolean.");
    }

    const auth = getAuth();
    const target = await auth.getUser(targetUid);
    const existing = (target.customClaims ?? {}) as Record<string, unknown>;

    let next: Record<string, unknown>;
    if (exempt) {
      next = {...existing, verificationExempt: true};
    } else {
      const {verificationExempt: _ve, ...rest} = existing;
      next = rest;
    }
    await auth.setCustomUserClaims(targetUid, next);

    const db = getFirestore();
    await db.collection("users").doc(targetUid).set(
      {verificationExempt: exempt, updatedAt: FieldValue.serverTimestamp()},
      {merge: true},
    );

    logger.warn("VERIFICATION EXEMPT CHANGED — strip before launch", {
      callerUid: request.auth.uid, targetUid, exempt,
    });

    return {success: true, targetUid, exempt};
  },
)
;
export {
  markInspectionAgentPayoutPaid,
  markRentLandlordPayoutPaid,
  markRentAgentCommissionPaid,
  adminForceFinalizeAgreement,
  markRefundPaid,
  onInspectionRefundTriggered,
  onRentalInterestAccepted,
} from "./admin_money_ops";

export {
  completeActiveRenewal,
  completeLinkedPromotion,
} from "./renewal_ops";
export {
  approveRentReview,
  rejectRentReview,
  approveImmediateRentChange,
} from "./rent_review_ops";

export {submitNin} from "./nin_ops";

export {deleteMyAccount} from "./account_ops";

export {getSignedAgreementUrl} from "./doc_access_ops";

export {agentUnassignFromProperty} from "./agent_property_ops";

export {inspectionLifecycleSweep} from "./inspection_lifecycle_ops";

export {rentalInterestStrandSweep} from "./rent_interest_ops";

export {
  adminReviewPropertyDoc,
  adminResolveInspection,
} from "./admin_review_ops";

export {onInspectionRated} from "./rating_ops";

export {getAvailableInspectionSlots} from "./inspection_slots_ops";

export {
  inspectionMorningReminders,
  inspectionSoonReminders,
} from "./inspection_reminders_ops";

export {onPropertyDeleted} from "./property_cleanup_ops";
