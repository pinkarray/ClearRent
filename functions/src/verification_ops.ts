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
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {defineSecret} from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {resolveServerAmount} from "./pricing";
import {
  runVerificationExpirySweep,
  stampVerificationClock,
  VERIFICATION_PERIOD_MS,
} from "./verification_lifecycle";

/** Same secret index.ts binds; defineSecret is keyed by name, not identity. */
const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

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
    // Narrow on 30 days out of 31. The full read exists only so a document
    // missing verificationExpiresAt can be backfilled — a range query cannot
    // match a field that is absent — and no such document has existed since
    // the feature shipped. Monthly is often enough to catch one; daily was
    // paying for every verified user on the platform to find nothing.
    const fullScan = new Date().getDate() === 1;
    const counts = await runVerificationExpirySweep(Date.now(), fullScan);
    logger.info("verificationExpirySweep complete", {fullScan, ...counts});
  },
);

/**
 * Promotes a PAID web verification into the admin review queue.
 *
 * Web cannot do what the app does. The app pays first and creates the request
 * afterwards, and the create rule permits an owner — so one write, no problem.
 * Web has to upload the documents BEFORE paying, because paying redirects to
 * Paystack and back through a different origin and the chosen File objects do
 * not survive the trip. So the request is parked at `awaiting_payment` and has
 * to be promoted on return.
 *
 * That promotion was written as a CLIENT update, and
 * `verification_requests` is `allow update: if isAdmin()`. Every web payment
 * was therefore taken, the documents stored, and the request left at
 * `awaiting_payment` — a state the admin queue deliberately hides. The user
 * paid and vanished.
 *
 * It has to be server-side anyway, not merely to satisfy the rule: if a client
 * could move its own request to `pending`, the fee would be skippable by
 * calling that write directly, which is the entire thing `awaiting_payment`
 * exists to prevent.
 *
 * Verifies with Paystack rather than trusting the caller, binds the reference
 * to the caller through the payments doc so one person's transaction cannot
 * promote another's application, and is idempotent — a double callback (or a
 * refresh of the callback page) is a no-op rather than a second promotion.
 */
export const finalizeWebVerification = onCall(
  {
    secrets: [paystackSecret],
    timeoutSeconds: 30,
    // Matches resolveAccount / verifyPayment. Web initialises App Check too.
    enforceAppCheck: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const data = request.data as {requestId?: unknown; reference?: unknown};
    const requestId = typeof data.requestId === "string" ?
      data.requestId.trim() :
      "";
    const reference = typeof data.reference === "string" ?
      data.reference.trim() :
      "";
    if (!requestId || !reference) {
      throw new HttpsError(
        "invalid-argument",
        "requestId and reference are both required.",
      );
    }

    const db = getFirestore();
    const reqRef = db.collection("verification_requests").doc(requestId);
    const reqSnap = await reqRef.get();
    const reqData = reqSnap.data();
    if (!reqData) {
      throw new HttpsError("not-found", "Verification application not found.");
    }
    if (reqData.userId !== uid) {
      logger.error("Verification promotion by a non-owner", {uid, requestId});
      throw new HttpsError(
        "permission-denied",
        "This application belongs to someone else.",
      );
    }

    // Idempotent: the callback page can be refreshed, and Paystack can call
    // back twice. Neither should promote anything a second time.
    if (reqData.status !== "awaiting_payment") {
      logger.info("Verification already promoted", {uid, requestId});
      return {ok: true, alreadyDone: true};
    }

    // Bind the reference to THIS caller. Without it a valid reference from
    // somebody else's verification payment would promote this application.
    const paySnap = await db.collection("payments").doc(reference).get();
    const pay = paySnap.data();
    if (!pay || pay.userId !== uid || pay.type !== "verification") {
      logger.error("Verification reference does not belong to caller", {
        uid, requestId, reference, payUser: pay?.userId, payType: pay?.type,
      });
      throw new HttpsError(
        "permission-denied",
        "That payment reference is not yours.",
      );
    }

    // What this user actually owed — initial or renewal, decided server-side.
    const expected = await resolveServerAmount("verification", uid);

    const resp = await fetch(
      "https://api.paystack.co/transaction/verify/" +
        encodeURIComponent(reference),
      {
        method: "GET",
        headers: {
          "Authorization": `Bearer ${paystackSecret.value()}`,
          "Content-Type": "application/json",
        },
      },
    );
    const body = (await resp.json()) as {
      status?: boolean;
      data?: {status?: string; amount?: number};
    };
    const tx = body.data;
    if (!resp.ok || body.status !== true || !tx || tx.status !== "success") {
      throw new HttpsError(
        "failed-precondition",
        "That payment has not completed. If you were charged, contact support.",
      );
    }
    const paid = (typeof tx.amount === "number" ? tx.amount : 0) / 100;
    if (expected !== null && paid + 0.5 < expected) {
      logger.error("Verification underpaid", {uid, requestId, paid, expected});
      throw new HttpsError(
        "failed-precondition",
        "The amount paid does not cover the verification fee.",
      );
    }

    const batch = db.batch();
    batch.set(reqRef, {
      status: "pending",
      paymentReference: reference,
      paymentStatus: "paid",
      paidAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    batch.set(db.collection("users").doc(uid), {
      verificationStatus: "pending",
      // Renewals carry no new NIN — lets admin tell an annual renewal from a
      // first-time application in the review queue.
      isRenewal: false,
      verificationSubmittedAt: FieldValue.serverTimestamp(),
      verificationPaymentReference: reference,
      verificationPaymentStatus: "paid",
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    await batch.commit();

    logger.info("Web verification promoted to review", {
      uid, requestId, reference, paid,
    });
    return {ok: true, alreadyDone: false};
  },
);
