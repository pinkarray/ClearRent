/* eslint-disable */
/**
 * Collapse a duplicated rental caused by the createRentalInterest race.
 *
 * Two concurrent createRentalInterest calls could both pass the read-then-write
 * dedupe and mint two interests for ONE inspection, which then became two
 * payable rentals on the same property — so the tenant could pay twice and
 * every server guard (all of which key on the interest id) considered both
 * charges legitimate. The race itself is fixed in rental_interest_ops.ts
 * (deterministic `ri_<inspectionRequestId>` id + `.create()`); this repairs
 * the records that already exist.
 *
 * DRY RUN by default — prints what it WOULD do and writes nothing.
 * Pass --confirm to perform the writes.
 *
 *   node scripts/fix_duplicate_rental.js
 *   node scripts/fix_duplicate_rental.js --confirm
 *
 * It does NOT move money. The duplicate charge is flagged for refund and must
 * be refunded from the Paystack dashboard by a human.
 */

const admin = require("firebase-admin");
admin.initializeApp({
  credential: admin.credential.cert(
    require("C:/Users/MIDE/clearrent/functions/serviceAccountKey.json"),
  ),
});
const db = admin.firestore();

const CONFIRM = process.argv.includes("--confirm");

// Keep the rental the user document already points at, so the tenant's own
// record needs no rewrite; drop its twin.
const KEEP = "AdYtoqJFxCcCNKGXJU6L";
const DROP = "u2bZ9GVNkiEkA0v5HSmY";
const TENANT = "ydGZHJjGK7MPe3usvnT3lWAPHzp1";
const PROPERTY = "aRRnXZOZzWO9iGH5w61i";
// The charge that paid for the rental being dropped.
const REFUND_REF = "CR_RENT_1788185837890_a56e9097";

async function main() {
  console.log(`\n${CONFIRM ? "EXECUTING" : "DRY RUN"}\n`);

  // Re-verify the premise rather than trusting the constants above: refuse to
  // delete anything unless the state still looks like the duplicate we mapped.
  const keep = await db.collection("active_rentals").doc(KEEP).get();
  const drop = await db.collection("active_rentals").doc(DROP).get();
  if (!keep.exists || !drop.exists) {
    console.log("Aborting — one of the rentals no longer exists. Re-inspect.");
    return;
  }
  if (
    keep.get("tenantId") !== TENANT ||
    drop.get("tenantId") !== TENANT ||
    keep.get("propertyId") !== PROPERTY ||
    drop.get("propertyId") !== PROPERTY
  ) {
    console.log("Aborting — tenant/property do not match. Re-inspect.");
    return;
  }
  const user = await db.collection("users").doc(TENANT).get();
  if (user.get("currentRentalId") !== KEEP) {
    console.log(
      `Aborting — user.currentRentalId is ${user.get("currentRentalId")}, ` +
        `not the rental being kept (${KEEP}). Re-inspect.`,
    );
    return;
  }

  console.log(`keep   active_rentals/${KEEP}`);
  console.log(`delete active_rentals/${DROP}`);
  console.log(`delete rental_interests/${DROP}`);
  console.log(`set    properties/${PROPERTY}.currentTenantsCount = 1 (was 2)`);
  console.log(`flag   payments/${REFUND_REF} as a duplicate awaiting refund`);
  console.log(`\nNOT DONE HERE: refund ₦25,000 for ${REFUND_REF} in Paystack.`);

  if (!CONFIRM) {
    console.log("\nDry run — nothing written. Re-run with --confirm.\n");
    return;
  }

  const batch = db.batch();
  batch.delete(db.collection("active_rentals").doc(DROP));
  batch.delete(db.collection("rental_interests").doc(DROP));
  // Set explicitly rather than relying on recomputePropertyOccupancy: the
  // recompute runs on its own triggers and will arrive at the same number, but
  // the property must not sit over-occupied in the meantime.
  batch.update(db.collection("properties").doc(PROPERTY), {
    currentTenantsCount: 1,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  // The charge stays on the books — it really happened — but is marked so it
  // is not mistaken for rent owed to the landlord, and so the refund is
  // traceable. Deleting it would hide a real movement of money.
  batch.set(
    db.collection("payments").doc(REFUND_REF),
    {
      duplicateOf: KEEP,
      voidedReason:
        "Duplicate rental created by the createRentalInterest race; " +
        "this charge paid for the rental that was removed.",
      refundRequired: true,
      needsReconciliation: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    {merge: true},
  );
  await batch.commit();
  console.log("\nDone. Now issue the Paystack refund for", REFUND_REF, "\n");
}

main().catch((e) => {
  console.error("ERR", e.message);
  process.exit(1);
});
