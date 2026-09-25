// Backfill `transactions` earnings rows for the Earnings screens.
//
// 1. Rent rows were born "completed" at payment. Set each to what its rental
//    says: completed only if that side's payout was actually sent.
// 2. Viewing fees never had rows. Create txn_insp_<id> for every credited
//    inspection, pending or completed by agentPayoutStatus.
//
// Usage: node scripts/backfill_earnings_rows.js          (dry run)
//        node scripts/backfill_earnings_rows.js --apply
const admin = require('firebase-admin')
admin.initializeApp({ projectId: 'clearrent-app' })
const db = admin.firestore()
const apply = process.argv.includes('--apply')

;(async () => {
  let rentChanged = 0
  const rent = await db.collection('transactions').where('type', '==', 'rent').get()
  for (const t of rent.docs) {
    const x = t.data()
    const rentals = await db.collection('active_rentals')
      .where('rentPaymentReference', '==', x.reference).limit(1).get()
    if (rentals.empty) { console.log('no rental for', t.id); continue }
    const r = rentals.docs[0].data()
    const payout = x.role === 'agent' ? r.agentPayoutStatus : r.landlordPayoutStatus
    const want = payout === 'paid' ? 'completed' : 'pending'
    if (x.status !== want) {
      console.log('rent', t.id, x.status, '->', want)
      rentChanged++
      if (apply) await t.ref.update({ status: want })
    }
  }

  let created = 0
  const insp = await db.collection('inspection_requests').where('earningsCredited', '==', true).get()
  for (const d of insp.docs) {
    const x = d.data()
    if (!(x.earningsAmount > 0)) continue
    const ref = db.collection('transactions').doc(`txn_insp_${d.id}`)
    if ((await ref.get()).exists) continue
    const isAgent = typeof x.agentId === 'string' && x.agentId.length > 0
    const handlerId = isAgent ? x.agentId : x.landlordId
    if (!handlerId) continue
    const row = {
      reference: d.id,
      type: 'inspection',
      role: isAgent ? 'agent' : 'landlord',
      [isAgent ? 'agentId' : 'landlordId']: handlerId,
      amount: x.earningsAmount,
      status: x.agentPayoutStatus === 'paid' ? 'completed' : 'pending',
      propertyId: x.propertyId ?? '',
      propertyTitle: x.propertyTitle ?? 'your property',
      tenantName: x.tenantName ?? '',
      createdAt: x.earningsCreditedAt ?? x.completedAt ?? admin.firestore.FieldValue.serverTimestamp(),
    }
    console.log('insp', d.id, row.role, row.amount, row.status, row.propertyTitle)
    created++
    if (apply) await ref.set(row)
  }
  console.log(apply ? 'APPLIED' : 'DRY RUN', { rentChanged, created })
  process.exit(0)
})().catch((e) => { console.error(e); process.exit(1) })
