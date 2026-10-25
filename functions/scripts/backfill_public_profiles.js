/* eslint-disable */
/**
 * Writes public_profiles/{uid} for every existing user, using the same
 * allowlist as the onUserWrittenPublicProfile trigger.
 *   npm run build && node scripts/backfill_public_profiles.js [--write]
 * Dry run by default.
 */
const admin = require("firebase-admin");
admin.initializeApp({credential: admin.credential.cert(require("../serviceAccountKey.json"))});
const {publicProfileOf} = require("../lib/public_profile_ops.js");

(async () => {
  const write = process.argv.includes("--write");
  const db = admin.firestore();
  const users = await db.collection("users").get();
  for (const u of users.docs) {
    const p = publicProfileOf(u.data());
    console.log(u.id, Object.keys(p).sort().join(","));
    if (write) await db.doc(`public_profiles/${u.id}`).set(p);
  }
  console.log(`${users.size} users ${write ? "written" : "(dry run)"}`);
})();
