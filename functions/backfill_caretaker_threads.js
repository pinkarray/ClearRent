/*
 * One-off backfill: open caretaker threads for units that were already
 * occupied before the occupancy triggers learned to open them.
 * Idempotent — the conversation id is deterministic and the write merges.
 */
const admin = require('firebase-admin');
admin.initializeApp({credential: admin.credential.cert(require('./serviceAccountKey.json'))});
const db = admin.firestore();
const OCCUPYING = ['active','expiring_soon','grace_locked','pending_payment','moveout_pending'];

(async () => {
  const props = await db.collection('properties').where('caretakerId','!=',null).get();
  for (const p of props.docs) {
    const caretakerId = p.get('caretakerId');
    if (!caretakerId) continue;
    const rentals = await db.collection('active_rentals').where('propertyId','==',p.id).get();
    const live = rentals.docs.find(d => OCCUPYING.includes(d.get('status')));
    if (!live) { console.log('skip (no live rental):', p.id); continue; }
    const id = `caretaker_${p.id}_${caretakerId}`;
    const existing = await db.doc('conversations/'+id).get();
    if (existing.exists) { console.log('already exists:', id); continue; }
    console.log('WOULD CREATE:', id, '| property=', p.get('title'), '| tenant=', live.get('tenantId'), '| landlord=', live.get('landlordId'));
  }
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
