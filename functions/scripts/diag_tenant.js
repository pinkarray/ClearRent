/* eslint-disable */
/**
 * Read-only diagnostic: dump a tenant's rental/interest/inspection state from
 * the LIVE project, so we can see exactly why the rent flow is stuck instead of
 * guessing. Prints statuses only — writes nothing.
 *
 *   node scripts/diag_tenant.js syd@gmail.com
 *
 * Auth: uses Application Default Credentials. If it errors with a credential
 * message, run once:  gcloud auth application-default login
 */

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "clearrent-app"});
const db = admin.firestore();

const email = process.argv[2] || "syd@gmail.com";

async function main() {
  // Find the user by email.
  const usersByEmail = await db
    .collection("users")
    .where("email", "==", email)
    .get();
  if (usersByEmail.empty) {
    console.log(`No user with email ${email}`);
    process.exit(0);
  }
  const uid = usersByEmail.docs[0].id;
  const u = usersByEmail.docs[0].data();
  console.log(`\n=== USER ${email} → ${uid} ===`);
  console.log(
    `hasActiveRental=${u.hasActiveRental}  currentPropertyId=${u.currentPropertyId}  currentRentalId=${u.currentRentalId}`,
  );

  console.log("\n=== active_rentals (tenantId == uid) ===");
  const rentals = await db
    .collection("active_rentals")
    .where("tenantId", "==", uid)
    .get();
  if (rentals.empty) console.log("(none)");
  rentals.forEach((d) => {
    const r = d.data();
    console.log(
      `- ${d.id}\n    status=${r.status}  agreementStatus=${r.agreementStatus}  rentPaymentStatus=${r.rentPaymentStatus}` +
        `\n    property=${r.propertyId} "${r.propertyTitle}"  interest=${r.rentalInterestId}` +
        `\n    endReason=${r.endReason ?? "-"}  createdAt=${r.createdAt && r.createdAt.toDate().toISOString()}`,
    );
  });

  console.log("\n=== rental_interests (tenantId == uid) ===");
  const interests = await db
    .collection("rental_interests")
    .where("tenantId", "==", uid)
    .get();
  if (interests.empty) console.log("(none)");
  interests.forEach((d) => {
    const r = d.data();
    console.log(
      `- ${d.id}  status=${r.status}  property=${r.propertyId}  inspection=${r.inspectionRequestId}  paymentAmount=${r.paymentAmount}`,
    );
  });

  console.log("\n=== inspection_requests (tenantId == uid) ===");
  const insps = await db
    .collection("inspection_requests")
    .where("tenantId", "==", uid)
    .get();
  if (insps.empty) console.log("(none)");
  insps.forEach((d) => {
    const r = d.data();
    console.log(
      `- ${d.id}  status=${r.status}  paymentStatus=${r.paymentStatus}  tenantRated=${r.tenantRated}  property=${r.propertyId}`,
    );
  });

  process.exit(0);
}

main().catch((e) => {
  console.error("Diag error:", e.message || e);
  process.exit(1);
});
