/* eslint-disable */
/**
 * Seed config/pricing with the current fee schedule.
 *
 * The server already falls back to DEFAULT_PRICING when this document is
 * absent, so seeding changes no behaviour — it exists so prices become
 * editable from the console/admin WITHOUT a Play Store release.
 *
 * Dry run by default; pass --write to actually write. Uses merge, so keys not
 * listed here are left alone.
 *
 *   node scripts/seed_pricing_config.js              (print what it would do)
 *   node scripts/seed_pricing_config.js --write      (write it)
 *   PROJECT_ID=clearrent-app node scripts/seed_pricing_config.js --write
 */

const admin = require("firebase-admin");

const PROJECT_ID = process.env.PROJECT_ID || "clearrent-app";
const WRITE = process.argv.includes("--write");

// Must mirror DEFAULT_PRICING in functions/src/pricing.ts and the client
// constants (VerificationFees, InspectionPricing).
const PRICING = {
  verification: { tenant: 3000, landlord: 12000, agent: 7000 },
  listing: 10000,
  inspection: { total: 10000, handler: 7000, platform: 3000 },
};

async function main() {
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    projectId: PROJECT_ID,
  });
  const db = admin.firestore();
  const ref = db.collection("config").doc("pricing");

  const existing = await ref.get();
  console.log(`project: ${PROJECT_ID}`);
  console.log(`config/pricing exists: ${existing.exists}`);
  if (existing.exists) {
    console.log("current:", JSON.stringify(existing.data(), null, 2));
  }
  console.log("would write:", JSON.stringify(PRICING, null, 2));

  if (!WRITE) {
    console.log("\nDRY RUN — nothing written. Re-run with --write to apply.");
    return;
  }

  await ref.set(
    {
      ...PRICING,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedBy: "seed_pricing_config.js",
    },
    { merge: true }
  );
  console.log("\nWritten to config/pricing.");
}

main().catch((e) => {
  console.error("Failed:", e.message);
  process.exit(1);
});
