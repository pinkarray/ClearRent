/**
 * Suspicious-activity checks, so the compliance officer is told about
 * anything that may need reporting to the NFIU.
 *
 * Each check that trips writes a compliance_flags/{flagId} record (server-only:
 * no rule matches the collection) and a critical admin alert, which is pushed
 * to every admin device. The flag stays open until an admin records a decision
 * with reviewComplianceFlag: "reported" (with the NFIU reference) or
 * "not_suspicious" (with a reason). That record is the evidence the review
 * happened, and is never deleted.
 *
 * Checks, thresholds from config/compliance (defaults below):
 *   large_payment     one payment at or above largePaymentNaira
 *   payment_velocity  velocityCount or more rent/renewal/extension payments
 *                     by one person within velocityDays
 *   shared_bank       one bank account saved by two different accounts
 *   duplicate_nin     one NIN submitted on two different accounts
 */
import {createHmac} from "crypto";
import * as logger from "firebase-functions/logger";
import {onDocumentWritten} from "firebase-functions/v2/firestore";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeAdminAlertOnce} from "./admin_alerts";
import {assertAdmin, writeAuditLog} from "./admin_helpers";

export interface ComplianceConfig {
  largePaymentNaira: number;
  velocityCount: number;
  velocityDays: number;
}

export const DEFAULT_COMPLIANCE: ComplianceConfig = {
  largePaymentNaira: 5_000_000,
  velocityCount: 3,
  velocityDays: 30,
};

const RENT_TYPES = new Set(["rent", "renewal", "extension"]);
/**
 * Money coming in. The payments collection also holds receipts for money
 * going out or already counted (rent_payout, refund, rent_renewal...), which
 * would double-count.
 */
const CHARGE_TYPES = new Set([
  "verification", "listing", "inspection", "rent", "renewal", "extension",
]);

/**
 * Thresholds, falling back per field to the defaults.
 * @return {Promise<ComplianceConfig>} The effective thresholds.
 */
async function getComplianceConfig(): Promise<ComplianceConfig> {
  const d = (await getFirestore().doc("config/compliance").get()).data() ?? {};
  const num = (v: unknown, f: number) =>
    typeof v === "number" && v > 0 ? v : f;
  return {
    largePaymentNaira: num(d.largePaymentNaira,
      DEFAULT_COMPLIANCE.largePaymentNaira),
    velocityCount: num(d.velocityCount, DEFAULT_COMPLIANCE.velocityCount),
    velocityDays: num(d.velocityDays, DEFAULT_COMPLIANCE.velocityDays),
  };
}

/**
 * Open a flag and alert the admins. Idempotent on flagId, so a re-fired
 * trigger never raises a second flag for the same thing.
 * @param {string} flagId Deterministic id for this finding.
 * @param {object} f What was found.
 * @return {Promise<boolean>} True if a new flag was opened.
 */
export async function raiseFlag(flagId: string, f: {
  kind: string;
  summary: string;
  uids: string[];
  meta?: Record<string, unknown>;
}): Promise<boolean> {
  const ref = getFirestore().collection("compliance_flags").doc(flagId);
  try {
    await ref.create({
      ...f,
      meta: f.meta ?? {},
      status: "open",
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    const code = (err as {code?: number | string}).code;
    if (code === 6 || code === "already-exists") return false;
    throw err;
  }
  await writeAdminAlertOnce(`suspicious_${flagId}`, {
    type: "suspicious_activity",
    severity: "critical",
    title: "Possible suspicious activity",
    body: `${f.summary} Review it and record whether you reported it to ` +
      "the NFIU.",
    targetCollection: "compliance_flags",
    targetId: flagId,
    meta: {kind: f.kind},
  });
  logger.warn("Compliance flag raised", {flagId, kind: f.kind});
  return true;
}

/**
 * A keyed fingerprint of a NIN: equal NINs give equal fingerprints, but the
 * NIN cannot be recovered or brute-forced without the key.
 * @param {string} nin The 11-digit NIN.
 * @param {string} key The NIN encryption key (reused as the HMAC key).
 * @return {string} Hex digest.
 */
export function ninFingerprint(nin: string, key: string): string {
  return createHmac("sha256", key).update(`nin|${nin}`).digest("hex");
}

/**
 * Flag a NIN already on another account.
 * @param {string} uid The account that just submitted it.
 * @param {string} fingerprint From ninFingerprint().
 * @return {Promise<void>}
 */
export async function checkDuplicateNin(
  uid: string,
  fingerprint: string,
): Promise<void> {
  const snap = await getFirestore().collection("users")
    .where("ninFingerprint", "==", fingerprint).limit(5).get();
  const others = snap.docs.map((d) => d.id).filter((id) => id !== uid);
  if (others.length === 0) return;
  await raiseFlag(`duplicate_nin_${fingerprint.slice(0, 16)}_${uid}`, {
    kind: "duplicate_nin",
    summary: `The same NIN is on ${others.length + 1} accounts.`,
    uids: [uid, ...others],
  });
}

/**
 * Flag a bank account saved by more than one person.
 * @param {string} uid The account that just saved it.
 * @return {Promise<void>}
 */
export async function checkSharedBank(uid: string): Promise<void> {
  const db = getFirestore();
  const key = (await db.collection("payout_accounts").doc(uid).get())
    .get("accountKey");
  if (typeof key !== "string") return;
  const snap = await db.collection("payout_accounts")
    .where("accountKey", "==", key).limit(5).get();
  const others = snap.docs.map((d) => d.id).filter((id) => id !== uid);
  if (others.length === 0) return;
  await raiseFlag(`shared_bank_${key.slice(0, 16)}_${uid}`, {
    kind: "shared_bank",
    summary: `One bank account is saved on ${others.length + 1} accounts.`,
    uids: [uid, ...others],
  });
}

/** Checks every payment as it completes. */
export const onPaymentCompletedCheck = onDocumentWritten(
  "payments/{ref}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!after || after.status !== "completed") return;
    if (before?.status === "completed") return;
    if (!CHARGE_TYPES.has(String(after.type))) return;
    const ref = event.params.ref;
    const uid = typeof after.userId === "string" ? after.userId : "";
    const amount = Number(after.amount ?? 0);
    const cfg = await getComplianceConfig();

    if (amount >= cfg.largePaymentNaira) {
      await raiseFlag(`large_payment_${ref}`, {
        kind: "large_payment",
        summary: `A payment of ₦${amount.toLocaleString("en-NG")} ` +
          `(${after.type ?? "payment"}) was made.`,
        uids: uid ? [uid] : [],
        meta: {reference: ref, amount, type: after.type ?? null},
      });
    }

    if (uid && RENT_TYPES.has(String(after.type))) {
      const since = Timestamp.fromMillis(
        Date.now() - cfg.velocityDays * 86_400_000);
      // Equality filters only, so no composite index; dates filtered here.
      const snap = await getFirestore().collection("payments")
        .where("userId", "==", uid)
        .where("status", "==", "completed")
        .get();
      const recent = snap.docs.filter((d) => {
        const t = d.get("createdAt") as Timestamp | undefined;
        return RENT_TYPES.has(String(d.get("type"))) &&
          (!t || t.toMillis() >= since.toMillis());
      });
      if (recent.length >= cfg.velocityCount) {
        await raiseFlag(`payment_velocity_${uid}_${ref}`, {
          kind: "payment_velocity",
          summary: `One person made ${recent.length} rent payments in ` +
            `${cfg.velocityDays} days.`,
          uids: [uid],
          meta: {references: recent.map((d) => d.id)},
        });
      }
    }
  },
);

/** Admin: record the decision on a flag. */
export const reviewComplianceFlag = onCall(
  {timeoutSeconds: 30, enforceAppCheck: false},
  async (request) => {
    assertAdmin(request.auth);
    const {flagId, outcome} = request.data ?? {};
    const note = String(request.data?.note ?? "").trim();
    const reportReference = String(request.data?.reportReference ?? "").trim();
    if (typeof flagId !== "string" || flagId.length === 0) {
      throw new HttpsError("invalid-argument", "flagId is required.");
    }
    if (outcome !== "reported" && outcome !== "not_suspicious") {
      throw new HttpsError("invalid-argument", "Choose an outcome.");
    }
    if (note.length === 0) {
      throw new HttpsError("invalid-argument", "Say why.");
    }
    if (outcome === "reported" && reportReference.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Add the NFIU report reference.",
      );
    }
    const db = getFirestore();
    const ref = db.collection("compliance_flags").doc(flagId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError("not-found", "Flag not found.");
      if (snap.get("status") !== "open") {
        throw new HttpsError("failed-precondition", "Already reviewed.");
      }
      tx.update(ref, {
        status: "reviewed",
        outcome,
        note,
        reportReference: reportReference || null,
        reviewedBy: request.auth!.uid,
        reviewedAt: FieldValue.serverTimestamp(),
      });
    });
    await db.collection("admin_alerts").doc(`suspicious_${flagId}`).set({
      status: "resolved",
      resolvedBy: request.auth!.uid,
      resolvedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    await writeAuditLog({
      actorId: request.auth!.uid,
      action: "review_compliance_flag",
      targetCollection: "compliance_flags",
      targetId: flagId,
      amount: 0,
      paymentReference: reportReference,
      paymentNote: `${outcome}: ${note}`,
    });
    return {success: true};
  },
);
