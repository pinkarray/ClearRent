/* eslint-disable */
/**
 * One-off: set `unitBuildingStructure` on grouped units written before the
 * field existed.
 *
 * A tenant browsing the LIST needs to know a room is in a face-me-I-face-you
 * rather than a block of flats — different products at the same room count.
 * The card reads this field so it doesn't have to load the building doc per
 * card, so units written earlier show nothing until this runs.
 *
 * Copies the unit's building's `structure`. Compounds are SKIPPED: a compound
 * is land that can carry a duplex and a bungalow, so which building a given
 * unit sits in is not derivable — the landlord has to say, on the unit.
 *
 * Dry run (default) prints what it would write and changes nothing:
 *   node scripts/backfill_unit_building.js
 * Apply:
 *   node scripts/backfill_unit_building.js --apply
 *
 * Auth: Application Default Credentials.
 *   gcloud auth application-default login
 */

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "clearrent-app"});
const db = admin.firestore();

const APPLY = process.argv.includes("--apply");

async function main() {
  const props = await db.collection("properties").get();
  const buildings = new Map();
  for (const b of (await db.collection("buildings").get()).docs) {
    buildings.set(b.id, b.data());
  }
  console.log(`${props.size} properties, ${buildings.size} buildings\n`);

  let writes = 0;
  let skipped = 0;
  for (const doc of props.docs) {
    const d = doc.data();
    const buildingId = d.buildingId;
    if (!buildingId) { skipped++; continue; }
    if (d.unitBuildingStructure) {
      console.log(`SKIP  ${doc.id}  already ${d.unitBuildingStructure}`);
      skipped++;
      continue;
    }
    const structure = buildings.get(buildingId)?.structure;
    if (!structure) {
      console.log(`SKIP  ${doc.id}  building has no structure`);
      skipped++;
      continue;
    }
    // A compound is not a building. Which of its buildings this unit sits in
    // cannot be inferred from the site, so leave it for the landlord to state.
    if (structure === "compound") {
      console.log(`SKIP  ${doc.id}  site is a compound - landlord must say`);
      skipped++;
      continue;
    }
    console.log(`WRITE ${doc.id}  <- ${structure}`);
    if (APPLY) {
      await doc.ref.update({unitBuildingStructure: structure});
    }
    writes++;
  }
  console.log(`\nwould write ${writes}, skipped ${skipped}`);
  if (!APPLY) console.log("Re-run with --apply to write.");
}

main().then(() => process.exit(0)).catch((e) => {
  console.error(e);
  process.exit(1);
});
