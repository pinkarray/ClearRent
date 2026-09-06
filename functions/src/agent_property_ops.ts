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
    // Readiness gate (Phase 2): the handler reverts to the landlord, who must
    // re-vet before the property is bookable again.
    readyForInspections: false,
    readinessCheckedAt: FieldValue.delete(),
    readinessCheckedBy: FieldValue.delete(),
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

// ─────────────────────────────────────────────────────────────────────────────
// getPropertyTenantHistory: who has already been through this property.
//
// The agent's "matching tenants" list scores every verified tenant against a
// listing with no idea which of them already inspected it, already rented it,
// or already lived there and left. So the top of the list could be someone who
// saw the place last month and passed, pitched to as though they were new.
//
// Hiding them would be worse than the bug: an agent may well want to
// re-approach someone who inspected and did not commit. So this labels rather
// than filters, and the client decides what to show.
//
// It has to be a callable. `active_rentals` is readable only by its tenant,
// its landlord or an admin, and the LIST rule was deliberately narrowed (H1)
// after it let any signed-in account enumerate every rental in the system.
// `inspection_requests` is no better for this purpose: an agent only matches
// rows where `agentId == uid`, so a landlord-handled or previous-agent
// inspection is invisible to them. Widening either rule to serve a convenience
// label would trade a real access boundary for a chip.
// ─────────────────────────────────────────────────────────────────────────────

/** What a tenant's history with one property amounts to, strongest first. */
const HISTORY_RANK = [
  "renting_now",
  "moved_out",
  "inspected",
  "was_interested",
] as const;

type HistoryLabel = (typeof HISTORY_RANK)[number];

// A tenancy that is running. `expiring_soon` and `grace_locked` are the same
// live tenancy near its end date, and `moveout_pending` is still occupied:
// the tenant has given notice but the landlord has not confirmed handover.
const LIVING_THERE_STATUSES = [
  "active",
  "expiring_soon",
  "grace_locked",
  "moveout_pending",
];

// A tenancy that ran and finished. See the `terminated` note below: that one
// is ambiguous and is handled on its own.
const ENDED_STATUSES = ["ended_by_tenant", "ended_by_landlord"];

// An inspection that actually put the tenant in front of the property.
// `awaitingOutcome` counts: the visit happened, only the verdict is missing.
const VISITED_STATUSES = ["completed", "awaitingOutcome"];

// Booked, then it came to nothing. Worth surfacing separately from a real
// visit: the tenant showed interest in THIS property but never saw it, so an
// agent re-approaching them is offering something new rather than repeating
// something they already turned down.
const INTERESTED_STATUSES = [
  "cancelled",
  "declined",
  "declinedByAgent",
  "expiredUnapproved",
  "refunded",
];

/**
 * Keep only the strongest label a tenant has earned.
 *
 * A tenant can hold several at once (they inspected, then rented, then moved
 * out) and the agent only needs the one describing where they stand now.
 *
 * @param {Map<string, HistoryLabel>} into Accumulator, tenantId to label.
 * @param {string} tenantId The tenant.
 * @param {HistoryLabel} label The label just derived.
 * @return {void}
 */
function keepStrongest(
  into: Map<string, HistoryLabel>,
  tenantId: string,
  label: HistoryLabel,
): void {
  const existing = into.get(tenantId);
  if (existing === undefined ||
      HISTORY_RANK.indexOf(label) < HISTORY_RANK.indexOf(existing)) {
    into.set(tenantId, label);
  }
}

export const getPropertyTenantHistory = onCall(
  callableOptions,
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const data = (request.data ?? {}) as {propertyId?: string};
    const propertyId = (data.propertyId ?? "").trim();
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required.");
    }

    const db = getFirestore();
    const snap = await db.collection("properties").doc(propertyId).get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Property not found.");
    }
    // The assigned agent ONLY. Not the landlord (they have their own screens
    // and their own read access) and not any agent who happens to ask: this
    // returns who has been through someone's property, which is exactly the
    // enumeration the rules refuse.
    if (snap.get("assignedAgentId") !== uid) {
      throw new HttpsError(
        "permission-denied",
        "You are not the assigned agent for this property.",
      );
    }

    // Both are single-field equality queries, so neither needs a composite
    // index, and the status filtering happens in code for the same reason.
    const [inspections, rentals] = await Promise.all([
      db.collection("inspection_requests")
        .where("propertyId", "==", propertyId).get(),
      db.collection("active_rentals")
        .where("propertyId", "==", propertyId).get(),
    ]);

    const labels = new Map<string, HistoryLabel>();

    for (const doc of inspections.docs) {
      const tenantId = doc.get("tenantId");
      if (typeof tenantId !== "string" || tenantId.length === 0) continue;
      const status = doc.get("status");
      if (VISITED_STATUSES.includes(status)) {
        keepStrongest(labels, tenantId, "inspected");
      } else if (INTERESTED_STATUSES.includes(status)) {
        keepStrongest(labels, tenantId, "was_interested");
      }
      // Anything still in flight (pending, approved, awaiting payment) is
      // deliberately unlabelled: that tenant is mid-deal on this property and
      // the agent is already dealing with them.
    }

    for (const doc of rentals.docs) {
      const tenantId = doc.get("tenantId");
      if (typeof tenantId !== "string" || tenantId.length === 0) continue;
      const status = doc.get("status");
      if (LIVING_THERE_STATUSES.includes(status)) {
        keepStrongest(labels, tenantId, "renting_now");
      } else if (status === "terminated") {
        // "terminated" covers two opposite things. An early termination ended
        // a real tenancy; the strand sweep uses the SAME status to release a
        // slot whose accept lapsed unpaid, and that tenant never moved in, was
        // never charged, and never even held keys. Only the endReason tells
        // them apart, so nothing here may fall back to a catch-all.
        if (doc.get("endReason") !== "accept_lapsed_unpaid") {
          keepStrongest(labels, tenantId, "moved_out");
        }
      } else if (ENDED_STATUSES.includes(status)) {
        keepStrongest(labels, tenantId, "moved_out");
      }
      // "pending_payment" is a rental that has not begun: the slot is held
      // and the rent is unpaid, so it says nothing about having lived here.
      // Anything unrecognised is left alone too, rather than guessed at.
    }

    logger.info("Property tenant history served", {
      propertyId,
      uid,
      labelled: labels.size,
    });
    return {labels: Object.fromEntries(labels)};
  },
);
