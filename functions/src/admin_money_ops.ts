/**
 * Admin money-flow Cloud Functions.
 *
 * Four callable functions for marking out-of-band money movements as
 * complete. The admin transfers money manually (bank app / Paystack
 * dashboard), then calls one of these to record the payment.
 *
 *   markInspectionAgentPayoutPaid
 *     Flips agentPayoutStatus on inspection_requests/{id}.
 *     Amount source: agentEarnings on the doc.
 *     Side-effects (post-W5): shifts handler's pendingEarnings →
 *     paidEarnings on their user doc (inside tx); writes a
 *     `payout_received` activity and a
 *     `payments/PAYOUT_INSPECTION_{requestId}` receipt (post-commit).
 *
 *   markRentLandlordPayoutPaid
 *     Flips landlordPayoutStatus on active_rentals/{id}.
 *     Amount source: landlordPayout on the doc.
 *     Side-effects (post-W5): writes a `rent_payout` activity and
 *     a `payments/PAYOUT_LANDLORD_{id}` receipt (post-commit).
 *
 *   markRentAgentCommissionPaid
 *     Flips agentPayoutStatus on active_rentals/{id}.
 *     Amount source: agentPayout on the doc.
 *     Side-effects (post-W5): writes a `rent_payout` activity and
 *     a `payments/PAYOUT_AGENT_{id}` receipt (post-commit). Skipped
 *     if agentId is null (no agent on the rental).
 *
 *   markRefundPaid
 *     Flips status on refunds/{id}.
 *     Amount source: amount on the doc.
 *
 * Design notes:
 *   - Each function runs a Firestore transaction for the money state.
 *     Money writes (status flips + earnings counter shifts) all happen
 *     inside the transaction; display docs (activities, payment
 *     receipts) are written after commit. Rationale: a failed receipt
 *     write should not roll back a real payout that's already been
 *     transferred. Receipt failures are logged loudly.
 *   - Status-transition guard inside the transaction blocks doc:pending
 *     -> paid only. Replays / double-clicks fail with failed-precondition.
 *   - Audit log write happens AFTER the transaction commits. If the
 *     audit write fails, the money-mark stands and we log loudly.
 *     See admin_helpers.ts for the rationale.
 *   - Field naming is inconsistent across collections (agentEarnings vs
 *     agentPayout). We tolerate this here rather than renaming, since
 *     a rename would require a data migration.
 *   - Receipt docs use deterministic IDs (PAYOUT_LANDLORD_{id} /
 *     PAYOUT_AGENT_{id}) and .create() so a re-fire of a CF that
 *     somehow gets past the status guard won't double-write a receipt.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {
  getFirestore,
  FieldValue,
  Firestore,
  Timestamp,
} from "firebase-admin/firestore";
import { assertAdmin, guardStatusTransition, writeAuditLog } from "./admin_helpers";
import {writeNotificationOnce} from "./notification_helpers";
import {getPricing} from "./pricing";

interface BeneficiaryBank {
  bankName: string | null;
  accountNumber: string | null;
  accountName: string | null;
  bankCode: string | null;
}

/**
 * Snapshot a beneficiary's payout account from users/{uid}/private/bank onto a
 * refund record, so the admin settling the refund sees exactly where to send
 * the money instead of having to look it up. Fields are null when not on file
 * (shouldn't happen now that requesting/accepting requires bank details, but
 * legacy disputes may predate that gate).
 *
 * @param {Firestore} db Firestore instance.
 * @param {string} uid Beneficiary user id.
 * @return {Promise<BeneficiaryBank>} Account fields (nulls if absent).
 */
async function readBeneficiaryBank(
  db: Firestore,
  uid: string,
): Promise<BeneficiaryBank> {
  try {
    const snap = await db
      .collection("users").doc(uid)
      .collection("private").doc("bank")
      .get();
    const d = snap.data() ?? {};
    return {
      bankName: (d.bankName as string | undefined) ?? null,
      accountNumber: (d.accountNumber as string | undefined) ?? null,
      accountName: (d.accountName as string | undefined) ?? null,
      bankCode: (d.bankCode as string | undefined) ?? null,
    };
  } catch (err) {
    logger.error("readBeneficiaryBank failed", {
      uid,
      error: err instanceof Error ? err.message : String(err),
    });
    return {
      bankName: null,
      accountNumber: null,
      accountName: null,
      bankCode: null,
    };
  }
}

interface MarkPaidInput {
  docId?: unknown;
  paymentReference?: unknown;
  paymentNote?: unknown;
}

interface ValidatedInput {
  docId: string;
  paymentReference: string;
  paymentNote: string | null;
}

/**
 * Pull and validate the three input fields shared across all four CFs.
 * Throws HttpsError(invalid-argument) on any failure.
 */
function validateInput(raw: unknown): ValidatedInput {
  const data = (raw ?? {}) as MarkPaidInput;

  if (typeof data.docId !== "string" || data.docId.trim().length === 0) {
    throw new HttpsError(
      "invalid-argument",
      "docId must be a non-empty string.",
    );
  }
  if (
    typeof data.paymentReference !== "string" ||
    data.paymentReference.trim().length === 0
  ) {
    throw new HttpsError(
      "invalid-argument",
      "paymentReference must be a non-empty string.",
    );
  }

  let note: string | null = null;
  if (data.paymentNote !== undefined && data.paymentNote !== null) {
    if (typeof data.paymentNote !== "string") {
      throw new HttpsError(
        "invalid-argument",
        "paymentNote, if provided, must be a string.",
      );
    }
    const trimmed = data.paymentNote.trim();
    if (trimmed.length > 0) note = trimmed;
  }

  return {
    docId: data.docId.trim(),
    paymentReference: data.paymentReference.trim(),
    paymentNote: note,
  };
}

/**
 * Shared options for the four onCall handlers. App Check is left off for
 * now to match the existing CFs in this codebase; tighten when ready.
 */
const callableOptions = {
  timeoutSeconds: 30,
  enforceAppCheck: false,
};

/**
 * Read a positive-number amount from a doc snapshot, or throw.
 */
function readAmount(
  data: FirebaseFirestore.DocumentData,
  fieldName: string,
): number {
  const raw = data[fieldName];
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) {
    throw new HttpsError(
      "failed-precondition",
      `Doc has invalid ${fieldName}: ${String(raw)}`,
    );
  }
  return raw;
}

/**
 * Gate a rent payout on the deal actually being done (G2/G3). The landlord
 * (and agent) are only paid once the tenancy agreement is FINALIZED — i.e. the
 * tenant reviewed and accepted it and the landlord finalized. A payout must
 * never leave while the agreement is disputed (money would be irreversibly gone
 * before the dispute is resolved), pending review, or not yet uploaded.
 *
 * Throws HttpsError(failed-precondition) with an admin-facing message; the
 * admin resolves it by finalizing the agreement (or settling the dispute first).
 * @param {FirebaseFirestore.DocumentData} data active_rental doc data.
 */
function assertAgreementFinalized(
  data: FirebaseFirestore.DocumentData,
): void {
  const status = data.agreementStatus;
  if (status === "finalized") return;
  if (status === "disputed") {
    throw new HttpsError(
      "failed-precondition",
      "The tenant is disputing the tenancy agreement. Resolve the dispute " +
        "and finalize the agreement before paying out.",
    );
  }
  throw new HttpsError(
    "failed-precondition",
    "The tenancy agreement isn't finalized yet — the tenant must accept it " +
      "and the landlord must finalize it before a payout can be sent.",
  );
}

/**
 * Gate a rent payout on the tenant's rent having actually been collected.
 *
 * Under pay-after-accept the active_rental is created UNPAID at acceptance and
 * only becomes paid once the accepted tenant pays (recordRentPayment stamps
 * rentPaymentStatus="paid"). A payout must never leave before the money is in —
 * previously acceptance implied payment, but it no longer does.
 *
 * Legacy rentals created under the old pay-before-accept flow have no
 * rentPaymentStatus field; treat its absence as paid so those in-flight payouts
 * are not blocked.
 * @param {FirebaseFirestore.DocumentData} data active_rental doc data.
 */
function assertRentPaid(data: FirebaseFirestore.DocumentData): void {
  const status = data.rentPaymentStatus;
  if (status === undefined || status === "paid") return;
  throw new HttpsError(
    "failed-precondition",
    "The tenant hasn't paid rent for this rental yet — no payout can be sent " +
      "until the rent is collected.",
  );
}

/**
 * Read an optional string from a doc snapshot. Returns null if missing
 * or non-string. Used for display-only fields (propertyTitle, etc) that
 * are nice-to-have on activities/receipts but not blocking.
 */
function readOptionalString(
  data: FirebaseFirestore.DocumentData,
  fieldName: string,
): string | null {
  const raw = data[fieldName];
  return typeof raw === "string" && raw.length > 0 ? raw : null;
}

// ============================================================
// 1. Inspection agent payout — flips agentPayoutStatus on
//    inspection_requests/{id}.
//
// In-tx side effect (W5): also shifts the handler's earnings counters
// (pendingEarnings → paidEarnings) on their user doc. Handler is the
// agent if agent-handled, else the landlord (self-handled). This is
// the only money side-effect of the three rent/inspection CFs — the
// rest are display docs.
//
// Post-commit side effect: writes a `payout_received` activity so
// the handler sees it in their feed. Activity write is best-effort.
// ============================================================
export const markInspectionAgentPayoutPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("inspection_requests").doc(input.docId);

    interface InspectionPayoutSideEffect {
      amount: number;
      handlerId: string | null;
      propertyId: string | null;
      propertyTitle: string | null;
    }

    const sideEffect = await db.runTransaction<InspectionPayoutSideEffect>(
      async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new HttpsError(
            "not-found",
            `inspection_requests/${input.docId} not found.`,
          );
        }
        const data = snap.data()!;
        guardStatusTransition(
          data.agentPayoutStatus,
          "pending",
          "agentPayoutStatus",
        );
        const amt = readAmount(data, "agentEarnings");

        const agentId = data.agentId as string | null | undefined;
        const landlordId = data.landlordId as string | undefined;
        const handlerId = agentId ?? landlordId ?? null;

        // Earnings shift on handler's user doc — IN the transaction
        // so a failure rolls back the status flip too. This is money
        // state, not a display doc.
        if (handlerId !== null) {
          const handlerRef = db.collection("users").doc(handlerId);
          tx.update(handlerRef, {
            pendingEarnings: FieldValue.increment(-amt),
            paidEarnings: FieldValue.increment(amt),
          });
        } else {
          // Should never happen — an inspection_request with no
          // agentId AND no landlordId is malformed. Log and proceed
          // with the status flip rather than crashing the admin
          // operation; the absence of a handler means no earnings
          // to shift anyway.
          logger.error(
            "Inspection payout has neither agentId nor landlordId",
            {docId: input.docId},
          );
        }

        tx.update(ref, {
          agentPayoutStatus: "paid",
          agentPaidAt: FieldValue.serverTimestamp(),
          agentPaidBy: adminUid,
          agentPaymentReference: input.paymentReference,
          agentPaymentNote: input.paymentNote,
        });

        return {
          amount: amt,
          handlerId,
          propertyId: readOptionalString(data, "propertyId"),
          propertyTitle: readOptionalString(data, "propertyTitle"),
        };
      });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_inspection_agent_payout_paid",
      targetCollection: "inspection_requests",
      targetId: input.docId,
      amount: sideEffect.amount,
      paymentReference: input.paymentReference,
      ...(input.paymentNote !== null && {paymentNote: input.paymentNote}),
    });

    // Post-commit: write the activity + payment receipt. Best-effort —
    // log on failure. Both are display-only docs and a failed write
    // should not undo the (already-real) money flip.
    if (sideEffect.handlerId !== null) {
      const propertyTitle = sideEffect.propertyTitle ?? "your property";

      try {
        await db.collection("activities").add({
          userId: sideEffect.handlerId,
          type: "payout_received",
          title: "Payment Received",
          message:
            `You've been paid ₦${sideEffect.amount.toFixed(0)} for ` +
            `inspection at ${propertyTitle}`,
          relatedId: input.docId,
          propertyId: sideEffect.propertyId,
          actorId: adminUid,
          actorName: "ClearRent Admin",
          isRead: false,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        logger.error("payout_received activity write failed", {
          docId: input.docId,
          handlerId: sideEffect.handlerId,
          error: err instanceof Error ? err.message : String(err),
        });
      }

      // Payment receipt — surfaces on the handler's Documents screen.
      // Deterministic ID + .create() so a duplicate trigger is a no-op.
      const receiptDocId = `PAYOUT_INSPECTION_${input.docId}`;
      try {
        await db.collection("payments").doc(receiptDocId).create({
          reference: receiptDocId,
          userId: sideEffect.handlerId,
          type: "inspection_payout",
          amount: sideEffect.amount,
          status: "completed",
          relatedId: input.docId,
          propertyId: sideEffect.propertyId,
          propertyTitle: sideEffect.propertyTitle,
          description: `Inspection payout for ${propertyTitle}`,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        const code = (err as {code?: unknown})?.code;
        if (code === 6 || code === "already-exists") {
          logger.info("Inspection payout receipt already exists, skipping", {
            receiptDocId,
          });
        } else {
          logger.error("Inspection payout receipt write failed", {
            docId: input.docId,
            receiptDocId,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      }
    }

    return {success: true, auditLogId};
  },
);

// ============================================================
// 2. Rent landlord payout — flips landlordPayoutStatus on
//    active_rentals/{id}.
//
// Post-commit side effects (W5): writes a `rent_payout` activity and
// a `payments/PAYOUT_LANDLORD_{rentalId}` receipt so the payout shows
// in the landlord's Documents screen. Both best-effort.
// ============================================================
export const markRentLandlordPayoutPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(input.docId);

    interface RentPayoutSideEffect {
      amount: number;
      beneficiaryId: string | null;
      propertyId: string | null;
      propertyTitle: string | null;
    }

    const sideEffect = await db.runTransaction<RentPayoutSideEffect>(
      async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new HttpsError(
            "not-found",
            `active_rentals/${input.docId} not found.`,
          );
        }
        const data = snap.data()!;
        // G2/G3: never pay the landlord before the agreement is finalized, and
        // never while it's disputed. Pay-after-accept: also never before the
        // tenant's rent has actually been collected.
        assertAgreementFinalized(data);
        assertRentPaid(data);
        guardStatusTransition(
          data.landlordPayoutStatus,
          "pending",
          "landlordPayoutStatus",
        );
        const amt = readAmount(data, "landlordPayout");

        tx.update(ref, {
          landlordPayoutStatus: "paid",
          landlordPaidAt: FieldValue.serverTimestamp(),
          landlordPaidBy: adminUid,
          landlordPaymentReference: input.paymentReference,
          landlordPaymentNote: input.paymentNote,
        });

        return {
          amount: amt,
          beneficiaryId: readOptionalString(data, "landlordId"),
          propertyId: readOptionalString(data, "propertyId"),
          propertyTitle: readOptionalString(data, "propertyTitle"),
        };
      });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_rent_landlord_payout_paid",
      targetCollection: "active_rentals",
      targetId: input.docId,
      amount: sideEffect.amount,
      paymentReference: input.paymentReference,
      ...(input.paymentNote !== null && {paymentNote: input.paymentNote}),
    });

    await writeRentPayoutSideEffects({
      rentalId: input.docId,
      beneficiaryId: sideEffect.beneficiaryId,
      amount: sideEffect.amount,
      propertyId: sideEffect.propertyId,
      propertyTitle: sideEffect.propertyTitle,
      receiptDocId: `PAYOUT_LANDLORD_${input.docId}`,
      activityTitle: "Rent Payout Sent",
      activityMessageBuilder: (a, p) =>
        `Your rent payout of ₦${a.toFixed(0)} for ${p} has been sent ` +
        "to your bank account.",
      receiptDescription: (p) => `Rent payout for ${p}`,
      adminUid,
    });

    return {success: true, auditLogId};
  },
);

// ============================================================
// 3. Rent agent commission — flips agentPayoutStatus on
//    active_rentals/{id}.
//
// Post-commit side effects (W5): writes a `rent_payout` activity and
// a `payments/PAYOUT_AGENT_{rentalId}` receipt. Both best-effort.
// Skipped if agentId is null (no agent on the rental). Mirrors the
// pre-migration mobile behaviour at active_rental_service.dart:888.
// ============================================================
export const markRentAgentCommissionPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(input.docId);

    interface RentPayoutSideEffect {
      amount: number;
      beneficiaryId: string | null;
      propertyId: string | null;
      propertyTitle: string | null;
    }

    const sideEffect = await db.runTransaction<RentPayoutSideEffect>(
      async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new HttpsError(
            "not-found",
            `active_rentals/${input.docId} not found.`,
          );
        }
        const data = snap.data()!;
        // G2/G3: gate the agent commission on the same finalized-agreement
        // condition as the landlord payout — no money leaves until the deal is
        // done and any dispute resolved — and on the rent having been collected.
        assertAgreementFinalized(data);
        assertRentPaid(data);
        guardStatusTransition(
          data.agentPayoutStatus,
          "pending",
          "agentPayoutStatus",
        );
        const amt = readAmount(data, "agentPayout");

        tx.update(ref, {
          agentPayoutStatus: "paid",
          agentPaidAt: FieldValue.serverTimestamp(),
          agentPaidBy: adminUid,
          agentPaymentReference: input.paymentReference,
          agentPaymentNote: input.paymentNote,
        });

        return {
          amount: amt,
          beneficiaryId: readOptionalString(data, "agentId"),
          propertyId: readOptionalString(data, "propertyId"),
          propertyTitle: readOptionalString(data, "propertyTitle"),
        };
      });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_rent_agent_commission_paid",
      targetCollection: "active_rentals",
      targetId: input.docId,
      amount: sideEffect.amount,
      paymentReference: input.paymentReference,
      ...(input.paymentNote !== null && {paymentNote: input.paymentNote}),
    });

    await writeRentPayoutSideEffects({
      rentalId: input.docId,
      beneficiaryId: sideEffect.beneficiaryId,
      amount: sideEffect.amount,
      propertyId: sideEffect.propertyId,
      propertyTitle: sideEffect.propertyTitle,
      receiptDocId: `PAYOUT_AGENT_${input.docId}`,
      activityTitle: "Agent Fee Payout Sent",
      activityMessageBuilder: (a, p) =>
        `Your agent fee payout of ₦${a.toFixed(0)} for ${p} has been ` +
        "sent to your bank account.",
      receiptDescription: (p) => `Agent fee payout for ${p}`,
      adminUid,
    });

    return {success: true, auditLogId};
  },
);

// ============================================================
// 3b. Admin force-finalize a tenancy agreement — the escape hatch for the
//     payout gate (G2/G3). When a deal was settled outside the in-app agreement
//     flow (offline, tenant unresponsive, legacy doc), admin can deliberately
//     mark the agreement finalized so the payout can proceed. Audit-logged;
//     records who/why on the rental. Blocks re-finalizing an already-finalized
//     agreement (idempotency).
// ============================================================
interface ForceFinalizeInput {
  docId?: unknown;
  reason?: unknown;
}

export const adminForceFinalizeAgreement = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const adminUid = request.auth!.uid;
    const raw = (request.data ?? {}) as ForceFinalizeInput;

    if (typeof raw.docId !== "string" || raw.docId.trim().length === 0) {
      throw new HttpsError("invalid-argument", "docId must be a non-empty string.");
    }
    if (typeof raw.reason !== "string" || raw.reason.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "reason is required — record why the agreement is being force-finalized.",
      );
    }
    const docId = raw.docId.trim();
    const reason = raw.reason.trim();

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(docId);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", `active_rentals/${docId} not found.`);
      }
      if (snap.data()!.agreementStatus === "finalized") {
        throw new HttpsError(
          "failed-precondition",
          "This agreement is already finalized.",
        );
      }
      tx.update(ref, {
        agreementStatus: "finalized",
        agreementFinalizedByAdmin: true,
        adminFinalizedReason: reason,
        adminFinalizedBy: adminUid,
        landlordFinalizedAt: FieldValue.serverTimestamp(),
        tenantDisputeReason: null,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "admin_force_finalize_agreement",
      targetCollection: "active_rentals",
      targetId: docId,
      amount: 0,
      paymentReference: "force_finalize",
      paymentNote: reason,
    });

    return {success: true, auditLogId};
  },
);

// ============================================================
// 4. Refund — flips status on refunds/{id}.
// ============================================================
export const markRefundPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("refunds").doc(input.docId);

    interface RefundSideEffect {
      amount: number;
      beneficiaryId: string | null;
      propertyId: string | null;
      propertyTitle: string | null;
    }

    const sideEffect = await db.runTransaction<RefundSideEffect>(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError(
          "not-found",
          `refunds/${input.docId} not found.`,
        );
      }
      const data = snap.data()!;
      guardStatusTransition(data.status, "pending", "status");
      const amt = readAmount(data, "amount");

      tx.update(ref, {
        status: "paid",
        paidAt: FieldValue.serverTimestamp(),
        paidBy: adminUid,
        paymentReference: input.paymentReference,
        paymentNote: input.paymentNote,
      });

      return {
        amount: amt,
        beneficiaryId: readOptionalString(data, "beneficiaryId"),
        propertyId: readOptionalString(data, "propertyId"),
        propertyTitle: readOptionalString(data, "propertyTitle"),
      };
    });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_refund_paid",
      targetCollection: "refunds",
      targetId: input.docId,
      amount: sideEffect.amount,
      paymentReference: input.paymentReference,
      ...(input.paymentNote !== null && {paymentNote: input.paymentNote}),
    });

    // Post-commit: notify the beneficiary + write a payment receipt so the
    // payout lands in their Documents screen. Both best-effort — a failed
    // display write must not undo the (already-real) money mark. Mirrors the
    // three payout CFs above.
    if (sideEffect.beneficiaryId !== null) {
      const propertyTitle = sideEffect.propertyTitle ?? "your inspection";

      await writeNotificationOnce(
        `refund_${input.docId}_paid_${sideEffect.beneficiaryId}`,
        {
          userId: sideEffect.beneficiaryId,
          type: "refund_paid",
          title: "Refund Sent",
          body:
            `Your refund of ₦${sideEffect.amount.toFixed(0)} for ` +
            `${propertyTitle} has been sent to your bank account.`,
          payload: {route: "/tenant/documents"},
        },
      );

      const receiptDocId = `REFUND_${input.docId}`;
      try {
        await db.collection("payments").doc(receiptDocId).create({
          reference: receiptDocId,
          userId: sideEffect.beneficiaryId,
          type: "refund",
          amount: sideEffect.amount,
          status: "completed",
          relatedId: input.docId,
          propertyId: sideEffect.propertyId,
          propertyTitle: sideEffect.propertyTitle,
          description: `Refund for ${propertyTitle}`,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        const code = (err as {code?: unknown})?.code;
        if (code === 6 || code === "already-exists") {
          logger.info("Refund receipt already exists, skipping", {
            receiptDocId,
          });
        } else {
          logger.error("Refund receipt write failed", {
            docId: input.docId,
            receiptDocId,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      }
    }

    return {success: true, auditLogId};
  },
);

// ============================================================
// Rent-payout post-commit side-effect helper.
//
// Shared by markRentLandlordPayoutPaid + markRentAgentCommissionPaid.
// Writes one activity doc + one payment receipt doc. Both writes are
// best-effort: failures are logged, never thrown. Receipt uses
// .create() with a deterministic ID so a duplicate trigger is a no-op.
//
// NOTE on the activity doc's `landlordId` field: the activity service
// queries by `landlordId` for the user's feed (see activity_service in
// mobile), so all activities — even agent-targeted ones — set
// `landlordId` to the beneficiary's UID. This is a pre-existing quirk
// of the activities schema; flagged for a future fix in a dedicated
// activities refactor ticket. Mirroring the mobile behaviour here so
// the agent's feed continues to surface their rent-payout activity.
// ============================================================

interface RentPayoutSideEffectsInput {
  rentalId: string;
  beneficiaryId: string | null;
  amount: number;
  propertyId: string | null;
  propertyTitle: string | null;
  receiptDocId: string;
  activityTitle: string;
  activityMessageBuilder: (amount: number, propertyTitle: string) => string;
  receiptDescription: (propertyTitle: string) => string;
  adminUid: string;
}

async function writeRentPayoutSideEffects(
  input: RentPayoutSideEffectsInput,
): Promise<void> {
  // Mirrors the mobile pre-migration behaviour: if there's no
  // beneficiary on the doc, skip activity + receipt entirely. The
  // money flip already succeeded; this is purely display.
  if (input.beneficiaryId === null) return;

  const db = getFirestore();
  const propertyTitle = input.propertyTitle ?? "your property";

  // Activity write.
  try {
    await db.collection("activities").add({
      // Pre-existing schema quirk: feed queries by `landlordId`, so
      // we set it to the beneficiary regardless of role. TODO: fix
      // in a dedicated activities-schema refactor ticket.
      landlordId: input.beneficiaryId,
      type: "rent_payout",
      title: input.activityTitle,
      message: input.activityMessageBuilder(input.amount, propertyTitle),
      propertyId: input.propertyId,
      rentalId: input.rentalId,
      amount: input.amount,
      actorId: input.adminUid,
      actorName: "ClearRent Admin",
      isRead: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    logger.error("rent_payout activity write failed", {
      rentalId: input.rentalId,
      beneficiaryId: input.beneficiaryId,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  // Payment receipt write (deterministic ID, .create() for idempotency).
  try {
    await db.collection("payments").doc(input.receiptDocId).create({
      reference: input.receiptDocId,
      userId: input.beneficiaryId,
      type: "rent_payout",
      amount: input.amount,
      status: "completed",
      relatedId: input.rentalId,
      propertyId: input.propertyId,
      propertyTitle: input.propertyTitle,
      description: input.receiptDescription(propertyTitle),
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    const code = (err as {code?: unknown})?.code;
    if (code === 6 || code === "already-exists") {
      logger.info("Payment receipt already exists, skipping", {
        receiptDocId: input.receiptDocId,
      });
      return;
    }
    logger.error("Payment receipt write failed", {
      rentalId: input.rentalId,
      receiptDocId: input.receiptDocId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

// ============================================================
// 5. Refund creation trigger — watches inspection_requests for
//    paymentStatus transitioning to "refunded", creates a
//    refunds/{requestId} doc with status: "pending".
//
// Idempotency: uses .create() with the inspectionRequest's own id
// as the refund doc id. Duplicate triggers fail cleanly on
// already-exists and we log and return.
//
// Reason derivation: pulls the most specific existing field that
// describes WHY the refund happened. This avoids forcing a refactor
// of the four mobile cancel/decline call sites.
// ============================================================

interface RefundReasonResult {
  source: string;
  reason: string;
}

function deriveRefundReason(
  data: FirebaseFirestore.DocumentData,
): RefundReasonResult {
  // Admin resolved an awaiting-outcome inspection from the review queue (a full
  // or partial refund). Take precedence so the refund record's source is
  // accurate for the audit trail instead of being mislabeled below.
  if (data.resolvedByAdmin === true) {
    return {
      source: "inspection_admin_review",
      reason:
        (data.refundReason as string | undefined) ??
        "Refund issued by admin after review",
    };
  }

  // System slot-conflict decline: ClearRent double-booked the handler and
  // auto-declined the newer request. Distinct source so the amount logic can
  // issue a FULL refund (our error) instead of keeping the platform charge.
  if (data.declineSource === "system_slot_conflict") {
    return {
      source: "inspection_slot_conflict",
      reason:
        (data.refundReason as string | undefined) ??
        (data.declineReason as string | undefined) ??
        "Slot conflict — automatic full refund",
    };
  }

  // Handler exit ramp: agent or landlord cancelled on tenant's behalf.
  const cancelledBy = data.cancelledBy as string | undefined;
  if (cancelledBy === "agent" || cancelledBy === "landlord") {
    return {
      source: "inspection_handler_cancel",
      reason:
        (data.cancellationReason as string | undefined) ??
        "Inspection cancelled by " + cancelledBy,
    };
  }

  // Final decline path — system or landlord declined after the window.
  const declinedBy = data.declinedBy as string | undefined;
  if (declinedBy === "landlord") {
    return {
      source: "inspection_landlord_decline",
      reason:
        (data.declineReason as string | undefined) ??
        "Inspection declined by landlord",
    };
  }
  if (declinedBy === "system") {
    return {
      source: "inspection_final_decline",
      reason:
        (data.declineReason as string | undefined) ??
        "Inspection request expired without approval",
    };
  }

  // Reschedule decline path — neither cancelledBy nor declinedBy is set,
  // but _processRefund still ran. The mobile path sets refundReason
  // explicitly in some cases.
  return {
    source: "inspection_reschedule_decline",
    reason:
      (data.refundReason as string | undefined) ??
      "Inspection refund processed",
  };
}

export const onInspectionRefundTriggered = onDocumentUpdated(
  "inspection_requests/{requestId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only fire on the paymentStatus transition INTO "refunded".
    if (before.paymentStatus === "refunded") return;
    if (after.paymentStatus !== "refunded") return;

    const requestId = event.params.requestId;

    const tenantId = after.tenantId as string | undefined;
    if (!tenantId) {
      logger.error("Refund trigger: tenantId missing", {requestId});
      return;
    }

    const totalFee = after.totalFee;
    if (
      typeof totalFee !== "number" ||
      !Number.isFinite(totalFee) ||
      totalFee <= 0
    ) {
      logger.error("Refund trigger: invalid totalFee", {requestId, totalFee});
      return;
    }

    const {source, reason} = deriveRefundReason(after);

    // Refund amount policy. The ₦3,000 platform service charge (=
    // InspectionPricing.clearrentTake) is NON-REFUNDABLE once a booking is
    // made — when an inspection falls through for reasons not attributable to
    // the tenant, only the handler's ₦7,000 portion is returned. Two sources
    // get the FULL fee back:
    //   • inspection_admin_review — the admin sets the exact refundAmount from
    //     the review queue (honored via the override below).
    //   • inspection_slot_conflict — ClearRent double-booked the handler, so it
    //     is our error and we do not keep our cut.
    // An explicit `refundAmount` override still wins when present, clamped to
    // (0, totalFee] so it can only ever REDUCE the refund, never inflate it.
    // The non-refundable platform charge comes from config/pricing — the same
    // document the tenant is charged from — so it can never drift from the
    // booking fee. Was a hardcoded 3000 kept in sync by hand.
    const platformCharge = (await getPricing()).inspection.platform;
    const fullRefundSource =
      source === "inspection_admin_review" ||
      source === "inspection_slot_conflict";
    const baseAmount = fullRefundSource ?
      totalFee :
      Math.max(0, totalFee - platformCharge);

    const override = after.refundAmount;
    const useOverride =
      typeof override === "number" &&
      Number.isFinite(override) &&
      override > 0 &&
      override <= totalFee;
    const amount = useOverride ? override : baseAmount;

    const db = getFirestore();
    const beneficiaryBank = await readBeneficiaryBank(db, tenantId);
    try {
      await db.collection("refunds").doc(requestId).create({
        status: "pending",
        amount,
        beneficiaryId: tenantId,
        beneficiaryRole: "tenant",
        beneficiaryBank,
        source,
        sourceCollection: "inspection_requests",
        sourceDocId: requestId,
        reason,
        propertyId: after.propertyId ?? null,
        propertyTitle: after.propertyTitle ?? null,
        createdAt: FieldValue.serverTimestamp(),
        paidAt: null,
        paidBy: null,
        paymentReference: null,
        paymentNote: null,
      });

      logger.info("Refund record created", {
        requestId,
        amount,
        beneficiaryId: tenantId,
        source,
      });
    } catch (err) {
      // .create() throws ALREADY_EXISTS if the refund doc is already
      // there — that means the trigger fired twice. Safe to ignore.
      // The error code can be a numeric gRPC status (6) or a string
      // identifier ("already-exists") depending on the SDK layer.
      const code = (err as {code?: unknown})?.code;
      if (code === 6 || code === "already-exists") {
        logger.info("Refund record already exists, skipping", {requestId});
        return;
      }
      logger.error("Refund record creation failed", {
        requestId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },
)
// ============================================================
// 6. Rental-interest loser refund trigger — watches rental_interests
//    for status transitioning to "accepted" (landlord picked a winner).
//    Every OTHER payment_verified interest on the same property is a
//    loser: the tenant paid in full and was locked in, but the
//    landlord chose someone else. Flip each to "lost_to_other",
//    record the refund reason, and notify the tenant. Admin processes
//    the actual bank refund from the payments dashboard (Refunded tab).
//
//    Refunds are MANUAL (no auto-Paystack): the flip surfaces the
//    loser in the admin payments page exactly like any other rent
//    refund. The refund must be returned to the originating account
//    — enforced at admin verification/refund time, NOT here.
//
//    Idempotency: re-firing on an already-accepted doc re-runs the
//    sibling query, but losers already flipped to lost_to_other no
//    longer match the payment_verified filter, so the second pass is
//    a no-op. Notifications use writeNotificationOnce with a
//    deterministic key.
// ============================================================
/**
 * Create the tenancy record the moment a landlord accepts.
 *
 * This used to be a client call made only by the Flutter landlord screen
 * (active_rental_service.dart createActiveRental). Web never had it, so a
 * landlord who accepted from the browser left the tenant with an accepted
 * interest and NO rental — nothing to attach an agreement to, and therefore no
 * way to pay rent. Doing it here makes it origin-agnostic and removes the
 * app's accept-then-create race, where a failed second step stranded a tenant.
 *
 * The rental doc id IS the interest id, so a double fire (or a client racing
 * this) converges on one document instead of minting duplicates. `create()`
 * throws ALREADY_EXISTS, which is the idempotency guard.
 *
 * Born UNPAID (`pending_payment`): pay-after-accept means the tenancy is not
 * real until rent lands, and that status is deliberately outside the server's
 * OCCUPYING_RENTAL_STATUSES, so the unit stays on the market until it is.
 *
 * @param {Firestore} db Firestore instance.
 * @param {string} interestId The accepted interest's id, reused as rental id.
 * @param {FirebaseFirestore.DocumentData} interest The accepted interest.
 * @return {Promise<void>}
 */
async function createRentalForAcceptedInterest(
  db: Firestore,
  interestId: string,
  interest: FirebaseFirestore.DocumentData,
): Promise<void> {
  const propertyId = interest.propertyId as string;

  // The caution deposit is snapshotted, not read at move-out: it lives on the
  // property, which the landlord may edit once the unit is vacant, so reading
  // it later would report whatever the listing says then rather than what this
  // tenant was promised.
  let cautionDeposit = 0;
  let cautionDepositRefundable = true;
  try {
    const propSnap = await db.collection("properties").doc(propertyId).get();
    const p = propSnap.data();
    if (p) {
      cautionDeposit = Number(p.cautionDeposit ?? 0);
      cautionDepositRefundable = p.cautionDepositRefundable !== false;
    }
  } catch (err) {
    logger.error("Caution-deposit snapshot failed — defaulting to 0", {
      interestId,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  const now = new Date();
  const leaseEnd = new Date(now);
  leaseEnd.setFullYear(leaseEnd.getFullYear() + 1);

  const rentAmount = Number(interest.rentAmount ?? 0) > 0 ?
    Number(interest.rentAmount) :
    Number(interest.paymentAmount ?? 0);
  const agentId = (interest.agentId as string | null) ?? null;

  // ── Pre-uploaded agreement ────────────────────────────────────────────
  // A landlord can attach a blank agreement to the PROPERTY before any tenant
  // exists. If one is on file it is copied onto this tenancy now, so accepting
  // a tenant needs no upload step. The tenant still reviews it: the status goes
  // to pending_review exactly as a manual upload does.
  //
  // The storage path is copied, not referenced. Every upload writes a new
  // uniquely-named object (`agreement_{millis}`), so a landlord replacing the
  // property's copy later cannot alter the document THIS tenant reviewed.
  //
  // Skipped when the rent has moved on since the agreement was written —
  // binding a tenant to a document showing the old price is worse than asking
  // the landlord to upload a current one.
  let agreementPath = "";
  try {
    const aSnap = await db
      .collection("properties")
      .doc(propertyId)
      .collection("private")
      .doc("agreement")
      .get();
    const a = aSnap.data();
    const storedPath = (a?.storagePath as string | undefined) ?? "";
    const rentAtUpload = Number(a?.rentAtUpload ?? 0);
    if (storedPath) {
      if (rentAtUpload > 0 && rentAmount > 0 && rentAtUpload !== rentAmount) {
        logger.info("Property agreement stale for this rent — not attached", {
          interestId, rentAtUpload, rentAmount,
        });
      } else {
        agreementPath = storedPath;
      }
    }
  } catch (err) {
    // Never block the tenancy on this — the landlord can still upload manually.
    logger.error("Property agreement lookup failed", {
      interestId,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  try {
    await db.collection("active_rentals").doc(interestId).create({
      propertyId,
      tenantId: interest.tenantId,
      landlordId: interest.landlordId,
      agentId,
      inspectionRequestId: interest.inspectionRequestId ?? null,
      rentalInterestId: interestId,
      propertyTitle: interest.propertyTitle ?? "",
      propertyImage: interest.propertyImage ?? "",
      propertyAddress: interest.propertyAddress ?? "",
      tenantName: interest.tenantName ?? "",
      landlordName: interest.landlordName ?? "",
      rentAmount,
      agentFee: Number(interest.agentFee ?? 0),
      totalPaid: 0,
      rentPaymentStatus: "pending",
      landlordPayout: Number(interest.landlordPayout ?? 0),
      agentPayout: Number(interest.agentPayout ?? 0),
      clearrentEarnings: Number(interest.clearrentEarnings ?? 0),
      landlordPayoutStatus: "pending",
      agentPayoutStatus: agentId ? "pending" : "not_applicable",
      inspectionFeeCredit: 5000,
      cautionDeposit,
      cautionDepositRefundable,
      rentFrequency: "yearly",
      leaseStartDate: Timestamp.fromDate(now),
      leaseEndDate: Timestamp.fromDate(leaseEnd),
      nextPaymentDue: Timestamp.fromDate(leaseEnd),
      status: "pending_payment",
      hasPaymentReminder: false,
      // pending_review is what prompts the tenant (onActiveRentalUpdated fires
      // on that transition). Without an agreement on file both stay unset and
      // the landlord uploads later, exactly as before.
      ...(agreementPath ?
        {
          agreementUrl: agreementPath,
          agreementStatus: "pending_review",
          agreementUploadedAt: FieldValue.serverTimestamp(),
          agreementFromProperty: true,
        } :
        {}),
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    logger.info("Active rental created for accepted interest", {
      interestId,
      agreementPreattached: agreementPath.length > 0,
    });
  } catch (err) {
    const code = (err as {code?: number | string})?.code;
    if (code === 6 || code === "already-exists") {
      logger.info("Active rental already exists, skipping", {interestId});
      return;
    }
    throw err;
  }
}

export const onRentalInterestAccepted = onDocumentUpdated(
  "rental_interests/{interestId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only fire on the transition INTO "accepted".
    if (before.status === "accepted") return;
    if (after.status !== "accepted") return;

    const winnerId = event.params.interestId;
    const propertyId = after.propertyId as string | undefined;
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "the property";

    // Tell the WINNING tenant they got the place — otherwise acceptance is a
    // silent surprise (only the losing applicants were ever notified). Fires
    // before the propertyId guard so the winner is told regardless.
    const winnerTenantId = after.tenantId as string | undefined;
    if (winnerTenantId) {
      await writeNotificationOnce(
        `interest_${winnerId}_accepted_${winnerTenantId}`,
        {
          userId: winnerTenantId,
          type: "rental_accepted",
          title: "You got the place! 🎉",
          body:
            `Your application for ${propertyTitle} was accepted. ` +
            "Next: review your tenancy agreement to complete your move-in.",
          payload: {route: "/tenant/my-rentals"},
        },
      );
    }

    if (!propertyId) {
      logger.error("Loser-refund trigger: propertyId missing", {winnerId});
      return;
    }

    const db = getFirestore();

    // The tenancy record itself. Wrapped so a failure here still leaves the
    // losing applicants to be closed out below — and logged loudly, because
    // without a rental the accepted tenant cannot be sent an agreement and
    // cannot pay, which is exactly the dead end this trigger exists to end.
    try {
      await createRentalForAcceptedInterest(db, winnerId, after);
    } catch (err) {
      logger.error("Active rental creation FAILED for accepted interest", {
        winnerId,
        error: err instanceof Error ? err.message : String(err),
      });
    }

    // ── Pay-after-accept: close the UNPAID applicants ──
    // Under the current flow only the accepted tenant ever pays, so every other
    // applicant is sitting at "pending_acceptance" having paid nothing. There is
    // no refund to issue — just mark them "not_selected" and tell them they were
    // not charged. Idempotent: a re-fire re-runs the query, but already-closed
    // siblings no longer match "pending_acceptance", so the second pass no-ops.
    const unpaidSnap = await db
      .collection("rental_interests")
      .where("propertyId", "==", propertyId)
      .where("status", "==", "pending_acceptance")
      .get();

    for (const doc of unpaidSnap.docs) {
      if (doc.id === winnerId) continue; // never touch the winner
      const applicant = doc.data();
      const tenantId = applicant.tenantId as string | undefined;

      try {
        await doc.ref.update({
          status: "not_selected",
          updatedAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        logger.error("Failed to close unpaid applicant", {
          loserId: doc.id,
          error: err instanceof Error ? err.message : String(err),
        });
        continue;
      }

      if (!tenantId) {
        logger.error("Unpaid applicant has no tenantId", {loserId: doc.id});
        continue;
      }

      // Push notification — deterministic key so a re-fire is a no-op.
      await writeNotificationOnce(
        `interest_${doc.id}_notSelected_${tenantId}`,
        {
          userId: tenantId,
          type: "rental_not_selected",
          title: "Another applicant was chosen",
          body:
            `The landlord chose another applicant for ${propertyTitle}. ` +
            "You were not charged.",
          payload: {route: "/tenant/inspections"},
        },
      );

      // Activity feed entry (feed queries by landlordId — set to the
      // recipient regardless of role; same schema quirk documented elsewhere).
      try {
        await db.collection("activities").add({
          userId: tenantId,
          landlordId: tenantId,
          type: "rental_not_selected",
          title: "Not Selected",
          message:
            `The landlord chose another applicant for ${propertyTitle}. ` +
            "You were not charged.",
          relatedId: doc.id,
          propertyId,
          isRead: false,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        logger.error("not_selected activity write failed", {
          loserId: doc.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }

      logger.info("Unpaid applicant closed (not_selected)", {
        loserId: doc.id,
        tenantId,
        propertyId,
      });
    }

    // ── LEGACY paid-loser refunds ──
    // Retained only for interests created under the OLD pay-before-accept flow,
    // where multiple tenants could reach "payment_verified" (paid in full). New
    // interests never enter that state, so this query is empty for them and the
    // block no-ops. Do not remove until all in-flight legacy interests drain.
    const snap = await db
      .collection("rental_interests")
      .where("propertyId", "==", propertyId)
      .where("status", "==", "payment_verified")
      .get();

    if (snap.empty) {
      logger.info("No legacy paid losers to refund", {winnerId, propertyId});
      return;
    }

    for (const doc of snap.docs) {
      // Defensive: never touch the winner (shouldn't match the filter
      // anyway since it's now "accepted", but guard regardless).
      if (doc.id === winnerId) continue;

      const loser = doc.data();
      const tenantId = loser.tenantId as string | undefined;

      const reason =
        "Property was rented to another applicant — " +
        "your payment is being refunded in full.";

      try {
        await doc.ref.update({
          status: "lost_to_other",
          refundReason: reason,
          refundedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        logger.error("Failed to flip losing interest", {
          loserId: doc.id,
          error: err instanceof Error ? err.message : String(err),
        });
        continue; // Skip notification if the flip itself failed.
      }

      if (!tenantId) {
        logger.error("Losing interest has no tenantId", {loserId: doc.id});
        continue;
      }

      // Refund record so the loser enters the admin payout queue, exactly
      // like an inspection refund. Best-effort + idempotent (deterministic
      // id = interest id, .create()): the lost_to_other flip above is the
      // source of truth; a failed refund-doc write is logged, never blocks.
      const refundAmount = loser.paymentAmount;
      if (
        typeof refundAmount === "number" &&
        Number.isFinite(refundAmount) &&
        refundAmount > 0
      ) {
        const beneficiaryBank = await readBeneficiaryBank(db, tenantId);
        try {
          await db.collection("refunds").doc(doc.id).create({
            status: "pending",
            amount: refundAmount,
            beneficiaryId: tenantId,
            beneficiaryRole: "tenant",
            beneficiaryBank,
            source: "rental_loser",
            sourceCollection: "rental_interests",
            sourceDocId: doc.id,
            reason,
            propertyId: propertyId ?? null,
            propertyTitle: after.propertyTitle ?? null,
            createdAt: FieldValue.serverTimestamp(),
            paidAt: null,
            paidBy: null,
            paymentReference: null,
            paymentNote: null,
          });
        } catch (err) {
          const code = (err as {code?: unknown})?.code;
          if (code === 6 || code === "already-exists") {
            logger.info("Loser refund record already exists, skipping", {
              loserId: doc.id,
            });
          } else {
            logger.error("Loser refund record creation failed", {
              loserId: doc.id,
              error: err instanceof Error ? err.message : String(err),
            });
          }
        }
      } else {
        logger.error("Loser refund: invalid paymentAmount", {
          loserId: doc.id,
          amount: refundAmount,
        });
      }

      // Push notification — deterministic key so a re-fire is a no-op.
      await writeNotificationOnce(
        `interest_${doc.id}_lostToOther_${tenantId}`,
        {
          userId: tenantId,
          type: "rental_not_selected",
          title: "Property Rented to Another Applicant",
          body:
            `The landlord accepted another tenant for ${propertyTitle}. ` +
            "Your full payment is being refunded.",
          payload: {
            route: "/tenant/inspections",
            initialTab: "2",
            param_interestId: doc.id,
          },
        },
      );

      // Activity feed entry. Mirrors the slot-conflict activity write:
      // the feed queries by `landlordId`, so set it to the recipient
      // (the losing tenant) regardless of role — same pre-existing
      // schema quirk documented in writeRentPayoutSideEffects.
      try {
        await db.collection("activities").add({
          userId: tenantId,
          landlordId: tenantId,
          type: "rental_not_selected",
          title: "Not Selected",
          message:
            `The landlord rented ${propertyTitle} to another applicant. ` +
            "Your payment is being refunded in full.",
          subtitle:
            `${propertyTitle} was rented to another applicant.`,
          relatedId: doc.id,
          propertyId,
          isRead: false,
          createdAt: FieldValue.serverTimestamp(),
        });
      } catch (err) {
        logger.error("Loser activity write failed", {
          loserId: doc.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }

      logger.info("Losing interest refunded", {
        loserId: doc.id,
        tenantId,
        propertyId,
      });
    }
  },
);