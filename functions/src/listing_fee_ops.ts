// ─────────────────────────────────────────────────────────────────────────────
// listing_fee_ops.ts - the listing fee, owed and paid on the server.
//
// A landlord's first listing is free; every later one costs config/pricing
// `listing`. That rule used to live only in the Flutter add-property screen,
// which charged and then wrote `listingFeeStatus: 'paid'` itself. The web
// listing form never charged at all, and nothing on the server checked, so the
// fee was optional for anyone who listed on web.
//
// Now:
//   - `listingFeeOwed` is the one definition of "this listing still owes".
//   - `confirmListingFee` is the only writer of `listingFeeStatus: 'paid'`
//     (firestore.rules refuses it from clients), after Paystack confirms the
//     reference and the reference is spent once.
//   - adminReviewPropertyDoc refuses to verify or publish a listing that owes.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  Transaction,
} from "firebase-admin/firestore";
import {defineSecret} from "firebase-functions/params";
import {getPricing} from "./pricing";
import {verifyAndConsumeReference} from "./payment_verify";

const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

/**
 * Whether a listing still owes the listing fee: it is unpaid, not yet live,
 * and the landlord has a listing created before it. The first listing is the
 * free one.
 *
 * @param {string} propertyId The listing's id.
 * @param {FirebaseFirestore.DocumentData} property The listing's data.
 * @param {Transaction} tx Read inside this transaction when given.
 * @return {Promise<boolean>} True when the fee is owed.
 */
export async function listingFeeOwed(
  propertyId: string,
  property: FirebaseFirestore.DocumentData,
  tx?: Transaction,
): Promise<boolean> {
  if (property.listingFeeStatus === "paid") return false;
  // Already live: listed before the fee was enforced, not charged afterwards.
  if (property.isVerified === true) return false;
  const createdAt = property.createdAt;
  // Every listing is born with createdAt. One without it predates that and is
  // not charged retroactively.
  if (!(createdAt instanceof Timestamp)) return false;

  const q = getFirestore()
    .collection("properties")
    .where("landlordId", "==", property.landlordId);
  const siblings = tx ? await tx.get(q) : await q.get();
  return siblings.docs.some((d) => {
    if (d.id === propertyId) return false;
    const other = d.get("createdAt");
    return other instanceof Timestamp &&
      other.toMillis() < createdAt.toMillis();
  });
}

interface ConfirmListingFeeInput {
  propertyId?: unknown;
  paymentReference?: unknown;
}

export const confirmListingFee = onCall(
  {
    secrets: [paystackSecret],
    timeoutSeconds: 30,
    enforceAppCheck: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const data = request.data as ConfirmListingFeeInput;
    if (
      typeof data.propertyId !== "string" ||
      data.propertyId.trim().length === 0 ||
      typeof data.paymentReference !== "string" ||
      data.paymentReference.trim().length === 0
    ) {
      throw new HttpsError(
        "invalid-argument",
        "propertyId and paymentReference are required.",
      );
    }
    const propertyId = data.propertyId.trim();
    const paymentReference = data.paymentReference.trim();

    const db = getFirestore();
    const ref = db.collection("properties").doc(propertyId);
    const snap = await ref.get();
    const property = snap.data();
    if (!property) {
      throw new HttpsError("not-found", "Listing not found.");
    }
    if (property.landlordId !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only the landlord of this listing can pay its fee.",
      );
    }
    if (property.listingFeeStatus === "paid") {
      return {success: true, alreadyPaid: true};
    }

    const amount = await verifyAndConsumeReference({
      reference: paymentReference,
      secret: paystackSecret.value(),
      expectedAmount: (await getPricing()).listing,
      purpose: "listing",
      purposeId: propertyId,
      uid,
    });

    await ref.update({
      listingFeeStatus: "paid",
      listingFeePaymentReference: paymentReference,
      listingFeeAmount: amount,
      listingFeePaidAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    logger.info("Listing fee confirmed", {propertyId, uid, amount});
    return {success: true};
  },
);
