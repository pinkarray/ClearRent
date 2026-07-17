/* eslint-disable */
/**
 * Rules verification for ownership-document integrity.
 *
 * Proves an owner cannot keep a 'verified' badge over a document the admin
 * never approved — by swapping the file or relabelling the type without
 * touching ownershipDocStatus. Also probes whether properties.isVerified is
 * self-settable (the adjacent finding).
 *
 * Emulator must be running on 8080:
 *   node scripts/verify_doc_rules.js
 */

const fs = require("fs");
const path = require("path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc} = require("firebase/firestore");

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
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

const L1 = "landlord_1";

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

  // Seed an APPROVED property + building owned by L1 (rules bypassed).
  await env.withSecurityRulesDisabled(async (ctx) => {
    const d = ctx.firestore();
    await setDoc(doc(d, "users", L1), {verificationStatus: "verified"});
    await setDoc(doc(d, "properties", "p1"), {
      landlordId: L1,
      ownershipDocUrl: "approved.pdf",
      ownershipDocType: "c_of_o",
      ownershipDocStatus: "verified",
      isVerified: true,
      currentTenantsCount: 0,
      rent: 1000000,
      agentFee: 0,
      cautionDeposit: 0,
    });
    await setDoc(doc(d, "buildings", "b1"), {
      landlordId: L1,
      name: "Block A",
      address: "1 Lekki Rd",
      ownershipDocUrl: "approved.pdf",
      ownershipDocType: "c_of_o",
      ownershipDocStatus: "verified",
    });
  });

  const owner = env.authenticatedContext(L1, {});
  const db = owner.firestore();

  // ── properties: the bug the landlord found ────────────────────────────
  check("property: CANNOT relabel doc type while 'verified'",
    await denies(updateDoc(doc(db, "properties", "p1"),
      {ownershipDocType: "deed"})));

  check("property: CANNOT swap doc file while 'verified'",
    await denies(updateDoc(doc(db, "properties", "p1"),
      {ownershipDocUrl: "something_else.pdf"})));

  // Relabelling an APPROVED doc is not allowed even if the owner also sends it
  // back for review — the file is what it is; changing the type requires
  // uploading the matching document.
  check("property: CANNOT relabel approved doc without a new file " +
    "(even with status → pending)",
  await denies(updateDoc(doc(db, "properties", "p1"),
    {ownershipDocType: "deed", ownershipDocStatus: "pending"})));

  // Legit path: new file + new type + back for review.
  check("property: CAN change type when a NEW FILE is uploaded",
    await passes(updateDoc(doc(db, "properties", "p1"),
      {ownershipDocUrl: "new.pdf", ownershipDocType: "deed",
        ownershipDocStatus: "pending"})));

  // ── buildings: same holes ─────────────────────────────────────────────
  check("building: CANNOT relabel doc type while 'verified'",
    await denies(updateDoc(doc(db, "buildings", "b1"),
      {ownershipDocType: "deed"})));

  check("building: CANNOT swap doc file while 'verified'",
    await denies(updateDoc(doc(db, "buildings", "b1"),
      {ownershipDocUrl: "something_else.pdf"})));

  check("building: CANNOT relabel approved doc without a new file",
    await denies(updateDoc(doc(db, "buildings", "b1"),
      {ownershipDocType: "deed", ownershipDocStatus: "pending"})));

  check("building: CAN change type when a NEW FILE is uploaded",
    await passes(updateDoc(doc(db, "buildings", "b1"),
      {ownershipDocUrl: "new.pdf", ownershipDocType: "deed",
        ownershipDocStatus: "pending"})));

  // ── self-verification, tested from a genuinely UNVERIFIED property ────
  // (Testing this on an already-'verified' doc is meaningless: writing the
  // same value is a no-op diff, so affectedKeys() rightly never reports it.)
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "properties", "p2"), {
      landlordId: L1,
      ownershipDocUrl: "unreviewed.pdf",
      ownershipDocType: "c_of_o",
      ownershipDocStatus: "pending",
      isVerified: false,
      currentTenantsCount: 0,
      rent: 1000000,
      agentFee: 0,
      cautionDeposit: 0,
    });
  });

  check("property: CANNOT self-set docStatus pending → 'verified'",
    await denies(updateDoc(doc(db, "properties", "p2"),
      {ownershipDocStatus: "verified"})));

  check("property: CANNOT self-set isVerified false → true",
    await denies(updateDoc(doc(db, "properties", "p2"),
      {isVerified: true})));

  check("property: CAN still edit normal listing fields",
    await passes(updateDoc(doc(db, "properties", "p2"), {rent: 1200000})));

  // Before an admin reviews it, a mislabel is just a mistake — let them fix it
  // without re-uploading. The lock only applies after approval.
  check("property: CAN relabel freely BEFORE review (status pending)",
    await passes(updateDoc(doc(db, "properties", "p2"),
      {ownershipDocType: "deed"})));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("RULES VERIFY CRASHED:", e);
  process.exit(2);
});
