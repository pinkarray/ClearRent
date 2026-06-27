/**
 * System D — renewal / promotion money path (tenant-facing).
 *
 *   completeActiveRenewal
 *     Caller: the tenant on a grace_locked active_rentals doc.
 *     Re-verifies the Paystack reference server-side, then (in a txn)
 *     extends leaseEndDate by one year from the OLD end (no lost days),
 *     resets status -> active and hasPaymentReminder -> false. No payout
 *     writes: the rental was already paid out at original creation.
 *     Side-effects (post-commit): two `renewal` activities (tenant feed +
 *     landlord feed) and a `payments/RENEWAL_{rentalId}_{ts}` receipt.
 *
 *   completeLinkedPromotion
 *     Caller: the tenant on a confirmed/expiring/grace_locked tenancy_link.
 *     Re-verifies the reference, then (in a txn) CREATES a new active_rentals
 *     doc shaped like a native rental (so the existing occupancy trigger and
 *     the dashboard treat it identically), with promotion economics:
 *       rentAmount        = link.rentAmount
 *       landlordPayout    = rentAmount - 5000   (landlord's deal fee netted)
 *       clearrentEarnings = 10000               (tenant 5k + landlord 5k)
 *       totalPaid         = rentAmount + 5000   (what the tenant's card paid)
 *       agentPayout/agentFee = 0, agentId = null (links have no agent)
 *       inspectionFeeCredit  = 0 (no inspection — tenant already occupying)
 *       sourceLinkId      = linkId
 *     The lease starts fresh from now (the link's term was off-platform).
 *     Then flips the link status -> promoted with promotedToRentalId.
 *     Side-effects (post-commit): two `promotion` activities + a
 *     `payments/PROMOTION_{newId}` receipt.
 *
 * Design notes (mirroring admin_money_ops.ts conventions):
 *   - Money/state writes happen inside a Firestore transaction. Display
 *     docs (activities, receipts) are written AFTER commit, best-effort:
 *     a failed display write never rolls back a real lease change.
 *   - Status guards inside the txn block replays (grace_locked -> active
 *     only; a link can't be promoted twice).
 *   - Auth is assertSelf (caller must be the rental/link's tenant) — NOT
 *     assertAdmin: this is a tenant action, the deliberate divergence from
 *     the admin-only money CFs in admin_money_ops.ts.
 *   - Receipts use deterministic IDs and .create(); an already-exists
 *     re-fire is swallowed (code 6 / "already-exists").
 *   - The activities `landlordId` field is the feed-routing key (pre-existing
 *     schema quirk): set to the tenant's uid for the tenant's copy and the
 *     landlord's uid for the landlord's copy.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {defineSecret} from "firebase-functions/params";
import {assertSelf, guardStatusTransition} from "./admin_helpers";

// Same Secret Manager entry as index.ts; defining the same name here is
// fine — both resolve to the one PAYSTACK_SECRET_KEY secret.
const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

const callableOptions = {
  secrets: [paystackSecret],
  timeoutSeconds: 30,
  enforceAppCheck: false,
};

const DEAL_FEE = 5000;

// ── input validation ────────────────────────────────────────────────────────

interface RenewalInput {
  sourceId?: unknown;
  paymentReference?: unknown;
}

interface ValidatedRenewalInput {
  sourceId: string;
  paymentReference: string;
}

function validateRenewalInput(data: unknown): ValidatedRenewalInput {
  const d = (data ?? {}) as RenewalInput;
  if (typeof d.sourceId !== "string" || d.sourceId.trim().length === 0) {
    throw new HttpsError(
      "invalid-argument",
      "sourceId must be a non-empty string.",
    );
  }
  if (
    typeof d.paymentReference !== "string" ||
    d.paymentReference.trim().length === 0
  ) {
    throw new HttpsError(
      "invalid-argument",
      "paymentReference must be a non-empty string.",
    );
  }
  return {sourceId: d.sourceId, paymentReference: d.paymentReference};
}

// ── server-side Paystack re-verification ─────────────────────────────────────

interface VerifyResult {
  ok: boolean;
  amountPaid: number;
}

/**
 * Re-verify a Paystack reference server-side. Mirrors the verify call in
 * index.ts's verifyPayment — the client claim of "success" is never trusted
 * for a money path.
 *
 * @param {string} reference the Paystack transaction reference
 * @param {string} secret the Paystack secret key
 * @return {Promise<VerifyResult>} ok + amount paid (Naira)
 */
async function verifyPaystackReference(
  reference: string,
  secret: string,
): Promise<VerifyResult> {
  const resp = await fetch(
    "https://api.paystack.co/transaction/verify/" +
      encodeURIComponent(reference),
    {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
    },
  );
  const body = (await resp.json()) as {
    status?: boolean;
    data?: {status?: string; amount?: number};
  };
  if (resp.ok && body.status === true && body.data) {
    const txStatus = body.data.status ?? "failed";
    const kobo = typeof body.data.amount === "number" ? body.data.amount : 0;
    return {ok: txStatus === "success", amountPaid: kobo / 100};
  }
  return {ok: false, amountPaid: 0};
}

// ── shared side-effects writer ───────────────────────────────────────────────

interface RenewalSideEffectsInput {
  kind: "renewal" | "promotion";
  rentalId: string;
  tenantId: string;
  tenantName: string;
  landlordId: string;
  propertyId: string;
  propertyTitle: string;
  amount: number;
  receiptDocId: string;
}

/**
 * Write the two feed activities (tenant + landlord) and one payment receipt.
 * All writes are best-effort: failures are logged, never thrown, so a display
 * failure can't roll back the committed lease change.
 *
 * @param {RenewalSideEffectsInput} input the side-effect payload
 * @return {Promise<void>} resolves once writes are attempted
 */
async function writeRenewalSideEffects(
  input: RenewalSideEffectsInput,
): Promise<void> {
  const db = getFirestore();
  const verb = input.kind === "renewal" ? "renewed" : "activated";
  const title =
    input.kind === "renewal" ? "Tenancy Renewed" : "Tenancy Activated";

  // Tenant's feed copy.
  try {
    await db.collection("activities").add({
      landlordId: input.tenantId, // feed-routing key (schema quirk)
      type: input.kind,
      title,
      message: `You ${verb} your tenancy at ${input.propertyTitle}.`,
      propertyId: input.propertyId,
      rentalId: input.rentalId,
      amount: input.amount,
      actorId: input.tenantId,
      actorName: input.tenantName,
      isRead: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    logger.error("renewal tenant activity write failed", {
      rentalId: input.rentalId,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  // Landlord's feed copy.
  try {
    await db.collection("activities").add({
      landlordId: input.landlordId, // feed-routing key (schema quirk)
      type: input.kind,
      title,
      message:
        `${input.tenantName} ${verb} their tenancy at ` +
        `${input.propertyTitle}.`,
      propertyId: input.propertyId,
      rentalId: input.rentalId,
      amount: input.amount,
      actorId: input.tenantId,
      actorName: input.tenantName,
      isRead: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    logger.error("renewal landlord activity write failed", {
      rentalId: input.rentalId,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  // Payment receipt (deterministic id, idempotent create).
  try {
    await db.collection("payments").doc(input.receiptDocId).create({
      reference: input.receiptDocId,
      userId: input.tenantId,
      type: input.kind === "renewal" ? "rent_renewal" : "rent_promotion",
      amount: input.amount,
      status: "completed",
      relatedId: input.rentalId,
      propertyId: input.propertyId,
      propertyTitle: input.propertyTitle,
      description: `Tenancy ${input.kind} for ${input.propertyTitle}`,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    const code = (err as {code?: unknown})?.code;
    if (code === 6 || code === "already-exists") {
      logger.info("Renewal receipt already exists, skipping", {
        receiptDocId: input.receiptDocId,
      });
    } else {
      logger.error("renewal receipt write failed", {
        receiptDocId: input.receiptDocId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }
}

// ── completeActiveRenewal ─────────────────────────────────────────────────────

export const completeActiveRenewal = onCall(
  callableOptions,
  async (request) => {
    const input = validateRenewalInput(request.data);
    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(input.sourceId);

    const verify = await verifyPaystackReference(
      input.paymentReference,
      paystackSecret.value(),
    );
    if (!verify.ok) {
      throw new HttpsError(
        "failed-precondition",
        "Payment could not be verified.",
      );
    }

    interface RenewalSideEffect {
      tenantId: string;
      tenantName: string;
      landlordId: string;
      propertyId: string;
      propertyTitle: string;
      amount: number;
    }

    const side = await db.runTransaction<RenewalSideEffect>(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError(
          "not-found",
          `active_rentals/${input.sourceId} not found.`,
        );
      }
      const data = snap.data()!;
      assertSelf(request.auth, data.tenantId as string);
      guardStatusTransition(data.status, "grace_locked", "status");

      // Apply a staged rent increase if one is scheduled and its effective
      // date has passed. Reads only this rental's own fields — never the
      // property — so co-tenants are never swept up. rentAmount mutates here
      // (renewal), not at approval.
      const currentRent = (data.rentAmount as number) ?? 0;
      const pendingRent = data.pendingRentForRenewal as number | undefined;
      const pendingEffective =
        (data.pendingRentEffectiveDate as Timestamp | undefined)?.toDate();
      const applyIncrease =
        pendingRent != null &&
        pendingRent > 0 &&
        pendingEffective != null &&
        pendingEffective.getTime() <= Date.now();
      const effectiveRent = applyIncrease ? pendingRent! : currentRent;

      const expected = effectiveRent + DEAL_FEE;
      if (verify.amountPaid < expected - 1) {
        throw new HttpsError(
          "failed-precondition",
          `Underpayment: expected ${expected}, got ${verify.amountPaid}.`,
        );
      }

      const oldEnd = (data.leaseEndDate as Timestamp).toDate();

      const newEnd = new Date(
        oldEnd.getFullYear() + 1,
        oldEnd.getMonth(),
        oldEnd.getDate(),
      );

      const rentalUpdate: Record<string, unknown> = {
        leaseEndDate: Timestamp.fromDate(newEnd),
        nextPaymentDue: Timestamp.fromDate(newEnd),
        status: "active",
        hasPaymentReminder: false,
        renewedAt: FieldValue.serverTimestamp(),
        renewalPaymentReference: input.paymentReference,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (applyIncrease) {
        rentalUpdate.rentAmount = effectiveRent;
        rentalUpdate.pendingRentForRenewal = FieldValue.delete();
        rentalUpdate.pendingRentEffectiveDate = FieldValue.delete();
      }

      tx.update(ref, rentalUpdate);

      return {
        tenantId: data.tenantId as string,
        tenantName: (data.tenantName as string) ?? "Your tenant",
        landlordId: data.landlordId as string,
        propertyId: (data.propertyId as string) ?? "",
        propertyTitle: (data.propertyTitle as string) ?? "your property",
        amount: verify.amountPaid,
      };
    });

    await writeRenewalSideEffects({
      kind: "renewal",
      rentalId: input.sourceId,
      tenantId: side.tenantId,
      tenantName: side.tenantName,
      landlordId: side.landlordId,
      propertyId: side.propertyId,
      propertyTitle: side.propertyTitle,
      amount: side.amount,
      receiptDocId: `RENEWAL_${input.sourceId}_${Date.now()}`,
    });

    return {success: true, rentalId: input.sourceId};
  },
);

// ── completeLinkedPromotion ───────────────────────────────────────────────────

const PROMOTABLE_LINK_STATUSES = [
  "confirmed",
  "expiring_soon",
  "grace_locked",
];

export const completeLinkedPromotion = onCall(
  callableOptions,
  async (request) => {
    const input = validateRenewalInput(request.data);
    const db = getFirestore();
    const linkRef = db.collection("tenancy_links").doc(input.sourceId);

    const verify = await verifyPaystackReference(
      input.paymentReference,
      paystackSecret.value(),
    );
    if (!verify.ok) {
      throw new HttpsError(
        "failed-precondition",
        "Payment could not be verified.",
      );
    }

    interface PromotionSideEffect {
      rentalId: string;
      tenantId: string;
      tenantName: string;
      landlordId: string;
      propertyId: string;
      propertyTitle: string;
      amount: number;
    }

    const side = await db.runTransaction<PromotionSideEffect>(async (tx) => {
      const snap = await tx.get(linkRef);
      if (!snap.exists) {
        throw new HttpsError(
          "not-found",
          `tenancy_links/${input.sourceId} not found.`,
        );
      }
      const link = snap.data()!;
      assertSelf(request.auth, link.tenantId as string);

      const status = link.status as string;
      if (!PROMOTABLE_LINK_STATUSES.includes(status)) {
        throw new HttpsError(
          "failed-precondition",
          `Link status "${status}" cannot be promoted.`,
        );
      }

      // Apply a staged rent increase if approveRentReview scheduled one against
      // this link and its effective date has passed (mirrors
      // completeActiveRenewal). The increase lands here — at promotion, the
      // link's "renewal".
      const baseRent = (link.rentAmount as number) ?? 0;
      const pendingRent = link.pendingRentForRenewal as number | undefined;
      const pendingEffective =
        (link.pendingRentEffectiveDate as Timestamp | undefined)?.toDate();
      const applyIncrease =
        pendingRent != null &&
        pendingRent > 0 &&
        pendingEffective != null &&
        pendingEffective.getTime() <= Date.now();
      const rentAmount = applyIncrease ? pendingRent! : baseRent;

      const expected = rentAmount + DEAL_FEE;
      if (verify.amountPaid < expected - 1) {
        throw new HttpsError(
          "failed-precondition",
          `Underpayment: expected ${expected}, got ${verify.amountPaid}.`,
        );
      }
      const now = new Date();
      // Renewal-as-continuation: extend from the link's prior lease end so
      // the landlord's cycle is preserved (tenant had the full term to
      // prepare). Legacy links with no term fall back to a fresh year.
      const priorEnd = link.leaseEndDate
        ? (link.leaseEndDate as Timestamp).toDate()
        : now;
      const leaseEnd = new Date(
        priorEnd.getFullYear() + 1,
        priorEnd.getMonth(),
        priorEnd.getDate(),
      );

      const newRentalRef = db.collection("active_rentals").doc();

      // A revised agreement attached to the link by approveRentReview is
      // carried into the promoted rental as pending_review, so the tenant
      // reviews the new terms at promotion (their "renewal").
      const linkAgreementUrl = (link.agreementUrl as string | undefined) ?? "";

      tx.set(newRentalRef, {
        propertyId: (link.propertyId as string) ?? "",
        tenantId: link.tenantId as string,
        landlordId: link.landlordId as string,
        agentId: null,
        inspectionRequestId: "",
        rentalInterestId: "",
        propertyTitle: (link.propertyTitle as string) ?? "",
        propertyImage: "",
        propertyAddress: (link.propertyAddress as string) ?? "",
        tenantName: (link.tenantName as string) ?? "",
        landlordName: (link.landlordName as string) ?? "",
        landlordPhone: (link.landlordPhone as string) ?? null,
        rentAmount: rentAmount,
        agentFee: 0,
        totalPaid: rentAmount + DEAL_FEE,
        landlordPayout: rentAmount - DEAL_FEE,
        agentPayout: 0,
        clearrentEarnings: DEAL_FEE * 2,
        landlordPayoutStatus: "pending",
        agentPayoutStatus: "not_applicable",
        inspectionFeeCredit: 0,
        rentFrequency: "yearly",
        leaseStartDate: Timestamp.fromDate(priorEnd),
        leaseEndDate: Timestamp.fromDate(leaseEnd),
        nextPaymentDue: Timestamp.fromDate(leaseEnd),
        status: "active",
        hasPaymentReminder: false,
        sourceLinkId: input.sourceId,
        promotionPaymentReference: input.paymentReference,
        ...(linkAgreementUrl
          ? {
            agreementUrl: linkAgreementUrl,
            agreementUploadedAt: FieldValue.serverTimestamp(),
            agreementStatus: "pending_review",
          }
          : {}),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.update(linkRef, {
        status: "promoted",
        promotedToRentalId: newRentalRef.id,
        promotedAt: FieldValue.serverTimestamp(),
      });

      return {
        rentalId: newRentalRef.id,
        tenantId: link.tenantId as string,
        tenantName: (link.tenantName as string) ?? "Your tenant",
        landlordId: link.landlordId as string,
        propertyId: (link.propertyId as string) ?? "",
        propertyTitle: (link.propertyTitle as string) ?? "your property",
        amount: verify.amountPaid,
      };
    });

    await writeRenewalSideEffects({
      kind: "promotion",
      rentalId: side.rentalId,
      tenantId: side.tenantId,
      tenantName: side.tenantName,
      landlordId: side.landlordId,
      propertyId: side.propertyId,
      propertyTitle: side.propertyTitle,
      amount: side.amount,
      receiptDocId: `PROMOTION_${side.rentalId}`,
    });

    return {success: true, rentalId: side.rentalId};
  },
);