/**
 * Payout cycles: money a tenant pays AFTER the first rent (a yearly renewal,
 * a furnished-stay extension) and that the landlord is owed.
 *
 * The payout fields on active_rentals (landlordPayout, landlordPayoutStatus,
 * the receipt and dispute fields) describe ONE payout. Renewals used to extend
 * the lease and write no payout at all, so a renewal's rent was collected and
 * nothing ever told an admin to send it on. Each later payment now opens a new
 * cycle on the same rental, so Rent Payouts, receipts and the landlord's
 * confirm/dispute work exactly as for the first rent:
 *
 *   - previous payout already sent: it moves to `payoutHistory` and the fields
 *     reset to a fresh pending payout of this amount (payoutCycle + 1);
 *   - previous payout still pending: this amount is added to it, so admin
 *     sends one transfer for both.
 */
import * as logger from "firebase-functions/logger";
import {
  getFirestore,
  FieldValue,
  type Transaction,
  type DocumentReference,
} from "firebase-admin/firestore";
import {writeAdminAlertOnce} from "./admin_alerts";

// Every per-payout field the receipt and dispute flow writes
// (payout_receipt.ts uses `${role}Payout...`). Cleared on a new cycle so the
// old payout's answer cannot stand in for the new one's.
const LANDLORD_PAYOUT_FIELDS = [
  "landlordPaidAt", "landlordPaidBy", "landlordPaymentReference",
  "landlordPaymentNote", "landlordPayoutReceipt", "landlordPayoutConfirmedAt",
  "landlordPayoutDisputedAt", "landlordPayoutDisputeReason",
  "landlordPayoutDisputeResolutionNote", "landlordPayoutDisputeResolvedAt",
  "landlordPayoutDisputeResolvedBy", "landlordPayoutProofPath",
];

export interface PayoutCycleInput {
  /** What the landlord is owed from this payment. */
  landlordAmount: number;
  /** What ClearRent keeps from it. */
  earned: number;
  /** The tenant's Paystack reference for this payment. */
  reference: string;
  kind: "renewal" | "extension";
}

/**
 * Adds this payment's payout to the rental, inside the caller's transaction.
 * @param {Transaction} tx The open transaction (rental already read).
 * @param {DocumentReference} ref The active_rentals doc.
 * @param {FirebaseFirestore.DocumentData} data Its data, read in `tx`.
 * @param {PayoutCycleInput} input The payment.
 * @return {number} The payout cycle this payment belongs to.
 */
export function openPayoutCycle(
  tx: Transaction,
  ref: DocumentReference,
  data: FirebaseFirestore.DocumentData,
  input: PayoutCycleInput,
): number {
  const cycle = typeof data.payoutCycle === "number" ? data.payoutCycle : 0;
  if (data.landlordPayoutStatus === "paid") {
    const history: Record<string, unknown> = {
      cycle,
      landlordPayout: data.landlordPayout ?? 0,
    };
    for (const f of LANDLORD_PAYOUT_FIELDS) {
      if (data[f] !== undefined) history[f] = data[f];
    }
    const update: Record<string, unknown> = {
      payoutHistory: FieldValue.arrayUnion(history),
      payoutCycle: cycle + 1,
      landlordPayout: input.landlordAmount,
      landlordPayoutStatus: "pending",
      // The ledger rows this cycle's payout settles (see markRentLandlord-
      // PayoutPaid). Reset: the old cycle's rows were settled with it.
      payoutCycleReferences: [input.reference],
      clearrentEarnings: FieldValue.increment(input.earned),
    };
    for (const f of LANDLORD_PAYOUT_FIELDS) update[f] = FieldValue.delete();
    tx.update(ref, update);
    return cycle + 1;
  }
  tx.update(ref, {
    landlordPayout: FieldValue.increment(input.landlordAmount),
    landlordPayoutStatus: "pending",
    payoutCycleReferences: FieldValue.arrayUnion(input.reference),
    clearrentEarnings: FieldValue.increment(input.earned),
  });
  return cycle;
}

/**
 * After commit: the landlord's earnings row and the admin's "payout due"
 * alert, as the first rent gets them. Best-effort: the money is recorded on
 * the rental already, and the rent_payment alert closes when it is paid.
 * @param {object} p The rental and payment.
 * @return {Promise<void>} Resolves when written.
 */
export async function announcePayoutCycle(p: {
  rentalId: string;
  input: PayoutCycleInput;
  landlordId: string;
  tenantId: string;
  tenantName: string;
  propertyId: string;
  propertyTitle: string;
}): Promise<void> {
  const {input} = p;
  try {
    await getFirestore().collection("transactions")
      .doc(`txn_${input.reference}_landlord`).create({
        reference: input.reference,
        type: input.kind,
        tenantId: p.tenantId,
        tenantName: p.tenantName,
        propertyId: p.propertyId,
        propertyTitle: p.propertyTitle,
        status: "pending",
        landlordId: p.landlordId,
        role: "landlord",
        amount: input.landlordAmount,
        createdAt: FieldValue.serverTimestamp(),
      });
  } catch (err) {
    const code = (err as {code?: number | string})?.code;
    if (code !== 6 && code !== "already-exists") {
      logger.error("Payout cycle ledger row failed", {
        rentalId: p.rentalId, error: String(err),
      });
    }
  }
  const what = input.kind === "renewal" ? "renewed" : "extended their stay at";
  try {
    await writeAdminAlertOnce(`payout_${p.rentalId}_${input.reference}`, {
      type: "rent_payment",
      severity: "warning",
      title: input.kind === "renewal" ?
        "Renewal paid - payout due" :
        "Stay extended - payout due",
      body: `${p.tenantName} ${what} ${p.propertyTitle}. ` +
        `₦${input.landlordAmount.toLocaleString("en-NG")} is owed to the ` +
        "landlord.",
      targetCollection: "active_rentals",
      targetId: p.rentalId,
      actors: {tenantId: p.tenantId, landlordId: p.landlordId},
      meta: {amount: input.landlordAmount, reference: input.reference},
    });
  } catch (err) {
    logger.error("Payout cycle alert failed", {
      rentalId: p.rentalId, error: String(err),
    });
  }
}
