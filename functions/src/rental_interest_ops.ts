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

    // Mirrors the client gate that used to live in RentalInterestService.
    const rated = insp.tenantRated === true || insp.tenantRating != null;
    if (insp.status !== "completed" || !rated) {
      throw new HttpsError(
        "failed-precondition",
        "Inspection must be completed and rated first.",
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
    const landlordPayout = rentAmount - dealFee;
    const agentPayout = hasAgent ? agentFee - dealFee : 0;
    const clearrentEarnings = dealFee * (hasAgent ? 3 : 2);

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
      status: "pending_payment",
      paymentAmount,
      rentAmount,
      agentFee,
      tenantDealFee: dealFee,
      landlordDealFee: dealFee,
      agentDealFee: hasAgent ? dealFee : 0,
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
