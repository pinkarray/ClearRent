/**
 * Server-authoritative rental-interest creation (closes HANDOVER H2).
 *
 * The client used to compute paymentAmount / rentAmount / agentFee and write
 * the rental_interests document itself. Firestore rules could freeze those
 * figures AFTER create but had no way to validate them, so a tampered client
 * could mint an interest claiming ₦100 against a ₦1.2m tenancy — and the rent
 * payment then charged whatever that record said.
 *
 * Creation now happens here, derived from the property and the pricing config,
 * and the client `create` on rental_interests is denied by rule. Because the
 * figures are captured at interest time and immutable afterwards, they remain
 * the stable contract the tenant was shown even if the property's rent later
 * changes (approveRentReview / approveImmediateRentChange).
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {getPricing} from "./pricing";

interface CreateRentalInterestInput {
  inspectionRequestId?: unknown;
}

export const createRentalInterest = onCall(
  {timeoutSeconds: 30, enforceAppCheck: true},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;

    const data = request.data as CreateRentalInterestInput;
    const inspectionRequestId = data.inspectionRequestId;
    if (
      typeof inspectionRequestId !== "string" ||
      inspectionRequestId.trim().length === 0
    ) {
      throw new HttpsError(
        "invalid-argument",
        "inspectionRequestId must be a non-empty string.",
      );
    }

    const db = getFirestore();

    // Idempotent: one interest per inspection. The old client path did the
    // same check, and a double-tap must not mint a second interest.
    const existing = await db
      .collection("rental_interests")
      .where("inspectionRequestId", "==", inspectionRequestId)
      .limit(1)
      .get();
    if (!existing.empty) {
      return {interestId: existing.docs[0].id, created: false};
    }

    const inspSnap = await db
      .collection("inspection_requests")
      .doc(inspectionRequestId)
      .get();
    const insp = inspSnap.data();
    if (!insp) {
      throw new HttpsError("not-found", "Inspection request not found.");
    }

    if (insp.tenantId !== uid) {
      logger.warn("Rental interest attempted by non-tenant", {
        uid,
        inspectionRequestId,
        tenantId: insp.tenantId,
      });
      throw new HttpsError(
        "permission-denied",
        "Only the tenant on this inspection can express interest.",
      );
    }

    // Two gates: the inspection must be COMPLETED, and the tenant must have
    // RATED it before the deal can move forward. Rating first is the tenant's
    // confirmation that the visit genuinely happened and a record of the
    // handler's conduct — it's what backs the handler's inspection payment.
    // (Rating was previously optional here; requiring it is a deliberate
    // product change, not a revert to the old client-side behaviour.)
    if (insp.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "You can only express interest after the inspection is completed.",
      );
    }
    if (insp.tenantRated !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Please rate your inspection before expressing interest.",
      );
    }

    const propSnap = await db
      .collection("properties")
      .doc(insp.propertyId)
      .get();
    const prop = propSnap.data();
    if (!prop) {
      throw new HttpsError("not-found", "Property not found.");
    }

    // The property must still be on the market. Occupancy is owned by the
    // occupancy-sync triggers (recomputePropertyOccupancy), so isAvailable /
    // currentTenantsCount here are server-authoritative — a tenant whose
    // inspected property was taken in the meantime must not be able to mint an
    // interest against it. Mirrors PropertyModel.isListable; a missing
    // isAvailable means available, matching the client's `?? true` default.
    const maxTenants =
      typeof prop.maxTenants === "number" ? prop.maxTenants : 1;
    const currentTenants =
      typeof prop.currentTenantsCount === "number" ?
        prop.currentTenantsCount :
        0;
    if (prop.isAvailable === false || currentTenants >= maxTenants) {
      logger.info("Rental interest rejected — property not listable", {
        uid,
        propertyId: insp.propertyId,
        isAvailable: prop.isAvailable,
        currentTenants,
        maxTenants,
      });
      throw new HttpsError(
        "failed-precondition",
        "This property is no longer available.",
      );
    }

    const pricing = await getPricing();
    const dealFee = pricing.dealFee;
    const rentAmount = typeof prop.rent === "number" ? prop.rent : 0;
    const agentFee = typeof prop.agentFee === "number" ? prop.agentFee : 0;
    if (!(rentAmount > 0)) {
      throw new HttpsError(
        "failed-precondition",
        "This property has no rent set. Contact support.",
      );
    }
    const hasAgent =
      typeof insp.agentId === "string" && insp.agentId.length > 0;

    // Same composition the client used: rent + agent fee + the tenant's share
    // of the deal-completion fee. The caution deposit is NOT collected here.
    const paymentAmount = rentAmount + agentFee + dealFee;

    // Each party pays a deal fee out of their OWN proceeds — the tenant on
    // top, the landlord out of the rent, the agent out of the agent fee. A fee
    // can therefore only be taken from money that party is actually owed.
    //
    // Unclamped, a rent (or agent fee) at or below the fee produced a NEGATIVE
    // payout, and `dealFee * parties` then booked the shortfall as revenue —
    // income never collected and impossible to realise, since nobody is ever
    // sent a negative transfer. It reconciled on paper only because the
    // negative payout cancelled the inflated take: one live rental claimed
    // ₦15,000 kept out of a ₦7,200 payment.
    const landlordDealFee = Math.min(dealFee, rentAmount);
    const agentDealFee = hasAgent ? Math.min(dealFee, agentFee) : 0;
    const landlordPayout = rentAmount - landlordDealFee;
    const agentPayout = hasAgent ? agentFee - agentDealFee : 0;

    // What is genuinely kept is whatever the tenant paid that is not being
    // sent on. Derived, never asserted, so it cannot exceed the money held.
    const clearrentEarnings = paymentAmount - landlordPayout - agentPayout;

    const ref = await db.collection("rental_interests").add({
      inspectionRequestId,
      propertyId: insp.propertyId,
      tenantId: insp.tenantId,
      landlordId: insp.landlordId,
      agentId: insp.agentId ?? null,
      propertyTitle: insp.propertyTitle ?? null,
      propertyImage: insp.propertyImage ?? null,
      propertyAddress: insp.propertyAddress ?? null,
      tenantName: insp.tenantName ?? null,
      landlordName: insp.landlordName ?? null,
      agentName: insp.agentName ?? null,
      // Pay-after-accept: the interest is created UNPAID and waits for the
      // landlord to pick one applicant. Payment is unlocked only once that
      // applicant is accepted AND the tenancy agreement is finalized, so only
      // the committed tenant ever pays (was "pending_payment", which charged
      // every applicant up front and refunded the losers).
      status: "pending_acceptance",
      paymentAmount,
      rentAmount,
      agentFee,
      tenantDealFee: dealFee,
      // The fee ACTUALLY taken, not the headline one, so admin can see when a
      // party's proceeds could not cover it.
      landlordDealFee,
      agentDealFee,
      landlordPayout,
      agentPayout,
      clearrentEarnings,
      paymentReceiptUrl: null,
      paymentUploadedAt: null,
      paymentVerifiedAt: null,
      paymentVerifiedBy: null,
      paymentRejectionReason: null,
      acceptedAt: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    logger.info("Rental interest created server-side", {
      interestId: ref.id,
      uid,
      propertyId: insp.propertyId,
      paymentAmount,
    });

    return {interestId: ref.id, created: true};
  },
);

interface RecordRentPaymentInput {
  rentalInterestId?: unknown;
  paymentReference?: unknown;
}

/**
 * Server-authoritative rent-payment recorder (pay-after-accept).
 *
 * The accepted tenant pays via Paystack (amount authorised by
 * resolveServerAmount, which already enforces accepted + agreement-finalized).
 * On checkout success the client calls THIS to record the paid state, rather
 * than writing the money-status fields itself — mirroring how createRentalInterest
 * took interest creation off the client. It flips the interest to "rent_paid"
 * and stamps the active_rental as rent-paid, in one transaction, only if the
 * caller is the tenant, the interest is "accepted", and the agreement is
 * "finalized". Idempotent: a replay after both docs are already paid is a no-op.
 *
 * Note: this does not itself re-verify the transaction with Paystack — the
 * HMAC-verified paystackWebhook remains the gateway-authoritative reconciler,
 * exactly as for the other client-confirmed payment types.
 */
export const recordRentPayment = onCall(
  {timeoutSeconds: 30, enforceAppCheck: true},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;

    const data = request.data as RecordRentPaymentInput;
    const interestId = data.rentalInterestId;
    if (typeof interestId !== "string" || interestId.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "rentalInterestId must be a non-empty string.",
      );
    }
    let paymentReference: string | null = null;
    if (
      typeof data.paymentReference === "string" &&
      data.paymentReference.trim().length > 0
    ) {
      paymentReference = data.paymentReference.trim();
    }

    const db = getFirestore();
    const interestRef = db.collection("rental_interests").doc(interestId);

    // The active_rental is created when the landlord accepts, so it exists by
    // the time payment is unlocked. Resolve its ref outside the transaction;
    // the transaction re-reads it for the state check + write.
    const rentalQuery = await db
      .collection("active_rentals")
      .where("rentalInterestId", "==", interestId)
      .limit(1)
      .get();
    if (rentalQuery.empty) {
      throw new HttpsError(
        "failed-precondition",
        "No rental record for this interest yet.",
      );
    }
    const rentalRef = rentalQuery.docs[0].ref;

    const result = await db.runTransaction(async (tx) => {
      const iSnap = await tx.get(interestRef);
      const i = iSnap.data();
      if (!i) {
        throw new HttpsError("not-found", "Rental interest not found.");
      }
      if (i.tenantId !== uid) {
        throw new HttpsError(
          "permission-denied",
          "Only the tenant on this rental can pay it.",
        );
      }
      const rSnap = await tx.get(rentalRef);
      const r = rSnap.data();
      if (!r) {
        throw new HttpsError("not-found", "Rental record not found.");
      }

      // Idempotent replay: both already marked paid → succeed without rewriting.
      if (i.status === "rent_paid" && r.rentPaymentStatus === "paid") {
        return {alreadyRecorded: true};
      }

      if (i.status !== "accepted") {
        throw new HttpsError(
          "failed-precondition",
          "This rental isn't ready for payment yet.",
        );
      }
      if (r.agreementStatus !== "finalized") {
        throw new HttpsError(
          "failed-precondition",
          "Finalize your tenancy agreement before paying rent.",
        );
      }

      const paidAmount =
        typeof i.paymentAmount === "number" ? i.paymentAmount : 0;

      tx.update(interestRef, {
        status: "rent_paid",
        isPaymentVerified: true,
        paymentReference,
        paymentVerifiedAt: FieldValue.serverTimestamp(),
        paidAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      tx.update(rentalRef, {
        rentPaymentStatus: "paid",
        totalPaid: paidAmount,
        rentPaidAt: FieldValue.serverTimestamp(),
        rentPaymentReference: paymentReference,
        // Pay-after-accept: the rental only becomes a real, occupying tenancy
        // once the rent is in. It was created as pending_payment (off-market,
        // not counted as occupying); flipping to active here is what fires the
        // occupancy recompute and takes the unit off the market.
        status: "active",
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Mark the tenant as actually having a rental now — deliberately NOT done
      // at acceptance any more, so an unpaid tenant never shows as a real
      // tenant on their dashboard.
      const propertyId =
        (r.propertyId as string | undefined) ??
        (i.propertyId as string | undefined) ??
        null;
      tx.update(db.collection("users").doc(uid), {
        hasActiveRental: true,
        currentPropertyId: propertyId,
        currentRentalId: rentalRef.id,
        rentStartDate: FieldValue.serverTimestamp(),
        rentEndDate: null,
        updatedAt: FieldValue.serverTimestamp(),
      });

      return {alreadyRecorded: false};
    });

    logger.info("Rent payment recorded server-side", {
      interestId,
      uid,
      alreadyRecorded: result.alreadyRecorded,
    });

    return {success: true, ...result};
  },
);
