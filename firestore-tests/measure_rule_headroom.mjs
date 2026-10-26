// How much of Firestore's per-request expression budget (1000) the viewing
// update rules leave free, in real units (2026-10-26). Pads the request's own
// path with N cheap comparisons and binary-searches the N at which an ALLOWED
// write starts being refused. A request costing nothing absorbs ~187 units,
// so "used" = (187 - headroom) / 187. On 2026-10-26 the old 27-row rules used
// ~59% (refund) and ~75% (on the way); the grouped function ~17% and ~21%.
//
// Run from clearrent/:
//   npx firebase-tools emulators:exec --only firestore --project demo-clearrent
//     "cd firestore-tests && node measure_rule_headroom.mjs ../firestore.rules 1"
// The second argument is 1 for the grouped viewingUpdateAllowed() function.
import { readFileSync } from "node:fs";
import { initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, serverTimestamp } from "firebase/firestore";
const [file, newStyle] = process.argv.slice(2);
const base = readFileSync(file, "utf8").replace(/\r\n/g, "\n");
const T = "tenant1", L = "landlord1";
// Padding as one helper: k lets of 10 comparisons each (a single long chain
// does not compile: "Expression is too complex").
function burnFn(n) {
  // At most 10 lets per function and no long chains, so: burn10 is 10
  // comparisons, burn100 calls it 10 times, burnFn calls those as needed.
  const hundreds = Math.floor(n / 100), tens = Math.ceil((n % 100) / 10);
  const calls = [...Array(hundreds).fill("burn100()"), ...Array(tens).fill("burn10()")];
  const c10 = Array.from({ length: 10 }, () => "1 < 2").join(" && ");
  const c100 = Array.from({ length: 10 }, () => "burn10()").join(" && ");
  return `function burn10() { return ${c10}; }
      function burn100() { return ${c100}; }
      function burnFn() { return ${calls.length ? calls.join(" && ") : "true"}; }`;
}
// Padding goes ONLY on the path the case takes, so both versions are
// measured on the same footing: old = the matching row's condition,
// new = the front of the whole function.
function inject(n, rowLabel) {
  const fn = burnFn(n);
  if (newStyle === "1") {
    return base.replace("function viewingUpdateAllowed() {", `${fn}\n      function viewingUpdateAllowed() {`)
      .replace(/\n        return\n/, "\n        return burnFn() && (\n")
      .replace("            && isRescheduleReceiver());\n      }", "            && isRescheduleReceiver()));\n      }");
  }
  const at = base.indexOf(rowLabel);
  const u = base.indexOf("allow update: if ", at);
  return base.slice(0, u) + "allow update: if burnFn() && " + base.slice(u + 17)
    .replace(/(match \/inspection_requests\/\{requestId\} \{)/, "$1");
}
function withFns(rules, n) {
  return rules.replace(/(match \/inspection_requests\/\{requestId\} \{)/, `$1\n      ${burnFn(n)}`);
}
const cases = {
  "[26] tenant takes refund": { row: "[Row 26]", seed: { status: "expiredUnapproved", paymentStatus: "paid" }, as: T,
    data: { status: "refunded", paymentStatus: "refunded", refundReason: "r", refundedAt: serverTimestamp(), updatedAt: serverTimestamp() } },
  "[23] handler on the way": { row: "[Row 23]", seed: { status: "approved" }, as: L,
    data: { handlerOnWay: true, handlerOnWayAt: serverTimestamp(), updatedAt: serverTimestamp() } },
};
async function allowed(n, c) {
  const env = await initializeTestEnvironment({ projectId: "hr-" + Math.random().toString(36).slice(2, 8),
    firestore: { host: "127.0.0.1", port: 8080, rules: newStyle === "1" ? inject(n, c.row) : withFns(inject(n, c.row), n) } });
  await env.withSecurityRulesDisabled(async (ctx) => setDoc(doc(ctx.firestore(), "inspection_requests/x"),
    { tenantId: T, landlordId: L, agentId: null, propertyId: "p1", ...c.seed }));
  let ok = true;
  try { await updateDoc(doc(env.authenticatedContext(c.as).firestore(), "inspection_requests/x"), c.data); } catch { ok = false; }
  await env.cleanup();
  return ok;
}
for (const [name, c] of Object.entries(cases)) {
  if (!(await allowed(0, c))) { console.log(`${name}: NOT ALLOWED even with no padding`); continue; }
  let lo = 0, hi = 1000;
  while (hi - lo > 10) { const mid = (lo + hi) >> 1; (await allowed(mid, c)) ? (lo = mid) : (hi = mid); }
  console.log(`${name}: headroom ~${lo} extra comparisons`);
}
process.exit(0);
