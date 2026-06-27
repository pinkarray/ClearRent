// Firestore security-rules tests, run against the Firestore emulator via
// `firebase emulators:exec`. Covers:
//   1. active_rentals update ALLOWLIST (the new rule) — positive + negative.
//   2. tenancy_links list rule (F1.13 ownership scoping) — positive + negative.
//
// Positive cases guard against an over-tight allowlist breaking real client
// writes; negative cases prove the holes (rentAmount / payout self-edits,
// unscoped tenancy enumeration) are closed.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test, { before, after, beforeEach } from "node:test";
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import {
  doc,
  setDoc,
  updateDoc,
  getDoc,
  collection,
  query,
  where,
  getDocs,
  serverTimestamp,
  Timestamp,
} from "firebase/firestore";

const PROJECT_ID = "demo-clearrent";
const LANDLORD = "landlord1";
const TENANT = "tenant1";
const AGENT = "agent1";
const OTHER = "other1";

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(
        fileURLToPath(new URL("../firestore.rules", import.meta.url)),
        "utf8"
      ),
      host: "127.0.0.1",
      port: 8080,
    },
  });
});

after(async () => {
  await testEnv?.cleanup();
});

// Re-seed a clean world before every test so writes/denials don't leak across.
beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const future = Timestamp.fromDate(
      new Date(Date.now() + 300 * 24 * 60 * 60 * 1000)
    );
    await setDoc(doc(db, "active_rentals/ar1"), {
      tenantId: TENANT,
      landlordId: LANDLORD,
      propertyId: "prop1",
      rentAmount: 50000,
      agentFee: 0,
      totalPaid: 50000,
      landlordPayout: 50000,
      agentPayout: 0,
      clearrentEarnings: 0,
      landlordPayoutStatus: "pending",
      agentPayoutStatus: "not_applicable",
      agreementStatus: "pending_review",
      status: "active",
      hasPaymentReminder: false,
      leaseEndDate: future,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
    await setDoc(doc(db, "tenancy_links/tl1"), {
      landlordId: LANDLORD,
      tenantId: TENANT,
      propertyId: "prop1",
      status: "confirmed",
      rentAmount: 50000,
      createdAt: serverTimestamp(),
    });
    await setDoc(doc(db, "buildings/b1"), {
      landlordId: LANDLORD,
      name: "Olu Compound",
      address: "12 Allen Ave",
      ownershipDocUrl: "https://example.com/cofo.jpg",
      ownershipDocType: "c_of_o",
      ownershipDocStatus: "pending",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
    // Verified landlords — property creation requires verificationStatus.
    await setDoc(doc(db, "users/" + LANDLORD), {
      verificationStatus: "verified",
    });
    await setDoc(doc(db, "users/" + OTHER), {
      verificationStatus: "verified",
    });
    // Owner-scoped list-hardening fixtures: one doc owned by TENANT/LANDLORD,
    // one owned by OTHER, per collection.
    await setDoc(doc(db, "payments/pay_tenant"), {
      userId: TENANT, type: "rent", amount: 1000, status: "completed",
    });
    await setDoc(doc(db, "payments/pay_other"), {
      userId: OTHER, type: "rent", amount: 1000, status: "completed",
    });
    await setDoc(doc(db, "notifications/n_tenant"), {
      userId: TENANT, title: "Hi", read: false,
    });
    await setDoc(doc(db, "notifications/n_other"), {
      userId: OTHER, title: "Hi", read: false,
    });
    await setDoc(doc(db, "transactions/tx_landlord"), {
      landlordId: LANDLORD, role: "landlord", amount: 1000,
    });
    await setDoc(doc(db, "transactions/tx_other"), {
      landlordId: OTHER, role: "landlord", amount: 1000,
    });
    await setDoc(doc(db, "refunds/rf_tenant"), {
      beneficiaryId: TENANT, amount: 1000, status: "pending",
    });
    await setDoc(doc(db, "refunds/rf_other"), {
      beneficiaryId: OTHER, amount: 1000, status: "pending",
    });
    await setDoc(doc(db, "rent_review_requests/rr_landlord"), {
      landlordId: LANDLORD, tenantId: TENANT, status: "pending",
    });
    await setDoc(doc(db, "rent_review_requests/rr_other"), {
      landlordId: OTHER, tenantId: OTHER, status: "pending",
    });
    // active_rental owned by OTHER (ar1 above is owned by TENANT/LANDLORD).
    await setDoc(doc(db, "active_rentals/ar_other"), {
      tenantId: OTHER, landlordId: OTHER, propertyId: "prop2",
      status: "active", leaseEndDate: future,
    });
    // H1-rest fixtures: issues / maintenance_logs / inspection_requests.
    await setDoc(doc(db, "issues/iss_party"), {
      tenantId: TENANT, landlordId: LANDLORD, propertyId: "prop1",
      status: "open",
    });
    await setDoc(doc(db, "issues/iss_other"), {
      tenantId: OTHER, landlordId: OTHER, propertyId: "prop2",
      status: "open",
    });
    await setDoc(doc(db, "maintenance_logs/ml_landlord"), {
      landlordId: LANDLORD, propertyId: "prop1", category: "plumbing",
      note: "Fixed tap", loggedAt: serverTimestamp(),
    });
    await setDoc(doc(db, "maintenance_logs/ml_other"), {
      landlordId: OTHER, propertyId: "prop2", category: "plumbing",
      note: "Fixed tap", loggedAt: serverTimestamp(),
    });
    await setDoc(doc(db, "inspection_requests/ir_party"), {
      tenantId: TENANT, landlordId: LANDLORD, agentId: AGENT,
      propertyId: "prop1", status: "pending",
    });
    await setDoc(doc(db, "inspection_requests/ir_other"), {
      tenantId: OTHER, landlordId: OTHER, agentId: OTHER,
      propertyId: "prop2", status: "pending",
    });
    // H2 fixtures: rental_interests in two lifecycle states.
    await setDoc(doc(db, "rental_interests/ri_pending"), {
      tenantId: TENANT, landlordId: LANDLORD, agentId: null,
      inspectionRequestId: "insp1", propertyId: "prop1",
      status: "pending_payment",
      paymentAmount: 50000, landlordPayout: 45000, agentPayout: 0,
    });
    await setDoc(doc(db, "rental_interests/ri_verified"), {
      tenantId: TENANT, landlordId: LANDLORD, agentId: null,
      inspectionRequestId: "insp1", propertyId: "prop1",
      status: "payment_verified",
      paymentAmount: 50000, landlordPayout: 45000, agentPayout: 0,
    });
    // inspection_requests doc the rental_interests read rule get()s.
    await setDoc(doc(db, "inspection_requests/insp1"), {
      tenantId: TENANT, landlordId: LANDLORD, agentId: null,
      propertyId: "prop1", status: "completed",
    });
    // C1 fixture: locked bank details in the private subcollection.
    await setDoc(doc(db, "users/" + LANDLORD + "/private/bank"), {
      bankName: "GTBank", bankCode: "058",
      accountNumber: "0123456789", accountName: "Landlord One",
    });
    // M1 fixtures: activities (landlord's feed item generated by the tenant).
    await setDoc(doc(db, "activities/act_party"), {
      landlordId: LANDLORD, actorId: TENANT, propertyId: "prop1",
      type: "propertyViewed", isRead: false,
    });
    await setDoc(doc(db, "activities/act_other"), {
      landlordId: OTHER, actorId: OTHER, propertyId: "prop2",
      type: "propertyViewed", isRead: false,
    });
    // M3 fixtures: conversations.
    await setDoc(doc(db, "conversations/conv_party"), {
      participants: [LANDLORD, TENANT, AGENT],
      landlordId: LANDLORD, tenantId: TENANT, agentId: AGENT,
      propertyId: "prop1", lastMessage: "hi",
    });
    await setDoc(doc(db, "conversations/conv_other"), {
      participants: [OTHER], landlordId: OTHER, tenantId: OTHER,
      propertyId: "prop2", lastMessage: "hi",
    });
  });
});

const landlordDb = () => testEnv.authenticatedContext(LANDLORD).firestore();
const tenantDb = () => testEnv.authenticatedContext(TENANT).firestore();
const agentDb = () => testEnv.authenticatedContext(AGENT).firestore();
const otherDb = () => testEnv.authenticatedContext(OTHER).firestore();
const adminDb = () =>
  testEnv.authenticatedContext("admin1", { admin: true }).firestore();

// ─── active_rentals allowlist — POSITIVE (must succeed) ──────────────────────
// Each mirrors a real update site in active_rental_service.dart.

test("landlord finalizes agreement (allowlisted fields) — allowed", async () => {
  // landlordFinalizeAgreement: agreementStatus + landlordFinalizedAt + updatedAt
  await assertSucceeds(
    updateDoc(doc(landlordDb(), "active_rentals/ar1"), {
      agreementStatus: "finalized",
      landlordFinalizedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
});

test("tenant accepts agreement (allowlisted fields) — allowed", async () => {
  // tenantAcceptAgreement: agreementStatus + tenantAcceptedAt + tenantDisputeReason + updatedAt
  await assertSucceeds(
    updateDoc(doc(tenantDb(), "active_rentals/ar1"), {
      agreementStatus: "accepted",
      tenantAcceptedAt: serverTimestamp(),
      tenantDisputeReason: null,
      updatedAt: serverTimestamp(),
    })
  );
});

test("tenant moves out (status lifecycle, allowlisted) — allowed", async () => {
  // tenantMoveOut: status + endReason + endedBy + endedAt + updatedAt
  await assertSucceeds(
    updateDoc(doc(tenantDb(), "active_rentals/ar1"), {
      status: "ended_by_tenant",
      endReason: "Relocating",
      endedBy: "tenant",
      endedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
});

test("landlord toggles payment reminder (allowlisted) — allowed", async () => {
  await assertSucceeds(
    updateDoc(doc(landlordDb(), "active_rentals/ar1"), {
      hasPaymentReminder: true,
      updatedAt: serverTimestamp(),
    })
  );
});

// ─── active_rentals allowlist — NEGATIVE (must be denied) ────────────────────
// These are the holes the allowlist closes.

test("non-admin writing rentAmount on own rental — denied", async () => {
  await assertFails(
    updateDoc(doc(landlordDb(), "active_rentals/ar1"), {
      rentAmount: 70000,
      updatedAt: serverTimestamp(),
    })
  );
});

test("tenant writing rentAmount on own rental — denied", async () => {
  await assertFails(
    updateDoc(doc(tenantDb(), "active_rentals/ar1"), {
      rentAmount: 70000,
      updatedAt: serverTimestamp(),
    })
  );
});

test("non-admin writing a payout field — denied", async () => {
  await assertFails(
    updateDoc(doc(landlordDb(), "active_rentals/ar1"), {
      landlordPayoutStatus: "paid",
      updatedAt: serverTimestamp(),
    })
  );
});

test("smuggling rentAmount alongside an allowlisted field — denied", async () => {
  // Proves the rule is hasOnly (allowlist), not just a single-field block:
  // an otherwise-valid agreement write that also touches rentAmount must fail.
  await assertFails(
    updateDoc(doc(landlordDb(), "active_rentals/ar1"), {
      agreementStatus: "finalized",
      rentAmount: 70000,
      updatedAt: serverTimestamp(),
    })
  );
});

// ─── tenancy_links F1.13 ownership scoping ───────────────────────────────────

test("owner-scoped query (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(
      query(
        collection(landlordDb(), "tenancy_links"),
        where("landlordId", "==", LANDLORD)
      )
    )
  );
});

test("tenant-scoped query (tenantId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(
      query(
        collection(tenantDb(), "tenancy_links"),
        where("tenantId", "==", TENANT)
      )
    )
  );
});

test("unscoped propertyId-only list by non-owner — denied", async () => {
  await assertFails(
    getDocs(
      query(
        collection(otherDb(), "tenancy_links"),
        where("propertyId", "==", "prop1")
      )
    )
  );
});

// ─── tenancy_links update allowlist ──────────────────────────────────────────
// Lifecycle transitions (accept/reject/remove) are allowed; rent/term fields
// and the admin-only pendingRent* are denied so a landlord can't self-apply an
// increase to a link and bypass the rent-review path.

test("tenant accepts link (status + acceptedAt) — allowed", async () => {
  await assertSucceeds(
    updateDoc(doc(tenantDb(), "tenancy_links/tl1"), {
      status: "confirmed",
      acceptedAt: serverTimestamp(),
    })
  );
});

test("landlord removes link (status + removedAt) — allowed", async () => {
  await assertSucceeds(
    updateDoc(doc(landlordDb(), "tenancy_links/tl1"), {
      status: "removed",
      removedAt: serverTimestamp(),
    })
  );
});

test("landlord writing pendingRentForRenewal on a link — denied", async () => {
  await assertFails(
    updateDoc(doc(landlordDb(), "tenancy_links/tl1"), {
      pendingRentForRenewal: 70000,
      pendingRentEffectiveDate: serverTimestamp(),
    })
  );
});

test("landlord writing rentAmount on a link — denied", async () => {
  await assertFails(
    updateDoc(doc(landlordDb(), "tenancy_links/tl1"), {
      rentAmount: 70000,
    })
  );
});

// ─── buildings (unit grouping + shared ownership doc) ────────────────────────
// A landlord creates a building and (re)uploads its C of O; only an admin can
// verify it. Units inherit the building's doc status, so any authed user can
// read a building, but only the owner/admin can list them.

test("landlord creates own building (pending doc) — allowed", async () => {
  await assertSucceeds(
    setDoc(doc(landlordDb(), "buildings/b2"), {
      landlordId: LANDLORD,
      name: "New Block",
      address: "",
      ownershipDocStatus: "pending",
      createdAt: serverTimestamp(),
    })
  );
});

test("creating a building for someone else — denied", async () => {
  await assertFails(
    setDoc(doc(landlordDb(), "buildings/b3"), {
      landlordId: OTHER,
      name: "Not mine",
      ownershipDocStatus: "none",
    })
  );
});

test("creating a building pre-verified — denied", async () => {
  await assertFails(
    setDoc(doc(landlordDb(), "buildings/b4"), {
      landlordId: LANDLORD,
      name: "Sneaky",
      ownershipDocStatus: "verified",
    })
  );
});

test("owner re-uploads building doc (status → pending) — allowed", async () => {
  await assertSucceeds(
    updateDoc(doc(landlordDb(), "buildings/b1"), {
      ownershipDocUrl: "https://example.com/revised.jpg",
      ownershipDocStatus: "pending",
      updatedAt: serverTimestamp(),
    })
  );
});

test("owner self-verifying the building doc — denied", async () => {
  await assertFails(
    updateDoc(doc(landlordDb(), "buildings/b1"), {
      ownershipDocStatus: "verified",
      updatedAt: serverTimestamp(),
    })
  );
});

test("owner-scoped building list — allowed", async () => {
  await assertSucceeds(
    getDocs(
      query(
        collection(landlordDb(), "buildings"),
        where("landlordId", "==", LANDLORD)
      )
    )
  );
});

test("non-owner listing another landlord's buildings — denied", async () => {
  await assertFails(
    getDocs(
      query(
        collection(otherDb(), "buildings"),
        where("landlordId", "==", LANDLORD)
      )
    )
  );
});

test("any authed user reads a building (unit doc inheritance) — allowed", async () => {
  await assertSucceeds(getDoc(doc(otherDb(), "buildings/b1")));
});

// ─── property ↔ building cross-owner guard ───────────────────────────────────
// A unit may only reference a building the SAME landlord owns — otherwise a
// modified client could borrow another owner's verified C of O.

const newUnit = (landlordId, buildingId) => ({
  landlordId,
  title: "Room 1",
  rent: 200000,
  ownershipDocStatus: buildingId ? "inherited" : "pending",
  ...(buildingId ? { buildingId } : {}),
});

test("creating a standalone unit (no building) — allowed", async () => {
  await assertSucceeds(
    setDoc(doc(landlordDb(), "properties/p_standalone"), newUnit(LANDLORD, null))
  );
});

test("creating a unit in a building the caller owns — allowed", async () => {
  await assertSucceeds(
    setDoc(doc(landlordDb(), "properties/p_owned"), newUnit(LANDLORD, "b1"))
  );
});

test("creating a unit in ANOTHER owner's building — denied", async () => {
  // OTHER is a verified landlord, but b1 belongs to LANDLORD.
  await assertFails(
    setDoc(doc(otherDb(), "properties/p_borrowed"), newUnit(OTHER, "b1"))
  );
});

test("creating a unit referencing a non-existent building — denied", async () => {
  await assertFails(
    setDoc(doc(landlordDb(), "properties/p_ghost"), newUnit(LANDLORD, "does_not_exist"))
  );
});

// ─── property ownershipDocStatus guard (owner can't self-verify) ─────────────

test("owner self-verifying their property doc — denied", async () => {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "properties/p_self"), {
      landlordId: LANDLORD,
      title: "Room",
      rent: 200000,
      ownershipDocStatus: "pending",
    });
  });
  await assertFails(
    updateDoc(doc(landlordDb(), "properties/p_self"), {
      ownershipDocStatus: "verified",
      updatedAt: serverTimestamp(),
    })
  );
});

test("owner re-uploads their property doc (status → pending) — allowed", async () => {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "properties/p_reup"), {
      landlordId: LANDLORD,
      title: "Room",
      rent: 200000,
      ownershipDocStatus: "rejected",
    });
  });
  await assertSucceeds(
    updateDoc(doc(landlordDb(), "properties/p_reup"), {
      ownershipDocUrl: "https://example.com/new.jpg",
      ownershipDocStatus: "pending",
      isAvailable: false,
      updatedAt: serverTimestamp(),
    })
  );
});

// ─── owner-scoped list hardening (H1) ────────────────────────────────────────
// payments / notifications / transactions / refunds each had
// `allow list: if request.auth != null`, letting any authed user query the
// WHOLE collection. Positive = the owner's own scoped query still works;
// negative = an unscoped query, or one targeting another user, is denied.

test("tenant lists own payments (userId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "payments"), where("userId", "==", TENANT)))
  );
});

test("tenant lists ALL payments (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "payments")));
});

test("tenant lists another user's payments — denied", async () => {
  await assertFails(
    getDocs(query(collection(tenantDb(), "payments"), where("userId", "==", OTHER)))
  );
});

test("user lists own notifications (userId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "notifications"), where("userId", "==", TENANT)))
  );
});

test("tenant lists ALL notifications (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "notifications")));
});

test("landlord lists own transactions (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "transactions"), where("landlordId", "==", LANDLORD)))
  );
});

test("other user lists landlord's transactions — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "transactions"), where("landlordId", "==", LANDLORD)))
  );
});

test("tenant lists own refunds (beneficiaryId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "refunds"), where("beneficiaryId", "==", TENANT)))
  );
});

test("tenant lists ALL refunds (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "refunds")));
});

test("landlord lists own rent-review requests (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "rent_review_requests"), where("landlordId", "==", LANDLORD)))
  );
});

test("other user lists ALL rent-review requests (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(otherDb(), "rent_review_requests")));
});

// ─── owner-scoped list hardening (H1-rest) ───────────────────────────────────
// issues / maintenance_logs / inspection_requests / active_rentals each had
// `allow list: if request.auth != null`. Positive = each real client query
// shape (scoped by the caller's id) still works; negative = an unscoped query,
// a propertyId-only query, or one targeting another user is denied.

// issues — tenant by tenantId, landlord by landlordId (PropertyHealth scopes
// landlordId then client-filters propertyId).
test("tenant lists own issues (tenantId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "issues"), where("tenantId", "==", TENANT)))
  );
});

test("landlord lists own issues (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "issues"), where("landlordId", "==", LANDLORD)))
  );
});

test("tenant lists ALL issues (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "issues")));
});

test("user lists issues by propertyId only (unscoped owner) — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "issues"), where("propertyId", "==", "prop1")))
  );
});

// maintenance_logs — landlord only.
test("landlord lists own maintenance logs (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "maintenance_logs"), where("landlordId", "==", LANDLORD)))
  );
});

test("tenant lists ALL maintenance logs (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "maintenance_logs")));
});

test("user lists maintenance logs by propertyId only — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "maintenance_logs"), where("propertyId", "==", "prop1")))
  );
});

// inspection_requests — party (tenant/landlord/agent).
test("tenant lists own inspection requests (tenantId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "inspection_requests"), where("tenantId", "==", TENANT)))
  );
});

test("landlord lists own inspection requests (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "inspection_requests"), where("landlordId", "==", LANDLORD)))
  );
});

test("agent lists own inspection requests (agentId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(agentDb(), "inspection_requests"), where("agentId", "==", AGENT)))
  );
});

test("tenant lists ALL inspection requests (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "inspection_requests")));
});

test("user lists inspection requests by propertyId only — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "inspection_requests"), where("propertyId", "==", "prop1")))
  );
});

// active_rentals — tenant or landlord on the rental.
test("tenant lists own active rentals (tenantId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "active_rentals"), where("tenantId", "==", TENANT)))
  );
});

test("landlord lists own active rentals (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "active_rentals"), where("landlordId", "==", LANDLORD)))
  );
});

test("tenant lists ALL active rentals (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "active_rentals")));
});

test("user lists active rentals by propertyId only — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "active_rentals"), where("propertyId", "==", "prop1")))
  );
});

// ─── H2: create / update fabrication guards ──────────────────────────────────
// Clients must not be able to mint already-paid financial state. Positive =
// the real client write still works; negative = the forgery is closed.

// rental_interests create — tenant files own, must start 'pending_payment'.
test("tenant creates own pending rental interest — allowed", async () => {
  await assertSucceeds(
    setDoc(doc(tenantDb(), "rental_interests/ri_new"), {
      tenantId: TENANT, landlordId: LANDLORD, inspectionRequestId: "insp1",
      propertyId: "prop1", status: "pending_payment",
      paymentAmount: 50000, landlordPayout: 45000,
    })
  );
});

test("tenant creates ALREADY-VERIFIED rental interest — denied", async () => {
  await assertFails(
    setDoc(doc(tenantDb(), "rental_interests/ri_forged"), {
      tenantId: TENANT, landlordId: LANDLORD, inspectionRequestId: "insp1",
      propertyId: "prop1", status: "payment_verified",
      paymentAmount: 50000, landlordPayout: 45000,
    })
  );
});

test("tenant creates rental interest attributed to someone else — denied", async () => {
  await assertFails(
    setDoc(doc(tenantDb(), "rental_interests/ri_spoof"), {
      tenantId: OTHER, landlordId: LANDLORD, inspectionRequestId: "insp1",
      propertyId: "prop1", status: "pending_payment",
    })
  );
});

// rental_interests update — lifecycle fields allowed, money immutable (M2).
test("tenant updates own interest lifecycle fields — allowed", async () => {
  await assertSucceeds(
    updateDoc(doc(tenantDb(), "rental_interests/ri_pending"), {
      status: "payment_uploaded",
      paymentReceiptUrl: "https://example.com/r.jpg",
      paymentUploadedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
});

test("tenant rewrites interest landlordPayout — denied", async () => {
  await assertFails(
    updateDoc(doc(tenantDb(), "rental_interests/ri_pending"), {
      landlordPayout: 9999999,
    })
  );
});

// active_rentals create — landlord only, backed by a verified interest.
test("landlord creates active rental from a verified interest — allowed", async () => {
  await assertSucceeds(
    setDoc(doc(landlordDb(), "active_rentals/ar_new"), {
      landlordId: LANDLORD, tenantId: TENANT, propertyId: "prop1",
      rentalInterestId: "ri_verified", status: "active",
      landlordPayout: 45000, leaseEndDate: Timestamp.fromDate(new Date(Date.now() + 1e10)),
    })
  );
});

test("tenant fabricates an active rental — denied", async () => {
  await assertFails(
    setDoc(doc(tenantDb(), "active_rentals/ar_forged"), {
      landlordId: LANDLORD, tenantId: TENANT, propertyId: "prop1",
      rentalInterestId: "ri_verified", status: "active",
      landlordPayout: 45000,
    })
  );
});

test("landlord creates active rental from an UNVERIFIED interest — denied", async () => {
  await assertFails(
    setDoc(doc(landlordDb(), "active_rentals/ar_premature"), {
      landlordId: LANDLORD, tenantId: TENANT, propertyId: "prop1",
      rentalInterestId: "ri_pending", status: "active",
      landlordPayout: 45000,
    })
  );
});

// ─── C1: bank details locked in users/{uid}/private/bank ─────────────────────
// The user doc is world-readable to authed users; account numbers must not
// live there. Only the owner and admin may read the private subcollection.

test("owner reads own bank details — allowed", async () => {
  await assertSucceeds(
    getDoc(doc(landlordDb(), "users/" + LANDLORD + "/private/bank"))
  );
});

test("admin reads another user's bank details — allowed", async () => {
  await assertSucceeds(
    getDoc(doc(adminDb(), "users/" + LANDLORD + "/private/bank"))
  );
});

test("other user reads someone's bank details — denied", async () => {
  await assertFails(
    getDoc(doc(otherDb(), "users/" + LANDLORD + "/private/bank"))
  );
});

test("owner writes own bank details — allowed", async () => {
  await assertSucceeds(
    setDoc(doc(landlordDb(), "users/" + LANDLORD + "/private/bank"), {
      bankName: "Access", bankCode: "044",
      accountNumber: "9876543210", accountName: "Landlord One",
    })
  );
});

test("other user writes someone's bank details — denied", async () => {
  await assertFails(
    setDoc(doc(otherDb(), "users/" + LANDLORD + "/private/bank"), {
      accountNumber: "0000000000",
    })
  );
});

// ─── M1: activities feed no longer world-enumerable ──────────────────────────
test("landlord lists own activity feed (landlordId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(landlordDb(), "activities"), where("landlordId", "==", LANDLORD)))
  );
});

test("actor lists activities they generated (actorId == uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "activities"), where("actorId", "==", TENANT)))
  );
});

test("user lists ALL activities (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "activities")));
});

test("other user lists a landlord's activity feed — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "activities"), where("landlordId", "==", LANDLORD)))
  );
});

test("landlord marks own activity read (isRead only) — allowed", async () => {
  await assertSucceeds(
    updateDoc(doc(landlordDb(), "activities/act_party"), { isRead: true })
  );
});

test("other user updates a landlord's activity — denied", async () => {
  await assertFails(
    updateDoc(doc(otherDb(), "activities/act_party"), { isRead: true })
  );
});

// ─── M3: conversations no longer world-enumerable ────────────────────────────
test("participant lists own conversations (array-contains uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "conversations"), where("participants", "array-contains", TENANT)))
  );
});

test("agent lists conversations they're in (array-contains uid) — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(agentDb(), "conversations"), where("participants", "array-contains", AGENT)))
  );
});

test("agent-path dedup: agent lists by participants then client-filters — allowed", async () => {
  // Mirrors the refactored getOrCreateConversation dedup (M3): the agent is
  // neither landlordId nor tenantId, so it must scope by participation.
  await assertSucceeds(
    getDocs(query(collection(agentDb(), "conversations"), where("participants", "array-contains", AGENT)))
  );
});

test("tenant-path dedup lists by tenantId == uid — allowed", async () => {
  await assertSucceeds(
    getDocs(query(collection(tenantDb(), "conversations"), where("tenantId", "==", TENANT)))
  );
});

test("user lists ALL conversations (unscoped) — denied", async () => {
  await assertFails(getDocs(collection(tenantDb(), "conversations")));
});

test("other user lists a landlord's conversations (landlordId) — denied", async () => {
  await assertFails(
    getDocs(query(collection(otherDb(), "conversations"), where("landlordId", "==", LANDLORD)))
  );
});
