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
 *
 *   markRentLandlordPayoutPaid
 *     Flips landlordPayoutStatus on active_rentals/{id}.
 *     Amount source: landlordPayout on the doc.
 *
 *   markRentAgentCommissionPaid
 *     Flips agentPayoutStatus on active_rentals/{id}.
 *     Amount source: agentPayout on the doc.
 *
 *   markRefundPaid
 *     Flips status on refunds/{id}.
 *     Amount source: amount on the doc.
 *
 * Design notes:
 *   - Each function runs in a Firestore transaction to prevent two
 *     admins from double-marking the same payout.
 *   - Status-transition guard inside the transaction blocks doc:pending
 *     -> paid only. Replays / double-clicks fail with failed-precondition.
 *   - Audit log write happens AFTER the transaction commits. If the
 *     audit write fails, the money-mark stands and we log loudly.
 *     See admin_helpers.ts for the rationale.
 *   - Field naming is inconsistent across collections (agentEarnings vs
 *     agentPayout). We tolerate this here rather than renaming, since
 *     a rename would require a data migration.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {
  assertAdmin,
  guardStatusTransition,
  writeAuditLog,
} from "./admin_helpers";

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

// ============================================================
// 1. Inspection agent payout — flips agentPayoutStatus on
//    inspection_requests/{id}.
// ============================================================
export const markInspectionAgentPayoutPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("inspection_requests").doc(input.docId);

    const amount = await db.runTransaction(async (tx) => {
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

      tx.update(ref, {
        agentPayoutStatus: "paid",
        agentPaidAt: FieldValue.serverTimestamp(),
        agentPaidBy: adminUid,
        agentPaymentReference: input.paymentReference,
        agentPaymentNote: input.paymentNote,
      });

      return amt;
    });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_inspection_agent_payout_paid",
      targetCollection: "inspection_requests",
      targetId: input.docId,
      amount,
      paymentReference: input.paymentReference,
      paymentNote: input.paymentNote ?? undefined,
    });

    return {success: true, auditLogId};
  },
);

// ============================================================
// 2. Rent landlord payout — flips landlordPayoutStatus on
//    active_rentals/{id}.
// ============================================================
export const markRentLandlordPayoutPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(input.docId);

    const amount = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError(
          "not-found",
          `active_rentals/${input.docId} not found.`,
        );
      }
      const data = snap.data()!;
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

      return amt;
    });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_rent_landlord_payout_paid",
      targetCollection: "active_rentals",
      targetId: input.docId,
      amount,
      paymentReference: input.paymentReference,
      paymentNote: input.paymentNote ?? undefined,
    });

    return {success: true, auditLogId};
  },
);

// ============================================================
// 3. Rent agent commission — flips agentPayoutStatus on
//    active_rentals/{id}.
// ============================================================
export const markRentAgentCommissionPaid = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const input = validateInput(request.data);
    const adminUid = request.auth!.uid;

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(input.docId);

    const amount = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError(
          "not-found",
          `active_rentals/${input.docId} not found.`,
        );
      }
      const data = snap.data()!;
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

      return amt;
    });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_rent_agent_commission_paid",
      targetCollection: "active_rentals",
      targetId: input.docId,
      amount,
      paymentReference: input.paymentReference,
      paymentNote: input.paymentNote ?? undefined,
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

    const amount = await db.runTransaction(async (tx) => {
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

      return amt;
    });

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: "mark_refund_paid",
      targetCollection: "refunds",
      targetId: input.docId,
      amount,
      paymentReference: input.paymentReference,
      paymentNote: input.paymentNote ?? undefined,
    });

    return {success: true, auditLogId};
  },
);

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

    const amount = after.totalFee;
    if (typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0) {
      logger.error("Refund trigger: invalid totalFee", {requestId, amount});
      return;
    }

    const {source, reason} = deriveRefundReason(after);

    const db = getFirestore();
    try {
      await db.collection("refunds").doc(requestId).create({
        status: "pending",
        amount,
        beneficiaryId: tenantId,
        beneficiaryRole: "tenant",
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
);