/**
 * Cross-domain admin-alert triggers (fast-follow to the inspection dispute).
 *
 * These are the "the admin should know about this" hooks for events that,
 * unlike inspections, had no admin-facing surface: a landlord filing a rent
 * change, and a user changing their own name/email. Each just calls the shared
 * writeAdminAlert so it lands in the same dashboard feed as everything else.
 *
 * (Rent-payment, tenancy-issue and agreement-dispute alerts live inline in
 * index.ts next to their existing notification triggers — see writeAdminAlert
 * callers there.)
 */

import {onDocumentCreated, onDocumentUpdated}
  from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {writeAdminAlert, upsertAdminAlert} from "./admin_alerts";

/**
 * A landlord filed a rent-change request (rent_review_requests/{id}). It sits
 * in `pending` until an admin approves/rejects it (approveRentReview etc.), but
 * nothing pinged the admin that one had arrived. This does.
 */
export const onRentReviewRequested = onDocumentCreated(
  "rent_review_requests/{requestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();
    if (d.status !== "pending") return; // only fresh, undecided requests

    const requestId = event.params.requestId;
    const propertyTitle =
      (d.propertyTitle as string | undefined) ?? "a property";
    const proposedRent = Number(d.proposedRent ?? 0);
    const immediate = (d.changeType as string | undefined) === "immediate";

    await writeAdminAlert({
      type: "rent_change_request",
      severity: "warning",
      title: immediate ?
        "Immediate rent change to review" :
        "Rent review to approve",
      body:
        `A landlord filed a ${immediate ? "immediate " : ""}rent change for ` +
        `${propertyTitle} to ₦${proposedRent.toLocaleString("en-NG")}.`,
      targetCollection: "rent_review_requests",
      targetId: requestId,
      actors: {
        landlordId: (d.landlordId as string | undefined) || undefined,
        tenantId: (d.tenantId as string | undefined) || undefined,
      },
      meta: {
        proposedRent,
        reasonType: (d.reasonType as string | undefined) ?? "",
        changeType: (d.changeType as string | undefined) ?? "scheduled",
      },
    });
    logger.info("Rent-change request admin alert raised", {requestId});
  },
);

/**
 * A user changed their own name or email. Identity changes are a support /
 * fraud / impersonation signal (e.g. an account being repurposed), so the admin
 * gets a heads-up. Fires only on an actual change to those two fields — the
 * users doc is written for many other reasons (rating, verification, …).
 */
export const onUserProfileUpdated = onDocumentUpdated(
  "users/{uid}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const nameBefore = (before.fullName as string | undefined) ?? "";
    const nameAfter = (after.fullName as string | undefined) ?? "";
    const emailBefore = (before.email as string | undefined) ?? "";
    const emailAfter = (after.email as string | undefined) ?? "";

    const nameChanged = nameBefore !== nameAfter;
    const emailChanged = emailBefore !== emailAfter;
    if (!nameChanged && !emailChanged) return;

    const uid = event.params.uid;
    const changes: string[] = [];
    if (nameChanged) changes.push(`name "${nameBefore}" → "${nameAfter}"`);
    if (emailChanged) changes.push(`email "${emailBefore}" → "${emailAfter}"`);

    await writeAdminAlert({
      type: "profile_identity_change",
      severity: "warning",
      title: "User changed their identity details",
      body: `${nameAfter || "A user"} updated their ${changes.join(" and ")}.`,
      targetCollection: "users",
      targetId: uid,
      actors: {tenantId: uid},
      meta: {
        nameChanged,
        emailChanged,
        nameBefore,
        nameAfter,
        emailBefore,
        emailAfter,
        accountType: (after.accountType as string | undefined) ?? "",
      },
    });
    logger.info("Profile identity-change admin alert raised", {uid});
  },
);

/**
 * A new account finished onboarding.
 *
 * Fires on the users doc create, which the client writes at the end of profile
 * setup — so this is "a real person joined", not "someone opened the app".
 * Info severity: nothing is blocked on the admin, it is pipeline awareness.
 */
export const onUserSignedUp = onDocumentCreated(
  "users/{uid}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();

    const uid = event.params.uid;
    const accountType = (d.accountType as string | undefined) ?? "unknown";
    const fullName = (d.fullName as string | undefined) ?? "Someone";

    await writeAdminAlert({
      type: "user_signed_up",
      severity: "info",
      title: `New ${accountType} signed up`,
      body: `${fullName} created a ${accountType} account.`,
      targetCollection: "users",
      targetId: uid,
      actors: {tenantId: uid},
      meta: {
        accountType,
        phone: (d.phone as string | undefined) ?? "",
        email: (d.email as string | undefined) ?? "",
      },
    });
    logger.info("New-user admin alert raised", {uid, accountType});
  },
);

/**
 * Someone submitted identity documents and is waiting on a human.
 *
 * This is the one that actually blocks a user: an unverified landlord cannot
 * list, an unverified tenant cannot book, and nothing moves until an admin
 * reviews. Until now the ONLY signal was the pending count on the dashboard,
 * which requires an admin to already be looking.
 *
 * `onVerificationVerified` (verification_ops.ts) is the other half — it fires
 * after the decision. This fires when the decision becomes due.
 *
 * Warning severity, deliberately: it is actionable, so it belongs in the
 * attention banner, which filters out `info`.
 */
export const onVerificationSubmitted = onDocumentUpdated(
  "users/{uid}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const wasPending =
      (before.verificationStatus as string | undefined) === "pending";
    const isPending =
      (after.verificationStatus as string | undefined) === "pending";
    // Only the transition into pending. The users doc is rewritten for many
    // other reasons and would otherwise re-alert on every one of them.
    if (wasPending || !isPending) return;

    const uid = event.params.uid;
    const accountType = (after.accountType as string | undefined) ?? "user";
    const fullName = (after.fullName as string | undefined) ?? "A user";

    await writeAdminAlert({
      type: "verification_submitted",
      severity: "warning",
      title: "Verification waiting for review",
      body:
        `${fullName} (${accountType}) submitted identity documents. ` +
        "They are blocked until this is reviewed.",
      targetCollection: "users",
      targetId: uid,
      actors: {tenantId: uid},
      meta: {
        accountType,
        // Agents submit a guarantor too, which is a longer review.
        hasGuarantor: Boolean(after.guarantor),
      },
    });
    logger.info("Verification-submitted admin alert raised", {uid});
  },
);

/**
 * An inspection reached its end state: completed, and rated by the tenant.
 *
 * Walks the SAME per-inspection alert as the rest of the lifecycle
 * (`insplc_<id>`, opened in index.ts at request time) rather than spawning a
 * second feed row — one inspection, one alert, whatever stage it is at.
 *
 * The rating matters beyond bookkeeping: it is what backs the handler's
 * payment, so "completed but unrated" and "completed and rated" are genuinely
 * different states to an admin chasing a payout.
 */
export const onInspectionCompleted = onDocumentUpdated(
  "inspection_requests/{requestId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const becameCompleted =
      before.status !== "completed" && after.status === "completed";
    const becameRated =
      before.tenantRated !== true && after.tenantRated === true;
    if (!becameCompleted && !becameRated) return;

    const requestId = event.params.requestId;
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "a property";
    const tenantName = (after.tenantName as string | undefined) ?? "a tenant";
    const rated = after.tenantRated === true;

    await upsertAdminAlert(`insplc_${requestId}`, {
      type: "inspection_lifecycle",
      severity: "info",
      title: rated ? "Inspection completed and rated" : "Inspection completed",
      body:
        `The inspection of ${propertyTitle} for ${tenantName} is complete` +
        (rated ?
          " and has been rated — the handler's payout can proceed." :
          " but has not been rated yet."),
      targetCollection: "inspection_requests",
      targetId: requestId,
      actors: {
        tenantId: (after.tenantId as string | undefined) ?? undefined,
        agentId: (after.agentId as string | undefined) || undefined,
        landlordId: (after.landlordId as string | undefined) ?? undefined,
      },
      meta: {state: rated ? "completed_rated" : "completed"},
    });
    logger.info("Inspection completion admin alert updated", {
      requestId,
      rated,
    });
  },
);

/**
 * A tenant expressed interest in renting after a completed inspection — the
 * first step of the money funnel, and the point at which a landlord decision is
 * pending. Creation is server-only (`allow create: if false`), so every one of
 * these came through createRentalInterest.
 */
export const onRentalInterestCreated = onDocumentCreated(
  "rental_interests/{interestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();

    const interestId = event.params.interestId;
    const propertyTitle =
      (d.propertyTitle as string | undefined) ?? "a property";
    const tenantName = (d.tenantName as string | undefined) ?? "A tenant";
    const rentAmount = Number(d.rentAmount ?? 0);

    await writeAdminAlert({
      type: "rental_interest",
      severity: "info",
      title: "Tenant wants to rent",
      body:
        `${tenantName} expressed interest in ${propertyTitle} ` +
        `(₦${rentAmount.toLocaleString("en-NG")}). Waiting on the landlord.`,
      targetCollection: "rental_interests",
      targetId: interestId,
      actors: {
        tenantId: (d.tenantId as string | undefined) ?? undefined,
        landlordId: (d.landlordId as string | undefined) ?? undefined,
      },
      meta: {
        rentAmount,
        paymentAmount: Number(d.paymentAmount ?? 0),
        status: (d.status as string | undefined) ?? "pending_acceptance",
      },
    });
    logger.info("Rental-interest admin alert raised", {interestId});
  },
);

/**
 * A landlord attached the tenancy agreement, so the tenant now has terms to
 * accept. The tenant already gets a notification (index.ts, "Tenancy agreement
 * ready"); this is the admin's copy, because an agreement appearing — and then
 * sitting unaccepted — is the start of most tenancy disputes.
 *
 * Keyed per rental so a re-upload after a dispute updates the same row rather
 * than stacking.
 */
export const onAgreementReady = onDocumentUpdated(
  "active_rentals/{rentalId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const rentalIdForFlag = event.params.rentalId;

    // ── The tenant contradicts the landlord's declaration ──────────────
    // A landlord revising a live tenancy declares whether the rent changed.
    // The tenant, who must read the document to sign it, can say otherwise.
    // That contradiction is the whole point of the mechanism, so it is
    // critical and carries BOTH sides — an admin should not have to go
    // digging to put it to the landlord.
    if (
      before.tenantFlaggedRentChange !== true &&
      after.tenantFlaggedRentChange === true
    ) {
      const declaredRent = Number(after.agreementRevisionDeclaredRent ?? 0);
      const rentOnRecord = Number(after.rentAmount ?? 0);
      await upsertAdminAlert(`rentflag_${rentalIdForFlag}`, {
        type: "agreement_rent_mismatch",
        severity: "critical",
        title: "Tenant says a revision changes their rent",
        body:
          "The landlord declared a terms-only revision for " +
          `${(after.propertyTitle as string | undefined) ?? "a property"}, ` +
          `keeping rent at ₦${declaredRent || rentOnRecord}. ` +
          `${(after.tenantName as string | undefined) ?? "The tenant"} says ` +
          "the document changes it. Signing is blocked until this is " +
          "settled. Tenant's account: " +
          `"${(after.tenantDisputeReason as string | undefined) ?? ""}"`,
        targetCollection: "active_rentals",
        targetId: rentalIdForFlag,
        actors: {
          tenantId: (after.tenantId as string | undefined) ?? undefined,
          landlordId: (after.landlordId as string | undefined) ?? undefined,
        },
        meta: {
          declaredRent,
          rentOnRecord,
          state: "open",
        },
      });
      logger.info("Rent-mismatch admin alert raised", {
        rentalId: rentalIdForFlag,
      });
      return;
    }

    const urlBefore = (before.agreementUrl as string | undefined) ?? "";
    const urlAfter = (after.agreementUrl as string | undefined) ?? "";
    // Only a genuinely new or replaced document.
    if (!urlAfter || urlBefore === urlAfter) return;

    const rentalId = event.params.rentalId;
    const propertyTitle =
      (after.propertyTitle as string | undefined) ?? "a property";
    const tenantName = (after.tenantName as string | undefined) ?? "the tenant";
    const replaced = Boolean(urlBefore);

    await upsertAdminAlert(`agree_${rentalId}`, {
      type: "agreement_ready",
      severity: "info",
      title: replaced ?
        "Tenancy agreement replaced" :
        "Tenancy agreement ready",
      body:
        `The landlord ${replaced ? "re-uploaded" : "uploaded"} the agreement ` +
        `for ${propertyTitle}. ${tenantName} needs to accept it before rent ` +
        "can be paid.",
      targetCollection: "active_rentals",
      targetId: rentalId,
      actors: {
        tenantId: (after.tenantId as string | undefined) ?? undefined,
        landlordId: (after.landlordId as string | undefined) ?? undefined,
      },
      meta: {
        replaced,
        agreementStatus: (after.agreementStatus as string | undefined) ?? "",
      },
    });
    logger.info("Agreement-ready admin alert raised", {rentalId, replaced});
  },
);

/**
 * A landlord published a listing.
 *
 * Nothing watched `properties` before this: the admin dashboard surfaced new
 * listings only through its "docs pending review" count, which resolves a
 * grouped unit's status from its BUILDING. So a unit added under a building
 * whose ownership document was already verified resolved to `verified`, never
 * entered that count, and arrived with no trace anywhere — the only way to
 * find it was to already know it had been submitted.
 *
 * Raised for every new listing, with the body naming what (if anything) still
 * needs reviewing, since that is the part that differs.
 */
export const onPropertyCreated = onDocumentCreated(
  "properties/{propertyId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();

    const propertyId = event.params.propertyId;
    const title = (d.title as string | undefined) ?? "A property";
    const landlordName =
      (d.landlordName as string | undefined) ?? "A landlord";
    const docStatus = (d.ownershipDocStatus as string | undefined) ?? "none";
    const buildingId = (d.buildingId as string | undefined) ?? null;
    const city = (d.city as string | undefined) ?? "";
    const state = (d.state as string | undefined) ?? "";
    const where = [city, state].filter((s) => s.length > 0).join(", ");

    let needs: string;
    if (docStatus === "pending") {
      needs = "Its ownership document is waiting for review.";
    } else if (docStatus === "inherited") {
      needs =
        "It sits under a building whose document is already verified, " +
        "so only the listing itself needs a look.";
    } else {
      needs = "No ownership document was attached.";
    }

    await writeAdminAlert({
      type: "property_created",
      severity: "info",
      title: "New listing submitted",
      body:
        `${landlordName} listed "${title}"` +
        (where ? ` in ${where}` : "") + `. ${needs}`,
      targetCollection: "properties",
      targetId: propertyId,
      actors: {
        landlordId: (d.landlordId as string | undefined) ?? undefined,
      },
      meta: {
        ownershipDocStatus: docStatus,
        buildingId,
        rent: Number(d.rent ?? 0),
        state,
      },
    });
    logger.info("New-listing admin alert raised", {propertyId, docStatus});
  },
);
