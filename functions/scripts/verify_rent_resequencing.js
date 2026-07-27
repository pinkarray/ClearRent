/* eslint-disable */
/**
 * Pay-after-accept rent charge-gate verification.
 *
 * Proves resolveServerAmount("rent", ...) — the pre-charge authority used by
 * initializePayment — only ever authorises a rent charge for the ACCEPTED
 * tenant, and only once the tenancy agreement is FINALIZED and the rent is
 * still unpaid. This is the exact boundary behind the statement to Paystack
 * ("only the accepted tenant ever pays"): a charge on any other state must
 * hard-fail (THROW), never fall back to a client-supplied amount.
 *
 * Only the firestore emulator is needed (no Auth — rent uses no custom claims).
 *   npm run build
 *   firebase emulators:start --only firestore --project demo-clearrent
 *   node scripts/verify_rent_resequencing.js
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "demo-clearrent";

const admin = require("firebase-admin");
admin.initializeApp({projectId: process.env.GCLOUD_PROJECT});

const {getFirestore} = require("firebase-admin/firestore");
const {resolveServerAmount} = require("../lib/pricing");

let failures = 0;
function check(name, cond, detail) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}` + (cond ? "" : `  ← ${detail}`));
  if (!cond) failures++;
}

const db = getFirestore();

const TENANT = "t_accepted";
const OTHER = "t_other";
const INTEREST = "ri_verify";
const RENTAL = "ar_verify";
const AMOUNT = 1250000;

async function wipe() {
  await db.collection("rental_interests").doc(INTEREST).delete();
  await db.collection("active_rentals").doc(RENTAL).delete();
}

/** Seed the interest at a given status, and optionally its active_rental. */
async function seed({interestStatus, rental}) {
  await db.collection("rental_interests").doc(INTEREST).set({
    tenantId: TENANT,
    status: interestStatus,
    paymentAmount: AMOUNT,
  });
  await db.collection("active_rentals").doc(RENTAL).delete();
  if (rental) {
    await db.collection("active_rentals").doc(RENTAL).set({
      rentalInterestId: INTEREST,
      tenantId: TENANT,
      agreementStatus: rental.agreementStatus,
      rentPaymentStatus: rental.rentPaymentStatus,
      // Slot hold: rent is only chargeable while the rental holds the slot.
      status: rental.status ?? "pending_payment",
    });
  }
}

/** Returns {ok, value|error}. resolveServerAmount throws HttpsError on block. */
async function resolve(uid) {
  try {
    const v = await resolveServerAmount("rent", uid, {
      rentalInterestId: INTEREST,
    });
    return {ok: true, value: v};
  } catch (e) {
    return {ok: false, error: e && e.message};
  }
}

async function main() {
  await wipe();

  // 1. Awaiting acceptance (new interests start here) — NOT chargeable.
  await seed({interestStatus: "pending_acceptance"});
  let r = await resolve(TENANT);
  check("pending_acceptance interest cannot be charged",
    r.ok === false, JSON.stringify(r));

  // 2. Accepted but NO active_rental / not finalized — NOT chargeable.
  await seed({interestStatus: "accepted"});
  r = await resolve(TENANT);
  check("accepted but agreement not finalized cannot be charged",
    r.ok === false, JSON.stringify(r));

  // 3. Accepted + agreement finalized + unpaid — the ONLY chargeable state.
  await seed({
    interestStatus: "accepted",
    rental: {agreementStatus: "finalized", rentPaymentStatus: "pending"},
  });
  r = await resolve(TENANT);
  check("accepted + finalized + unpaid charges the stored amount",
    r.ok === true && r.value === AMOUNT, JSON.stringify(r));

  // 4. Wrong tenant on a fully-ready rental — NOT chargeable (permission).
  r = await resolve(OTHER);
  check("a different user cannot pay the accepted tenant's rent",
    r.ok === false, JSON.stringify(r));

  // 5. Already paid — NOT chargeable again (no double charge).
  await seed({
    interestStatus: "rent_paid",
    rental: {agreementStatus: "finalized", rentPaymentStatus: "paid"},
  });
  r = await resolve(TENANT);
  check("already-paid rent cannot be charged again",
    r.ok === false, JSON.stringify(r));

  // 6. Missing rentalInterestId — NOT chargeable (no client-amount fallback).
  try {
    await resolveServerAmount("rent", TENANT, {});
    check("rent with no interestId throws", false, "did not throw");
  } catch (_) {
    check("rent with no interestId throws", true);
  }

  // 7. Slot released (rental terminated after an unpaid lapse) — NOT chargeable
  //    even though the interest still says accepted + agreement finalized.
  await seed({
    interestStatus: "accepted",
    rental: {
      agreementStatus: "finalized",
      rentPaymentStatus: "pending",
      status: "terminated",
    },
  });
  r = await resolve(TENANT);
  check("a released (terminated) rental cannot be charged",
    r.ok === false, JSON.stringify(r));

  await wipe();
  console.log(failures === 0 ?
    "\nAll rent-resequencing charge-gate checks passed." :
    `\n${failures} check(s) FAILED.`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("Runner error:", e);
  process.exit(1);
});
