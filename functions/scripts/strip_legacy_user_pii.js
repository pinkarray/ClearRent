/* eslint-disable */
/**
 * Removes legacy PII from users/{uid}, which `allow read: if request.auth != null`
 * makes readable by EVERY signed-in account (proven 2026-10-08: a reviewer
 * account read the super-admin's BVN over the REST API).
 *
 *   - bvn           referenced nowhere in app, functions, web or admin. Legacy.
 *   - bankDetails   superseded by users/{uid}/private/bank (audit C1), which is
 *                   correctly owner+admin only. The old copy defeated that fix.
 *   - nin           belongs here ONLY as versioned ciphertext ("v1:…", see
 *                   nin_ops.ts). A plaintext value predates the encryption and
 *                   is stripped; encrypted ones are left alone.
 *
 * Dry run by default; pass --execute to write.
 */
const admin = require("firebase-admin");
admin.initializeApp({projectId: "clearrent-app"});
const db = admin.firestore();
const EXECUTE = process.argv.includes("--execute");
const FV = admin.firestore.FieldValue;

(async () => {
  console.log(EXECUTE ? "=== EXECUTING ===" : "=== DRY RUN ===");
  let touched = 0;
  for (const d of (await db.collection("users").get()).docs) {
    const x = d.data();
    const strip = [];
    if (x.bvn !== undefined) strip.push("bvn");
    if (x.bankDetails !== undefined) strip.push("bankDetails");
    if (typeof x.nin === "string" && !x.nin.startsWith("v1:")) strip.push("nin (plaintext)");
    if (!strip.length) { console.log("  clean  ", x.email || d.id); continue; }
    touched++;
    console.log("  STRIP  ", (x.email || d.id).padEnd(36), strip.join(", "));
    if (EXECUTE) {
      const patch = {};
      if (x.bvn !== undefined) patch.bvn = FV.delete();
      if (x.bankDetails !== undefined) patch.bankDetails = FV.delete();
      if (typeof x.nin === "string" && !x.nin.startsWith("v1:")) patch.nin = FV.delete();
      await d.ref.update(patch);
    }
  }
  console.log(`\n${touched} doc(s) ${EXECUTE ? "updated" : "would be updated"}`);
})();
