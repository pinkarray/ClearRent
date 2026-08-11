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
 * Needs BOTH the firestore (8080) and auth (9099) emulators — platform admin
 * status lives in Auth custom claims, so proving admins are never soft-locked
 * requires Auth. firebase.json must have an "auth" entry under "emulators".
 *   npm run build
 *   firebase emulators:start --only firestore,auth --project demo-clearrent
 *   node scripts/verify_verification_lifecycle.js
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.FIREBASE_AUTH_EMULATOR_HOST =
  process.env.FIREBASE_AUTH_EMULATOR_HOST || "127.0.0.1:9099";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "demo-clearrent";

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT});

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
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
  "u_admin",
];

async function wipe() {
  for (const uid of USERS) await db.collection("users").doc(uid).delete();
  try {
    await getAuth().deleteUser("u_admin");
  } catch (_) { /* no Auth record yet */ }
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
  // Lapsed superAdmin — admin status lives in Auth claims only, so the sweep
  // must consult Auth and refuse to soft-lock them out of their own platform.
  await getAuth().createUser({uid: "u_admin", email: "admin@clearrent.test"});
  await getAuth().setCustomUserClaims("u_admin", {superAdmin: true});
  await db.collection("users").doc("u_admin").set(
    v({verificationExpiresAt: Timestamp.fromMillis(now - DAY)}));
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

  const adminUser = await get("u_admin");
  check("superAdmin: NOT expired despite lapsed clock",
    adminUser.verificationStatus === "verified" &&
    adminUser.isVerified === true, adminUser.verificationStatus);

  check("counts: 1 backfilled, 1 expired, 2 warned, 1 admin skipped",
    c1.backfilled === 1 && c1.expired === 1 && c1.warned === 2 &&
    c1.skippedAdmins === 1,
    JSON.stringify(c1));

  // ── Second sweep: must be idempotent ──
  const c2 = await runVerificationExpirySweep(now);
  check("idempotent: nothing re-expired or re-warned",
    c2.expired === 0 && c2.warned === 0 && c2.backfilled === 0,
    JSON.stringify(c2));

  const expiredAgain = await get("u_expired");
  check("idempotent: expired user unchanged",
    expiredAgain.verificationStatus === "expired", "changed");

  // ── Narrow path (fullScan=false) — what the daily job actually runs ──
  //
  // The range query cannot see documents with no verificationExpiresAt, so
  // backfill is expected to be MISSED here; that is why the scheduled job
  // still does a full read once a month. Everything time-critical — expiry
  // and both warning buckets — must still be caught.
  await wipe();
  await seed(now);
  const c3 = await runVerificationExpirySweep(now, false);
  check("narrow: expires the lapsed user",
    c3.expired === 1, JSON.stringify(c3));
  check("narrow: still warns both buckets",
    c3.warned === 2, JSON.stringify(c3));
  check("narrow: still spares the exempt/admin users",
    c3.skippedAdmins === 1 &&
      (await get("u_exempt")).verificationStatus === "verified",
    JSON.stringify(c3));
  check("narrow: reads far fewer docs than a full scan",
    c3.scanned < c1.scanned, `${c3.scanned} vs ${c1.scanned}`);
  check("narrow: leaves the healthy user untouched",
    (await get("u_safe")).verificationStatus === "verified", "touched");
  check("narrow: cannot backfill (range query skips absent field)",
    c3.backfilled === 0, JSON.stringify(c3));

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
