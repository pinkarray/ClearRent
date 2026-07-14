/* eslint-disable */
/**
 * Emulator verification for the inspection lifecycle admin alerts.
 * One evolving alert per inspection: requested → paid → approved/declined.
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/verify_lifecycle.js
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = "demo-clearrent";

const test = require("firebase-functions-test")();
// Requiring index initializes the admin app (don't init it ourselves).
const idx = require("../lib/index");
const admin = require("firebase-admin");
const db = admin.firestore();

const wrappedCreate = test.wrap(idx.onInspectionRequestCreated);
const wrappedUpdate = test.wrap(idx.onInspectionRequestUpdated);

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
}

function snapOf(data, path) {
  return test.firestore.makeDocumentSnapshot(data, path);
}

async function lc(id) {
  const d = await db.collection("admin_alerts").doc(`insplc_${id}`).get();
  return d.exists ? d.data() : null;
}
async function alertCount() {
  return (await db.collection("admin_alerts").get()).size;
}

async function main() {
  for (const c of ["inspection_requests", "admin_alerts", "notifications"]) {
    const s = await db.collection(c).get();
    await Promise.all(s.docs.map((d) => d.ref.delete()));
  }

  const base = {
    tenantId: "T1",
    tenantName: "Ada",
    agentId: "A1",
    agentName: "Bola",
    landlordId: "L1",
    propertyTitle: "Lekki flat",
  };
  const path = "inspection_requests/req1";

  // ── requested (create, pendingPayment) ────────────────────────────────
  await db.collection("inspection_requests").doc("req1")
    .set({...base, status: "pendingPayment"});
  await wrappedCreate({
    data: snapOf({...base, status: "pendingPayment"}, path),
    params: {requestId: "req1"},
  });
  let a = await lc("req1");
  check("requested: alert created", !!a);
  check("requested: type + info severity",
    a && a.type === "inspection_lifecycle" && a.severity === "info");
  check("requested: state requested_unpaid",
    a && a.meta && a.meta.state === "requested_unpaid");
  check("requested: exactly one alert", (await alertCount()) === 1);

  // ── paid (pendingPayment → pending) ───────────────────────────────────
  await wrappedUpdate({
    data: {
      before: snapOf({...base, status: "pendingPayment"}, path),
      after: snapOf({...base, status: "pending"}, path),
    },
    params: {requestId: "req1"},
  });
  a = await lc("req1");
  check("paid: same alert now state=paid", a && a.meta.state === "paid");
  check("paid: title reflects payment", a && a.title.includes("paid"));
  check("paid: STILL one alert (upsert, not new)",
    (await alertCount()) === 1);

  // ── approved (pending → approved) ─────────────────────────────────────
  await wrappedUpdate({
    data: {
      before: snapOf({...base, status: "pending"}, path),
      after: snapOf({...base, status: "approved"}, path),
    },
    params: {requestId: "req1"},
  });
  a = await lc("req1");
  check("approved: state=approved", a && a.meta.state === "approved");
  check("approved: still one alert", (await alertCount()) === 1);

  // ── declined path on a second inspection ──────────────────────────────
  const path2 = "inspection_requests/req2";
  await wrappedUpdate({
    data: {
      before: snapOf({...base, status: "declinedByAgent"}, path2),
      after: snapOf({...base, status: "declined"}, path2),
    },
    params: {requestId: "req2"},
  });
  const b = await lc("req2");
  check("declined: alert created state=declined",
    b && b.meta.state === "declined");
  check("two inspections → two lifecycle alerts total",
    (await alertCount()) === 2);

  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("VERIFY CRASHED:", e);
  process.exit(2);
});
