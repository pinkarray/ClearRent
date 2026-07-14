/**
 * Admin-facing inspection-day operations.
 *
 * `nudgeInspectionParty` lets an admin send an on-demand reminder push to
 * the tenant or the handler (agent, or the landlord on a self-handled
 * inspection) of an upcoming/awaiting inspection. It complements — does NOT
 * replace — the automatic reminders (`inspectionMorningReminders` 07:00,
 * `inspectionSoonReminders` hourly); this is the manual dimension when an
 * admin is watching the day's schedule and wants to prod one party.
 *
 * Notifications carry `create: if false` in firestore.rules — only the
 * admin SDK (this CF) can write them — so the nudge must go server-side.
 * Unlike the event-trigger notifications this uses an auto-id create (not
 * writeNotificationOnce): an admin pressing "nudge" twice SHOULD send twice.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {assertAdmin, writeAuditLog} from "./admin_helpers";

// App Check is left off to match the other admin-web callables (the admin
// dashboard has no App Check configured). Caller is still admin-gated.
const callableOptions = {
  timeoutSeconds: 30,
  enforceAppCheck: false,
};

type NudgeTarget = "tenant" | "handler";

interface NudgeInput {
  inspectionId: string;
  target: NudgeTarget;
}

function validateInput(data: unknown): NudgeInput {
  const d = (data ?? {}) as Record<string, unknown>;
  const inspectionId = d.inspectionId;
  const target = d.target;
  if (typeof inspectionId !== "string" || inspectionId.length === 0) {
    throw new HttpsError("invalid-argument", "inspectionId is required");
  }
  if (target !== "tenant" && target !== "handler") {
    throw new HttpsError(
      "invalid-argument",
      "target must be 'tenant' or 'handler'",
    );
  }
  return {inspectionId, target};
}

export const nudgeInspectionParty = onCall(callableOptions, async (request) => {
  assertAdmin(request.auth);
  const adminUid = request.auth!.uid;
  const {inspectionId, target} = validateInput(request.data);

  const db = getFirestore();
  const ref = db.collection("inspection_requests").doc(inspectionId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Inspection not found");
  }
  const x = snap.data() as Record<string, unknown>;

  const tenantId = (x.tenantId as string) ?? "";
  const agentId = (x.agentId as string) ?? "";
  const landlordId = (x.landlordId as string) ?? "";
  // Handler is the agent if agent-handled, else the landlord (self-handled).
  const handlerId = agentId || landlordId;
  const propertyTitle = (x.propertyTitle as string) ?? "your inspection";

  const recipientId = target === "tenant" ? tenantId : handlerId;
  if (!recipientId) {
    throw new HttpsError(
      "failed-precondition",
      `No ${target} is attached to this inspection`,
    );
  }

  // Deep-link each party to the screen where they act on the inspection.
  const route =
    target === "tenant" ?
      "/tenant/inspections" :
      agentId ?
        "/agent/inspections" :
        "/landlord/inspections";

  const title = "Reminder: upcoming inspection";
  const body =
    target === "tenant" ?
      `Please confirm you're attending the inspection at ${propertyTitle}.` :
      `Please confirm you're handling the inspection at ${propertyTitle}.`;

  await db.collection("notifications").add({
    userId: recipientId,
    type: "inspection_nudge",
    title,
    body,
    payload: {route, inspectionId},
    read: false,
    readAt: null,
    createdAt: FieldValue.serverTimestamp(),
  });

  await writeAuditLog({
    actorId: adminUid,
    action: `nudge_inspection_${target}`,
    targetCollection: "inspection_requests",
    targetId: inspectionId,
    amount: 0,
    paymentReference: "",
    paymentNote: `Admin nudged ${target} (${recipientId})`,
  });

  logger.info("Inspection nudge sent", {inspectionId, target, recipientId});
  return {ok: true};
});

// ── messageInspectionParties ─────────────────────────────────────────────────
// Admin sends a FREE-TEXT message to the tenant and/or handler of an
// inspection — the in-app half of "reach out about a dispute". Each message
// becomes a notification doc (→ FCM push + bell inbox) and is audit-logged.
// Distinct from nudge, which only sends a canned attendance reminder.

type MessageTarget = "tenant" | "handler" | "both";

interface MessageInput {
  inspectionId: string;
  target: MessageTarget;
  message: string;
}

/**
 * Validate + narrow the messageInspectionParties payload.
 * @param {unknown} data Raw request.data.
 * @return {MessageInput} The validated inspectionId, target and message.
 */
function validateMessageInput(data: unknown): MessageInput {
  const d = (data ?? {}) as Record<string, unknown>;
  const inspectionId = d.inspectionId;
  const target = d.target;
  const message = typeof d.message === "string" ? d.message.trim() : "";
  if (typeof inspectionId !== "string" || inspectionId.length === 0) {
    throw new HttpsError("invalid-argument", "inspectionId is required");
  }
  if (target !== "tenant" && target !== "handler" && target !== "both") {
    throw new HttpsError(
      "invalid-argument",
      "target must be 'tenant', 'handler' or 'both'",
    );
  }
  if (message.length === 0) {
    throw new HttpsError("invalid-argument", "message is required");
  }
  return {inspectionId, target, message: message.slice(0, 1000)};
}

export const messageInspectionParties = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const adminUid = request.auth!.uid;
    const {inspectionId, target, message} = validateMessageInput(request.data);

    const db = getFirestore();
    const ref = db.collection("inspection_requests").doc(inspectionId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Inspection not found");
    }
    const x = snap.data() as Record<string, unknown>;

    const tenantId = (x.tenantId as string) ?? "";
    const agentId = (x.agentId as string) ?? "";
    const landlordId = (x.landlordId as string) ?? "";
    const handlerId = agentId || landlordId;

    // Build the recipient list per target, deep-linking each to their own
    // inspections screen.
    const recipients: {id: string; route: string}[] = [];
    if (target === "tenant" || target === "both") {
      if (tenantId) {
        recipients.push({id: tenantId, route: "/tenant/inspections"});
      }
    }
    if (target === "handler" || target === "both") {
      const route = agentId ? "/agent/inspections" : "/landlord/inspections";
      if (handlerId) recipients.push({id: handlerId, route});
    }
    if (recipients.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "No recipient is attached to this inspection for that target",
      );
    }

    for (const r of recipients) {
      await db.collection("notifications").add({
        userId: r.id,
        type: "inspection_admin_message",
        title: "Message from ClearRent support",
        body: message,
        payload: {route: r.route, inspectionId},
        read: false,
        readAt: null,
        createdAt: FieldValue.serverTimestamp(),
      });
    }

    await writeAuditLog({
      actorId: adminUid,
      action: `message_inspection_${target}`,
      targetCollection: "inspection_requests",
      targetId: inspectionId,
      amount: 0,
      paymentReference: "",
      paymentNote: message.slice(0, 200),
    });

    logger.info("Inspection party message sent", {
      inspectionId,
      target,
      count: recipients.length,
    });
    return {ok: true, sent: recipients.length};
  },
);
