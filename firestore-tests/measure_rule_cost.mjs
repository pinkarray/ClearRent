// Estimates how close key requests come to Firestore's 1000-expression
// limit, using emulator rule coverage as a ruler (2026-10-25). The two
// CALIBRATION requests are known to hit the limit; read the others as a share
// of their score. Run: npx firebase-tools emulators:exec --only firestore
//   --project demo-clearrent "cd firestore-tests && node measure_rule_cost.mjs"
// Runs ONE request per fresh coverage window and reports the total
// expressions the emulator evaluated for it.
import { readFileSync } from "node:fs";
import { initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, serverTimestamp, Timestamp } from "firebase/firestore";
const rules = readFileSync("C:/Users/MIDE/clearrent/firestore.rules", "utf8");
const T="tenant1", L="landlord1";
async function cost(name, seed, act) {
  const env = await initializeTestEnvironment({ projectId: "measure-" + Math.random().toString(36).slice(2,8),
    firestore: { host: "127.0.0.1", port: 8080, rules } });
  await env.withSecurityRulesDisabled(async (ctx) => { await seed(ctx.firestore()); });
  let ok = true; try { await act(env); } catch (e) { ok = false; }
  const cov = await (await fetch(`http://127.0.0.1:8080/emulator/v1/projects/${env.projectId}:ruleCoverage`)).json();
  let n = 0; const walk = (x) => { for (const v of x.values ?? []) n += v.count; for (const c of x.children ?? []) walk(c); };
  for (const r of cov.report ?? []) walk(r);
  console.log(`${ok ? "ALLOWED" : "DENIED "}  ~${n} expressions  ${name}`);
  await env.cleanup();
}
const insp = (db, id, extra) => setDoc(doc(db, `inspection_requests/${id}`), { tenantId: T, landlordId: L, agentId: null, propertyId: "p1", ...extra });
await cost("[23] handler on the way (late row)", (db) => insp(db, "x", { status: "approved" }),
  (env) => updateDoc(doc(env.authenticatedContext(L).firestore(), "inspection_requests/x"), { handlerOnWay: true, handlerOnWayAt: serverTimestamp(), updatedAt: serverTimestamp() }));
await cost("[26] tenant takes refund (last row)", (db) => insp(db, "x", { status: "expiredUnapproved", paymentStatus: "paid" }),
  (env) => updateDoc(doc(env.authenticatedContext(T).firestore(), "inspection_requests/x"), { status: "refunded", paymentStatus: "refunded", refundReason: "r", refundedAt: serverTimestamp(), updatedAt: serverTimestamp() }));
await cost("[14a] handler approves (first row)", async (db) => { await insp(db, "x", { status: "pending" }); await setDoc(doc(db, "users/"+L), { hasBankDetails: true }); },
  (env) => updateDoc(doc(env.authenticatedContext(L).firestore(), "inspection_requests/x"), { status: "approved", updatedAt: serverTimestamp() }));
await cost("landlord relists a listing (property update)", async (db) => {
    await setDoc(doc(db, "users/"+L), { verificationStatus: "verified" });
    await setDoc(doc(db, "properties/p1"), { landlordId: L, title: "t", rent: 200000, agentFee: 0, cautionDeposit: 0, isAvailable: false, ownershipDocStatus: "verified", furnishing: "partly" }); },
  (env) => updateDoc(doc(env.authenticatedContext(L).firestore(), "properties/p1"), { isAvailable: true, title: "t2", furnishing: "fully" }));
await cost("tenant reports an issue (create)", async () => {},
  (env) => setDoc(doc(env.authenticatedContext(T).firestore(), "issues/i1"), { tenantId: T, landlordId: L, propertyId: "p1", status: "open", priority: "high", createdAt: serverTimestamp(), photoPaths: ["issues/"+T+"/a.jpg"] }));
await cost("CALIBRATION: stranger updates a viewing (walks all 27 rows, hits the ceiling)", (db) => insp(db, "x", { status: "approved" }),
  (env) => updateDoc(doc(env.authenticatedContext("stranger").firestore(), "inspection_requests/x"), { handlerOnWay: true, updatedAt: serverTimestamp() }));
await cost("CALIBRATION: stranger updates a listing", async (db) => { await setDoc(doc(db, "properties/p1"), { landlordId: L, title: "t", rent: 200000, agentFee: 0, cautionDeposit: 0, isAvailable: false }); },
  (env) => updateDoc(doc(env.authenticatedContext("stranger").firestore(), "properties/p1"), { title: "x" }));
process.exit(0);
