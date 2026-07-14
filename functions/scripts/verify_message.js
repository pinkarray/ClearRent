/* eslint-disable */
/**
 * Emulator verification for messageInspectionParties (admin → tenant/handler).
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/verify_message.js
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = "demo-clearrent";

const admin = require("firebase-admin");
admin.initializeApp({projectId: "demo-clearrent"});

const test = require("firebase-functions-test")();
const {messageInspectionParties} = require("../lib/inspection_admin_ops");

const db = admin.firestore();
const wrapped = test.wrap(messageInspectionParties);

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
}

async function call(auth, data) {
  return wrapped({data, auth});
}

async function notifsFor(uid) {
  return db.collection("notifications").where("userId", "==", uid).get();
}

async function main() {
  // Clean.
  for (const c of ["inspection_requests", "notifications", "admin_audit_log"]) {
    const s = await db.collection(c).get();
    await Promise.all(s.docs.map((d) => d.ref.delete()));
  }

  await db.collection("inspection_requests").doc("insp1").set({
    tenantId: "T1",
    agentId: "A1",
    landlordId: "L1",
    propertyTitle: "Lekki flat",
  });

  const adminAuth = {uid: "admin1", token: {admin: true}};

  // Target 'both' → tenant + handler(agent) each get one notification.
  const res = await call(adminAuth, {
    inspectionId: "insp1",
    target: "both",
    message: "We're reviewing your report — please share any photos.",
  });
  check("returns ok, sent=2", res && res.ok === true && res.sent === 2);
  check("tenant got a notification", (await notifsFor("T1")).size === 1);
  check("handler (agent) got a notification", (await notifsFor("A1")).size === 1);
  check("landlord NOT messaged (agent is handler)",
    (await notifsFor("L1")).size === 0);
  const tNotif = (await notifsFor("T1")).docs[0].data();
  check("notification carries the message + type",
    tNotif.type === "inspection_admin_message" &&
    tNotif.body.includes("reviewing your report"));
  check("audit entry written",
    (await db.collection("admin_audit_log")
      .where("targetId", "==", "insp1").get()).size === 1);

  // Target 'tenant' only.
  await call(adminAuth, {inspectionId: "insp1", target: "tenant", message: "hi"});
  check("tenant-only adds one more to tenant, none to handler",
    (await notifsFor("T1")).size === 2 && (await notifsFor("A1")).size === 1);

  // Negatives.
  let denied = null;
  try {
    await call({uid: "T1", token: {}}, {
      inspectionId: "insp1", target: "both", message: "x",
    });
  } catch (e) {
    denied = e.code || e.httpErrorCode;
  }
  check("non-admin denied", String(denied).includes("permission-denied"));

  let bad = null;
  try {
    await call(adminAuth, {inspectionId: "insp1", target: "both", message: "  "});
  } catch (e) {
    bad = e.code || e.httpErrorCode;
  }
  check("empty message rejected", String(bad).includes("invalid-argument"));

  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("VERIFY CRASHED:", e);
  process.exit(2);
});
