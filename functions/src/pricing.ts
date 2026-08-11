/**
 * Canonical, server-held pricing.
 *
 * Fee amounts previously lived only in the mobile client, which caused two
 * problems:
 *   1. Changing a price required a Play Store release + review + user update.
 *   2. initializePayment trusted the amount the client sent, so a tampered
 *      client could charge itself ₦100 for verification. (The webhook flagged
 *      the mismatch, but only after the money moved.)
 *
 * The schedule now lives in Firestore at config/pricing — admin-writable, and
 * readable by the app for display — and the server derives what it actually
 * charges for fixed-price types.
 */

import * as logger from "firebase-functions/logger";
import {HttpsError} from "firebase-functions/v2/https";
import {getFirestore} from "firebase-admin/firestore";

/**
 * What a role pays to verify, first time versus every year after.
 *
 * Renewal is cheaper because it re-collects only the role proof, not identity
 * — NIN is permanent and is carried forward. The gap is the discount for
 * already being known to the platform.
 */
export interface RoleFee {
  initial: number;
  renewal: number;
}

export interface PricingConfig {
  verification: {tenant: RoleFee; landlord: RoleFee; agent: RoleFee};
  listing: number;
  inspection: {total: number; handler: number; platform: number};
  /** Deal-completion fee charged per party on a completed rental. */
  dealFee: number;
  /**
   * Lowest rent a property may be listed at.
   *
   * At or below `dealFee` the fee consumes the whole rent and the landlord
   * nets nothing — createRentalInterest clamps the split at zero rather than
   * letting it go negative, so the listing is not broken, just pointless.
   * Configurable (rather than derived from dealFee) because testing wants tiny
   * rents to keep card charges small while production wants a real floor.
   */
  minRent: number;
}

/**
 * Fallbacks used when config/pricing is missing or partial. These MUST mirror
 * the client constants (VerificationFees in verification_service.dart,
 * InspectionPricing in inspection_pricing.dart) so behaviour is identical
 * before the document is seeded.
 */
export const DEFAULT_PRICING: PricingConfig = {
  verification: {
    tenant: {initial: 5000, renewal: 3000},
    landlord: {initial: 15000, renewal: 12000},
    agent: {initial: 10000, renewal: 7000},
  },
  listing: 10000,
  inspection: {total: 10000, handler: 7000, platform: 3000},
  dealFee: 5000,
  minRent: 10000,
};

/**
 * Accepts either shape for a role's fee.
 *
 * The seeded config/pricing document holds a bare number per role, from before
 * initial and renewal were distinguished. Reading that number as BOTH prices
 * keeps behaviour identical until the document is rewritten, so deploying this
 * code cannot by itself change what anyone is charged.
 *
 * @param {unknown} value Raw value from the config document.
 * @param {RoleFee} fallback Default for this role.
 * @return {RoleFee} Normalised initial/renewal pair.
 */
function toRoleFee(value: unknown, fallback: RoleFee): RoleFee {
  if (typeof value === "number") return {initial: value, renewal: value};
  if (value && typeof value === "object") {
    const v = value as Partial<RoleFee>;
    return {
      initial: typeof v.initial === "number" ? v.initial : fallback.initial,
      renewal: typeof v.renewal === "number" ? v.renewal : fallback.renewal,
    };
  }
  return fallback;
}

/**
 * Read the pricing schedule, falling back per-field to DEFAULT_PRICING so a
 * missing or half-written document can never produce an undefined price.
 * @return {Promise<PricingConfig>} The effective pricing schedule.
 */
export async function getPricing(): Promise<PricingConfig> {
  try {
    const snap = await getFirestore()
      .collection("config")
      .doc("pricing")
      .get();
    const d = (snap.data() ?? {}) as Record<string, unknown>;
    const v = (d.verification ?? {}) as Record<string, unknown>;
    return {
      verification: {
        tenant: toRoleFee(v.tenant, DEFAULT_PRICING.verification.tenant),
        landlord: toRoleFee(v.landlord, DEFAULT_PRICING.verification.landlord),
        agent: toRoleFee(v.agent, DEFAULT_PRICING.verification.agent),
      },
      listing: typeof d.listing === "number" ?
        d.listing :
        DEFAULT_PRICING.listing,
      inspection: {
        ...DEFAULT_PRICING.inspection,
        ...((d.inspection ?? {}) as Partial<PricingConfig["inspection"]>),
      },
      dealFee: typeof d.dealFee === "number" ?
        d.dealFee :
        DEFAULT_PRICING.dealFee,
      minRent: typeof d.minRent === "number" ?
        d.minRent :
        DEFAULT_PRICING.minRent,
    };
  } catch (err) {
    logger.warn("Pricing config unreadable — using defaults", {
      error: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_PRICING;
  }
}

/**
 * The authoritative amount (in Naira) for a payment.
 *
 * Fixed-price types come from the schedule. Rent comes from the frozen
 * rental_interests record rather than being recomputed from the property:
 * a rent change between interest-creation and payment (approveRentReview /
 * approveImmediateRentChange) would otherwise charge an amount the tenant was
 * never shown. The interest's figures are immutable post-create by rule, so
 * they are a stable contract for this payment.
 *
 * Residual, deliberately not solved here: those figures are client-supplied at
 * interest CREATION (see the rental_interests create rule / HANDOVER H2).
 * Closing that needs interest creation to be server-authoritative; until then
 * this at least pins the charge to the persisted record instead of an
 * arbitrary number in the payment call.
 * @param {string} type The payment type.
 * @param {string} uid The paying user's id.
 * @param {object} metadata Caller metadata (may carry rentalInterestId).
 * @return {Promise<number|null>} Amount in Naira, or null if underivable (which
 *   makes initializePayment fall back to the client amount). The "rent" branch
 *   never returns null — it THROWS on any failure so an unauthorised/unready
 *   rent payment can never fall back to a client-supplied amount.
 */
export async function resolveServerAmount(
  type: string,
  uid: string,
  metadata?: Record<string, unknown>,
): Promise<number | null> {
  const pricing = await getPricing();

  if (type === "listing") return pricing.listing;
  if (type === "inspection") return pricing.inspection.total;

  if (type === "rent") {
    // Rent THROWS on every failure mode instead of returning null. A null here
    // would let initializePayment fall back to the client-supplied amount
    // (chargeAmount = serverAmount ?? amount) — for rent that is precisely the
    // hole this whole flow closes, so an unauthorised/unready rent payment must
    // hard-fail, never charge an arbitrary number.
    const interestId = typeof metadata?.rentalInterestId === "string" ?
      metadata.rentalInterestId :
      null;
    if (!interestId) {
      throw new HttpsError(
        "invalid-argument",
        "Rent payment requires a rentalInterestId.",
      );
    }
    const db = getFirestore();
    const snap = await db.collection("rental_interests").doc(interestId).get();
    const data = snap.data();
    if (!data) {
      throw new HttpsError("not-found", "Rental interest not found.");
    }
    if (data.tenantId !== uid) {
      logger.error("Rent payment by non-tenant of the interest", {
        uid,
        interestId,
        tenantId: data.tenantId,
      });
      throw new HttpsError(
        "permission-denied",
        "Only the tenant on this rental can pay it.",
      );
    }

    // Pay-after-accept gate: rent is payable ONLY once the landlord has
    // accepted this applicant (status "accepted") AND the tenancy agreement has
    // been finalized in-app. Awaiting acceptance, not finalized, or already paid
    // are all non-chargeable states.
    if (data.status !== "accepted") {
      throw new HttpsError(
        "failed-precondition",
        "This rental isn't ready for payment yet.",
      );
    }
    const rentalSnap = await db
      .collection("active_rentals")
      .where("rentalInterestId", "==", interestId)
      .limit(1)
      .get();
    const rental = rentalSnap.docs[0]?.data();
    if (!rental || rental.agreementStatus !== "finalized") {
      throw new HttpsError(
        "failed-precondition",
        "Finalize your tenancy agreement before paying rent.",
      );
    }
    if (rental.rentPaymentStatus === "paid") {
      throw new HttpsError(
        "failed-precondition",
        "Rent for this rental has already been paid.",
      );
    }
    // Slot hold: rent is only payable while the rental is holding the slot
    // (pending_payment). If it was released (terminated because the accept
    // lapsed unpaid) the slot is gone and it must not be chargeable.
    if (rental.status !== "pending_payment") {
      throw new HttpsError(
        "failed-precondition",
        "This rental is no longer awaiting payment.",
      );
    }

    const stored = data.paymentAmount;
    if (typeof stored !== "number" || !(stored > 0)) {
      throw new HttpsError(
        "failed-precondition",
        "This rental has no valid amount. Contact support.",
      );
    }
    return stored;
  }

  if (type === "renewal") {
    // A renewal charges the rental's own rent plus the tenant's deal fee. The
    // client sends only `sourceId`, which is either an active_rentals or a
    // tenancy_links doc without saying which, so try both. Anything unexpected
    // returns null and falls back to the caller's amount — no worse than now.
    const sourceId = typeof metadata?.sourceId === "string" ?
      metadata.sourceId :
      null;
    if (!sourceId) {
      logger.warn("Renewal payment without sourceId", {uid});
      return null;
    }
    const db = getFirestore();
    let snap = await db.collection("active_rentals").doc(sourceId).get();
    if (!snap.exists) {
      snap = await db.collection("tenancy_links").doc(sourceId).get();
    }
    if (!snap.exists) {
      logger.warn("Renewal payment for unknown sourceId", {uid, sourceId});
      return null;
    }
    if (snap.get("tenantId") !== uid) {
      logger.error("Renewal payment by non-tenant of the rental", {
        uid,
        sourceId,
      });
      return null;
    }
    const rent = snap.get("rentAmount");
    if (typeof rent !== "number" || !(rent > 0)) {
      logger.warn("Renewal source has no usable rentAmount", {uid, sourceId});
      return null;
    }
    return rent + pricing.dealFee;
  }

  if (type === "verification") {
    const snap = await getFirestore().collection("users").doc(uid).get();
    const user = snap.data();
    const accountType = user?.accountType as string | undefined;
    const fees = pricing.verification as Record<string, RoleFee | undefined>;
    const fee = accountType ? fees[accountType] : undefined;
    if (fee) {
      // Renewal is decided HERE, from `verifiedAt`, and never from anything the
      // caller sends. That field is stamped only when an admin approves a
      // verification (verification_ops.ts), so "have they ever been verified"
      // is a fact the client cannot assert its way into. The app's own
      // `isRenewal` flag — derived from whether a NIN file was attached — is
      // fine for choosing which form to show, but it is a client claim and
      // would be a discount anyone could take by omitting a file.
      //
      // Deliberately NOT keyed on status == 'expired': someone renewing early,
      // while still verified, is renewing too. Rejected-and-resubmitting has no
      // verifiedAt and correctly pays the initial fee.
      const isRenewal = user?.verifiedAt != null;
      return isRenewal ? fee.renewal : fee.initial;
    }

    // Unknown role — fall through to the caller's amount rather than blocking
    // a legitimate payment on a malformed profile.
    logger.warn("Verification payment with unknown accountType", {
      uid,
      accountType,
    });
    return null;
  }

  return null;
}
