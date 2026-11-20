/**
 * When a house is taken, nobody keeps paying to view it.
 *
 * The moment a property goes from available to not available (the rent is
 * paid, a landlord adds an off-app tenant, the landlord marks it occupied, or
 * an admin takes it down), every viewing on it that has not happened yet is
 * cancelled:
 *   - unpaid: cancelled, and the tenant is told the house has been rented;
 *   - paid: cancelled and marked refunded (onInspectionRefundTriggered pays
 *     back the handler's share; ClearRent's booking charge is not refunded),
 *     and the tenant gets a free-booking voucher for their next viewing;
 *   - already happened: untouched, but the tenant is told it has been rented.
 * awaitingOutcome (date passed, unclear whether it happened) stays with the
 * admin review queue.
 *
 * Free-booking vouchers (viewing_credits/{id}) are never money: a voucher only
 * waives ClearRent's own booking charge on one later viewing, so the handler
 * is still paid in full. initializePayment reserves one for the request being
 * paid; confirmInspectionPayment consumes it. A reservation older than an hour
 * that was never paid is free to be reserved again. A voucher-paid viewing
 * that is later refunded gets its voucher back (onInspectionRefundTriggered).
 */
import * as logger from "firebase-functions/logger";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

export const VOUCHER_MONTHS = 6;
const RESERVATION_MS = 60 * 60 * 1000;

/** Viewings that have not happened yet. */
const NOT_HAPPENED = new Set([
  "pendingPayment", "pendingVerification", "pending", "approved",
  "declinedByAgent", "expiredUnapproved", "rebookOffered",
]);

/**
 * Give a tenant a free-booking voucher. Idempotent on the source viewing.
 * @param {string} uid The tenant.
 * @param {string} sourceRequestId The viewing that earned it.
 * @return {Promise<void>}
 */
async function issueVoucher(uid: string, sourceRequestId: string) {
  const expires = new Date();
  expires.setMonth(expires.getMonth() + VOUCHER_MONTHS);
  try {
    await getFirestore().collection("viewing_credits")
      .doc(`taken_${sourceRequestId}`).create({
        uid,
        status: "available",
        reason: "property_taken",
        sourceRequestId,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(expires),
      });
  } catch (err) {
    const code = (err as {code?: number | string}).code;
    if (code !== 6 && code !== "already-exists") throw err;
  }
}

/**
 * Reserve a voucher for the viewing about to be paid, or return the one
 * already reserved for it.
 * @param {string} uid The tenant.
 * @param {string} requestId The inspection being paid.
 * @return {Promise<string | null>} The voucher id, or null if none.
 */
export async function reserveVoucher(
  uid: string,
  requestId: string,
): Promise<string | null> {
  const db = getFirestore();
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(
      db.collection("viewing_credits").where("uid", "==", uid));
    const now = Date.now();
    const live = snap.docs.filter((d) =>
      (d.get("expiresAt") as Timestamp).toMillis() > now);
    const mine = live.find((d) => d.get("status") === "reserved" &&
      d.get("reservedFor") === requestId);
    if (mine) return mine.id;
    const free = live.find((d) => d.get("status") === "available" ||
      (d.get("status") === "reserved" &&
        now - (d.get("reservedAt") as Timestamp).toMillis() > RESERVATION_MS));
    if (!free) return null;
    tx.update(free.ref, {
      status: "reserved",
      reservedFor: requestId,
      reservedAt: Timestamp.now(),
    });
    return free.id;
  });
}

/**
 * The voucher reserved for this viewing, if any.
 * @param {string} uid The tenant.
 * @param {string} requestId The inspection.
 * @return {Promise<FirebaseFirestore.DocumentReference | null>} Its ref.
 */
export async function reservedVoucherFor(
  uid: string,
  requestId: string,
): Promise<FirebaseFirestore.DocumentReference | null> {
  const snap = await getFirestore().collection("viewing_credits")
    .where("uid", "==", uid)
    .where("reservedFor", "==", requestId).get();
  const d = snap.docs.find((x) => x.get("status") === "reserved");
  return d ? d.ref : null;
}

/**
 * Put a used voucher back, when the viewing it paid for is refunded.
 * Only a voucher used on this very viewing comes back, so writing a voucher
 * id onto some other viewing achieves nothing.
 * @param {string} voucherId The voucher.
 * @param {string} requestId The viewing being refunded.
 * @return {Promise<void>}
 */
export async function reinstateVoucher(
  voucherId: string,
  requestId: string,
): Promise<void> {
  const ref = getFirestore().collection("viewing_credits").doc(voucherId);
  const snap = await ref.get();
  if (snap.get("status") !== "used" || snap.get("usedFor") !== requestId) {
    return;
  }
  await ref.update({
    status: "available",
    reservedFor: FieldValue.delete(),
    reservedAt: FieldValue.delete(),
    usedFor: FieldValue.delete(),
    usedAt: FieldValue.delete(),
    reinstatedAt: FieldValue.serverTimestamp(),
  });
}

export const onPropertyTaken = onDocumentUpdated(
  "properties/{propertyId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    if (before.isAvailable !== true || after.isAvailable !== false) return;

    const propertyId = event.params.propertyId;
    const title = (after.title as string | undefined) ?? "a house you viewed";
    const db = getFirestore();
    const [insps, rentals] = await Promise.all([
      db.collection("inspection_requests")
        .where("propertyId", "==", propertyId).get(),
      db.collection("active_rentals")
        .where("propertyId", "==", propertyId).get(),
    ]);
    // The people now living there are not told their own house was taken.
    const occupants = new Set(rentals.docs
      .filter((d) => ["active", "pending_payment"].includes(d.get("status")))
      .map((d) => d.get("tenantId") as string));

    let cancelled = 0;
    for (const doc of insps.docs) {
      const i = doc.data();
      const tenantId = i.tenantId as string | undefined;
      if (!tenantId || occupants.has(tenantId)) continue;

      if (i.status === "completed") {
        await writeNotificationOnce(`taken_${doc.id}_viewed`, {
          userId: tenantId,
          type: "property_taken",
          title: "This house has been rented",
          body: `${title}, which you viewed, has now been rented.`,
          payload: {route: "/tenant/inspections"},
        });
        continue;
      }
      if (!NOT_HAPPENED.has(i.status)) continue;

      const paid = i.paymentStatus === "paid";
      await doc.ref.update({
        status: "cancelled",
        cancelledBy: "system",
        cancellationReason: "The house was rented before your viewing.",
        propertyTaken: true,
        ...(paid ?
          {
            paymentStatus: "refunded",
            refundReason: "The house was rented before your viewing.",
          } :
          {}),
        updatedAt: FieldValue.serverTimestamp(),
      });
      cancelled++;

      if (paid) {
        // A voucher-paid viewing gets its own voucher back through the refund
        // trigger, so only a full-price one earns a new voucher.
        if (!i.viewingCreditId) await issueVoucher(tenantId, doc.id);
        const handlerFee = Number(i.totalFee ?? 0) - Number(i.clearrentFee ?? 0);
        await writeNotificationOnce(`taken_${doc.id}_tenant`, {
          userId: tenantId,
          type: "property_taken",
          title: "This house has been rented",
          body: `${title} was rented before your viewing, so it is ` +
            `cancelled. ₦${handlerFee.toLocaleString("en-NG")} is being ` +
            "refunded, and your next viewing's booking charge is free.",
          payload: {route: "/tenant/inspections"},
        });
        const agentId = i.agentId as string | undefined;
        if (agentId) {
          await writeNotificationOnce(`taken_${doc.id}_agent`, {
            userId: agentId,
            type: "property_taken",
            title: "Viewing cancelled: house rented",
            body: `Your viewing of ${title} for ${i.tenantName ?? "a tenant"}` +
              " is cancelled because the house has been rented.",
            payload: {route: "/agent/inspections"},
          });
        }
      } else {
        await writeNotificationOnce(`taken_${doc.id}_tenant`, {
          userId: tenantId,
          type: "property_taken",
          title: "This house has been rented",
          body: `${title} has been rented, so your viewing request is ` +
            "cancelled. You have not been charged.",
          payload: {route: "/tenant/inspections"},
        });
      }
    }
    if (cancelled > 0) {
      logger.info("Viewings released on a taken house", {
        propertyId, cancelled,
      });
    }
  },
);
