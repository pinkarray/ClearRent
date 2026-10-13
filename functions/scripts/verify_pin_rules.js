/* eslint-disable */
/**
 * properties/{id}/private/location.confirmedPin is the on-site GPS reading
 * that video viewings check the handler's presence against. Only the
 * confirmPropertyPin CF may write it; the owner must still be able to move
 * the pin and edit the address as before.
 *
 * Each denial is paired with a positive control, so a vacuously-failing write
 * cannot be mistaken for the rule working.
 *   node scripts/verify_pin_rules.js   (emulator on 8080)
 */
const fs = require("fs");
const path = require("path");
const {initializeTestEnvironment, assertFails, assertSucceeds} =
  require("@firebase/rules-unit-testing");
const {doc, getDoc, setDoc, updateDoc, deleteDoc} = require("firebase/firestore");

let failures = 0;
const check = (name, ok) => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); if (!ok) failures++; };
const ok = (p) => assertSucceeds(p).then(() => true, () => false);
const denied = (p) => assertFails(p).then(() => true, () => false);

(async () => {
  const env = await initializeTestEnvironment({
    projectId: "clearrent-pin-" + Date.now(),
    firestore: {host: "127.0.0.1", port: 8080,
      rules: fs.readFileSync(path.join(__dirname, "..", "..", "firestore.rules"), "utf8")},
  });
  const OWNER = "landlord_1", AGENT = "agent_1", OTHER = "stranger_1", CARETAKER = "caretaker_1";
  const PID = "prop_pin";
  const pinned = {latitude: 6.5, longitude: 3.35, accuracyM: 12, confirmedBy: OWNER, role: "landlord"};

  const reset = async (locationData) => env.withSecurityRulesDisabled(async (c) => {
    const f = c.firestore();
    await f.doc(`properties/${PID}`).set({landlordId: OWNER, assignedAgentId: AGENT, caretakerId: CARETAKER, city: "Yaba", state: "Lagos"});
    const loc = f.doc(`properties/${PID}/private/location`);
    if (locationData) await loc.set(locationData); else await loc.delete();
  });
  const loc = (uid) => doc(env.authenticatedContext(uid).firestore(), `properties/${PID}/private/location`);

  // CREATE
  await reset(null);
  check("create: owner writes address + pin (positive control)",
    await ok(setDoc(loc(OWNER), {address: "1 Herbert Macaulay Way", latitude: 6.5, longitude: 3.37})));
  await reset(null);
  check("create: owner cannot plant a confirmedPin",
    await denied(setDoc(loc(OWNER), {address: "x", latitude: 6.5, longitude: 3.37, confirmedPin: pinned})));

  // UPDATE, on a pin the CF already confirmed
  await reset({address: "1 Herbert Macaulay Way", latitude: 6.5, longitude: 3.35, confirmedPin: pinned});
  check("update: owner moves the pin by hand (positive control)",
    await ok(updateDoc(loc(OWNER), {latitude: 6.6, longitude: 3.4})));
  check("update: agent edits the address (positive control)",
    await ok(setDoc(loc(AGENT), {address: "2 Herbert Macaulay Way"}, {merge: true})));
  check("update: owner cannot rewrite confirmedPin",
    await denied(updateDoc(loc(OWNER), {confirmedPin: {...pinned, latitude: 6.6, longitude: 3.4}})));
  check("update: owner cannot nudge one field of confirmedPin",
    await denied(updateDoc(loc(OWNER), {"confirmedPin.accuracyM": 1})));
  check("update: agent cannot rewrite confirmedPin",
    await denied(setDoc(loc(AGENT), {confirmedPin: {...pinned, latitude: 6.7}}, {merge: true})));
  check("update: stranger cannot touch the location at all",
    await denied(updateDoc(loc(OTHER), {latitude: 6.6})));

  // UPDATE, on an unconfirmed pin: the confirmation can't be self-granted
  await reset({address: "x", latitude: 6.5, longitude: 3.35});
  check("update: owner cannot add confirmedPin to an unconfirmed pin",
    await denied(setDoc(loc(OWNER), {confirmedPin: pinned}, {merge: true})));

  // CARETAKER: may read the location (to see and confirm the pin), nothing else
  await reset({address: "x", latitude: 6.5, longitude: 3.35, confirmedPin: pinned});
  await env.withSecurityRulesDisabled(async (c) => {
    await c.firestore().doc(`properties/${PID}/private/agreement`).set({url: "agreements/a.pdf"});
  });
  const ctDb = env.authenticatedContext(CARETAKER).firestore();
  check("caretaker: reads the location (positive control)",
    await ok(getDoc(doc(ctDb, `properties/${PID}/private/location`))));
  check("caretaker: cannot read the agreement",
    await denied(getDoc(doc(ctDb, `properties/${PID}/private/agreement`))));
  check("caretaker: cannot write the location",
    await denied(updateDoc(doc(ctDb, `properties/${PID}/private/location`), {latitude: 6.6})));
  check("stranger: cannot read the location",
    await denied(getDoc(loc(OTHER))));

  // DELETE stays as it was (owner may remove their own location doc)
  await reset({address: "x", latitude: 6.5, longitude: 3.35, confirmedPin: pinned});
  check("delete: owner may still delete the location doc (unchanged behaviour)",
    await ok(deleteDoc(loc(OWNER))));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILED"}`);
  process.exit(failures ? 1 : 0);
})();
