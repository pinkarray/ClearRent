/* eslint-disable */
/**
 * Repair payout splits written by the OLD client-side calculation.
 *
 * Before createRentalInterest moved the maths server-side, the deal fee was
 * subtracted from each party without a floor, so a rent below the fee produced
 * a NEGATIVE payout (and `clearrentEarnings` booked the shortfall as revenue).
 * rental_interest_ops.ts now clamps both sides:
 *
 *   landlordDealFee = min(dealFee, rentAmount)
 *   agentDealFee    = hasAgent ? min(dealFee, agentFee) : 0
 *   landlordPayout  = rentAmount - landlordDealFee      // >= 0
 *   agentPayout     = hasAgent ? agentFee - agentDealFee : 0
 *   clearrentEarnings = totalPaid - landlordPayout - agentPayout
 *
 * This applies the same formula to the docs already in the database.
 *
 * It also RETIRES zero payouts. markRentLandlordPayoutPaid reads the amount
 * with readAmount(), which throws unless it is > 0 — so a payout of 0 (or a
 * negative one) can never be marked paid and sits in the admin queue forever.
 * Where the correct payout is 0 there is genuinely nothing to send, so the
 * status becomes `not_applicable` and it leaves the queue.
 *
 * Statuses are only ever touched while they are still `pending`. Anything
 * already `paid` is left exactly as it is — this must not rewrite the record
 * of money that actually moved.
 *
 * DRY RUN by default — prints what it WOULD do and writes nothing.
 * Pass --confirm to perform the writes.
 *
 *   node scripts/backfill_payout_splits.js            # dry run
 *   node scripts/backfill_payout_splits.js --confirm  # execute
 */

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "clearrent-app"});
const db = admin.firestore();

const CONFIRM = process.argv.includes("--confirm");

const num = (v) => (typeof v === "number" && isFinite(v) ? v : 0);

/** The live formula, applied to a doc's existing figures. */
function correctSplit(d) {
  const dealFee = num(d.__dealFee);
  const rentAmount = num(d.rentAmount);
  const agentFee = num(d.agentFee);
  const hasAgent = typeof d.agentId === "string" && d.agentId.length > 0;
  // totalPaid on active_rentals, paymentAmount on rental_interests.
  const paid = num(d.totalPaid) || num(d.paymentAmount);

  const landlordPayout = rentAmount - Math.min(dealFee, rentAmount);
  const agentPayout = hasAgent ? agentFee - Math.min(dealFee, agentFee) : 0;
  const clearrentEarnings = paid - landlordPayout - agentPayout;
  return {landlordPayout, agentPayout, clearrentEarnings, hasAgent};
}

async function main() {
  const pricingSnap = await db.collection("config").doc("pricing").get();
  const dealFee = num(pricingSnap.data() && pricingSnap.data().dealFee) || 5000;
  console.log(`dealFee = ${dealFee}${CONFIRM ? "" : "   (DRY RUN)"}\n`);

  let touched = 0;

  for (const col of ["active_rentals", "rental_interests"]) {
    const snap = await db.collection(col).get();
    console.log(`=== ${col} (${snap.size}) ===`);

    for (const doc of snap.docs) {
      const d = doc.data();
      d.__dealFee = dealFee;
      const want = correctSplit(d);
      const patch = {};

      if (num(d.landlordPayout) !== want.landlordPayout) {
        patch.landlordPayout = want.landlordPayout;
      }
      if (num(d.agentPayout) !== want.agentPayout) {
        patch.agentPayout = want.agentPayout;
      }
      if (num(d.clearrentEarnings) !== want.clearrentEarnings) {
        patch.clearrentEarnings = want.clearrentEarnings;
      }

      // Retire what can never be sent. Only from `pending` — never rewrite a
      // status that says money already moved.
      if (col === "active_rentals") {
        if (d.landlordPayoutStatus === "pending" && want.landlordPayout <= 0) {
          patch.landlordPayoutStatus = "not_applicable";
        }
        if (d.agentPayoutStatus === "pending" && want.agentPayout <= 0) {
          patch.agentPayoutStatus = "not_applicable";
        }
      }

      if (Object.keys(patch).length === 0) continue;
      touched++;

      console.log(`  ${doc.id} (${d.propertyTitle || "?"})`);
      console.log(`    rent=${num(d.rentAmount)} agentFee=${num(d.agentFee)} ` +
        `agent=${want.hasAgent ? "yes" : "no"}`);
      for (const [k, v] of Object.entries(patch)) {
        console.log(`    ${k}: ${JSON.stringify(d[k])} -> ${JSON.stringify(v)}`);
      }

      if (CONFIRM) {
        patch.payoutSplitRepairedAt =
          admin.firestore.FieldValue.serverTimestamp();
        await doc.ref.update(patch);
      }
    }
  }

  console.log(`\n${CONFIRM ? "Updated" : "Would update"} ${touched} doc(s).`);
  if (!CONFIRM) console.log("Re-run with --confirm to apply.");
  process.exit(0);
}

main().catch((e) => {
  console.error("FAILED:", e);
  process.exit(1);
});
