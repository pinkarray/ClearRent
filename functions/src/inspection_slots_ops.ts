/**
 * Server-authoritative inspection slot availability.
 *
 * The tenant slot picker must exclude times the handler (agent or landlord)
 * is already booked for. It CAN'T do that client-side: a tenant isn't allowed
 * to list another handler's inspection_requests (that would expose other
 * tenants' bookings), so the client query was silently denied and every slot
 * looked free — letting a tenant book a taken slot, pay, and only then get
 * auto-declined by the rejectIfSlotConflict guard.
 *
 * This callable computes availability with the admin SDK (bypasses rules) and
 * returns only slot *strings* (no tenant identity), so double-booking is
 * prevented BEFORE payment without leaking anyone's schedule details.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import {getFirestore, Timestamp} from "firebase-admin/firestore";

// The CF runtime is UTC, but the app is Nigeria-only (WAT = UTC+1, no DST).
// Comparing calendar days with UTC getters slips across the UTC-midnight
// boundary — a Thursday-midnight-WAT request is Wednesday 23:00 UTC, so a
// Wednesday booking would wrongly collide with Thursday. Normalise every
// instant to its WAT wall-clock day (YYYY-MM-DD) before comparing.
const WAT_OFFSET_MS = 60 * 60 * 1000;
/**
 * @param {number} ms Epoch millis.
 * @return {string} The instant's WAT calendar day as YYYY-MM-DD.
 */
function watDayKey(ms: number): string {
  return new Date(ms + WAT_OFFSET_MS).toISOString().slice(0, 10);
}

// Statuses that "hold" a slot — mirror inspection_service._slotHoldingStatuses.
// Cancelled/declined/refunded/completed/expired do NOT hold a slot.
const SLOT_HOLDING_STATUSES = [
  "pendingPayment",
  "pendingVerification",
  "pending",
  "declinedByAgent", // still in the 12hr landlord-override window
  "approved",
];

interface SlotsInput {
  propertyId?: unknown;
  dateMillis?: unknown;
}

export const getAvailableInspectionSlots = onCall(
  {timeoutSeconds: 15, enforceAppCheck: false},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const data = request.data as SlotsInput;
    const propertyId = data?.propertyId;
    const dateMillis = data?.dateMillis;
    if (typeof propertyId !== "string" || propertyId.length === 0) {
      throw new HttpsError("invalid-argument", "propertyId is required.");
    }
    if (typeof dateMillis !== "number" || !Number.isFinite(dateMillis)) {
      throw new HttpsError("invalid-argument", "dateMillis is required.");
    }
    const requestedDayKey = watDayKey(dateMillis);

    const db = getFirestore();
    const propSnap = await db.collection("properties").doc(propertyId).get();
    if (!propSnap.exists) {
      throw new HttpsError("not-found", "Property not found.");
    }
    const prop = propSnap.data()!;

    const landlordSlots: string[] = Array.isArray(prop.inspectionTimeSlots) ?
      (prop.inspectionTimeSlots as string[]) :
      [];

    const isAgentHandled =
      prop.inspectionHandler === "agent" &&
      typeof prop.assignedAgentId === "string" &&
      prop.assignedAgentId.length > 0;
    const handlerField = isAgentHandled ? "agentId" : "landlordId";
    const handlerId = isAgentHandled ?
      (prop.assignedAgentId as string) :
      (prop.landlordId as string);

    // Eligible = landlord's offered slots, intersected with the agent's
    // available slots when agent-handled.
    let eligible = landlordSlots;
    if (isAgentHandled) {
      const agentSnap = await db
        .collection("users")
        .doc(prop.assignedAgentId as string)
        .get();
      const agentSlots: string[] =
        agentSnap.exists && Array.isArray(agentSnap.get("availableTimeSlots")) ?
          (agentSnap.get("availableTimeSlots") as string[]) :
          [];
      if (agentSlots.length > 0) {
        eligible = landlordSlots.filter((s) => agentSlots.includes(s));
      }
    }

    if (!handlerId) {
      // Malformed property — no handler. Return eligible unfiltered; the CF
      // conflict guard still backstops.
      return {slots: eligible};
    }

    // Taken slots for this handler on this date. Single-field equality query
    // (auto-indexed — can't fail on a missing composite index) + in-memory
    // status/date filter.
    const snap = await db
      .collection("inspection_requests")
      .where(handlerField, "==", handlerId)
      .get();

    const taken = new Set<string>();
    for (const doc of snap.docs) {
      const d = doc.data();
      if (!SLOT_HOLDING_STATUSES.includes(d.status)) continue;
      const ts = d.requestedDate as Timestamp | undefined;
      const slot = d.requestedTimeSlot as string | undefined;
      if (!ts || !slot) continue;
      if (watDayKey(ts.toMillis()) === requestedDayKey) {
        taken.add(slot);
      }
    }

    return {slots: eligible.filter((s) => !taken.has(s))};
  },
);
