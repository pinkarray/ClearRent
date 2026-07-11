/**
 * One-shot backfill for collusion analytics (Phase 3):
 * denormalize the handler identity onto every existing inspection_request so
 * admin analytics can group inspections by the tenant↔handler PAIR.
 *   handlerId   = agentId (agent-handled) ?? landlordId (self-handled)
 *   handlerType = "agent" | "landlord"
 *
 * New inspections get this stamped by the onInspectionRequestCreated trigger;
 * this backfills the ones created before that shipped.
 *
 * Idempotent — skips docs whose handlerId already matches. Dry-run by default;
 * pass --apply to write.
 *
 * Run:
 *   npx ts-node scripts/backfill-inspection-handler.ts           # dry run
 *   npx ts-node scripts/backfill-inspection-handler.ts --apply   # writes
 */

import * as admin from "firebase-admin";

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

async function main() {
  const apply = process.argv.includes("--apply");
  console.log(`Mode: ${apply ? "APPLY (writes)" : "DRY RUN"}`);

  const snap = await db.collection("inspection_requests").get();
  console.log(`Scanning ${snap.size} inspection_request docs...`);

  const toFix: { id: string; handlerId: string; handlerType: string }[] = [];
  let alreadyStamped = 0;
  let noHandler = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const agentId =
      typeof data.agentId === "string" && data.agentId.length > 0
        ? data.agentId
        : null;
    const landlordId =
      typeof data.landlordId === "string" && data.landlordId.length > 0
        ? data.landlordId
        : null;
    const handlerId = agentId ?? landlordId;
    if (!handlerId) {
      noHandler++;
      continue;
    }
    const handlerType = agentId ? "agent" : "landlord";
    if (data.handlerId === handlerId && data.handlerType === handlerType) {
      alreadyStamped++;
      continue;
    }
    toFix.push({ id: doc.id, handlerId, handlerType });
  }

  console.log(`\nSummary:`);
  console.log(`  Already stamped: ${alreadyStamped}`);
  console.log(`  No handler (skip): ${noHandler}`);
  console.log(`  To stamp: ${toFix.length}`);

  if (!apply) {
    console.log(`\nDry run complete. Re-run with --apply to write.`);
    return;
  }

  if (toFix.length === 0) {
    console.log(`\nNothing to stamp.`);
    return;
  }

  // Chunk into batches of 400 (Firestore batch limit is 500).
  console.log(`\nApplying ${toFix.length} updates...`);
  for (let i = 0; i < toFix.length; i += 400) {
    const chunk = toFix.slice(i, i + 400);
    const batch = db.batch();
    for (const u of chunk) {
      batch.update(db.collection("inspection_requests").doc(u.id), {
        handlerId: u.handlerId,
        handlerType: u.handlerType,
      });
    }
    await batch.commit();
    console.log(`  Committed ${Math.min(i + 400, toFix.length)}/${toFix.length}`);
  }
  console.log(`✅ Done.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
