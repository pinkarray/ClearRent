/**
 * ClearRent — Clean stale data for super admin
 * 
 * Removes active_rentals and activities that reference 
 * tenants/users who no longer exist in Firestore.
 * 
 * Run the same way as cleanup_firestore.js:
 *   node cleanup_stale_data.js
 */

const admin = require('firebase-admin');

// Only init if not already initialized (in case you run both scripts)
if (!admin.apps.length) {
  const serviceAccount = require('./serviceAccountKey.json');
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
}

const db = admin.firestore();

async function userExists(uid) {
  if (!uid) return false;
  const doc = await db.collection('users').doc(uid).get();
  return doc.exists;
}

async function cleanStaleActiveRentals() {
  console.log('\n🔵 Cleaning stale active_rentals...');
  const snapshot = await db.collection('active_rentals').get();
  let deleted = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const tenantId = data.tenantId;
    const landlordId = data.landlordId;

    // Check if either party no longer exists
    const tenantOk = tenantId ? await userExists(tenantId) : true;
    const landlordOk = landlordId ? await userExists(landlordId) : true;

    if (!tenantOk || !landlordOk) {
      console.log(`   🗑️  Deleting rental ${doc.id} (tenant exists: ${tenantOk}, landlord exists: ${landlordOk})`);
      await doc.ref.delete();
      deleted++;
    }
  }

  console.log(`   ✅ Deleted ${deleted} stale active_rentals`);
  return deleted;
}

async function cleanStaleActivities() {
  console.log('\n🔵 Cleaning stale activities...');
  const snapshot = await db.collection('activities').get();
  let deleted = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const actorId = data.actorId;

    // If activity references an actor (viewer/tenant) that no longer exists, delete it
    if (actorId) {
      const actorOk = await userExists(actorId);
      if (!actorOk) {
        console.log(`   🗑️  Deleting activity "${data.title}" — actor ${actorId} gone`);
        await doc.ref.delete();
        deleted++;
      }
    }
  }

  console.log(`   ✅ Deleted ${deleted} stale activities`);
  return deleted;
}

async function cleanStaleInspections() {
  console.log('\n🔵 Cleaning stale inspection_requests...');
  const snapshot = await db.collection('inspection_requests').get();
  let deleted = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const tenantOk = data.tenantId ? await userExists(data.tenantId) : true;
    const landlordOk = data.landlordId ? await userExists(data.landlordId) : true;

    if (!tenantOk || !landlordOk) {
      console.log(`   🗑️  Deleting inspection ${doc.id} (tenant: ${tenantOk}, landlord: ${landlordOk})`);
      await doc.ref.delete();
      deleted++;
    }
  }

  console.log(`   ✅ Deleted ${deleted} stale inspection_requests`);
  return deleted;
}

async function cleanStaleConversations() {
  console.log('\n🔵 Cleaning stale conversations...');
  const snapshot = await db.collection('conversations').get();
  let deleted = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const participants = data.participants || [];

    let hasGhost = false;
    for (const uid of participants) {
      if (!(await userExists(uid))) {
        hasGhost = true;
        break;
      }
    }

    if (hasGhost) {
      // Delete messages subcollection first
      const msgs = await doc.ref.collection('messages').get();
      for (const msg of msgs.docs) {
        await msg.ref.delete();
      }
      await doc.ref.delete();
      deleted++;
    }
  }

  console.log(`   ✅ Deleted ${deleted} stale conversations`);
  return deleted;
}

async function cleanStaleTenancyLinks() {
  console.log('\n🔵 Cleaning stale tenancy_links...');
  const snapshot = await db.collection('tenancy_links').get();
  let deleted = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const tenantOk = data.tenantId ? await userExists(data.tenantId) : true;

    if (!tenantOk) {
      await doc.ref.delete();
      deleted++;
    }
  }

  console.log(`   ✅ Deleted ${deleted} stale tenancy_links`);
  return deleted;
}

async function main() {
  console.log('═══════════════════════════════════════');
  console.log('  ClearRent — Stale Data Cleanup');
  console.log('═══════════════════════════════════════');

  await cleanStaleActiveRentals();
  await cleanStaleActivities();
  await cleanStaleInspections();
  await cleanStaleConversations();
  await cleanStaleTenancyLinks();

  console.log('\n═══════════════════════════════════════');
  console.log('  DONE — All ghost references removed');
  console.log('═══════════════════════════════════════\n');

  process.exit(0);
}

main().catch((err) => {
  console.error('❌ Failed:', err);
  process.exit(1);
});