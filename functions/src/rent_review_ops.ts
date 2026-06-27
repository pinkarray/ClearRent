// ─────────────────────────────────────────────────────────────────────────────
// rent_review_ops.ts — admin decisions on landlord rent-review requests.
//
// A landlord files rent_review_requests/{id} on an occupied property to raise
// rent at the sitting tenant's NEXT renewal. Admin approves or rejects.
//
// On approval: the per-tenant staged figure (pendingRentForRenewal +
// pendingRentEffectiveDate) is written onto the reviewed active_rental ONLY.
// completeActiveRenewal reads+clears it at that tenant's renewal. The current
// rentAmount is NOT mutated here. The property-level "₦X → ₦Y on [date]" badge
// + increase-counter is a SEPARATE write (Block B-2), not done here.
//
// rent_review_requests/{id} contract (written by the mobile filing form):
//   landlordId, tenantId, rentalId   — strings
//   proposedRent                     — number (naira)
//   effectiveDate                    — Timestamp (landlord's chosen date)
//   reasonType                       — 'improvements' | 'market' | 'both'
//   justification                    — string
//   status                           — 'pending' | 'approved' | 'rejected'
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {
  assertAdmin,
  guardStatusTransition,
  writeAuditLog,
} from "./admin_helpers";
import {writeNotificationOnce} from "./notification_helpers";

// Lighter options than renewal_ops — no Paystack secret needed here.
const callableOptions = {
  enforceAppCheck: false,
  timeoutSeconds: 30,
};

const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 30 * 6;
const TENANT_RENTALS_ROUTE = "/tenant/my-rentals";
// Linked tenants have no active_rental, so /tenant/my-rentals is empty for
// them — their tenancy (and the revised agreement) lives on the home dashboard.
const TENANT_HOME_ROUTE = "/tenant/home";
// Occupied-context outcomes (scheduled approve, reject) deep-link to the
// landlord's active rentals, where the affected unit shows. A vacant/immediate
// change has no active rental, so it deep-links to that unit's property detail
// (route built with the propertyId at the call site).
const LANDLORD_RENTALS_ROUTE = "/landlord/rentals";

function formatNaira(amount: number): string {
  return `₦${amount.toLocaleString("en-NG")}`;
}

// ── approveRentReview ─────────────────────────────────────────────────────────
export const approveRentReview = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const requestId = (request.data?.requestId as string) ?? "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId is required.");
    }

    const db = getFirestore();
    const reviewRef = db.collection("rent_review_requests").doc(requestId);

    interface ApprovalResult {
      tenantId: string;
      landlordId: string;
      propertyTitle: string;
      proposedRent: number;
      reasonType: string;
      hasAgreement: boolean;
      isLink: boolean;
    }

    const result = await db.runTransaction<ApprovalResult>(async (tx) => {
      const reviewSnap = await tx.get(reviewRef);
      if (!reviewSnap.exists) {
        throw new HttpsError(
          "not-found",
          `rent_review_requests/${requestId} not found.`,
        );
      }
      const review = reviewSnap.data()!;
      guardStatusTransition(review.status, "pending", "status");

      const rentalId = (review.rentalId as string) ?? "";
      const proposedRent = (review.proposedRent as number) ?? 0;
      const effectiveDate = review.effectiveDate as Timestamp | undefined;
      if (!rentalId || proposedRent <= 0 || !effectiveDate) {
        throw new HttpsError(
          "failed-precondition",
          "Request is missing rentalId, proposedRent, or effectiveDate.",
        );
      }

      // The target tenancy is either an active_rental (inspection→payment path)
      // or a tenancy_link (landlord-link path). Resolve by existence — ids are
      // collection-unique. The link case carries through to
      // completeLinkedPromotion, which reads the same pendingRent* fields when
      // the link promotes to an active rental. (All reads before any writes —
      // Firestore transaction rule.)
      const activeRef = db.collection("active_rentals").doc(rentalId);
      const activeSnap = await tx.get(activeRef);
      const isLink = !activeSnap.exists;
      const targetRef = isLink
        ? db.collection("tenancy_links").doc(rentalId)
        : activeRef;
      const targetSnap = isLink ? await tx.get(targetRef) : activeSnap;
      if (!targetSnap.exists) {
        throw new HttpsError(
          "not-found",
          `No active_rental or tenancy_link found for ${rentalId}.`,
        );
      }
      const target = targetSnap.data()!;

      // 6-month notice gate (auto-reject). Approval ≈ notice time, so this
      // measures from now. Legacy links with no lease term ("never expires")
      // have no renewal to measure against — skip the gate for them.
      const leaseEndTs = target.leaseEndDate as Timestamp | undefined;
      if (leaseEndTs && leaseEndTs.toDate().getTime() - Date.now() < SIX_MONTHS_MS) {
        throw new HttpsError(
          "failed-precondition",
          "Too late for this cycle — the increase needs 6 months' notice " +
            "before the tenant's renewal. Refile earlier.",
        );
      }

      const revisedAgreementUrl =
        (review.revisedAgreementUrl as string | undefined) ?? "";

      // Stage the per-tenant figure. The current rent is NOT mutated here — it
      // applies at the tenant's renewal (completeActiveRenewal) or promotion
      // (completeLinkedPromotion).
      const targetUpdate: Record<string, unknown> = {
        pendingRentForRenewal: proposedRent,
        pendingRentEffectiveDate: effectiveDate,
        updatedAt: FieldValue.serverTimestamp(),
      };
      // D-2: attach the revised agreement. active_rentals run the full review
      // flow (pending_review); links just carry the URL, which
      // completeLinkedPromotion turns into a pending_review on promotion.
      if (revisedAgreementUrl) {
        targetUpdate.agreementUrl = revisedAgreementUrl;
        if (!isLink) {
          targetUpdate.agreementUploadedAt = FieldValue.serverTimestamp();
          targetUpdate.agreementStatus = "pending_review";
          targetUpdate.tenantDisputeReason = FieldValue.delete();
        }
      }
      tx.update(targetRef, targetUpdate);

      // New/future tenants pay the new rate immediately — bump the property's
      // asking rent. Sitting tenants are protected separately by the staged
      // pendingRent* above. (Replaces the old dead scheduledRent* fields, which
      // nothing read.)
      const propertyId =
        (review.propertyId as string | undefined) ??
        (target.propertyId as string | undefined);
      if (propertyId) {
        const propertyRef = db.collection("properties").doc(propertyId);
        tx.update(propertyRef, {
          rent: proposedRent,
          rentIncreaseCount: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }

      tx.update(reviewRef, {
        status: "approved",
        decidedBy: request.auth!.uid,
        decidedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      return {
        tenantId: (review.tenantId as string) ?? "",
        landlordId: (review.landlordId as string) ?? "",
        propertyTitle:
          (review.propertyTitle as string | undefined) ?? "your property",
        proposedRent,
        reasonType: (review.reasonType as string) ?? "market",
        hasAgreement: revisedAgreementUrl.length > 0,
        isLink,
      };
    });

    await writeAuditLog({
      actorId: request.auth!.uid,
      action: "approve_rent_review",
      targetCollection: "rent_review_requests",
      targetId: requestId,
      amount: result.proposedRent,
      paymentReference: "",
    });

    await writeNotificationOnce(
      `rent_review_${requestId}_approved_${result.tenantId}`,
      {
        userId: result.tenantId,
        title: "Rent review approved",
        body:
          `Your landlord's rent review was approved. At your next renewal ` +
          `the rent will be ${formatNaira(result.proposedRent)} ` +
          `(reason: ${result.reasonType}).` +
          (result.hasAgreement
            ? " A revised tenancy agreement is ready for you to review."
            : ""),
        payload: {
          route: result.isLink ? TENANT_HOME_ROUTE : TENANT_RENTALS_ROUTE,
          requestId,
        },
        type: "rent_review_approved",
      },
    );

    // Notify the LANDLORD too — they filed it and should know the outcome
    // regardless of which way it went.
    await writeNotificationOnce(
      `rent_review_${requestId}_approved_landlord_${result.landlordId}`,
      {
        userId: result.landlordId,
        title: "Rent review approved",
        body:
          `Your rent review for ${result.propertyTitle} was approved. ` +
          `The new rent of ${formatNaira(result.proposedRent)} takes effect ` +
          `at your tenant's next renewal.`,
        payload: {route: LANDLORD_RENTALS_ROUTE, requestId},
        type: "rent_review_approved",
      },
    );

    logger.info("Rent review approved", {requestId});
    return {success: true, requestId};
  },
);

// ── rejectRentReview ──────────────────────────────────────────────────────────
export const rejectRentReview = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const requestId = (request.data?.requestId as string) ?? "";
    const decisionReason = (request.data?.decisionReason as string) ?? "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId is required.");
    }

    const db = getFirestore();
    const reviewRef = db.collection("rent_review_requests").doc(requestId);

    interface RejectResult {
      landlordId: string;
      propertyTitle: string;
    }

    const result = await db.runTransaction<RejectResult>(async (tx) => {
      const reviewSnap = await tx.get(reviewRef);
      if (!reviewSnap.exists) {
        throw new HttpsError(
          "not-found",
          `rent_review_requests/${requestId} not found.`,
        );
      }
      const review = reviewSnap.data()!;
      guardStatusTransition(review.status, "pending", "status");

      tx.update(reviewRef, {
        status: "rejected",
        decidedBy: request.auth!.uid,
        decidedAt: FieldValue.serverTimestamp(),
        decisionReason,
        updatedAt: FieldValue.serverTimestamp(),
      });

      return {
        landlordId: (review.landlordId as string) ?? "",
        propertyTitle:
          (review.propertyTitle as string | undefined) ?? "your property",
      };
    });

    await writeAuditLog({
      actorId: request.auth!.uid,
      action: "reject_rent_review",
      targetCollection: "rent_review_requests",
      targetId: requestId,
      amount: 0,
      paymentReference: "",
    });

    // Notify the LANDLORD who filed the request — the tenant is intentionally
    // NOT told about a rejected increase (nothing changed on their tenancy).
    await writeNotificationOnce(
      `rent_review_${requestId}_rejected_${result.landlordId}`,
      {
        userId: result.landlordId,
        title: "Rent review not approved",
        body: decisionReason.length > 0
          ? `Your rent review for ${result.propertyTitle} was not approved: ` +
            decisionReason
          : `Your rent review for ${result.propertyTitle} was not approved.`,
        payload: {route: LANDLORD_RENTALS_ROUTE, requestId},
        type: "rent_review_rejected",
      },
    );

    logger.info("Rent review rejected", {requestId});
    return {success: true, requestId};
  },
);

// ── approveImmediateRentChange ────────────────────────────────────────────────
// Vacant-property rent change (error correction / re-pricing). Applies to
// property.rent IMMEDIATELY on approval. Server re-checks occupancy — a tenant
// may have moved in between filing and approval, in which case this MUST refuse
// and the landlord must use the scheduled review path instead.
export const approveImmediateRentChange = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const requestId = (request.data?.requestId as string) ?? "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId is required.");
    }

    const db = getFirestore();
    const reviewRef = db.collection("rent_review_requests").doc(requestId);

    // Read the request first to get propertyId for the occupancy queries.
    // (Transactions can't run collection queries, so the occupancy check
    // happens before the transaction — small TOCTOU window, acceptable for an
    // admin-gated action.)
    const preSnap = await reviewRef.get();
    if (!preSnap.exists) {
      throw new HttpsError(
        "not-found",
        `rent_review_requests/${requestId} not found.`,
      );
    }
    const pre = preSnap.data()!;
    if ((pre.changeType as string) !== "immediate") {
      throw new HttpsError(
        "failed-precondition",
        "This request is not an immediate rent change.",
      );
    }
    const propertyId = (pre.propertyId as string) ?? "";
    if (!propertyId) {
      throw new HttpsError(
        "failed-precondition",
        "Request is missing propertyId.",
      );
    }

    // Server-side occupancy re-check. Either an occupying active_rental OR a
    // confirmed tenancy_link means the property now has a sitting tenant.
    const occupyingStatuses = ["active", "expiring_soon", "grace_locked"];
    const rentalsSnap = await db
      .collection("active_rentals")
      .where("propertyId", "==", propertyId)
      .where("status", "in", occupyingStatuses)
      .limit(1)
      .get();
    const linksSnap = await db
      .collection("tenancy_links")
      .where("propertyId", "==", propertyId)
      .where("status", "==", "confirmed")
      .limit(1)
      .get();
    if (!rentalsSnap.empty || !linksSnap.empty) {
      throw new HttpsError(
        "failed-precondition",
        "Property now has a tenant — use the scheduled review path instead.",
      );
    }

    const proposedRent = await db.runTransaction<number>(async (tx) => {
      const reviewSnap = await tx.get(reviewRef);
      if (!reviewSnap.exists) {
        throw new HttpsError(
          "not-found",
          `rent_review_requests/${requestId} not found.`,
        );
      }
      const review = reviewSnap.data()!;
      guardStatusTransition(review.status, "pending", "status");

      const newRent = (review.proposedRent as number) ?? 0;
      if (newRent <= 0) {
        throw new HttpsError(
          "failed-precondition",
          "Request has an invalid proposedRent.",
        );
      }

      // Apply immediately to the property's stored rent.
      const propertyRef = db.collection("properties").doc(propertyId);
      tx.update(propertyRef, {
        rent: newRent,
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.update(reviewRef, {
        status: "approved",
        decidedBy: request.auth!.uid,
        decidedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      return newRent;
    });

    await writeAuditLog({
      actorId: request.auth!.uid,
      action: "approve_immediate_rent_change",
      targetCollection: "rent_review_requests",
      targetId: requestId,
      amount: proposedRent,
      paymentReference: "",
    });

    // Notify the landlord who filed it (no tenant on a vacant property).
    const landlordId = (pre.landlordId as string | undefined) ?? "";
    const propertyTitle =
      (pre.propertyTitle as string | undefined) ?? "your property";
    if (landlordId) {
      await writeNotificationOnce(
        `rent_review_${requestId}_immediate_approved_${landlordId}`,
        {
          userId: landlordId,
          title: "Rent change approved",
          body:
            `Your rent change for ${propertyTitle} was approved — the new ` +
            `rent of ${formatNaira(proposedRent)} is now live.`,
          payload: {route: `/landlord/property/${propertyId}`, requestId},
          type: "rent_review_approved",
        },
      );
    }

    logger.info("Immediate rent change approved", {requestId, propertyId});
    return {success: true, requestId};
  },
);