// ─────────────────────────────────────────────────────────────────────────────
// admin_review_ops.ts — admin review actions that were previously raw client
// updateDoc calls and so bypassed the immutable admin_audit_log (money-flow
// certification "audit gap", Medium). Routing them through admin-SDK callables
// gives every property-doc verdict and inspection-review resolution a
// server-authoritative, immutable audit entry — the same accountability the
// money-ops CFs already have.
//
//   adminReviewPropertyDoc  — verify / reject / publish a property's ownership
//                             doc (and its building, if grouped).
//   adminResolveInspection  — refund or complete an inspection stuck in the
//                             admin review queue.
//
// admin_audit_log is `create: if false` (admin SDK only), so the audit trail
// can only be written here, not from the client.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {assertAdmin, writeAuditLog} from "./admin_helpers";
import {resolveAdminAlertsForTarget} from "./admin_alerts";

const callableOptions = {timeoutSeconds: 30, enforceAppCheck: false};

function reqString(v: unknown, name: string): string {
  if (typeof v !== "string" || v.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} must be a non-empty string.`);
  }
  return v.trim();
}

// ── Property ownership-doc review ────────────────────────────────────────────

interface ReviewPropertyInput {
  propertyId?: unknown;
  action?: unknown; // 'verify' | 'reject' | 'publish'
  reason?: unknown; // required for 'reject'
}

export const adminReviewPropertyDoc = onCall(callableOptions, async (request) => {
  assertAdmin(request.auth);
  const adminUid = request.auth!.uid;
  const raw = (request.data ?? {}) as ReviewPropertyInput;

  const propertyId = reqString(raw.propertyId, "propertyId");
  const action = reqString(raw.action, "action");
  if (!["verify", "reject", "publish"].includes(action)) {
    throw new HttpsError("invalid-argument", "action must be verify|reject|publish.");
  }
  const reason =
    action === "reject" ? reqString(raw.reason, "reason") : null;

  const db = getFirestore();
  const propRef = db.collection("properties").doc(propertyId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(propRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", `properties/${propertyId} not found.`);
    }
    // Server derives the building link (don't trust the client).
    const buildingId = snap.data()!.buildingId as string | undefined;
    const now = FieldValue.serverTimestamp();

    if (action === "verify") {
      if (buildingId) {
        tx.update(db.collection("buildings").doc(buildingId), {
          ownershipDocStatus: "verified",
          ownershipDocRejectionReason: "",
          updatedAt: now,
        });
        tx.update(propRef, {isVerified: true, isAvailable: true, updatedAt: now});
      } else {
        tx.update(propRef, {
          ownershipDocStatus: "verified",
          isVerified: true,
          isAvailable: true,
          updatedAt: now,
        });
      }
    } else if (action === "reject") {
      if (buildingId) {
        tx.update(db.collection("buildings").doc(buildingId), {
          ownershipDocStatus: "rejected",
          ownershipDocRejectionReason: reason,
          updatedAt: now,
        });
        tx.update(propRef, {isAvailable: false, updatedAt: now});
      } else {
        tx.update(propRef, {
          ownershipDocStatus: "rejected",
          isVerified: false,
          isAvailable: false,
          ownershipDocRejectionReason: reason,
          updatedAt: now,
        });
      }
    } else {
      // publish — a grouped unit whose building C of O is already verified.
      tx.update(propRef, {isVerified: true, isAvailable: true, updatedAt: now});
    }
  });

  const auditLogId = await writeAuditLog({
    actorId: adminUid,
    action: `admin_property_doc_${action}`,
    targetCollection: "properties",
    targetId: propertyId,
    amount: 0,
    paymentReference: "property_review",
    ...(reason !== null && {paymentNote: reason}),
  });

  return {success: true, auditLogId};
});

// ── Inspection review resolution ─────────────────────────────────────────────

interface ResolveInspectionInput {
  requestId?: unknown;
  action?: unknown; // 'refund' | 'complete' | 'dismiss'
  refundAmount?: unknown; // required for 'refund', in Naira
}

export const adminResolveInspection = onCall(callableOptions, async (request) => {
  assertAdmin(request.auth);
  const adminUid = request.auth!.uid;
  const raw = (request.data ?? {}) as ResolveInspectionInput;

  const requestId = reqString(raw.requestId, "requestId");
  const action = reqString(raw.action, "action");
  if (!["refund", "complete", "dismiss"].includes(action)) {
    throw new HttpsError(
      "invalid-argument", "action must be refund|complete|dismiss.");
  }

  const db = getFirestore();
  const ref = db.collection("inspection_requests").doc(requestId);

  const resolvedAmount = await db.runTransaction<number>(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", `inspection_requests/${requestId} not found.`);
    }
    const data = snap.data()!;
    const now = FieldValue.serverTimestamp();
    // If there's an open dispute, any resolution closes it.
    const closesDispute = data.disputeStatus === "open" ?
      {disputeStatus: "resolved"} : {};

    if (action === "dismiss") {
      // Unfounded dispute: no money moves, status is untouched. This exists
      // purely to close the dispute + its admin alert with an audit trail.
      if (data.disputeStatus !== "open") {
        throw new HttpsError(
          "failed-precondition", "No open dispute to dismiss.");
      }
      tx.update(ref, {
        disputeStatus: "resolved",
        disputeDismissedAt: now,
        resolvedByAdmin: true,
        updatedAt: now,
      });
      return 0;
    }

    if (action === "complete") {
      tx.update(ref, {
        status: "completed",
        completedAt: now,
        resolvedByAdmin: true,
        updatedAt: now,
        ...closesDispute,
      });
      return 0;
    }

    // refund — clamp to (0, totalFee]. Setting paymentStatus=refunded triggers
    // onInspectionRefundTriggered to create the refund payout record.
    const totalFee = data.totalFee;
    if (typeof totalFee !== "number" || !(totalFee > 0)) {
      throw new HttpsError("failed-precondition", "Inspection has no valid totalFee.");
    }
    const amount = typeof raw.refundAmount === "number" ? raw.refundAmount : NaN;
    if (!Number.isFinite(amount) || amount <= 0 || amount > totalFee) {
      throw new HttpsError(
        "invalid-argument",
        `refundAmount must be between 1 and ${totalFee}.`,
      );
    }
    tx.update(ref, {
      status: "refunded",
      paymentStatus: "refunded",
      refundAmount: amount,
      refundReason:
        amount < totalFee ?
          "Resolved by admin — partial refund (non-refundable cut retained)" :
          "Resolved by admin — inspection not completed",
      resolvedByAdmin: true,
      refundedAt: now,
      updatedAt: now,
      ...closesDispute,
    });
    return amount;
  });

  // Close any open admin_alerts for this inspection (e.g. the dispute alert)
  // now that it's resolved, so the dashboard queue clears. Best-effort —
  // a failure here shouldn't undo the resolution above.
  try {
    await resolveAdminAlertsForTarget(requestId, adminUid);
  } catch (err) {
    logger.error("Failed to close admin alerts after resolution", {
      requestId,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  const auditLogId = await writeAuditLog({
    actorId: adminUid,
    action: `admin_inspection_${action}`,
    targetCollection: "inspection_requests",
    targetId: requestId,
    amount: resolvedAmount,
    paymentReference: "inspection_resolve",
  });

  return {success: true, auditLogId};
});
