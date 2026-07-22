/**
 * Annual re-verification — Cloud Function wrappers.
 *
 * Verification is granted by an admin (direct write of
 * verificationStatus: "verified" / isVerified: true on the user doc — from
 * the admin dashboard or the Flutter admin path). These two triggers add the
 * "annual" part. The logic they call lives in verification_lifecycle.ts so it
 * stays testable outside the Functions runtime.
 */

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {
  runVerificationExpirySweep,
  stampVerificationClock,
  VERIFICATION_PERIOD_MS,
} from "./verification_lifecycle";

/**
 * Stamp verifiedAt + verificationExpiresAt whenever a user transitions INTO
 * the "verified" state. This is the single authoritative point for the
 * verification clock: every approval path sets verificationStatus:
 * "verified" on the user doc, so this catches first-time approvals and
 * renewals alike. The stamp leaves verificationStatus untouched, so the
 * self-update it produces is ignored by the transition guard below.
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
    await stampVerificationClock(after.ref, now);

    logger.info("Verification clock stamped", {
      uid: event.params.uid,
      expiresAt: new Date(now + VERIFICATION_PERIOD_MS).toISOString(),
    });
  },
);

/**
 * Daily verification-clock sweep. See runVerificationExpirySweep for the
 * backfill / expiry / warning semantics.
 * @return {Promise<void>}
 */
export const verificationExpirySweep = onSchedule(
  {schedule: "0 8 * * *", timeZone: "Africa/Lagos"},
  async () => {
    await runVerificationExpirySweep();
  },
);
