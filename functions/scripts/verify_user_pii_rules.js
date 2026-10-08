/* eslint-disable */
/**
 * users/{uid} is readable by EVERY signed-in account, so identity and payout
 * data must never land on it. Proven exposed 2026-10-08: a reviewer account
 * read the super-admin's BVN over the REST API.
 *
 * Each denial is paired with a positive control that would have passed before
 * the rule, so a vacuously-failing write cannot be mistaken for a fix.
 *   node scripts/verify_user_pii_rules.js   (emulator on 8080)
 */
const fs = require("fs");
const path = require("path");
const {initializeTestEnvironment, assertFails, assertSucceeds} =
  require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc} = require("firebase/firestore");

let failures = 0;
const check = (name, ok) => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); if (!ok) failures++; };

(async () => {
  const env = await initializeTestEnvironment({
    projectId: "clearrent-pii-" + Date.now(),
    firestore: {host: "127.0.0.1", port: 8080,
      rules: fs.readFileSync(path.join(__dirname, "..", "..", "firestore.rules"), "utf8")},
  });
  const UID = "u_pii";
  const db = env.authenticatedContext(UID).firestore();
  const ref = doc(db, "users", UID);
  const base = {uid: UID, email: "a@b.com", fullName: "A B", accountType: "tenant"};

  // CREATE
  check("create: plain profile is allowed (positive control)",
    await assertSucceeds(setDoc(ref, base)).then(() => true, () => false));
  await env.withSecurityRulesDisabled(async (c) => { await c.firestore().doc(`users/${UID}`).delete(); });
  for (const [f, v] of [["bvn","22211122233"],["nin","12345678901"],["bankDetails",{accountNumber:"0123456789"}]]) {
    check(`create: ${f} is denied`,
      await assertFails(setDoc(ref, {...base, [f]: v})).then(() => true, () => false));
  }

  // UPDATE
  await env.withSecurityRulesDisabled(async (c) => {
    await c.firestore().doc(`users/${UID}`).set(base);
  });
  check("update: ordinary field is allowed (positive control)",
    await assertSucceeds(updateDoc(ref, {fullName: "A C"})).then(() => true, () => false));
  for (const [f, v] of [["bvn","22211122233"],["nin","12345678901"],["bankDetails",{accountNumber:"0123456789"}]]) {
    check(`update: ${f} is denied`,
      await assertFails(updateDoc(ref, {[f]: v})).then(() => true, () => false));
  }

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILED"}`);
  process.exit(failures ? 1 : 0);
})();
