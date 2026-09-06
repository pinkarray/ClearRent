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
 * Has a successful charge for this exact purpose already gone through?
 *
 * Every other precondition in [resolveServerAmount] reads state that only the
 * CLIENT's follow-up write produces — rentPaymentStatus, the request's paid
 * flag. When the app dies between the charge and that write, all of them still
 * say "unpaid" and the next initialize is waved through, so the same thing gets
 * charged twice. This reads the CHARGE instead, which is recorded either by the
 * client or, when the client never got there, by paystackWebhook.
 *
 * Equality filters only, so no composite index is required.
 *
 * NOTE: this is only as good as the webhook actually being registered in the
 * Paystack dashboard (Settings → API Keys & Webhooks, for BOTH test and live).
 * Without that registration an abandoned charge leaves no record anywhere and
 * nothing here can see it.
 *
 * @param {string} type The payment type, as stored on the payments doc.
 * @param {string} field The purpose field to match on.
 * @param {string} id The purpose id.
 * @return {Promise<string|null>} The existing reference, or null.
 */
async function existingSuccessfulCharge(
  type: string,
  field: string,
  id: string,
): Promise<string | null> {
  const snap = await getFirestore()
    .collection("payments")
    .where(field, "==", id)
    .where("type", "==", type)
    .where("status", "==", "completed")
    .limit(1)
    .get();
  return snap.empty ? null : snap.docs[0].id;
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
  if (type === "inspection") {
    // Same double-charge protection as rent. The inspection fee is smaller but
    // the failure mode is identical: charge succeeds, app dies before
    // confirmInspectionPayment runs, request still reads unpaid, tenant pays
    // again.
    const requestId = typeof metadata?.requestId === "string" ?
      metadata.requestId :
      null;
    if (requestId) {
      const prior = await existingSuccessfulCharge(
        "inspection",
        "requestId",
        requestId,
      );
      if (prior !== null) {
        logger.error("Second inspection charge blocked", {
          uid,
          requestId,
          existingReference: prior,
        });
        throw new HttpsError(
          "failed-precondition",
          "We've already received the fee for this inspection. It is being " +
            "confirmed — please contact support if it does not unlock " +
            "shortly. You have not been charged again.",
        );
      }
    }
    return pricing.inspection.total;
  }

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

    // A successful rent charge already exists for this rental, even though the
    // rental is not marked paid.
    //
    // This is the case the check above CANNOT see, and it is how the same rent
    // was charged twice: the money moved at Paystack, then the app died before
    // recordRentPayment ran, so rentPaymentStatus stayed "pending" and the next
    // initialize was waved straight through. Every other guard here reads state
    // that only the CLIENT's follow-up write produces; this one reads the
    // charge itself, which either the client or paystackWebhook records.
    //
    // Equality filters only, so no composite index is required.
    const priorCharge = await existingSuccessfulCharge(
      "rent",
      "rentalInterestId",
      interestId,
    );
    if (priorCharge !== null) {
      logger.error("Second rent charge blocked — one already succeeded", {
        uid,
        interestId,
        existingReference: priorCharge,
      });
      // Worded as "received", not "refused": the tenant HAS paid. Telling them
      // it failed would send them looking for another way to pay the very
      // thing they are being protected from paying twice.
      throw new HttpsError(
        "failed-precondition",
        "We've already received a rent payment for this property. It is " +
          "being confirmed — please contact support if your tenancy has not " +
          "activated shortly. You have not been charged again.",
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
    // tenancy_links doc without saying which, so try both.
    //
    // Every failure below THROWS. It used to return null, and null means "no
    // server figure" - which initializePayment reads as permission to charge
    // `serverAmount ?? amount`, i.e. whatever the caller asked for. So omitting
    // sourceId was a self-service discount: name your own renewal price and it
    // was taken. Exactly the hole the verification branch below was already
    // fixed for; renewal never got the same treatment.
    const sourceId = typeof metadata?.sourceId === "string" ?
      metadata.sourceId :
      null;
    if (!sourceId) {
      logger.error("Renewal payment without sourceId", {uid});
      throw new HttpsError(
        "invalid-argument",
        "We could not tell which tenancy this renewal is for. " +
        "Reopen the rental and try again.",
      );
    }
    const db = getFirestore();
    let snap = await db.collection("active_rentals").doc(sourceId).get();
    if (!snap.exists) {
      snap = await db.collection("tenancy_links").doc(sourceId).get();
    }
    if (!snap.exists) {
      logger.error("Renewal payment for unknown sourceId", {uid, sourceId});
      throw new HttpsError(
        "not-found",
        "That tenancy no longer exists, so it cannot be renewed.",
      );
    }
    // Not merely a mispricing risk: this is someone initialising a renewal
    // against a tenancy that is not theirs. permission-denied, not a fallback.
    if (snap.get("tenantId") !== uid) {
      logger.error("Renewal payment by non-tenant of the rental", {
        uid,
        sourceId,
      });
      throw new HttpsError(
        "permission-denied",
        "This tenancy belongs to a different tenant.",
      );
    }
    const rent = snap.get("rentAmount");
    if (typeof rent !== "number" || !(rent > 0)) {
      logger.error("Renewal source has no usable rentAmount", {uid, sourceId});
      throw new HttpsError(
        "failed-precondition",
        "This tenancy has no rent recorded, so a renewal cannot be priced. " +
        "Contact support.",
      );
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

    // Unknown role THROWS rather than returning null, for the same reason the
    // "rent" branch above does. null means "no server figure", and both
    // consumers treat that as permission to skip the check:
    // initializePayment charges `serverAmount ?? amount` (the caller's own
    // number) and verification_ops skips its underpayment comparison on a null
    // expectation. `accountType` lives on the user document and is not in the
    // users update blocklist, so it is self-writable — which turned "malformed
    // profile" into a self-service discount: clear or misspell the field, then
    // initialize a ₦100 verification payment and have it accepted in full.
    //
    // A genuinely malformed profile now gets a clear error instead of a
    // mispriced charge, which is the better failure.
    logger.error("Verification payment with unknown accountType", {
      uid,
      accountType,
    });
    throw new HttpsError(
      "failed-precondition",
      "Your account type is not set. Contact support.",
    );
  }

  return null;
}
