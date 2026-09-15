/* eslint-disable */
/**
 * Split caretaker threads that more than one tenancy was merged into.
 *
 * openCaretakerThread used one conversation per unit and caretaker
 * (`caretaker_{propertyId}_{caretakerId}`) and unioned each new tenant into it,
 * overwriting tenantId/tenantName. So the former tenant stayed a participant
 * and kept reading the thread, and the new tenant inherited their history. The
 * id now carries the tenant (caretaker_ops.ts); this repairs threads that
 * already hold more than one tenant.
 *
 * For each such legacy thread, `tenantId` is the MOST RECENT tenant (every
 * re-open overwrote it). The thread goes back to the former tenant whose
 * history it holds, the most recent tenant is taken off it, and they get their
 * own per-tenancy thread if they still live there and the caretaker still
 * manages the unit.
 *
 * DRY RUN by default - prints what it WOULD do and writes nothing.
 * Pass --confirm to perform the writes.
 *
 *   node scripts/repair_caretaker_threads.js
 *   node scripts/repair_caretaker_threads.js --confirm
 */

const admin = require("firebase-admin");
admin.initializeApp({
  credential: admin.credential.cert(
    require("C:/Users/MIDE/clearrent/functions/serviceAccountKey.json"),
  ),
});
const db = admin.firestore();
const {FieldValue, Timestamp} = admin.firestore;

const CONFIRM = process.argv.includes("--confirm");
// Must match OCCUPYING_RENTAL_STATUSES in caretaker_ops.ts.
const OCCUPYING = [
  "active", "expiring_soon", "grace_locked", "pending_payment", "moveout_pending",
];

async function nameOf(uid, fallback) {
  const snap = await db.collection("users").doc(uid).get();
  return snap.get("fullName") || fallback;
}

(async () => {
  const snap = await db.collection("conversations")
    .where("caretakerId", "!=", "")
    .get();
  // Legacy ids have exactly three parts; per-tenancy ids have four.
  const legacy = snap.docs.filter((d) =>
    d.id.startsWith("caretaker_") && d.id.split("_").length === 3);
  console.log(`${legacy.length} legacy caretaker thread(s)`);

  for (const doc of legacy) {
    const c = doc.data();
    const current = c.tenantId;
    const former = (c.participants || []).filter((p) =>
      p !== c.landlordId && p !== c.caretakerId && p !== current);
    if (former.length === 0) {
      console.log(`ok     ${doc.id} (one tenant only)`);
      continue;
    }
    if (former.length > 1) {
      console.log(`WARN   ${doc.id} holds ${former.length} former tenants; ` +
        `handing it to the first`);
    }
    const formerName = await nameOf(former[0], "Tenant");
    console.log(`split  ${doc.id} "${c.propertyTitle}": back to ${formerName} ` +
      `(${former[0]}), removing ${c.tenantName} (${current})`);

    const [rentals, prop] = await Promise.all([
      db.collection("active_rentals")
        .where("propertyId", "==", c.propertyId)
        .where("tenantId", "==", current)
        .get(),
      db.collection("properties").doc(c.propertyId).get(),
    ]);
    const stillLives = rentals.docs.some((r) =>
      OCCUPYING.includes(r.get("status")));
    const stillManages = prop.get("caretakerId") === c.caretakerId;
    const newId = `${doc.id}_${current}`;
    const newRef = db.collection("conversations").doc(newId);
    const openNew = stillLives && stillManages &&
      !(await newRef.get()).exists;
    console.log(openNew ?
      `       open ${newId} for ${c.tenantName}` :
      `       no new thread (lives=${stillLives} manages=${stillManages})`);

    if (!CONFIRM) continue;

    await doc.ref.update({
      participants: FieldValue.arrayRemove(current),
      tenantId: former[0],
      tenantName: formerName,
    });
    if (openNew) {
      const now = Timestamp.now();
      await newRef.create({
        id: newId,
        propertyId: c.propertyId,
        propertyTitle: c.propertyTitle,
        propertyImage: c.propertyImage || "",
        landlordId: c.landlordId,
        landlordName: c.landlordName,
        tenantId: current,
        tenantName: c.tenantName,
        agentId: "",
        agentName: "",
        caretakerId: c.caretakerId,
        caretakerName: c.caretakerName,
        participants: [c.landlordId, current, c.caretakerId],
        lastMessage: "",
        lastMessageTime: now,
        lastMessageSenderId: "",
        unreadCounts: {[c.landlordId]: 0, [current]: 0, [c.caretakerId]: 0},
        createdAt: now,
      });
    }
  }
  console.log(CONFIRM ? "done" : "dry run: nothing written, pass --confirm");
})().catch((e) => {
  console.error("ERR", e.message);
  process.exit(1);
});
