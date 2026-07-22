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
    };
  } catch (err) {
    logger.warn("Pricing config unreadable — using defaults", {
      error: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_PRICING;
  }
}

/**
 * The authoritative amount (in Naira) for a fixed-price payment type.
 *
 * Returns null for variable-price types (rent, renewal), whose amount depends
 * on the specific rental and cannot come from a static schedule — those still
 * carry the caller's amount. TODO: derive those from the rental doc so no
 * payment type trusts a client-supplied amount.
 * @param {string} type The payment type.
 * @param {string} uid The paying user's id.
 * @return {Promise<number|null>} Amount in Naira, or null when variable.
 */
export async function resolveServerAmount(
  type: string,
  uid: string,
): Promise<number | null> {
  const pricing = await getPricing();

  if (type === "listing") return pricing.listing;
  if (type === "inspection") return pricing.inspection.total;

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
