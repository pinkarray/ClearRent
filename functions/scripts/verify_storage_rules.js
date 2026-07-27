/* eslint-disable */
/**
 * Rules verification for ownership-document storage.
 *
 * An approved C of O is EVIDENCE. `allow write` also covers overwrite and
 * delete, which defeated the whole ownership-doc integrity rule from outside
 * Firestore: an admin approves the document, then the owner PUTs different bytes
 * to the same path. ownershipDocUrl never changes, so no firestore rule fires,
 * and the listing stays 'verified' over a file nobody reviewed.
 *
 * These docs are write-once. Proving that matters more than usual: no ownership
 * document has been uploaded to Storage in production yet (everything predates
 * the move off Cloudinary), so this path is unexercised — a mistake here blocks
 * every new listing from review rather than merely leaving a hole open.
 *
 * Storage emulator must be running on 9199:
 *   npx firebase-tools emulators:start --only storage --project demo-clearrent
 *   node scripts/verify_storage_rules.js
 */

const fs = require("fs");
const path = require("path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {
  ref, uploadBytes, getBytes, deleteObject, listAll,
} = require("firebase/storage");

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
const L2 = "landlord_2";
const BYTES = new Uint8Array([1, 2, 3, 4]);
const OTHER = new Uint8Array([9, 9, 9, 9]);

/**
 * env.clearStorage() does NOT do this: it lists the ROOT only and deletes
 * `items`, ignoring `prefixes`, so anything nested (all of ours live at
 * ownership/{uid}/…) silently survives. It still resolves OK, which makes the
 * suite pass once on a clean emulator and then fail the two upload checks on
 * every run after — the rules are fine, the fixture isn't. Recurse instead.
 */
async function clearAllStorage(env) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const rm = async (dir) => {
      const {items, prefixes} = await listAll(dir);
      await Promise.all(items.map((i) => deleteObject(i)));
      for (const p of prefixes) await rm(p);
    };
    await rm(ref(ctx.storage()));
  });
}

async function main() {
  const env = await initializeTestEnvironment({
    projectId: "demo-clearrent",
    storage: {
      host: "127.0.0.1",
      port: 9199,
      rules: fs.readFileSync(
        path.join(__dirname, "..", "..", "storage.rules"), "utf8"),
    },
  });
  await clearAllStorage(env);

  const owner = env.authenticatedContext(L1, {}).storage();
  const other = env.authenticatedContext(L2, {}).storage();
  const admin = env.authenticatedContext("admin_1", {admin: true}).storage();
  const anon = env.unauthenticatedContext().storage();

  const P = `ownership/${L1}/cofo_1.jpg`;

  // ── the normal path still works ───────────────────────────────────────
  check("owner: CAN upload a new ownership doc",
    await passes(uploadBytes(ref(owner, P), BYTES)));

  check("owner: CAN read back their own doc",
    await passes(getBytes(ref(owner, P))));

  check("admin: CAN read the doc to review it",
    await passes(getBytes(ref(admin, P))));

  // ── write-once: the approved bytes are immutable ──────────────────────
  check("owner: CANNOT overwrite an existing doc (the byte-swap)",
    await denies(uploadBytes(ref(owner, P), OTHER)));

  check("owner: CANNOT delete an existing doc",
    await denies(deleteObject(ref(owner, P))));

  // A NEW document means a NEW path — that's the supported way to replace one,
  // and it flips the Firestore status back to 'pending' for re-review.
  check("owner: CAN upload a REPLACEMENT at a new path",
    await passes(uploadBytes(ref(owner, `ownership/${L1}/cofo_2.jpg`), BYTES)));

  // ── nobody else gets near it ──────────────────────────────────────────
  check("other landlord: CANNOT read someone else's C of O",
    await denies(getBytes(ref(other, P))));

  check("other landlord: CANNOT write into someone else's folder",
    await denies(uploadBytes(ref(other, P), OTHER)));

  check("anonymous: CANNOT read an ownership doc",
    await denies(getBytes(ref(anon, P))));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("STORAGE RULES VERIFY CRASHED:", e);
  process.exit(2);
});
