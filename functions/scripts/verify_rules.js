/* eslint-disable */
/**
 * Rules verification for the admin_alerts collection, against the Firestore
 * emulator with firestore.rules loaded.
 *   node scripts/verify_rules.js   (emulator must be running on 8080)
 */

const fs = require("fs");
const path = require("path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {
  doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc, collection,
} = require("firebase/firestore");

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
}

async function main() {
  const env = await initializeTestEnvironment({
    projectId: "demo-clearrent",
    firestore: {
      host: "127.0.0.1",
      port: 8080,
      rules: fs.readFileSync(
        path.join(__dirname, "..", "..", "firestore.rules"), "utf8"),
    },
  });

  // Seed one alert with admin privileges (rules bypassed in this context).
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "admin_alerts", "a1"), {
      type: "inspection_dispute", status: "open", read: false,
    });
  });

  const admin = env.authenticatedContext("admin_1", {admin: true});
  const viewer = env.authenticatedContext("viewer_1", {viewer: true});
  const tenant = env.authenticatedContext("tenant_1", {});

  // Admin: full read/update/delete.
  await check("admin can read alert",
    await passes(getDoc(doc(admin.firestore(), "admin_alerts", "a1"))));
  await check("admin can update (resolve) alert",
    await passes(updateDoc(
      doc(admin.firestore(), "admin_alerts", "a1"), {status: "resolved"})));

  // Viewer: read/list only.
  await check("viewer can read alert",
    await passes(getDoc(doc(viewer.firestore(), "admin_alerts", "a1"))));
  await check("viewer can list alerts",
    await passes(getDocs(collection(viewer.firestore(), "admin_alerts"))));
  await check("viewer CANNOT update alert",
    await denies(updateDoc(
      doc(viewer.firestore(), "admin_alerts", "a1"), {read: true})));

  // Plain tenant: no access at all.
  await check("tenant CANNOT read alert",
    await denies(getDoc(doc(tenant.firestore(), "admin_alerts", "a1"))));
  await check("tenant CANNOT list alerts",
    await denies(getDocs(collection(tenant.firestore(), "admin_alerts"))));

  // Nobody (not even admin) may create from a client — SDK only.
  await check("admin client CANNOT create alert",
    await denies(setDoc(
      doc(admin.firestore(), "admin_alerts", "a2"), {type: "x"})));
  await check("tenant client CANNOT create alert",
    await denies(setDoc(
      doc(tenant.firestore(), "admin_alerts", "a3"), {type: "x"})));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

async function passes(p) {
  try {
    await assertSucceeds(p);
    return true;
  } catch (_) {
    return false;
  }
}
async function denies(p) {
  try {
    await assertFails(p);
    return true;
  } catch (_) {
    return false;
  }
}

main().catch((e) => {
  console.error("RULES VERIFY CRASHED:", e);
  process.exit(2);
});
