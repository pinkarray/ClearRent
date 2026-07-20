/**
 * Annual verification lifecycle.
 *
 * Verification is granted by an admin (direct write of
 * verificationStatus: "verified" / isVerified: true on the user doc — from
 * the admin dashboard or the Flutter admin path). These two functions add
 * the "annual" part:
 *
 *   onVerificationVerified — stamps the verification clock (verifiedAt +
 *     verificationExpiresAt) at the single moment a user becomes verified,
 *     covering every approval path including renewals.
 *
 *   verificationExpirySweep — a daily job that backfills pre-existing
 *     verified users, soft-locks lapsed ones, and warns those approaching
 *     expiry.
 */

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

// One verification period = 365 days.
const VERIFICATION_PERIOD_MS = 365 * 24 * 60 * 60 * 1000;

// Days-before-expiry at which the user is warned to renew. Ascending so the
// sweep fires the tightest bucket the user currently falls into.
const WARNING_THRESHOLDS_DAYS = [7, 14];

/**
 * Stamp verifiedAt + verificationExpiresAt whenever a user transitions INTO
 * the "verified" state. This is the single authoritative point for the
 * verification clock: every approval path sets verificationStatus:
 * "verified" on the user doc, so this catches first-time approvals and
 * renewals alike. The write below leaves verificationStatus untouched, so
 * the self-update it produces is ignored by the transition guard.
 * @param {object} event Firestore update event for users/{uid}.
 * @return {Promise<void>}
 */
export const onVerificationVerified = onDocumentUpdated(
  "users/{uid}",
  async (event) => {
    const before = event.data?.before;
    const after = event.data?.after;
    if (!before || !after) return;

    const beforeData = before.data();
    const afterData = after.data();
    if (!beforeData || !afterData) return;

    if (afterData.verificationStatus !== "verified") return;
    if (beforeData.verificationStatus === "verified") return;

    const now = Date.now();
    await after.ref.set(
      {
        verifiedAt: Timestamp.fromMillis(now),
        verificationExpiresAt: Timestamp.fromMillis(
          now + VERIFICATION_PERIOD_MS,
        ),
        updatedAt: FieldValue.serverTimestamp(),
      },
      {merge: true},
    );

    logger.info("Verification clock stamped", {
      uid: event.params.uid,
      expiresAt: new Date(now + VERIFICATION_PERIOD_MS).toISOString(),
    });
  },
);

/**
 * Daily verification-clock sweep:
 *   • Backfills any verified user missing verificationExpiresAt (existing
 *     users at launch) with a fresh 365-day window, so nobody is expired
 *     merely for having been verified before this feature shipped.
 *   • Expires verified users past their window: verificationStatus →
 *     "expired", isVerified → false. This is a soft-lock — the app blocks
 *     gated actions but the user can still sign in and renew. Notifies them.
 *   • Warns users approaching expiry at the WARNING_THRESHOLDS_DAYS marks.
 * verificationExempt users (staff/test) are skipped entirely.
 * @return {Promise<void>}
 */
export const verificationExpirySweep = onSchedule(
  {schedule: "0 8 * * *", timeZone: "Africa/Lagos"},
  async () => {
    const db = getFirestore();
    const now = Date.now();
    const dayMs = 24 * 60 * 60 * 1000;

    const snap = await db
      .collection("users")
      .where("verificationStatus", "==", "verified")
      .get();

    let backfilled = 0;
    let expired = 0;
    let warned = 0;

    for (const doc of snap.docs) {
      const data = doc.data();
      if (data.verificationExempt === true) continue;

      const expiresTs = data.verificationExpiresAt as Timestamp | undefined;

      // ── Backfill: verified before this feature existed ──
      if (!expiresTs) {
        await doc.ref.set(
          {
            verifiedAt: data.verifiedAt ?? Timestamp.fromMillis(now),
            verificationExpiresAt: Timestamp.fromMillis(
              now + VERIFICATION_PERIOD_MS,
            ),
            updatedAt: FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
        backfilled++;
        continue;
      }

      const expiresMs = expiresTs.toMillis();

      // ── Lapsed → soft-lock + renewal-due notice ──
      if (expiresMs <= now) {
        await doc.ref.set(
          {
            verificationStatus: "expired",
            isVerified: false,
            updatedAt: FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
        expired++;
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
      const daysLeft = Math.ceil((expiresMs - now) / dayMs);
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
          if (wrote) warned++;
          break; // tightest bucket only
        }
      }
    }

    logger.info("Verification expiry sweep complete", {
      scanned: snap.size,
      backfilled,
      expired,
      warned,
    });
  },
);
