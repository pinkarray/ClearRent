/* eslint-disable */
/**
 * One-off: set `structure` on buildings created before the field existed.
 *
 * A building's structure is what the WHOLE thing is (duplex, compound, storey
 * building) — the axis `propertyType` used to swallow. Units listed under a
 * building read it to say "a room in a duplex" without claiming to BE the
 * duplex. Buildings written before this field carry none, so the app and admin
 * simply omit the line; this fills them in.
 *
 * Dry run (default) prints what it would write and changes nothing:
 *   node scripts/backfill_building_structure.js
 * Apply:
 *   node scripts/backfill_building_structure.js --apply
 *
 * Auth: Application Default Credentials.
 *   gcloud auth application-default login
 */

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "clearrent-app"});
const db = admin.firestore();

const APPLY = process.argv.includes("--apply");

// Values from BuildingModel.structures. Only these are written.
const VALID = new Set([
  "duplex", "bungalow", "storeyBuilding", "blockOfFlats",
  "compound", "faceMeIFaceYou", "detachedHouse", "other",
]);

/**
 * Best guess from the building's own name — the two live buildings are called
 * "<Name>'s Compound". Anything we can't read confidently is LEFT ALONE rather
 * than guessed: a wrong structure is worse than an absent one, since the app
 * omits the line when it's empty.
 */
function guessStructure(name) {
  const n = (name || "").toLowerCase();
  if (n.includes("compound")) return "compound";
  if (n.includes("duplex")) return "duplex";
  if (n.includes("bungalow")) return "bungalow";
  if (n.includes("block")) return "blockOfFlats";
  if (n.includes("face me")) return "faceMeIFaceYou";
  return null;
}

async function main() {
  const snap = await db.collection("buildings").get();
  console.log(`${snap.size} buildings\n`);

  let written = 0;
  let skipped = 0;
  for (const d of snap.docs) {
    const b = d.data();
    if (b.structure && VALID.has(b.structure)) {
      console.log(`SKIP  ${d.id}  already ${b.structure}`);
      skipped++;
      continue;
    }
    const guess = guessStructure(b.name);
    if (!guess) {
      console.log(`SKIP  ${d.id}  cannot read a structure from ${JSON.stringify(b.name)}`);
      skipped++;
      continue;
    }
    console.log(`${APPLY ? "WRITE" : "would write"}  ${d.id}  ${JSON.stringify(b.name)} -> ${guess}`);
    if (APPLY) {
      await d.ref.update({
        structure: guess,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    written++;
  }

  console.log(
    `\n${APPLY ? "wrote" : "would write"} ${written}, skipped ${skipped}` +
    (APPLY ? "" : "\nRe-run with --apply to write.")
  );
}

main().then(() => process.exit(0)).catch((e) => {
  console.error(e.message);
  process.exit(1);
});
