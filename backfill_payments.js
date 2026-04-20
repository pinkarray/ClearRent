/**
 * backfill_payments.js
 * 
 * Pulls all successful transactions from Paystack and writes them
 * to the Firestore `payments` collection using the same schema
 * that PaystackService.recordPayment() uses.
 *
 * Usage:
 *   node backfill_payments.js [--dry-run]
 *
 * Flags:
 *   --dry-run   Print what would be written without actually writing to Firestore
 *
 * Requirements:
 *   npm install firebase-admin node-fetch@2
 *   (node-fetch v2 for CommonJS require() support)
 *
 * Place your Firebase service account JSON at:
 *   ./serviceAccountKey.json  (or update the path below)
 */

const admin = require('firebase-admin');
const fetch = require('node-fetch');

// ── Config ───────────────────────────────────────────────────────────
const PAYSTACK_SECRET_KEY = 'sk_test_dba926781692c2cd5e56e84244262448d6d46d2d';
const FIREBASE_PROJECT_ID = 'clearrent-app';
const SERVICE_ACCOUNT_PATH = './serviceAccountKey.json';

const DRY_RUN = process.argv.includes('--dry-run');

// ── Firebase init ────────────────────────────────────────────────────
const serviceAccount = require(SERVICE_ACCOUNT_PATH);
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: FIREBASE_PROJECT_ID,
});
const db = admin.firestore();

// ── Paystack API ─────────────────────────────────────────────────────

/**
 * Fetch all transactions from Paystack (paginated).
 * Only returns transactions with status === 'success'.
 */
async function fetchAllTransactions() {
  const allTransactions = [];
  let page = 1;
  const perPage = 100;
  let hasMore = true;

  while (hasMore) {
    const url = `https://api.paystack.co/transaction?perPage=${perPage}&page=${page}&status=success`;
    
    const response = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${PAYSTACK_SECRET_KEY}`,
        'Content-Type': 'application/json',
      },
    });

    const data = await response.json();

    if (!data.status || !data.data) {
      console.error('❌ Paystack API error:', data.message || 'Unknown error');
      break;
    }

    const transactions = data.data;
    allTransactions.push(...transactions);

    console.log(`  Page ${page}: fetched ${transactions.length} transactions`);

    // Check if there are more pages
    const meta = data.meta;
    if (meta && meta.pageCount && page < meta.pageCount) {
      page++;
    } else {
      hasMore = false;
    }
  }

  return allTransactions;
}

/**
 * Map a Paystack transaction to the Firestore payment document schema
 * (matches PaystackService.recordPayment format).
 */
function mapToPaymentDoc(tx) {
  const reference = tx.reference || '';
  const amountNaira = (tx.amount || 0) / 100; // Paystack stores in kobo
  const email = tx.customer?.email || '';
  const paidAt = tx.paid_at ? new Date(tx.paid_at) : new Date(tx.created_at);
  
  // Extract metadata
  const metadata = tx.metadata || {};
  const userId = metadata.userId || metadata.user_id || null;
  const paymentType = metadata.paymentType || _inferTypeFromReference(reference);
  const propertyId = metadata.propertyId || null;
  const rentalInterestId = metadata.rentalInterestId || null;
  const description = metadata.description || null;

  const doc = {
    reference: reference,
    userId: userId,
    userEmail: email,
    type: paymentType,
    amount: amountNaira,
    status: 'completed',
    createdAt: admin.firestore.Timestamp.fromDate(paidAt),
  };

  // Add optional fields if present
  if (propertyId) doc.propertyId = propertyId;
  if (rentalInterestId) doc.rentalInterestId = rentalInterestId;
  if (description) doc.description = description;

  return doc;
}

/**
 * Infer payment type from the reference string prefix
 * (e.g. CR_INSPECTION_..., CR_LISTING_..., CR_VERIFICATION_..., CR_RENT_...)
 */
function _inferTypeFromReference(reference) {
  const ref = (reference || '').toUpperCase();
  if (ref.includes('INSPECTION')) return 'inspection';
  if (ref.includes('LISTING')) return 'listing';
  if (ref.includes('VERIFICATION')) return 'verification';
  if (ref.includes('RENT')) return 'rent';
  return 'unknown';
}

// ── Main ─────────────────────────────────────────────────────────────
async function main() {
  console.log('🔄 Backfilling Firestore payments from Paystack...');
  if (DRY_RUN) console.log('   (DRY RUN — no writes will be made)\n');

  // 1. Fetch all successful transactions from Paystack
  console.log('📡 Fetching transactions from Paystack...');
  const transactions = await fetchAllTransactions();
  console.log(`\n✅ Found ${transactions.length} successful transactions\n`);

  if (transactions.length === 0) {
    console.log('Nothing to backfill.');
    process.exit(0);
  }

  // 2. Check which already exist in Firestore (by reference = doc ID)
  let skipped = 0;
  let written = 0;
  let errors = 0;

  for (const tx of transactions) {
    const reference = tx.reference || '';
    if (!reference) {
      console.log('  ⚠️  Skipping transaction with no reference');
      skipped++;
      continue;
    }

    // Check if already exists
    const existingDoc = await db.collection('payments').doc(reference).get();
    if (existingDoc.exists) {
      console.log(`  ⏭️  Already exists: ${reference}`);
      skipped++;
      continue;
    }

    const paymentDoc = mapToPaymentDoc(tx);

    if (DRY_RUN) {
      console.log(`  📝 Would write: ${reference}`);
      console.log(`     Type: ${paymentDoc.type} | Amount: ₦${paymentDoc.amount} | User: ${paymentDoc.userId || 'unknown'}`);
      written++;
      continue;
    }

    // 3. Write to Firestore
    try {
      await db.collection('payments').doc(reference).set(paymentDoc);
      console.log(`  ✅ Written: ${reference} (${paymentDoc.type}, ₦${paymentDoc.amount})`);
      written++;
    } catch (err) {
      console.error(`  ❌ Error writing ${reference}:`, err.message);
      errors++;
    }
  }

  // 4. Summary
  console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`📊 Summary:`);
  console.log(`   ${DRY_RUN ? 'Would write' : 'Written'}: ${written}`);
  console.log(`   Skipped (already exist): ${skipped}`);
  if (errors > 0) console.log(`   Errors: ${errors}`);
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  process.exit(0);
}

main().catch((err) => {
  console.error('❌ Fatal error:', err);
  process.exit(1);
});