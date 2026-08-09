/* eslint-disable */
/**
 * Rules verification for the move-out handover relist gate.
 *
 * ClearRent never holds the caution deposit, so blocking the RELIST is the only
 * leverage that makes a landlord settle up. That gate is only real if the
 * landlord cannot simply write `isAvailable: true` themselves — which they
 * could, because the owner-update rule never pinned the occupancy fields.
 *
 * Emulator must be running on 8080:
 *   node scripts/verify_handover_rules.js
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
const T1 = "tenant_1";

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

  const baseProperty = {
    landlordId: L1,
    ownershipDocUrl: "approved.pdf",
    ownershipDocType: "c_of_o",
    ownershipDocStatus: "verified",
    isVerified: true,
    currentTenantsCount: 0,
    isAvailable: false,
    rent: 1000000,
    agentFee: 0,
    cautionDeposit: 0,
    cautionDepositRefundable: true,
  };

  await env.withSecurityRulesDisabled(async (ctx) => {
    const d = ctx.firestore();
    await setDoc(doc(d, "users", L1), {verificationStatus: "verified"});
    // A unit whose tenant has moved out but whose handover is unsettled.
    await setDoc(doc(d, "properties", "gated"), {
      ...baseProperty,
      handoverPending: true,
    });
    // An ordinary vacant unit with nothing outstanding.
    await setDoc(doc(d, "properties", "free"), {
      ...baseProperty,
      handoverPending: false,
    });
    // Pre-dates the field entirely — must behave like "free".
    await setDoc(doc(d, "properties", "legacy"), {...baseProperty});
    await setDoc(doc(d, "active_rentals", "r1"), {
      landlordId: L1,
      tenantId: T1,
      propertyId: "gated",
      status: "ended_by_tenant",
      cautionDeposit: 50000,
    });
  });

  const db = env.authenticatedContext(L1, {}).firestore();
  const tenantDb = env.authenticatedContext(T1, {}).firestore();

  // ── The gate itself ───────────────────────────────────────────────────
  check("CANNOT relist while the handover is unsettled",
    await denies(updateDoc(doc(db, "properties", "gated"),
      {isAvailable: true})));

  check("CANNOT sneak the relist through alongside an innocent edit",
    await denies(updateDoc(doc(db, "properties", "gated"),
      {title: "Renovated!", isAvailable: true})));

  check("CAN still edit a gated listing without relisting it",
    await passes(updateDoc(doc(db, "properties", "gated"),
      {title: "Same unit, new photos"})));

  // ── The toggle the landlord legitimately owns ─────────────────────────
  check("CAN relist a vacant unit with nothing outstanding",
    await passes(updateDoc(doc(db, "properties", "free"),
      {isAvailable: true})));

  check("CAN relist a listing predating handoverPending",
    await passes(updateDoc(doc(db, "properties", "legacy"),
      {isAvailable: true})));

  check("CAN still delist their own property",
    await passes(updateDoc(doc(db, "properties", "free"),
      {isAvailable: false})));

  // ── Server-owned fields ───────────────────────────────────────────────
  check("CANNOT clear the gate flag themselves",
    await denies(updateDoc(doc(db, "properties", "gated"),
      {handoverPending: false})));

  // Must be a DIFFERENT value: affectedKeys() ignores a write that sets a
  // field to what it already holds, so re-writing 0 over 0 proves nothing.
  check("CANNOT forge occupancy to force availability",
    await denies(updateDoc(doc(db, "properties", "free"),
      {currentTenantsCount: 5})));

  // ── Handover fields on the rental ─────────────────────────────────────
  check("landlord CAN confirm they checked the unit",
    await passes(updateDoc(doc(db, "active_rentals", "r1"), {
      handoverConditionConfirmedAt: new Date(),
      handoverConditionNotes: "Kitchen tap dripping",
      handoverStage: "awaiting_settlement",
    })));

  check("landlord CAN record settlement + proof",
    await passes(updateDoc(doc(db, "active_rentals", "r1"), {
      handoverSettlementMethod: "off_platform_transfer",
      handoverSettledAt: new Date(),
      handoverProofUrl: "proofs/l1/transfer.jpg",
    })));

  check("tenant CAN confirm they were paid",
    await passes(updateDoc(doc(tenantDb, "active_rentals", "r1"),
      {handoverTenantConfirmedAt: new Date()})));

  check("tenant CAN contest",
    await passes(updateDoc(doc(tenantDb, "active_rentals", "r1"), {
      tenantContested: true,
      tenantContestStatement: "Nothing was transferred",
    })));

  check("CANNOT write an unlisted field alongside handover fields",
    await denies(updateDoc(doc(db, "active_rentals", "r1"),
      {handoverStage: "closed", rentAmount: 1})));

  await env.cleanup();
  console.log(failures === 0 ?
    "\nALL PASS" :
    `\n${failures} FAILURE(S)`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
