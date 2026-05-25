/**
 * Shared helpers for admin-only money-flow Cloud Functions.
 *
 * Used by:
 *   - markInspectionAgentPayoutPaid
 *   - markRentLandlordPayoutPaid
 *   - markRentAgentCommissionPaid
 *   - markRefundPaid
 *
 * Design notes:
 *   - Admin check is dual: custom claim `admin: true` OR super admin UID.
 *     This matches the dual model used elsewhere and lets us add more
 *     admins via claims without redeploying rules/functions.
 *   - Audit writes are best-effort. If the audit write fails after the
 *     money-mark succeeded, we log loudly but do not roll back. The
 *     alternative — failing the whole operation — would block the admin
 *     from marking a payout paid because of a transient Firestore hiccup,
 *     which is worse than a missing audit row we can reconstruct from logs.
 */

import {HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

// Must match the UID hard-coded in firestore.rules isAdmin().
// If you ever rotate this, update both places.
const SUPER_ADMIN_UID = "hEKsYuKKdzLlPD0QWOP2CvAxYlq2";

/**
 * Throws HttpsError if the caller is not an admin.
 *
 * Accepts the caller as admin if EITHER:
 *   (a) their auth token has a custom claim `admin === true`, OR
 *   (b) their UID matches SUPER_ADMIN_UID.
 *
 * (b) is the fallback so admin CFs keep working even if the custom-claim
 * mechanism is misconfigured or a claim is accidentally removed.
 */
export function assertAdmin(
  auth: {uid: string; token?: Record<string, unknown>} | undefined,
): void {
  if (!auth) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }

  const hasAdminClaim = auth.token?.admin === true;
  const isSuperAdmin = auth.uid === SUPER_ADMIN_UID;

  if (!hasAdminClaim && !isSuperAdmin) {
    throw new HttpsError("permission-denied", "Admin access required");
  }
}

/**
 * Throws HttpsError if the document's status field is not the expected
 * value. Used to prevent double-payment: a CF should only flip a doc
 * from `pending` to `paid`, never `paid` to `paid` again.
 *
 * @param currentStatus the value currently on the doc
 * @param expectedStatus the value we require to proceed (usually "pending")
 * @param fieldName the field name being checked, for the error message
 */
export function guardStatusTransition(
  currentStatus: string | undefined,
  expectedStatus: string,
  fieldName: string,
): void {
  if (currentStatus !== expectedStatus) {
    throw new HttpsError(
      "failed-precondition",
      `Cannot proceed: ${fieldName} is "${currentStatus ?? "unset"}", ` +
        `expected "${expectedStatus}"`,
    );
  }
}

/**
 * Entry written to admin_audit_log on every successful money-mark.
 *
 * `action` is one of:
 *   - mark_inspection_agent_payout_paid
 *   - mark_rent_landlord_payout_paid
 *   - mark_rent_agent_commission_paid
 *   - mark_refund_paid
 *
 * Amount is in naira (matches existing convention across the codebase).
 */
export interface AuditEntry {
  actorId: string;
  action: string;
  targetCollection: string;
  targetId: string;
  amount: number;
  paymentReference: string;
  paymentNote?: string;
}

/**
 * Write to admin_audit_log. Best-effort: never throws.
 *
 * Returns the new doc id on success, or null on failure. Callers can
 * ignore the return value — failures are logged here.
 */
export async function writeAuditLog(entry: AuditEntry): Promise<string | null> {
  try {
    const db = getFirestore();
    const ref = await db.collection("admin_audit_log").add({
      ...entry,
      createdAt: FieldValue.serverTimestamp(),
    });
    return ref.id;
  } catch (err) {
    logger.error("Audit log write failed", {
      entry,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}