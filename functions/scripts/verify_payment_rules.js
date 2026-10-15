/* eslint-disable */
/**
 * Payments: the payer may write only what the app writes (recordPayment and
 * initiateRefund). The server-only fields, refundRequired above all, feed the
 * admin refund queue and must be refused.
 *
 * Each denial has a positive control beside it.
 *   node scripts/verify_payment_rules.js   (emulator on 8080)
 */
const fs = require("fs");
const path = require("path");
const {initializeTestEnvironment, assertFails, assertSucceeds} =
  require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc, serverTimestamp} = require("firebase/firestore");

let failures = 0;
const check = (name, ok) => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); if (!ok) failures++; };
const ok = (p) => assertSucceeds(p).then(() => true, () => false);
const denied = (p) => assertFails(p).then(() => true, () => false);

(async () => {
  const env = await initializeTestEnvironment({
    projectId: "clearrent-payments-" + Date.now(),
    firestore: {host: "127.0.0.1", port: 8080,
      rules: fs.readFileSync(path.join(__dirname, "..", "..", "firestore.rules"), "utf8")},
  });
  const ME = "payer", OTHER = "someone_else";
  const db = env.authenticatedContext(ME, {email: "p@x.com"}).firestore();
  const base = (ref, extra) => ({
    reference: ref, userId: ME, userEmail: "p@x.com", type: "inspection",
    amount: 10000, status: "completed", relatedId: null,
    createdAt: serverTimestamp(), ...extra,
  });
  const merge = (ref, data) => setDoc(doc(db, `payments/${ref}`), data, {merge: true});

  // CREATE: every recordPayment shape the app sends
  check("create: inspection with propertyId/requestId",
    await ok(merge("r_insp", base("r_insp", {propertyId: "p", requestId: "q"}))));
  check("create: rent with its split fields",
    await ok(merge("r_rent", base("r_rent", {type: "rent", rentalInterestId: "ri",
      propertyId: "p", rentAmount: 1, agentFee: 1, tenantDealFee: 1,
      landlordPayout: 1, agentPayout: 1, clearrentEarnings: 1}))));
  check("create: verification docs_upload_failed",
    await ok(merge("r_ver", base("r_ver", {type: "verification",
      status: "docs_upload_failed", accountType: "tenant"}))));
  check("create: listing fee", await ok(merge("r_list", base("r_list", {type: "listing"}))));
  check("create: refundRequired refused",
    await denied(merge("r_bad1", base("r_bad1", {refundRequired: true, description: "Duplicate charge"}))));
  check("create: webhookVerified refused",
    await denied(merge("r_bad2", base("r_bad2", {webhookVerified: true}))));
  check("create: odd status refused",
    await denied(merge("r_bad3", base("r_bad3", {status: "refunded"}))));
  check("create: for someone else refused",
    await denied(merge("r_bad4", base("r_bad4", {userId: OTHER}))));

  // UPDATE after the webhook wrote first (server fields already present)
  await env.withSecurityRulesDisabled(async (c) => {
    await c.firestore().doc("payments/r_hook").set({
      reference: "r_hook", userId: ME, type: "inspection", amount: 10000,
      status: "completed", source: "webhook", webhookVerified: true,
      gatewayAmount: 10000, needsReconciliation: true,
    });
  });
  check("update: recordPayment merge over a webhook record",
    await ok(merge("r_hook", base("r_hook", {propertyId: "p", requestId: "q"}))));
  check("update: initiateRefund fields",
    await ok(updateDoc(doc(db, "payments/r_hook"), {status: "refund_initiated",
      refundReason: "x", refundInitiatedAt: serverTimestamp()})));
  check("update: refundRequired refused",
    await denied(updateDoc(doc(db, "payments/r_hook"), {refundRequired: true})));
  check("update: duplicateOf refused",
    await denied(updateDoc(doc(db, "payments/r_hook"), {duplicateOf: "ri"})));
  check("update: gatewayAmount refused",
    await denied(updateDoc(doc(db, "payments/r_hook"), {gatewayAmount: 1})));
  check("update: clearing needsReconciliation refused",
    await denied(updateDoc(doc(db, "payments/r_hook"), {needsReconciliation: false})));
  check("update: handing the record to someone else refused",
    await denied(updateDoc(doc(db, "payments/r_hook"), {userId: OTHER})));
  check("update: by a stranger refused",
    await denied(updateDoc(doc(env.authenticatedContext(OTHER).firestore(), "payments/r_hook"), {status: "completed"})));

  await env.cleanup();
  console.log(failures ? `\n${failures} FAILED` : "\nall passed");
  process.exit(failures ? 1 : 0);
})();
