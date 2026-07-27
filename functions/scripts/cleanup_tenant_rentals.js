/* eslint-disable */
/**
 * Reset ONE test tenant's rental state to a clean slate, so the rent flow can be
 * tested end-to-end without the pile of half-finished records from earlier runs.
 *
 * DRY RUN by default — prints what it WOULD do and writes nothing.
 * Pass --confirm to actually perform the writes.
 *
 *   node scripts/cleanup_tenant_rentals.js syd@gmail.com            # dry run
 *   node scripts/cleanup_tenant_rentals.js syd@gmail.com --confirm  # execute
 *
 * For [tenant] it: deletes every active_rentals + rental_interests doc,
 * clears the user's hasActiveRental/currentPropertyId/currentRentalId, and
 * resets each referenced property to isAvailable=true, currentTenantsCount=0.
 * inspection_requests are LEFT ALONE (so the tenant can re-express interest on
 * an already-completed+rated inspection).
 */

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "clearrent-app"});
const db = admin.firestore();

const email = process.argv[2] || "syd@gmail.com";
const CONFIRM = process.argv.includes("--confirm");

async function main() {
  const usersByEmail = await db
    .collection("users").where("email", "==", email).get();
  if (usersByEmail.empty) {
    console.log(`No user with email ${email}`);
    process.exit(0);
  }
  const uid = usersByEmail.docs[0].id;
  console.log(`\n${CONFIRM ? "EXECUTING" : "DRY RUN"} — tenant ${email} (${uid})\n`);

  const rentals = await db.collection("active_rentals")
    .where("tenantId", "==", uid).get();
  const interests = await db.collection("rental_interests")
    .where("tenantId", "==", uid).get();

  const propertyIds = new Set();
  rentals.forEach((d) => d.get("propertyId") && propertyIds.add(d.get("propertyId")));

  console.log(`active_rentals to DELETE (${rentals.size}):`);
  rentals.forEach((d) => console.log(`  - ${d.id}  (status=${d.get("status")}, property=${d.get("propertyId")})`));
  console.log(`rental_interests to DELETE (${interests.size}):`);
  interests.forEach((d) => console.log(`  - ${d.id}  (status=${d.get("status")})`));
  console.log(`user ${uid}: clear hasActiveRental/currentPropertyId/currentRentalId`);
  console.log(`properties to FREE (${propertyIds.size}): ${[...propertyIds].join(", ")}`);

  if (!CONFIRM) {
    console.log("\n(dry run — nothing written. Re-run with --confirm to execute.)");
    process.exit(0);
  }

  const batch = db.batch();
  rentals.forEach((d) => batch.delete(d.ref));
  interests.forEach((d) => batch.delete(d.ref));
  batch.update(db.collection("users").doc(uid), {
    hasActiveRental: false,
    currentPropertyId: null,
    currentRentalId: null,
    rentStartDate: null,
    rentEndDate: null,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  for (const pid of propertyIds) {
    batch.update(db.collection("properties").doc(pid), {
      isAvailable: true,
      currentTenantsCount: 0,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();
  console.log("\n✅ Done. Tenant reset to a clean slate.");
  process.exit(0);
}

main().catch((e) => {
  console.error("Cleanup error:", e.message || e);
  process.exit(1);
});
