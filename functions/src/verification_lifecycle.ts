/**
 * Verification lifecycle logic.
 *
 * Deliberately free of firebase-functions *trigger* imports so it can be
 * invoked directly — by the Cloud Function wrappers in verification_ops.ts in
 * production, and by scripts/verify_verification_lifecycle.js against the
 * Firestore emulator. `nowMs` is injectable so tests can place a user either
 * side of an expiry boundary without waiting a year.
 */

import * as logger from "firebase-functions/logger";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  DocumentReference,
} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

// One verification period = 365 days.
export const VERIFICATION_PERIOD_MS = 365 * 24 * 60 * 60 * 1000;

// Days-before-expiry at which the user is warned to renew. Ascending so the
// sweep fires the tightest bucket the user currently falls into.
export const WARNING_THRESHOLDS_DAYS = [7, 14];

export interface SweepCounts {
  scanned: number;
  backfilled: number;
  expired: number;
  warned: number;
}

/**
 * Write the verification clock onto a user doc.
 * @param {DocumentReference} ref The user document reference.
 * @param {number} nowMs Clock origin in milliseconds.
 * @return {Promise<void>}
 */
export async function stampVerificationClock(
  ref: DocumentReference,
  nowMs: number,
): Promise<void> {
  await ref.set(
    {
      verifiedAt: Timestamp.fromMillis(nowMs),
      verificationExpiresAt: Timestamp.fromMillis(
        nowMs + VERIFICATION_PERIOD_MS,
      ),
      updatedAt: FieldValue.serverTimestamp(),
    },
    {merge: true},
  );
}

/**
 * Sweep the verification clock over every currently-verified user:
 *   • missing verificationExpiresAt → backfill a fresh 365-day window, so
 *     users verified before this feature shipped are not instantly expired;
 *   • past their window → soft-lock (status "expired", isVerified false) and
 *     send a renewal-due notice;
 *   • approaching expiry → one warning per threshold bucket crossed.
 * verificationExempt users (staff/test) are skipped entirely.
 * @param {number} nowMs Treated as "now"; injectable for tests.
 * @return {Promise<SweepCounts>} What the sweep did.
 */
export async function runVerificationExpirySweep(
  nowMs: number = Date.now(),
): Promise<SweepCounts> {
  const db = getFirestore();
  const dayMs = 24 * 60 * 60 * 1000;

  const snap = await db
    .collection("users")
    .where("verificationStatus", "==", "verified")
    .get();

  const counts: SweepCounts = {
    scanned: snap.size,
    backfilled: 0,
    expired: 0,
    warned: 0,
  };

  for (const doc of snap.docs) {
    const data = doc.data();
    if (data.verificationExempt === true) continue;

    const expiresTs = data.verificationExpiresAt as Timestamp | undefined;

    // ── Backfill: verified before this feature existed ──
    if (!expiresTs) {
      await doc.ref.set(
        {
          verifiedAt: data.verifiedAt ?? Timestamp.fromMillis(nowMs),
          verificationExpiresAt: Timestamp.fromMillis(
            nowMs + VERIFICATION_PERIOD_MS,
          ),
          updatedAt: FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
      counts.backfilled++;
      continue;
    }

    const expiresMs = expiresTs.toMillis();

    // ── Lapsed → soft-lock + renewal-due notice ──
    if (expiresMs <= nowMs) {
      await doc.ref.set(
        {
          verificationStatus: "expired",
          isVerified: false,
          updatedAt: FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
      counts.expired++;
      await writeNotificationOnce(
        `verif_expired_${doc.id}_${expiresMs}`,
        {
          userId: doc.id,
          title: "Verification expired — renew to continue",
          body:
            "Your annual verification has lapsed. Renew now to keep " +
            "booking, listing, and messaging on ClearRent.",
          payload: {type: "verification_expired"},
          type: "verification_expired",
        },
      );
      continue;
    }

    // ── Approaching expiry → warn once per threshold crossed ──
    const daysLeft = Math.ceil((expiresMs - nowMs) / dayMs);
    for (const threshold of WARNING_THRESHOLDS_DAYS) {
      if (daysLeft <= threshold) {
        const wrote = await writeNotificationOnce(
          `verif_expiring_${doc.id}_${threshold}_${expiresMs}`,
          {
            userId: doc.id,
            title: "Verification expiring soon",
            body:
              `Your verification expires in ${daysLeft} day` +
              `${daysLeft === 1 ? "" : "s"}. Renew to avoid losing ` +
              "access to bookings and listings.",
            payload: {type: "verification_expiring"},
            type: "verification_expiring",
          },
        );
        if (wrote) counts.warned++;
        break; // tightest bucket only
      }
    }
  }

  logger.info("Verification expiry sweep complete", counts);
  return counts;
}
