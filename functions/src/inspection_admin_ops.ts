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
