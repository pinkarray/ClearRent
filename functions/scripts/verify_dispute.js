/* eslint-disable */
/**
 * Emulator verification for the inspection-dispute + admin-alert pipeline.
 * Run against the Firestore emulator:
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/verify_dispute.js
 *
 * Exercises the real Cloud Function handlers (via firebase-functions-test)
 * against emulator Firestore — not mocks.
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = "demo-clearrent";

const admin = require("firebase-admin");
admin.initializeApp({projectId: "demo-clearrent"});

const test = require("firebase-functions-test")();
const {reportInspectionIssue} = require("../lib/inspection_dispute_ops");
const {inspectionTodayAdminDigest} = require("../lib/admin_digest_ops");
const {adminResolveInspection} = require("../lib/admin_review_ops");

const db = admin.firestore();
const wrappedReport = test.wrap(reportInspectionIssue);
const wrappedDigest = test.wrap(inspectionTodayAdminDigest);
const wrappedResolve = test.wrap(adminResolveInspection);

const TENANT = "tenant_1";
const AGENT = "agent_1";
const LANDLORD = "landlord_1";

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
}

async function callReport(uid, requestId, category, details) {
  return wrappedReport({
    data: {requestId, category, details},
    auth: {uid, token: {}},
  });
}

async function seedInspection(id, extra) {
  await db.collection("inspection_requests").doc(id).set({
    tenantId: TENANT,
    tenantName: "Test Tenant",
    agentId: AGENT,
    agentName: "Test Agent",
    landlordId: LANDLORD,
    landlordName: "Test Landlord",
    propertyTitle: "2-bed in Lekki",
    totalFee: 7000,
    ...extra,
  });
}

async function clearAll() {
  for (const c of ["inspection_requests", "admin_alerts", "admin_audit_log"]) {
    const snap = await db.collection(c).get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
  }
}

async function main() {
  await clearAll();

  // ── 1. Happy path: tenant disputes a completed inspection ──────────────
  await seedInspection("insp_completed", {status: "completed"});
  const res1 = await callReport(
    TENANT, "insp_completed", "misrepresented", "Photos were fake");
  check("report returns ok", res1 && res1.ok === true);

  const doc1 = (await db.collection("inspection_requests")
    .doc("insp_completed").get()).data();
  check("inspection flagged disputed", doc1.disputed === true);
  check("disputeStatus open", doc1.disputeStatus === "open");
  check("disputeCategory persisted",
    doc1.disputeCategory === "misrepresented");
  check("completed status unchanged", doc1.status === "completed");

  const alerts1 = await db.collection("admin_alerts")
    .where("targetId", "==", "insp_completed").get();
  check("exactly one admin alert", alerts1.size === 1);
  const alert1 = alerts1.docs[0] && alerts1.docs[0].data();
  check("alert type inspection_dispute",
    alert1 && alert1.type === "inspection_dispute");
  check("alert status open", alert1 && alert1.status === "open");
  check("alert carries actors",
    alert1 && alert1.actors && alert1.actors.tenantId === TENANT);

  const audit1 = await db.collection("admin_audit_log")
    .where("targetId", "==", "insp_completed").get();
  check("audit entry written", audit1.size === 1);

  // ── 2. Idempotent: second report while open is a no-op ─────────────────
  const res2 = await callReport(
    TENANT, "insp_completed", "safety", "again");
  check("second report alreadyOpen", res2 && res2.alreadyOpen === true);
  const alerts1b = await db.collection("admin_alerts")
    .where("targetId", "==", "insp_completed").get();
  check("no duplicate alert on re-report", alerts1b.size === 1);

  // ── 3. Approved inspection is moved into the review queue ──────────────
  await seedInspection("insp_approved", {status: "approved"});
  await callReport(TENANT, "insp_approved", "no_show", "");
  const doc3 = (await db.collection("inspection_requests")
    .doc("insp_approved").get()).data();
  check("approved → awaitingOutcome", doc3.status === "awaitingOutcome");
  check("approved flagged disputed", doc3.disputed === true);

  // ── 4. Safety category → critical severity ─────────────────────────────
  await seedInspection("insp_safety", {status: "completed"});
  await callReport(TENANT, "insp_safety", "safety", "unsafe wiring");
  const safetyAlert = (await db.collection("admin_alerts")
    .where("targetId", "==", "insp_safety").get()).docs[0].data();
  check("safety alert is critical", safetyAlert.severity === "critical");

  // ── 4b. Admin dismiss closes the dispute + its open alerts ─────────────
  await wrappedResolve({
    data: {requestId: "insp_safety", action: "dismiss"},
    auth: {uid: "admin_1", token: {admin: true}},
  });
  const dismissed = (await db.collection("inspection_requests")
    .doc("insp_safety").get()).data();
  check("dismiss resolves dispute", dismissed.disputeStatus === "resolved");
  const safetyAlerts = await db.collection("admin_alerts")
    .where("targetId", "==", "insp_safety").get();
  check("dismiss closed the alert",
    safetyAlerts.docs.every((d) => d.data().status === "resolved"));

  // ── 5. Negative: non-owner is denied ───────────────────────────────────
  await seedInspection("insp_other", {status: "completed"});
  let deniedCode = null;
  try {
    await callReport("someone_else", "insp_other", "unprofessional", "");
  } catch (e) {
    deniedCode = e.code || e.httpErrorCode || (e.details && e.details.code);
  }
  check("non-owner denied (permission-denied)",
    String(deniedCode).includes("permission-denied"));
  const otherDoc = (await db.collection("inspection_requests")
    .doc("insp_other").get()).data();
  check("denied report left doc untouched", otherDoc.disputed === undefined);

  // ── 6. Negative: cancelled inspection can't be disputed ────────────────
  await seedInspection("insp_cancelled", {status: "cancelled"});
  let preCond = null;
  try {
    await callReport(TENANT, "insp_cancelled", "refund_request", "");
  } catch (e) {
    preCond = e.code || e.httpErrorCode;
  }
  check("cancelled rejected (failed-precondition)",
    String(preCond).includes("failed-precondition"));

  // ── 7. Invalid category rejected ───────────────────────────────────────
  await seedInspection("insp_badcat", {status: "completed"});
  let badArg = null;
  try {
    await callReport(TENANT, "insp_badcat", "not_a_category", "");
  } catch (e) {
    badArg = e.code || e.httpErrorCode;
  }
  check("invalid category rejected (invalid-argument)",
    String(badArg).includes("invalid-argument"));

  // ── 8. Daily digest: one alert for today's approved inspections ────────
  // insp_approved was moved to awaitingOutcome above, so seed a fresh one
  // dated today.
  await db.collection("admin_alerts").get()
    .then((s) => Promise.all(s.docs
      .filter((d) => d.data().type === "inspection_today_digest")
      .map((d) => d.ref.delete())));
  await seedInspection("insp_today", {
    status: "approved",
    requestedDate: admin.firestore.Timestamp.fromDate(new Date()),
    requestedTimeDisplay: "9:00 AM",
  });
  await wrappedDigest({});
  const digests1 = await db.collection("admin_alerts")
    .where("type", "==", "inspection_today_digest").get();
  check("digest produced one alert", digests1.size === 1);
  const digest = digests1.docs[0] && digests1.docs[0].data();
  check("digest counts today's inspection",
    digest && digest.meta && digest.meta.count >= 1);

  // Re-run → deterministic id dedupes.
  await wrappedDigest({});
  const digests2 = await db.collection("admin_alerts")
    .where("type", "==", "inspection_today_digest").get();
  check("digest re-run does not duplicate", digests2.size === 1);

  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  await clearAll();
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("VERIFY CRASHED:", e);
  process.exit(2);
});
