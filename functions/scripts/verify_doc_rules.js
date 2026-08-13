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
const {doc, setDoc, updateDoc, addDoc, collection} = require("firebase/firestore");

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

  // ── The create path ───────────────────────────────────────────────────
  // Every guard above is downstream of a review. If a listing can be BORN
  // approved, none of them matter — this is the hole that made the rest moot.
  // Mirrors what PropertyService.createProperty actually sends, `state`
  // included — ClearRent is Lagos-only and `create` is gated on it.
  const newProp = {
    landlordId: L1, title: "x", currentTenantsCount: 0,
    rent: 1000000, agentFee: 0, cautionDeposit: 0, state: "Lagos",
  };

  check("create: CANNOT be born ownershipDocStatus 'verified'",
    await denies(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocUrl: "never_reviewed.pdf",
        ownershipDocType: "c_of_o", ownershipDocStatus: "verified"})));

  check("create: CANNOT be born isVerified true",
    await denies(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "pending", isVerified: true})));

  check("create: CANNOT seed an admin rejection reason",
    await denies(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "pending",
        ownershipDocRejectionReason: "looks fine to me"})));

  // The real add-property payloads. Tightening `create` is only safe if the
  // shapes PropertyService actually sends still get through — a rule that
  // blocks listing creation is worse than the hole it closes.
  check("create: CAN publish a normal standalone listing for review",
    await passes(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocUrl: "mine.pdf", ownershipDocType: "c_of_o",
        ownershipDocStatus: "pending", isVerified: false})));

  check("create: CAN publish a standalone listing with NO doc yet",
    await passes(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "none", isVerified: false})));

  check("create: CAN publish a clean grouped unit (inherited, no doc fields)",
    await passes(addDoc(collection(db, "properties"),
      {...newProp, buildingId: "b1", ownershipDocStatus: "inherited",
        isVerified: false})));

  // add_property_screen's post-create review step.
  const docless = await addDoc(collection(db, "properties"),
    {...newProp, ownershipDocStatus: "none", isVerified: false});
  check("add-property: CAN mark a doc-less listing 'not_uploaded' + hidden",
    await passes(updateDoc(docless,
      {ownershipDocStatus: "not_uploaded", isAvailable: false})));

  // ── Grouped units: the building's doc is the only reviewed artifact ────
  // These carry ownershipDocStatus 'inherited', which is never the literal
  // 'verified' — so every status-keyed guard used to pass trivially.
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "properties", "unit1"), {
      landlordId: L1, buildingId: "b1",
      ownershipDocStatus: "inherited", isVerified: true,
      currentTenantsCount: 0, rent: 1000000, agentFee: 0, cautionDeposit: 0,
    });
  });

  check("grouped unit: CANNOT relabel its own doc type ('inherited' bypass)",
    await denies(updateDoc(doc(db, "properties", "unit1"),
      {ownershipDocType: "other"})));

  check("grouped unit: CANNOT attach its own doc file",
    await denies(updateDoc(doc(db, "properties", "unit1"),
      {ownershipDocUrl: "unit_cofo.pdf"})));

  check("grouped unit: CANNOT be created carrying its own doc",
    await denies(addDoc(collection(db, "properties"),
      {...newProp, buildingId: "b1", ownershipDocStatus: "inherited",
        ownershipDocUrl: "mine.pdf", ownershipDocType: "c_of_o"})));

  check("grouped unit: CAN still edit normal listing fields",
    await passes(updateDoc(doc(db, "properties", "unit1"), {rent: 1500000})));

  // ── buildingId is not a skeleton key ──────────────────────────────────
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "properties", "rejected1"), {
      landlordId: L1,
      ownershipDocUrl: "bad.pdf", ownershipDocType: "c_of_o",
      ownershipDocStatus: "rejected",
      ownershipDocRejectionReason: "Not a real C of O",
      isVerified: false,
      currentTenantsCount: 0, rent: 1000000, agentFee: 0, cautionDeposit: 0,
    });
  });

  check("property: CANNOT attach a rejected listing to an owned verified " +
    "building (would inherit 'verified')",
  await denies(updateDoc(doc(db, "properties", "rejected1"),
    {buildingId: "b1"})));

  check("property: CANNOT clear its own admin rejection reason",
    await denies(updateDoc(doc(db, "properties", "rejected1"),
      {ownershipDocRejectionReason: ""})));

  check("property: CANNOT detach from a building either",
    await denies(updateDoc(doc(db, "properties", "unit1"),
      {buildingId: null})));

  // ── One listing = one tenancy ─────────────────────────────────────────
  // Everything priced on the doc is singular. The web listing form used to
  // send maxTenants as a free number, and the slot guards key off whatever
  // is stored, so a second tenant could be accepted against one rent.
  check("create: CANNOT be born with maxTenants > 1",
    await denies(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "none", isVerified: false,
        maxTenants: 3})));

  check("create: CAN publish with maxTenants 1",
    await passes(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "none", isVerified: false,
        maxTenants: 1})));

  check("property: CANNOT raise maxTenants after creation",
    await denies(updateDoc(doc(db, "properties", "p2"), {maxTenants: 2})));

  // ── State is NOT gated in rules, on purpose ───────────────────────────
  // ClearRent operates in Lagos today, but the gate is admin review: a listing
  // is born isVerified:false / isAvailable:false, so nothing outside Lagos can
  // reach a tenant without a human approving it. Rules enforcement would add
  // nothing and would cost a rules deploy AND an app release the day another
  // state opens. These two cases exist so the decision is deliberate — if a
  // state guard is ever added, they fail loudly rather than the behaviour
  // changing silently.
  check("create: an out-of-state listing IS allowed (admin rejects it, not rules)",
    await passes(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "none", isVerified: false,
        state: "Enugu"})));

  check("create: it is still born unreviewed, so no tenant can see it",
    await passes(addDoc(collection(db, "properties"),
      {...newProp, ownershipDocStatus: "none", isVerified: false,
        state: "Enugu", isAvailable: false})));

  // ── Unit identity travels with the listing ────────────────────────────
  check("grouped unit: CAN set its unit label and floor",
    await passes(updateDoc(doc(db, "properties", "unit1"),
      {unitLabel: "Room 2", floor: "1"})));

  // ── buildings: structure is editable, still can't self-verify ─────────
  check("building: CAN set its structure",
    await passes(updateDoc(doc(db, "buildings", "b1"),
      {structure: "duplex", totalFloors: 2})));

  check("building: CANNOT self-verify while setting structure",
    await denies(updateDoc(doc(db, "buildings", "b1"),
      {structure: "compound", ownershipDocStatus: "verified"})));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("RULES VERIFY CRASHED:", e);
  process.exit(2);
});
