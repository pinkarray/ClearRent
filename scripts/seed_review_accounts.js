/* eslint-disable */
// Seeds the two Paystack reviewer accounts and six bookable listings.
//
//   REVIEW_TENANT_PASSWORD=... REVIEW_LANDLORD_PASSWORD=... \
//     node scripts/seed_review_accounts.js
//
//
// The addresses MUST sit on a real TLD. initializePayment sends the Auth
// account's own email to Paystack, and Paystack rejects a reserved TLD with
// '"email" must be a valid email', so clearrent.test accounts could browse and
// book but never pay. Verified on device 2026-10-07.
//
// Safe to re-run: accounts are looked up by email, listings use fixed doc ids,
// and every write merges. Everything it writes carries `seededForReview: true`
// so it can be found and removed before launch.
//
// RENTS ARE DELIBERATELY WELL UNDER 500,000. Rent is charged as rent +
// agentFee + the 5,000 deal fee in ONE transaction, so the rent itself must
// leave headroom. Paystack's TEST card tops out between
// 500k and 650k: measured 2026-10-08, 500,000 succeeded and 650,000 returned
// "Insufficient Funds". Every rent here started above that, so a reviewer could
// book and pay for a viewing but never complete a RENT payment. The viewing fee
// (10k), listing fee (10k), deal fee (5k) and verification fees are all far
// below the ceiling and were never affected. Real Lagos rents are several times
// these figures; raise them once live keys are in.
//
// What it skips, on purpose:
//  - NIN. Both accounts are written straight to verificationStatus 'verified'
//    (the field every gate reads) plus verificationExempt, so the expiry sweep
//    never locks them. No NIN, no verification_requests doc.
//  - Ownership review. Listings are written the way adminReviewPropertyDoc
//    leaves an approved one (ownershipDocStatus 'verified', isVerified,
//    isAvailable) but there is no ownership document behind them.
//  - Real photos. Each listing carries a BRANDED STAND-IN generated for the
//    review (scratchpad/gen.js, uploaded to Cloudinary under
//    clearrent/properties/review_seed). It states "Photo pending - sample
//    listing" on its face: a reviewer must never take it for a photograph of
//    the unit. Swap in real photos before these listings are used for anything
//    but review.
const admin = require("firebase-admin");
admin.initializeApp({projectId: "clearrent-app"});
const auth = admin.auth();
const db = admin.firestore();
const FV = admin.firestore.FieldValue;
const TS = admin.firestore.Timestamp;

const YEAR_MS = 365 * 24 * 60 * 60 * 1000;

const ACCOUNTS = [
  {key: "tenant", email: "paystack.tenant@verealtytech.com",
    fullName: "Paystack Reviewer (Tenant)", accountType: "tenant",
    password: process.env.REVIEW_TENANT_PASSWORD},
  {key: "landlord", email: "paystack.landlord@verealtytech.com",
    fullName: "Paystack Reviewer (Landlord)", accountType: "landlord",
    password: process.env.REVIEW_LANDLORD_PASSWORD},
];

// cluster = the LGA key scripts/lagos_areas.json maps the area to.
const LISTINGS = [
  {title: "2 Bedroom Flat in Yaba", propertyType: "flat", city: "Yaba",
    cluster: "yaba_mainland", address: "Off Herbert Macaulay Way, Yaba", lat: 6.5095, lng: 3.3711,
    bedrooms: 2, bathrooms: 2, toilets: 3, livingRooms: 1, kitchens: 1,
    rent: 380000, cautionDeposit: 38000, agentFee: 0,
    amenities: ["Running Water", "Prepaid Meter", "Tiled Floor", "Kitchen Cabinets"]},
  {title: "Self Contain in Surulere", propertyType: "selfContain", city: "Surulere",
    bathroomAccess: "private", toiletAccess: "private",
    kitchenAccess: "private", livingRoomAccess: "private",
    cluster: "surulere", address: "Off Adeniran Ogunsanya Street, Surulere", lat: 6.4969, lng: 3.3481,
    bedrooms: 1, bathrooms: 1, toilets: 1, livingRooms: 0, kitchens: 1,
    rent: 220000, cautionDeposit: 22000, agentFee: 0,
    amenities: ["Running Water", "Prepaid Meter", "Wardrobe"]},
  {title: "3 Bedroom Flat in Gbagada", propertyType: "flat", city: "Gbagada",
    cluster: "shomolu", address: "Off Diya Street, Gbagada Phase 1", lat: 6.555, lng: 3.387,
    bedrooms: 3, bathrooms: 3, toilets: 4, livingRooms: 1, kitchens: 1,
    rent: 420000, cautionDeposit: 42000, agentFee: 0,
    amenities: ["Running Water", "Security", "Parking Space", "Prepaid Meter"]},
  {title: "Room & Parlour in Ikeja GRA", propertyType: "roomAndParlour", city: "Ikeja GRA",
    bathroomAccess: "private", toiletAccess: "private",
    kitchenAccess: "private", livingRoomAccess: "private",
    cluster: "ikeja", address: "Off Isaac John Street, Ikeja GRA", lat: 6.5833, lng: 3.3517,
    bedrooms: 1, bathrooms: 1, toilets: 1, livingRooms: 1, kitchens: 1,
    rent: 280000, cautionDeposit: 28000, agentFee: 0,
    amenities: ["Running Water", "Security", "Tiled Floor"]},
  {title: "4 Bedroom Duplex in Lekki Phase 1",
    propertyType: "duplex", city: "Lekki Phase 1",
    cluster: "eti_osa", address: "Off Admiralty Way, Lekki Phase 1", lat: 6.4409, lng: 3.471,
    bedrooms: 4, bathrooms: 4, toilets: 5, livingRooms: 2, kitchens: 1,
    rent: 460000, cautionDeposit: 46000, agentFee: 0,
    amenities: ["24/7 Power Supply", "Running Water", "Security", "Parking Space", "CCTV"]},
  {title: "2 Bedroom Bungalow in Ajah", propertyType: "bungalow", city: "Ajah",
    cluster: "eti_osa", address: "Off Addo Road, Ajah", lat: 6.4667, lng: 3.5667,
    bedrooms: 2, bathrooms: 2, toilets: 2, livingRooms: 1, kitchens: 1,
    rent: 330000, cautionDeposit: 33000, agentFee: 0,
    amenities: ["Running Water", "Parking Space", "Garden"]},
];

const PLACEHOLDERS = [
  "https://res.cloudinary.com/den5t1dai/image/upload/v1791429641/clearrent/properties/review_seed/bpppqi5ka9q7lezx7nag.png",
  "https://res.cloudinary.com/den5t1dai/image/upload/v1791429643/clearrent/properties/review_seed/t8j9oglhyymvlnz2ubs0.png",
  "https://res.cloudinary.com/den5t1dai/image/upload/v1791429645/clearrent/properties/review_seed/vazpegk2azzjplxa2pn1.png",
  "https://res.cloudinary.com/den5t1dai/image/upload/v1791429646/clearrent/properties/review_seed/fnvxuurtthcpuqxpdxt6.png",
  "https://res.cloudinary.com/den5t1dai/image/upload/v1791429648/clearrent/properties/review_seed/xoc1feopambyx6tbwkyz.png",
  "https://res.cloudinary.com/den5t1dai/image/upload/v1791429650/clearrent/properties/review_seed/nqa3zibif9hyoe9lzbuf.png",
];

// DELIBERATELY NOT A REAL ACCOUNT. These details exist only to satisfy
// actorHasBankDetails() in firestore.rules, which gates requesting and
// accepting an inspection. No payout is ever made to a reviewer account.
//
// It MUST stay fake: the credentials for these accounts go to an outside
// review team in a document, and a user can read their own private/bank
// subdoc, so a real account number and account name would be readable by
// anyone holding that shared password.
const BANK = {
  bankName: "Access Bank",
  bankCode: "044",
  accountNumber: "0000000000",
  accountName: "CLEARRENT REVIEW ACCOUNT (NOT FOR PAYOUT)",
};

async function upsertAccount(a) {
  if (!a.password || a.password.length < 8) {
    throw new Error(`Set a password of 8+ characters for ${a.email} ` +
      `(REVIEW_${a.key.toUpperCase()}_PASSWORD)`);
  }
  let user;
  try {
    user = await auth.getUserByEmail(a.email);
    user = await auth.updateUser(user.uid, {password: a.password, emailVerified: true});
  } catch (e) {
    if (e.code !== "auth/user-not-found") throw e;
    user = await auth.createUser({email: a.email, password: a.password,
      displayName: a.fullName, emailVerified: true});
  }
  await auth.setCustomUserClaims(user.uid,
    {...(user.customClaims || {}), verificationExempt: true});

  const now = Date.now();
  await db.collection("users").doc(user.uid).set({
    uid: user.uid,
    fullName: a.fullName,
    fullNameLower: a.fullName.toLowerCase(),
    email: a.email,
    accountType: a.accountType,
    profileCompleted: true,
    emailVerified: true,
    verificationStatus: "verified",
    isVerified: true,
    verifiedAt: TS.fromMillis(now),
    verificationExpiresAt: TS.fromMillis(now + YEAR_MS),
    verificationExempt: true,
    hasBankDetails: true,
    seededForReview: true,
    createdAt: FV.serverTimestamp(),
    updatedAt: FV.serverTimestamp(),
  }, {merge: true});
  await db.collection("users").doc(user.uid).collection("private").doc("bank")
    .set({...BANK, updatedAt: FV.serverTimestamp()}, {merge: true});
  console.log(`${a.key}: ${a.email} -> ${user.uid}`);
  return user.uid;
}

async function seedListing(l, i, landlordUid, landlordName) {
  const ref = db.collection("properties").doc(`review_seed_${i + 1}`);
  const {cluster, address, lat, lng, ...fields} = l;
  await ref.set({
    ...fields,
    landlordId: landlordUid,
    landlordName,
    landlordPhone: null,
    description: `${l.title}. Seeded for payment review; photos to follow.`,
    guestRooms: 0,
    images: [PLACEHOLDERS[i]],
    state: "Lagos",
    lga: "",
    rentFrequency: "yearly",
    cautionDepositRefundable: true,
    rules: ["No subletting"],
    inspectionHandler: "self",
    inspectionDays: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
    inspectionTimeSlots: ["morning", "afternoon", "late_afternoon"],
    assignedAgentId: null,
    assignedAgentName: null,
    assignedAgentPhone: null,
    maxTenants: 1,
    viewCount: 0,
    inquiryCount: 0,
    savedCount: 0,
    landlordLivesInProperty: false,
    currentTenantsCount: 0,
    // Flat-fee model (InspectionPricing.calculateSelfHandledFee).
    inspectionFeeTotal: 10000,
    inspectionTransportFee: 0,
    inspectionServiceFee: 7000,
    inspectionAgentCluster: cluster,
    inspectionPropertyCluster: cluster,
    // As adminReviewPropertyDoc leaves an approved listing.
    ownershipDocStatus: "verified",
    isVerified: true,
    isAvailable: true,
    // As markReadyForInspections leaves a vetted one.
    readyForInspections: true,
    readinessCheckedAt: FV.serverTimestamp(),
    readinessCheckedBy: landlordUid,
    readinessChecklist: ["visited", "accurate_media", "accurate_address", "accessible"],
    seededForReview: true,
    createdAt: FV.serverTimestamp(),
    updatedAt: FV.serverTimestamp(),
  }, {merge: true});
  // onInspectionPaid copies address AND coords from here onto the request,
  // which is what draws the map pin and the Directions button after payment.
  await ref.collection("private").doc("location").set({
    address,
    latitude: lat,
    longitude: lng,
    updatedAt: FV.serverTimestamp(),
  });
  console.log(`listing ${ref.id}: ${l.title}`);
}

(async () => {
  const uids = {};
  for (const a of ACCOUNTS) uids[a.key] = await upsertAccount(a);
  const landlord = ACCOUNTS.find((a) => a.key === "landlord");
  for (let i = 0; i < LISTINGS.length; i++) {
    await seedListing(LISTINGS[i], i, uids.landlord, landlord.fullName);
  }
  await db.collection("users").doc(uids.landlord).set(
    {totalListingsCreated: LISTINGS.length}, {merge: true});
  console.log("done");
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
