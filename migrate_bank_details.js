/**
 * migrate_bank_details.js
 *
 * C1 security migration. Moves sensitive bank details OFF the
 * `users/{uid}` doc (which is readable by any authenticated user) and INTO
 * the locked `users/{uid}/private/bank` subcollection (owner + admin only).
 *
 * For each user that has a `bankDetails` map on their doc:
 *   1. Copy it to `users/{uid}/private/bank`.
 *   2. Set the non-sensitive flag `hasBankDetails: true` on the user doc
 *      (the home-screen nudges read this).
 *   3. Delete the `bankDetails` field from the user doc.
 *
 * Idempotent: re-running skips users whose `bankDetails` field is already
 * gone. Safe to run AFTER the new app/admin are deployed (they read the
 * subcollection first, with a legacy fallback).
 *
 * Usage:
 *   node migrate_bank_details.js [--dry-run]
 *
 * Requirements:
 *   npm install firebase-admin
 *   Place the Firebase service account JSON at ./serviceAccountKey.json
 *   (gitignored — never commit it).
 */

const admin = require('firebase-admin');

const FIREBASE_PROJECT_ID = 'clearrent-app';
const SERVICE_ACCOUNT_PATH = './serviceAccountKey.json';
const DRY_RUN = process.argv.includes('--dry-run');

const serviceAccount = require(SERVICE_ACCOUNT_PATH);
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: FIREBASE_PROJECT_ID,
});
const db = admin.firestore();

async function main() {
  console.log(`\n🔐 Bank-details migration${DRY_RUN ? ' (DRY RUN)' : ''}\n`);

  const snap = await db.collection('users').get();
  let migrated = 0;
  let skipped = 0;

  for (const userDoc of snap.docs) {
    const data = userDoc.data();
    const bank = data.bankDetails;

    // Skip users with no bankDetails field (nothing to move / already done).
    if (!bank || typeof bank !== 'object') {
      skipped++;
      continue;
    }

    const uid = userDoc.id;
    console.log(
      `→ ${uid}: ${bank.bankName || '?'} · ${bank.accountNumber || '?'}`
    );

    if (DRY_RUN) {
      migrated++;
      continue;
    }

    // 1. Copy to the locked subcollection (merge — preserve any existing).
    await db
      .collection('users').doc(uid)
      .collection('private').doc('bank')
      .set(
        { ...bank, migratedAt: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true }
      );

    // 2 + 3. Flag the user doc and remove the sensitive field.
    await db.collection('users').doc(uid).update({
      hasBankDetails: true,
      bankDetails: admin.firestore.FieldValue.delete(),
    });

    migrated++;
  }

  console.log(
    `\n✅ Done. ${migrated} ${DRY_RUN ? 'would be migrated' : 'migrated'}, ` +
    `${skipped} skipped (no bankDetails).\n`
  );
  process.exit(0);
}

main().catch((err) => {
  console.error('❌ Migration failed:', err);
  process.exit(1);
});
