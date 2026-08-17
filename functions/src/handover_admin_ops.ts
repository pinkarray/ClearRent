/**
 * Admin-facing move-out handover operations.
 *
 * `nudgeHandoverParty` lets an admin prod whichever side is holding up a
 * handover. Until now a contested deposit produced a `warning` alert an admin
 * could only DISMISS: the property stays off the market, the two parties
 * disagree about whether money moved, and the dashboard offered no way to
 * reach either of them. Dismissing the alert changed nothing about the stall.
 *
 * Mirrors issue_admin_ops.ts deliberately, including its two decisions:
 *   - notifications are admin-SDK-only writes, so this must go server-side;
 *   - an auto-id create (not writeNotificationOnce) because an admin pressing
 *     "nudge" twice SHOULD send twice.
 *
 * The nudge is stamped onto the rental (`lastHandoverNudgedAt` / count) so the
 * next admin can see it has already been chased instead of piling on. Those
 * fields are written with the admin SDK, which bypasses rules — they are
 * deliberately NOT in the active_rentals client allowlist.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {assertAdmin, writeAuditLog} from "./admin_helpers";

// App Check off to match the other admin-web callables (the admin dashboard has
// none configured). The caller is still admin-gated by assertAdmin.
const callableOptions = {
  timeoutSeconds: 30,
  enforceAppCheck: false,
};

type NudgeTarget = "landlord" | "tenant";

interface NudgeInput {
  rentalId: string;
  target: NudgeTarget;
  /** Optional admin note appended to the canned reminder. */
  note: string;
}

/**
 * Validate + narrow the nudgeHandoverParty payload.
 * @param {unknown} data Raw request.data.
 * @return {NudgeInput} The validated rentalId, target and note.
 */
function validateInput(data: unknown): NudgeInput {
  const d = (data ?? {}) as Record<string, unknown>;
  const rentalId = d.rentalId;
  const target = d.target;
  const note = typeof d.note === "string" ? d.note.trim() : "";
  if (typeof rentalId !== "string" || rentalId.length === 0) {
    throw new HttpsError("invalid-argument", "rentalId is required");
  }
  if (target !== "landlord" && target !== "tenant") {
    throw new HttpsError(
      "invalid-argument",
      "target must be 'landlord' or 'tenant'",
    );
  }
  return {rentalId, target, note: note.slice(0, 300)};
}

/** Which stages are actually waiting on each party. */
const LANDLORD_STAGES = ["awaiting_condition", "awaiting_settlement"];
const TENANT_STAGES = ["awaiting_evidence", "awaiting_confirm"];

interface BuiltNudge {
  recipientId: string;
  title: string;
  body: string;
  payload: Record<string, string>;
}

/**
 * Work out who to chase on a handover and what to say, or why we cannot.
 *
 * A CONTESTED handover is the exception to the stage rules: the stage says
 * `awaiting_confirm` (the tenant's turn) but the thing actually outstanding is
 * the landlord proving the money moved, so both sides are reachable.
 *
 * @param {Record<string, unknown>} x The active_rental doc data.
 * @param {string} rentalId The rental doc id (deep-linked).
 * @param {NudgeTarget} target Which party to nudge.
 * @param {string} note Optional admin note appended to the reminder.
 * @return {BuiltNudge | {reason: string}} The notification, or a skip reason.
 */
function buildNudge(
  x: Record<string, unknown>,
  rentalId: string,
  target: NudgeTarget,
  note: string,
): BuiltNudge | {reason: string} {
  const stage = (x.handoverStage as string) ?? "";
  const propertyTitle = (x.propertyTitle as string) ?? "the property";
  const contested = x.tenantContested === true;

  if (stage.length === 0) {
    return {reason: "This tenancy has no handover in progress"};
  }
  if (stage === "closed") {
    return {reason: "This handover is already closed"};
  }
  // Outside a dispute, only chase the side whose turn it actually is —
  // otherwise the nudge reads as a demand on someone who is not blocking.
  if (!contested) {
    const waiting =
      target === "landlord" ? LANDLORD_STAGES : TENANT_STAGES;
    if (!waiting.includes(stage)) {
      return {
        reason: `The ${target} is not the one holding this up ` +
          `(stage: ${stage.replace(/_/g, " ")})`,
      };
    }
  }

  const recipientId =
    target === "landlord" ?
      ((x.landlordId as string) ?? "") :
      ((x.tenantId as string) ?? "");
  if (!recipientId) {
    return {reason: `No ${target} is attached to this tenancy`};
  }

  let title: string;
  let base: string;
  if (contested) {
    title = target === "landlord" ?
      "Your former tenant says the deposit has not arrived" :
      "About the deposit you reported";
    base = target === "landlord" ?
      `${propertyTitle} is off the market while this is open. Please send ` +
        "proof of the transfer, or settle it with your former tenant." :
      `We are looking into the caution deposit for ${propertyTitle}. ` +
        "Please check whether it has arrived since you reported it.";
  } else if (target === "landlord") {
    title = "Reminder: a move-out is waiting on you";
    base = stage === "awaiting_condition" ?
      `Please check the condition of ${propertyTitle} so the deposit can ` +
        "be settled." :
      `Please settle the caution deposit for ${propertyTitle}. The unit ` +
        "cannot be relisted until you do.";
  } else {
    title = "Reminder: your move-out needs one more step";
    base = stage === "awaiting_evidence" ?
      `Please record the condition you left ${propertyTitle} in — it is ` +
        "what a deduction has to be argued against." :
      `Please confirm whether your caution deposit for ${propertyTitle} ` +
        "arrived.";
  }

  return {
    recipientId,
    title,
    body: note ? `${base} — ${note}` : base,
    // Both parties land on the same handover screen; it decides what to show
    // from who is signed in, which is why there is one route here.
    payload: {route: `/handover/${rentalId}`, rentalId},
  };
}

export const nudgeHandoverParty = onCall(callableOptions, async (request) => {
  assertAdmin(request.auth);
  const adminUid = request.auth!.uid;
  const {rentalId, target, note} = validateInput(request.data);

  const db = getFirestore();
  const ref = db.collection("active_rentals").doc(rentalId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Tenancy not found");
  }
  const x = snap.data() as Record<string, unknown>;

  const built = buildNudge(x, rentalId, target, note);
  if ("reason" in built) {
    throw new HttpsError("failed-precondition", built.reason);
  }
  const {recipientId, title, body, payload} = built;

  await db.collection("notifications").add({
    userId: recipientId,
    type: "handover_nudge",
    title,
    body,
    payload,
    read: false,
    readAt: null,
    createdAt: FieldValue.serverTimestamp(),
  });

  // Not a stage change, so onActiveRentalUpdated's handover branches ignore it.
  await ref.update({
    lastHandoverNudgedAt: FieldValue.serverTimestamp(),
    lastHandoverNudgedTarget: target,
    lastHandoverNudgedBy: adminUid,
    handoverNudgeCount: FieldValue.increment(1),
  });

  await writeAuditLog({
    actorId: adminUid,
    action: `nudge_handover_${target}`,
    targetCollection: "active_rentals",
    targetId: rentalId,
    amount: 0,
    paymentReference: "",
    paymentNote: note ?
      `Admin nudged ${target} (${recipientId}): ${note}` :
      `Admin nudged ${target} (${recipientId})`,
  });

  logger.info("Handover nudge sent", {rentalId, target, recipientId});
  return {ok: true, recipientId};
});
