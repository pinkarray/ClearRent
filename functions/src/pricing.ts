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
import {getFirestore} from "firebase-admin/firestore";

export interface PricingConfig {
  verification: {tenant: number; landlord: number; agent: number};
  listing: number;
  inspection: {total: number; handler: number; platform: number};
  /** Deal-completion fee charged per party on a completed rental. */
  dealFee: number;
}

/**
 * Fallbacks used when config/pricing is missing or partial. These MUST mirror
 * the client constants (VerificationFees in verification_service.dart,
 * InspectionPricing in inspection_pricing.dart) so behaviour is identical
 * before the document is seeded.
 */
export const DEFAULT_PRICING: PricingConfig = {
  verification: {tenant: 3000, landlord: 12000, agent: 7000},
  listing: 10000,
  inspection: {total: 10000, handler: 7000, platform: 3000},
  dealFee: 5000,
};

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
    const d = (snap.data() ?? {}) as Partial<PricingConfig>;
    return {
      verification: {
        ...DEFAULT_PRICING.verification,
        ...(d.verification ?? {}),
      },
      listing: typeof d.listing === "number" ?
        d.listing :
        DEFAULT_PRICING.listing,
      inspection: {...DEFAULT_PRICING.inspection, ...(d.inspection ?? {})},
      dealFee: typeof d.dealFee === "number" ?
        d.dealFee :
        DEFAULT_PRICING.dealFee,
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
 * @return {Promise<number|null>} Amount in Naira, or null if underivable.
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
    const interestId = typeof metadata?.rentalInterestId === "string" ?
      metadata.rentalInterestId :
      null;
    if (!interestId) {
      logger.warn("Rent payment without rentalInterestId", {uid});
      return null;
    }
    const snap = await getFirestore()
      .collection("rental_interests")
      .doc(interestId)
      .get();
    const data = snap.data();
    if (!data) {
      logger.warn("Rent payment for missing rental_interest", {
        uid,
        interestId,
      });
      return null;
    }
    if (data.tenantId !== uid) {
      logger.error("Rent payment by non-tenant of the interest", {
        uid,
        interestId,
        tenantId: data.tenantId,
      });
      return null;
    }
    const stored = data.paymentAmount;
    return typeof stored === "number" && stored > 0 ? stored : null;
  }

  if (type === "verification") {
    const snap = await getFirestore().collection("users").doc(uid).get();
    const accountType = snap.data()?.accountType as string | undefined;
    const fees = pricing.verification as Record<string, number | undefined>;
    const fee = accountType ? fees[accountType] : undefined;
    if (typeof fee === "number") return fee;

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
