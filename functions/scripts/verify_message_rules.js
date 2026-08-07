/* eslint-disable */
/**
 * Rules verification for message edit / delete / read-receipt, against the
 * Firestore emulator with firestore.rules loaded.
 *   node scripts/verify_message_rules.js   (emulator must be running on 8080)
 *
 * The point of these cases is the allowlist. Message update used to be blanket
 * "any active participant", which meant adding edit and delete would also have
 * handed every participant a way to rewrite the OTHER party's messages, or to
 * rewrite senderId / timestamp / the property-share snapshot on their own. Each
 * DENIES case below is one of those paths.
 */

const fs = require("fs");
const path = require("path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc, deleteDoc} = require("firebase/firestore");

const CONVO = "c1";
const LANDLORD = "landlord1";
const TENANT = "tenant1";

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures++;
}

/** Path to a message doc under the test conversation. */
function msg(db, id) {
  return doc(db, "conversations", CONVO, "messages", id);
}

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

  // Seed the conversation, two verified users, and one message from each side.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "users", LANDLORD), {verificationStatus: "verified"});
    await setDoc(doc(db, "users", TENANT), {verificationStatus: "verified"});
    await setDoc(doc(db, "conversations", CONVO), {
      participants: [LANDLORD, TENANT],
      landlordId: LANDLORD,
      tenantId: TENANT,
      lastMessage: "hi",
    });
    await setDoc(msg(db, "mine"), {
      senderId: TENANT,
      senderName: "Tenant",
      text: "original",
      timestamp: new Date(),
      isRead: false,
    });
    await setDoc(msg(db, "theirs"), {
      senderId: LANDLORD,
      senderName: "Landlord",
      text: "from the landlord",
      timestamp: new Date(),
      isRead: false,
    });
    await setDoc(msg(db, "gone"), {
      senderId: TENANT,
      senderName: "Tenant",
      text: "",
      timestamp: new Date(),
      isRead: false,
      deleted: true,
    });
  });

  const tenant = env.authenticatedContext(TENANT).firestore();
  const outsider = env.authenticatedContext("stranger").firestore();

  // ── Read receipts ─────────────────────────────────────────────────────
  await check("participant CAN mark another's message read",
    await passes(updateDoc(msg(tenant, "theirs"), {isRead: true})));
  await check("read receipt CANNOT carry a text change",
    await denies(updateDoc(
      msg(tenant, "theirs"), {isRead: true, text: "rewritten"})));
  await check("read flag CANNOT be set back to false",
    await denies(updateDoc(msg(tenant, "theirs"), {isRead: false})));

  // ── Editing ───────────────────────────────────────────────────────────
  await check("author CAN edit their own message",
    await passes(updateDoc(
      msg(tenant, "mine"), {text: "edited", editedAt: new Date(),
        mentions: []})));
  await check("author CANNOT edit the OTHER party's message",
    await denies(updateDoc(
      msg(tenant, "theirs"), {text: "put words in their mouth",
        editedAt: new Date()})));
  await check("edit CANNOT rewrite senderId",
    await denies(updateDoc(
      msg(tenant, "mine"), {text: "edited", senderId: LANDLORD})));
  await check("edit CANNOT rewrite senderName",
    await denies(updateDoc(
      msg(tenant, "mine"), {text: "edited", senderName: "Landlord"})));
  await check("edit CANNOT move the timestamp",
    await denies(updateDoc(
      msg(tenant, "mine"), {text: "edited", timestamp: new Date(0)})));
  await check("edit CANNOT flip isRead",
    await denies(updateDoc(
      msg(tenant, "mine"), {text: "edited again", isRead: true})));
  await check("author CANNOT receipt their OWN message",
    await denies(updateDoc(msg(tenant, "mine"), {isRead: true})));
  await check("edit CANNOT plant a property-share card",
    await denies(updateDoc(msg(tenant, "mine"), {
      text: "edited", type: "property_share", sharedPropertyId: "p1"})));
  await check("edit CANNOT blank the text (that is a delete)",
    await denies(updateDoc(
      msg(tenant, "mine"), {text: "", editedAt: new Date()})));
  await check("a deleted message CANNOT be edited back to life",
    await denies(updateDoc(
      msg(tenant, "gone"), {text: "back", editedAt: new Date()})));

  // ── Deleting ──────────────────────────────────────────────────────────
  await check("author CAN soft-delete their own message",
    await passes(updateDoc(msg(tenant, "mine"), {
      text: "", deleted: true, deletedAt: new Date(), mentions: []})));
  await check("author CANNOT delete the OTHER party's message",
    await denies(updateDoc(
      msg(tenant, "theirs"), {text: "", deleted: true,
        deletedAt: new Date()})));
  await check("delete CANNOT leave the text behind",
    await denies(updateDoc(
      msg(tenant, "theirs"), {deleted: true, deletedAt: new Date()})));
  await check("hard delete is still refused",
    await denies(deleteDoc(msg(tenant, "mine"))));

  // ── Non-participants ──────────────────────────────────────────────────
  await check("outsider CANNOT mark a message read",
    await denies(updateDoc(msg(outsider, "theirs"), {isRead: true})));
  await check("outsider CANNOT edit a message",
    await denies(updateDoc(
      msg(outsider, "theirs"), {text: "hijacked", editedAt: new Date()})));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
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

main().catch((e) => {
  console.error("RULES VERIFY CRASHED:", e);
  process.exit(2);
});
