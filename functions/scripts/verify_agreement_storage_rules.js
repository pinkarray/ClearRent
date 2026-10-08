/* eslint-disable */
/**
 * Rules verification for the tenancy-agreement storage prefix.
 *
 * The executed agreement is the LEGAL RECORD of the tenancy, and
 * `agreements/` was the only evidence prefix here still on a plain
 * `allow write` - which also covers overwrite and delete. Once the tenant had
 * signed, the landlord could PUT different bytes at the same path; because
 * `agreementUrl` never changes, no Firestore rule fires and the tenancy
 * silently references a document the tenant never agreed to. The tenant could
 * do the same to their own signed copy. Verified ALLOWED against the emulator
 * on 2026-10-08, while `ownership/` correctly denied the same move.
 *
 * Write-once is safe because the client timestamps every upload
 * (PropertyService.uploadAgreementDoc), so a revision is a NEW path.
 *
 *   npx firebase-tools emulators:start --only storage --project demo-clearrent
 *   node scripts/verify_agreement_storage_rules.js
 */
const fs = require("fs");
const path = require("path");
const {initializeTestEnvironment} = require("@firebase/rules-unit-testing");
const {ref, uploadBytes, getBytes, deleteObject} = require("firebase/storage");

const B = (s) => new Uint8Array(Buffer.from(s));
let failures = 0;
const check = (name, ok) => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  if (!ok) failures++;
};
const run = async (p) => {
  try { await p; return "ALLOWED"; } catch (_) { return "denied"; }
};

(async () => {
  const env = await initializeTestEnvironment({
    projectId: "demo-clearrent",
    storage: {host: "127.0.0.1", port: 9199,
      rules: fs.readFileSync(path.join(__dirname, "..", "..", "storage.rules"), "utf8")},
  });
  const L = "landlord_ag", T = "tenant_ag";
  const ldb = env.authenticatedContext(L, {}).storage();
  const tdb = env.authenticatedContext(T, {}).storage();
  const adb = env.authenticatedContext("admin_ag", {admin: true}).storage();
  const anon = env.unauthenticatedContext().storage();

  // Positive controls first: a rule that denies everything would "pass" every
  // negative case below, so each denial is paired with a write that must work.
  check("landlord CAN upload an agreement",
    await run(uploadBytes(ref(ldb, `agreements/${L}/a1.pdf`), B("ORIGINAL"))) === "ALLOWED");
  check("landlord CANNOT overwrite it (the byte swap)",
    await run(uploadBytes(ref(ldb, `agreements/${L}/a1.pdf`), B("SWAPPED"))) === "denied");
  check("landlord CANNOT delete it",
    await run(deleteObject(ref(ldb, `agreements/${L}/a1.pdf`))) === "denied");
  check("landlord CAN upload a revision at a NEW path",
    await run(uploadBytes(ref(ldb, `agreements/${L}/a2.pdf`), B("REVISED"))) === "ALLOWED");

  check("tenant CAN upload their signed copy",
    await run(uploadBytes(ref(tdb, `agreements/${T}/s1.pdf`), B("SIGNED"))) === "ALLOWED");
  check("tenant CANNOT overwrite their signed copy",
    await run(uploadBytes(ref(tdb, `agreements/${T}/s1.pdf`), B("DIFFERENT"))) === "denied");
  check("landlord CANNOT write into the tenant's folder",
    await run(uploadBytes(ref(ldb, `agreements/${T}/x.pdf`), B("X"))) === "denied");

  check("landlord CAN read their own agreement",
    await run(getBytes(ref(ldb, `agreements/${L}/a1.pdf`))) === "ALLOWED");
  check("admin CAN read it",
    await run(getBytes(ref(adb, `agreements/${L}/a1.pdf`))) === "ALLOWED");
  // The tenant is a party but not the uploader; storage rules cannot read
  // Firestore to check membership, so they get it via getSignedAgreementUrl.
  check("tenant CANNOT read the landlord's copy directly",
    await run(getBytes(ref(tdb, `agreements/${L}/a1.pdf`))) === "denied");
  check("anonymous CANNOT read it",
    await run(getBytes(ref(anon, `agreements/${L}/a1.pdf`))) === "denied");

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures ? 1 : 0);
})();
