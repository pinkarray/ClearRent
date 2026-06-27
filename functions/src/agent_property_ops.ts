// ─────────────────────────────────────────────────────────────────────────────
// agent_property_ops.ts — agent ↔ property assignment lifecycle.
//
//   revertPropertyToSelf  — shared cleanup when an agent stops handling a
//     property (self-unassign OR account deletion): reverts the unit to
//     landlord-handled, PRESERVES the agent fee in `savedAgentFee` (zeroing
//     the live `agentFee` so the tenant isn't charged a commission with no
//     agent — the rent-payment flow treats agentFee>0 as "has agent"), and
//     notifies the landlord. The saved fee is restored client-side when a new
//     agent is assigned, so the landlord never re-enters it.
//
//   agentUnassignFromProperty — callable: an agent steps back from a property
//     they're assigned to, with a reason. Blocked if they have an in-flight
//     inspection on that property (don't strand a tenant mid-deal). Runs
//     server-side because the agent isn't the property owner (Firestore rules
//     only let the owner write the property).
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {
  getFirestore,
  FieldValue,
  DocumentReference,
  DocumentData,
} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

// Inspection states that represent a live obligation — an agent (or tenant /
// landlord) with one of these shouldn't vanish mid-flow.
export const ACTIVE_INSPECTION_STATUSES = [
  "pending",
  "pendingVerification",
  "pendingPayment",
  "approved",
];

// M4: enforced — the Flutter app sends Play Integrity App Check tokens.
const callableOptions = {enforceAppCheck: true, timeoutSeconds: 30};

/**
 * True if the agent has an in-flight inspection on the given property.
 * Fetches by propertyId (single-field, auto-indexed) and filters in code to
 * avoid a composite-index requirement.
 *
 * @param {string} agentId Agent uid.
 * @param {string} propertyId Property doc id.
 * @return {Promise<boolean>} Whether an active inspection exists.
 */
export async function agentHasActiveInspectionOnProperty(
  agentId: string,
  propertyId: string,
): Promise<boolean> {
  const db = getFirestore();
  const snap = await db
    .collection("inspection_requests")
    .where("propertyId", "==", propertyId)
    .get();
  return snap.docs.some(
    (d) =>
      d.get("agentId") === agentId &&
      ACTIVE_INSPECTION_STATUSES.includes(d.get("status")),
  );
}

/**
 * Revert one property from agent-handled to landlord-handled, preserving the
 * agent fee, and notify the landlord. Used by self-unassign and the
 * account-deletion cascade.
 *
 * @param {DocumentReference} propertyRef The property doc ref.
 * @param {DocumentData} property The property data.
 * @param {object} opts cause ('left' | 'deleted'), optional reason + agentName.
 * @return {Promise<void>}
 */
export async function revertPropertyToSelf(
  propertyRef: DocumentReference,
  property: DocumentData,
  opts: {cause: "left" | "deleted"; reason?: string; agentName?: string},
): Promise<void> {
  const landlordId = property.landlordId as string | undefined;
  const title = (property.title as string | undefined) ?? "your property";
  const currentFee = (property.agentFee as number | undefined) ?? 0;

  const update: Record<string, unknown> = {
    inspectionHandler: "self",
    assignedAgentId: null,
    assignedAgentName: null,
    assignedAgentPhone: null,
    agentFee: 0,
    updatedAt: FieldValue.serverTimestamp(),
  };
  // Preserve the fee so the landlord doesn't re-enter it on re-assignment.
  if (currentFee > 0) update.savedAgentFee = currentFee;
  await propertyRef.update(update);

  if (!landlordId) return;
  const agentName = opts.agentName ?? "Your agent";
  const reasonSuffix =
    opts.cause === "left" && opts.reason ? ` Reason: ${opts.reason}` : "";
  const lead =
    opts.cause === "left" ?
      `${agentName} stepped back from ${title}.` :
      `The agent handling ${title} left ClearRent.`;
  await writeNotificationOnce(
    `property_${propertyRef.id}_agent_removed_${Date.now()}`,
    {
      userId: landlordId,
      type: "agent_removed",
      title: "Agent removed from your property",
      body:
        `${lead} It's now self-handled and the agent fee is paused (saved ` +
        `for when you assign a new agent).${reasonSuffix}`,
      payload: {route: `/landlord/property/${propertyRef.id}`},
    },
  );
}

export const agentUnassignFromProperty = onCall(
  callableOptions,
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const data = (request.data ?? {}) as {propertyId?: string; reason?: string};
    const propertyId = (data.propertyId ?? "").trim();
    const reason = (data.reason ?? "").trim();
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required.");
    }
    if (!reason) {
      throw new HttpsError(
        "invalid-argument",
        "Please give a reason for stepping back.",
      );
    }

    const db = getFirestore();
    const propertyRef = db.collection("properties").doc(propertyId);
    const snap = await propertyRef.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Property not found.");
    }
    const property = snap.data()!;
    if (property.assignedAgentId !== uid) {
      throw new HttpsError(
        "permission-denied",
        "You are not the assigned agent for this property.",
      );
    }

    if (await agentHasActiveInspectionOnProperty(uid, propertyId)) {
      throw new HttpsError(
        "failed-precondition",
        "You have a pending or scheduled inspection on this property. " +
          "Complete or decline it before stepping back.",
      );
    }

    await revertPropertyToSelf(propertyRef, property, {
      cause: "left",
      reason,
      agentName: (property.assignedAgentName as string | undefined) ??
        "Your agent",
    });

    logger.info("Agent self-unassigned from property", {propertyId, uid});
    return {success: true};
  },
);
