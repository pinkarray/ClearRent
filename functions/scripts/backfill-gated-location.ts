/**
 * One-shot backfill for reveal-on-approval (Phase 2b):
 * move each property's exact street `address` + precise `latitude`/`longitude`
 * from the world-readable parent doc into the gated
 * `properties/{id}/private/location` subdoc, then strip those fields from the
 * parent so a browsing tenant can no longer read them.
 *
 * Optional: in this project all property data is disposable test data, so a
 * fresh listing already writes the subdoc via PropertyService.createProperty.
 * Run this only if you want EXISTING listings to keep working (show the exact
 * address to entitled viewers, and stay bookable) after the new rules deploy.
 *
 * Idempotent — skips a property that has no exact fields left on the parent.
 * Dry-run by default; pass --apply to actually write.
 *
 * Run:
 *   npx ts-node scripts/backfill-gated-location.ts           # dry run
 *   npx ts-node scripts/backfill-gated-location.ts --apply   # writes
 */

import * as admin from "firebase-admin";

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

async function main() {
  const apply = process.argv.includes("--apply");
  console.log(`Mode: ${apply ? "APPLY (writes)" : "DRY RUN"}`);

  const snap = await db.collection("properties").get();
  console.log(`Scanning ${snap.size} property docs...`);

  const toMigrate: {
    id: string;
    address: string;
    latitude: number | null;
    longitude: number | null;
  }[] = [];
  let alreadyClean = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const hasExact =
      "address" in data || "latitude" in data || "longitude" in data;
    if (!hasExact) {
      alreadyClean++;
      continue;
    }
    toMigrate.push({
      id: doc.id,
      address: typeof data.address === "string" ? data.address : "",
      latitude: typeof data.latitude === "number" ? data.latitude : null,
      longitude: typeof data.longitude === "number" ? data.longitude : null,
    });
  }

  console.log(`\nSummary:`);
  console.log(`  Already migrated (no exact fields on parent): ${alreadyClean}`);
  console.log(`  To migrate: ${toMigrate.length}`);

  if (toMigrate.length > 0) {
    console.log(`\nMigrations planned:`);
    toMigrate.forEach((p) =>
      console.log(
        `  ${p.id}: "${p.address}" (${p.latitude ?? "—"}, ${p.longitude ?? "—"})`
      )
    );
  }

  if (!apply) {
    console.log(`\nDry run complete. Re-run with --apply to write.`);
    return;
  }

  if (toMigrate.length === 0) {
    console.log(`\nNothing to migrate.`);
    return;
  }

  console.log(`\nApplying ${toMigrate.length} migrations...`);
  const batch = db.batch();
  for (const p of toMigrate) {
    const propRef = db.collection("properties").doc(p.id);
    batch.set(
      propRef.collection("private").doc("location"),
      {
        address: p.address,
        ...(p.latitude !== null ? { latitude: p.latitude } : {}),
        ...(p.longitude !== null ? { longitude: p.longitude } : {}),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    batch.update(propRef, {
      address: admin.firestore.FieldValue.delete(),
      latitude: admin.firestore.FieldValue.delete(),
      longitude: admin.firestore.FieldValue.delete(),
    });
  }
  await batch.commit();
  console.log(`✅ Done.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
