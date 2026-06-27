/**
 * One-shot backfill: convert any users.phone stored in local format
 * (e.g. "08053385667") to E.164 (e.g. "+2348053385667").
 *
 * Idempotent — skips docs already in E.164. Logs every change.
 * Dry-run by default; pass --apply to actually write.
 *
 * Run:
 *   npx ts-node scripts/backfill-phone-e164.ts           # dry run
 *   npx ts-node scripts/backfill-phone-e164.ts --apply   # writes
 */

import * as admin from "firebase-admin";

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

function normalizeToE164(raw: string): string | null {
  const digits = raw.replace(/[\s\-()+]/g, "");
  if (!/^\d+$/.test(digits)) return null;
  let subscriber: string;
  if (digits.length === 11 && digits.startsWith("0")) {
    subscriber = digits.slice(1);
  } else if (digits.length === 13 && digits.startsWith("234")) {
    subscriber = digits.slice(3);
  } else if (digits.length === 10) {
    subscriber = digits;
  } else {
    return null;
  }
  if (!/^[789]\d{9}$/.test(subscriber)) return null;
  return "+234" + subscriber;
}

async function main() {
  const apply = process.argv.includes("--apply");
  console.log(`Mode: ${apply ? "APPLY (writes)" : "DRY RUN"}`);

  const snap = await db.collection("users").get();
  console.log(`Scanning ${snap.size} user docs...`);

  let already = 0;
  let toFix: { uid: string; from: string; to: string }[] = [];
  let invalid: { uid: string; value: string }[] = [];
  let missing = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const phone = data.phone;
    if (typeof phone !== "string" || phone.length === 0) {
      missing++;
      continue;
    }
    if (phone.startsWith("+234") && phone.length === 14) {
      already++;
      continue;
    }
    const normalized = normalizeToE164(phone);
    if (normalized === null) {
      invalid.push({ uid: doc.id, value: phone });
      continue;
    }
    toFix.push({ uid: doc.id, from: phone, to: normalized });
  }

  console.log(`\nSummary:`);
  console.log(`  Already E.164: ${already}`);
  console.log(`  No phone field: ${missing}`);
  console.log(`  Invalid (will skip): ${invalid.length}`);
  console.log(`  To update: ${toFix.length}`);

  if (invalid.length > 0) {
    console.log(`\nInvalid phones (review manually):`);
    invalid.forEach((i) => console.log(`  ${i.uid}: "${i.value}"`));
  }

  if (toFix.length > 0) {
    console.log(`\nUpdates planned:`);
    toFix.forEach((u) =>
      console.log(`  ${u.uid}: "${u.from}" → "${u.to}"`)
    );
  }

  if (!apply) {
    console.log(`\nDry run complete. Re-run with --apply to write.`);
    return;
  }

  if (toFix.length === 0) {
    console.log(`\nNothing to update.`);
    return;
  }

  console.log(`\nApplying ${toFix.length} updates...`);
  const batch = db.batch();
  for (const u of toFix) {
    batch.update(db.collection("users").doc(u.uid), { phone: u.to });
  }
  await batch.commit();
  console.log(`✅ Done.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});