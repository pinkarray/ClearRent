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
import {writeAdminAlert} from "./admin_alerts";

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
