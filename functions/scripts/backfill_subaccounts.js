/* eslint-disable */
/**
 * Creates a Paystack subaccount for every verified landlord and agent who
 * already has bank details, using the same code as the triggers.
 *   npm run build
 *   PAYSTACK_SECRET_KEY=... node scripts/backfill_subaccounts.js [--write]
 * Dry run by default.
 */
const admin = require("firebase-admin");
admin.initializeApp({credential: admin.credential.cert(require("../serviceAccountKey.json"))});
const {syncSubaccount} = require("../lib/subaccount_ops.js");

(async () => {
  const write = process.argv.includes("--write");
  const db = admin.firestore();
  const users = await db.collection("users")
    .where("verificationStatus", "==", "verified").get();
  let eligible = 0;
  for (const u of users.docs) {
    if (!["landlord", "agent"].includes(u.get("accountType"))) continue;
    if (u.get("hasBankDetails") !== true) continue;
    eligible++;
    console.log(u.id, u.get("accountType"), write ? await syncSubaccount(u.id) : "would sync");
  }
  console.log(`${eligible} of ${users.size} verified users ${write ? "synced" : "(dry run)"}`);
  process.exit(0);
})();
