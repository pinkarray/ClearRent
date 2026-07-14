/* eslint-disable */
/**
 * Emulator verification for the cross-domain admin-alert triggers.
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/verify_alerts.js
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = "demo-clearrent";

const admin = require("firebase-admin");
admin.initializeApp({projectId: "demo-clearrent"});

const test = require("firebase-functions-test")();
const {
  onRentReviewRequested,
  onUserProfileUpdated,
} = require("../lib/admin_alert_triggers");

const db = admin.firestore();
let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
}

async function alertsOfType(type) {
  return db.collection("admin_alerts").where("type", "==", type).get();
}

async function clearAlerts() {
  const s = await db.collection("admin_alerts").get();
  await Promise.all(s.docs.map((d) => d.ref.delete()));
}

async function main() {
  await clearAlerts();

  // ── Rent-change request filed → one warning alert ──────────────────────
  const rentWrapped = test.wrap(onRentReviewRequested);
  const rentSnap = test.firestore.makeDocumentSnapshot(
    {
      status: "pending",
      landlordId: "L1",
      tenantId: "T1",
      propertyTitle: "Flat A",
      proposedRent: 1500000,
      reasonType: "market",
      changeType: "scheduled",
    },
    "rent_review_requests/req1",
  );
  await rentWrapped({data: rentSnap, params: {requestId: "req1"}});
  const rentAlerts = await alertsOfType("rent_change_request");
  check("rent-change request raises one alert", rentAlerts.size === 1);
  check("rent alert severity warning",
    rentAlerts.docs[0] && rentAlerts.docs[0].data().severity === "warning");
  check("rent alert targets the request",
    rentAlerts.docs[0] &&
    rentAlerts.docs[0].data().targetId === "req1");

  // Non-pending create (e.g. already-approved import) → no alert.
  const rentSnap2 = test.firestore.makeDocumentSnapshot(
    {status: "approved", landlordId: "L1", proposedRent: 1},
    "rent_review_requests/req2",
  );
  await rentWrapped({data: rentSnap2, params: {requestId: "req2"}});
  check("non-pending request raises no alert",
    (await alertsOfType("rent_change_request")).size === 1);

  // ── Profile name/email change → alert; unrelated change → none ─────────
  const userWrapped = test.wrap(onUserProfileUpdated);

  // (a) name changed
  await userWrapped({
    data: {
      before: test.firestore.makeDocumentSnapshot(
        {fullName: "Ada A", email: "ada@x.com", accountType: "tenant"},
        "users/U1"),
      after: test.firestore.makeDocumentSnapshot(
        {fullName: "Ada B", email: "ada@x.com", accountType: "tenant"},
        "users/U1"),
    },
    params: {uid: "U1"},
  });
  let pAlerts = await alertsOfType("profile_identity_change");
  check("name change raises one alert", pAlerts.size === 1);
  check("profile alert records nameChanged",
    pAlerts.docs[0] && pAlerts.docs[0].data().meta.nameChanged === true &&
    pAlerts.docs[0].data().meta.emailChanged === false);

  // (b) email changed
  await userWrapped({
    data: {
      before: test.firestore.makeDocumentSnapshot(
        {fullName: "Ada B", email: "ada@x.com"}, "users/U1"),
      after: test.firestore.makeDocumentSnapshot(
        {fullName: "Ada B", email: "new@x.com"}, "users/U1"),
    },
    params: {uid: "U1"},
  });
  check("email change raises another alert",
    (await alertsOfType("profile_identity_change")).size === 2);

  // (c) unrelated field change (rating) → NO alert
  await userWrapped({
    data: {
      before: test.firestore.makeDocumentSnapshot(
        {fullName: "Ada B", email: "new@x.com", rating: 4.0}, "users/U1"),
      after: test.firestore.makeDocumentSnapshot(
        {fullName: "Ada B", email: "new@x.com", rating: 4.5}, "users/U1"),
    },
    params: {uid: "U1"},
  });
  check("unrelated user update raises no alert",
    (await alertsOfType("profile_identity_change")).size === 2);

  await clearAlerts();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("VERIFY CRASHED:", e);
  process.exit(2);
});
