/* eslint-disable */
/**
 * Video viewings: arrival is recorded only by video_viewing_ops (after the
 * handler's GPS check, and when the tenant joins the call), so the in-person
 * "I've arrived" taps must be refused on a video viewing, and the `video`
 * evidence can't be planted when booking.
 *
 * Each denial has a positive control beside it.
 *   node scripts/verify_video_rules.js   (emulator on 8080)
 */
const fs = require("fs");
const path = require("path");
const {initializeTestEnvironment, assertFails, assertSucceeds} =
  require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc, Timestamp} = require("firebase/firestore");

let failures = 0;
const check = (name, ok) => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); if (!ok) failures++; };
const ok = (p) => assertSucceeds(p).then(() => true, () => false);
const denied = (p) => assertFails(p).then(() => true, () => false);

(async () => {
  const env = await initializeTestEnvironment({
    projectId: "clearrent-video-" + Date.now(),
    firestore: {host: "127.0.0.1", port: 8080,
      rules: fs.readFileSync(path.join(__dirname, "..", "..", "firestore.rules"), "utf8")},
  });
  const TENANT = "tenant_v", LANDLORD = "landlord_v", PID = "prop_v";
  const now = Timestamp.fromDate(new Date());
  const approved = (mode) => ({
    tenantId: TENANT, landlordId: LANDLORD, agentId: null, propertyId: PID,
    status: "approved", paymentStatus: "paid", requestedDate: now,
    tenantArrived: false, handlerArrived: false,
    ...(mode ? {viewingMode: mode} : {}),
  });
  await env.withSecurityRulesDisabled(async (c) => {
    const f = c.firestore();
    await f.doc(`properties/${PID}`).set({landlordId: LANDLORD, readyForInspections: true});
    await f.doc(`users/${TENANT}`).set({hasBankDetails: true});
    await f.doc("inspection_requests/in_person").set(approved(null));
    await f.doc("inspection_requests/video").set(approved("video"));
  });
  const tdb = env.authenticatedContext(TENANT).firestore();
  const ldb = env.authenticatedContext(LANDLORD).firestore();
  const arrive = (db, id, who) => updateDoc(doc(db, `inspection_requests/${id}`),
    {[`${who}Arrived`]: true, [`${who}ArrivedAt`]: now, updatedAt: now});

  // ARRIVAL TAPS
  check("in-person: tenant taps arrived (positive control)", await ok(arrive(tdb, "in_person", "tenant")));
  check("in-person: handler taps arrived (positive control)", await ok(arrive(ldb, "in_person", "handler")));
  check("video: tenant cannot tap arrived", await denied(arrive(tdb, "video", "tenant")));
  check("video: handler cannot tap arrived", await denied(arrive(ldb, "video", "handler")));

  // CREATE
  const booking = (extra) => ({
    tenantId: TENANT, landlordId: LANDLORD, agentId: null, propertyId: PID,
    status: "pending", paymentStatus: "unpaid", requestedDate: now, ...extra,
  });
  check("create: in-person booking (positive control)",
    await ok(setDoc(doc(tdb, "inspection_requests/new1"), booking({}))));
  check("create: video booking (positive control)",
    await ok(setDoc(doc(tdb, "inspection_requests/new2"), booking({viewingMode: "video"}))));
  check("create: unknown viewingMode is denied",
    await denied(setDoc(doc(tdb, "inspection_requests/new3"), booking({viewingMode: "zoom"}))));
  check("create: planting video evidence is denied",
    await denied(setDoc(doc(tdb, "inspection_requests/new4"),
      booking({viewingMode: "video", video: {startedAt: now}}))));

  await env.cleanup();
  console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILED"}`);
  process.exit(failures ? 1 : 0);
})();
