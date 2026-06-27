/**
 * Backfill: fold `requestedTimeSlot` start hour into
 * `requestedDate` for inspection_requests where requestedDate is
 * midnight (the legacy date-only encoding).
 *
 * Why: the model gates (isWithinOnWayWindow, isWithinRescheduleWindow)
 * compute cutoff = requestedDate - 2h. With midnight requestedDate
 * and a 3pm slot, cutoff lands at the previous evening, so
 * "I'm on my way" shows from midnight onwards. Forward-fix is in
 * inspection_service.dart composeScheduledDateTime. This script
 * heals existing docs.
 *
 * Idempotent. Safe to re-run. Skips docs that already have a
 * non-midnight hour on requestedDate.
 *
 * Run dry: ts-node functions/scripts/backfill-requested-date-slot-hour.ts
 * Apply:   ts-node functions/scripts/backfill-requested-date-slot-hour.ts --apply
 */

import {initializeApp, applicationDefault} from "firebase-admin/app";
import {getFirestore, Timestamp} from "firebase-admin/firestore";

const SLOT_HOUR: Record<string, number> = {
  morning: 9,
  afternoon: 12,
  late_afternoon: 15,
  evening: 18,
};

const apply = process.argv.includes("--apply");

initializeApp({credential: applicationDefault()});
const db = getFirestore();

async function main() {
  console.log(apply ? "🔧 APPLY mode" : "🧪 DRY RUN");

  const snap = await db.collection("inspection_requests").get();
  console.log(`Scanned ${snap.size} inspection_requests docs`);

  let toUpdate = 0;
  let skippedAlreadyFolded = 0;
  let skippedUnknownSlot = 0;
  let skippedNoDate = 0;
  let skippedNoSlot = 0;

  const batchSize = 400;
  let batch = db.batch();
  let inBatch = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const ts = data.requestedDate as Timestamp | undefined;
    const slot = data.requestedTimeSlot as string | undefined;

    if (!ts) {
      skippedNoDate++;
      continue;
    }
    if (!slot) {
      skippedNoSlot++;
      continue;
    }

    const hour = SLOT_HOUR[slot];
    if (hour === undefined) {
      skippedUnknownSlot++;
      continue;
    }

    const current = ts.toDate();
    // Already folded (hour matches the slot's start). Be lenient:
    // any non-midnight hour means someone (or an earlier run)
    // already migrated this doc — leave it alone.
    if (current.getHours() !== 0 || current.getMinutes() !== 0) {
      skippedAlreadyFolded++;
      continue;
    }

    const fixed = new Date(
      current.getFullYear(),
      current.getMonth(),
      current.getDate(),
      hour,
      0,
      0,
      0,
    );

    console.log(
      `  ${doc.id}: ${current.toISOString()} → ${fixed.toISOString()} ` +
        `(slot=${slot})`,
    );
    toUpdate++;

    if (apply) {
      batch.update(doc.ref, {requestedDate: Timestamp.fromDate(fixed)});
      inBatch++;
      if (inBatch >= batchSize) {
        await batch.commit();
        batch = db.batch();
        inBatch = 0;
      }
    }
  }

  if (apply && inBatch > 0) {
    await batch.commit();
  }

  console.log("");
  console.log("Summary:");
  console.log(`  Would update / updated: ${toUpdate}`);
  console.log(`  Skipped (already folded): ${skippedAlreadyFolded}`);
  console.log(`  Skipped (unknown slot): ${skippedUnknownSlot}`);
  console.log(`  Skipped (no requestedDate): ${skippedNoDate}`);
  console.log(`  Skipped (no requestedTimeSlot): ${skippedNoSlot}`);

  if (!apply) {
    console.log("");
    console.log("Re-run with --apply to commit changes.");
  }
}

main().catch((e) => {
  console.error("❌ Backfill failed:", e);
  process.exit(1);
});