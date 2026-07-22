/* eslint-disable */
/**
 * Annual re-verification lifecycle verification.
 *
 * Exercises verificationExpirySweep against the Firestore emulator so the
 * soft-lock path is proven before it can gate real users in production.
 * Covers: launch-day backfill, expiry soft-lock + notice, the 7/14-day
 * warning buckets, untouched healthy users, exempt accounts, and idempotency
 * on a second run.
 *
 * Emulator must be running on 8080, and functions must be built:
 *   npm run build
 *   firebase emulators:start --only firestore     (separate shell)
 *   node scripts/verify_verification_lifecycle.js
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "demo-clearrent";

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT});

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {
  runVerificationExpirySweep,
  VERIFICATION_PERIOD_MS,
} = require("../lib/verification_lifecycle");

let failures = 0;
function check(name, cond, detail) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}` + (cond ? "" : `  ← ${detail}`));
  if (!cond) failures++;
}

const DAY = 24 * 60 * 60 * 1000;
const db = getFirestore();

const USERS = [
  "u_backfill", "u_expired", "u_warn7", "u_warn14", "u_safe", "u_exempt",
];

async function wipe() {
  for (const uid of USERS) await db.collection("users").doc(uid).delete();
  const notifs = await db.collection("notifications").get();
  for (const d of notifs.docs) {
    if (USERS.some((u) => d.id.includes(u))) await d.ref.delete();
  }
}

async function seed(now) {
  const v = (extra) => ({
    verificationStatus: "verified", isVerified: true, ...extra,
  });
  // No expiry yet — the launch-day backfill case.
  await db.collection("users").doc("u_backfill").set(v({}));
  // Lapsed yesterday — must soft-lock.
  await db.collection("users").doc("u_expired").set(
    v({verificationExpiresAt: Timestamp.fromMillis(now - DAY)}));
  // 5 days left — falls in the 7-day warning bucket.
  await db.collection("users").doc("u_warn7").set(
    v({verificationExpiresAt: Timestamp.fromMillis(now + 5 * DAY)}));
  // 12 days left — falls in the 14-day warning bucket.
  await db.collection("users").doc("u_warn14").set(
    v({verificationExpiresAt: Timestamp.fromMillis(now + 12 * DAY)}));
  // Healthy — must be left completely alone.
  await db.collection("users").doc("u_safe").set(
    v({verificationExpiresAt: Timestamp.fromMillis(now + 100 * DAY)}));
  // Lapsed BUT exempt — must be skipped.
  await db.collection("users").doc("u_exempt").set(
    v({
      verificationExempt: true,
      verificationExpiresAt: Timestamp.fromMillis(now - DAY),
    }));
}

const get = async (uid) => (await db.collection("users").doc(uid).get()).data();
const notifExists = async (id) =>
  (await db.collection("notifications").doc(id).get()).exists;

async function main() {
  const now = Date.now();
  await wipe();
  await seed(now);

  // ── First sweep ──
  const c1 = await runVerificationExpirySweep(now);

  const backfill = await get("u_backfill");
  const expectedExpiry = now + VERIFICATION_PERIOD_MS;
  check("backfill: stays verified",
    backfill.verificationStatus === "verified", backfill.verificationStatus);
  check("backfill: gets a fresh ~365d window",
    backfill.verificationExpiresAt &&
    Math.abs(backfill.verificationExpiresAt.toMillis() - expectedExpiry) < 60000,
    String(backfill.verificationExpiresAt &&
      backfill.verificationExpiresAt.toMillis()));
  check("backfill: verifiedAt stamped", !!backfill.verifiedAt, "missing");

  const expired = await get("u_expired");
  check("expired: status -> expired",
    expired.verificationStatus === "expired", expired.verificationStatus);
  check("expired: isVerified -> false",
    expired.isVerified === false, String(expired.isVerified));
  check("expired: renewal-due notification written",
    await notifExists(`verif_expired_u_expired_${now - DAY}`), "not found");

  const warn7 = await get("u_warn7");
  check("warn7: still verified",
    warn7.verificationStatus === "verified", warn7.verificationStatus);
  check("warn7: 7-day bucket notification",
    await notifExists(`verif_expiring_u_warn7_7_${now + 5 * DAY}`), "not found");

  const warn14 = await get("u_warn14");
  check("warn14: still verified",
    warn14.verificationStatus === "verified", warn14.verificationStatus);
  check("warn14: 14-day bucket notification",
    await notifExists(`verif_expiring_u_warn14_14_${now + 12 * DAY}`),
    "not found");

  const safe = await get("u_safe");
  check("healthy user: untouched",
    safe.verificationStatus === "verified" &&
    safe.verificationExpiresAt.toMillis() === now + 100 * DAY, "changed");

  const exempt = await get("u_exempt");
  check("exempt: NOT expired despite lapsed clock",
    exempt.verificationStatus === "verified" && exempt.isVerified === true,
    exempt.verificationStatus);

  check("counts: 1 backfilled, 1 expired, 2 warned",
    c1.backfilled === 1 && c1.expired === 1 && c1.warned === 2,
    JSON.stringify(c1));

  // ── Second sweep: must be idempotent ──
  const c2 = await runVerificationExpirySweep(now);
  check("idempotent: nothing re-expired or re-warned",
    c2.expired === 0 && c2.warned === 0 && c2.backfilled === 0,
    JSON.stringify(c2));

  const expiredAgain = await get("u_expired");
  check("idempotent: expired user unchanged",
    expiredAgain.verificationStatus === "expired", "changed");

  await wipe();
  console.log(failures === 0 ?
    "\nAll verification-lifecycle checks passed." :
    `\n${failures} check(s) FAILED.`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("Runner error:", e);
  process.exit(1);
});
