// ─────────────────────────────────────────────────────────────────────────────
// admin_handover_ops.ts — the human in the move-out loop.
//
// Everything else in the handover flow is mechanical: the tenant records the
// condition, the landlord checks the unit and declares what they are keeping,
// and silence closes it after a week with the claim written down. None of that
// decides who was RIGHT, and it deliberately doesn't try to.
//
// A contested settlement is the one place a judgement has to be made, and it
// is made here by a person. Two consequences exist and neither fires
// automatically anywhere in the codebase:
//
//   suspension — a landlord may be barred from listing, either until a date or
//                until an admin lifts it.
//   rating     — a guilty finding may cost them reputation.
//
// Both are irreversible in practice (you cannot un-tell a market someone was
// suspended), and the evidence they rest on is uploaded photos nobody has
// independently verified. So they are admin verbs, always. The sweeps only
// ever record.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {assertAdmin, writeAuditLog} from "./admin_helpers";
import {writeNotificationOnce} from "./notification_helpers";

const callableOptions = {timeoutSeconds: 30, enforceAppCheck: false};

/**
 * @param {unknown} v Candidate value.
 * @param {string} name Field name for the error message.
 * @return {string} The trimmed string.
 */
function reqString(v: unknown, name: string): string {
  if (typeof v !== "string" || v.trim().length === 0) {
    throw new HttpsError(
      "invalid-argument", `${name} must be a non-empty string.`);
  }
  return v.trim();
}

interface ResolveHandoverInput {
  rentalId?: unknown;
  // Who the admin found for. 'tenant' means the deduction was not justified.
  finding?: unknown;
  note?: unknown;
  // Optional consequences, applied only on a finding against the landlord.
  ratingPenalty?: unknown;
  suspendListingDays?: unknown;
}

/**
 * Adjudicates a contested move-out settlement and releases the property.
 *
 * Closing the handover is unconditional: whoever was right, the unit has been
 * held off the market long enough and the argument about money does not need
 * to keep a property dark. What the finding changes is what gets recorded
 * against the landlord, not whether they can trade.
 */
export const adminResolveHandover = onCall(callableOptions, async (request) => {
  assertAdmin(request.auth);
  const adminUid = request.auth!.uid;
  const raw = (request.data ?? {}) as ResolveHandoverInput;

  const rentalId = reqString(raw.rentalId, "rentalId");
  const finding = reqString(raw.finding, "finding");
  if (!["landlord", "tenant", "inconclusive"].includes(finding)) {
    throw new HttpsError(
      "invalid-argument", "finding must be landlord|tenant|inconclusive.");
  }
  const note = reqString(raw.note, "note");

  // Consequences are only coherent when the landlord was found at fault. A
  // penalty attached to a finding in their favour is a mistake, not a policy.
  const penalty = Number(raw.ratingPenalty ?? 0);
  const suspendDays = Number(raw.suspendListingDays ?? 0);
  if (finding !== "tenant" && (penalty > 0 || suspendDays !== 0)) {
    throw new HttpsError(
      "invalid-argument",
      "Consequences require a finding for the tenant.",
    );
  }
  if (!Number.isFinite(penalty) || penalty < 0 || penalty > 5) {
    throw new HttpsError(
      "invalid-argument", "ratingPenalty must be between 0 and 5.");
  }
  // -1 is the explicit "until an admin lifts it" case; 0 means no suspension.
  if (!Number.isFinite(suspendDays) || suspendDays < -1) {
    throw new HttpsError(
      "invalid-argument", "suspendListingDays must be -1, 0, or positive.");
  }

  const db = getFirestore();
  const rentalRef = db.collection("active_rentals").doc(rentalId);
  const snap = await rentalRef.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", `active_rentals/${rentalId} not found.`);
  }
  const rental = snap.data()!;
  if (rental.handoverStage === "closed") {
    throw new HttpsError(
      "failed-precondition", "This handover is already closed.");
  }

  const landlordId = rental.landlordId as string | undefined;
  const tenantId = rental.tenantId as string | undefined;
  const propertyTitle =
    (rental.propertyTitle as string | undefined) ?? "the property";

  // Closing the stage is what releases the property — onHandoverClosed reacts
  // to it, so the gate is lifted by the same path as every other route out.
  await rentalRef.update({
    handoverStage: "closed",
    handoverClosedBy: "admin",
    handoverClosedAt: FieldValue.serverTimestamp(),
    handoverAdminFinding: finding,
    handoverAdminNote: note,
    handoverAdminBy: adminUid,
    updatedAt: FieldValue.serverTimestamp(),
  });

  let ratingBefore: number | null = null;
  if (landlordId) {
    // Any adjudicated contest is worth recording even when the landlord was
    // vindicated: a pattern of contests is itself information, and hiding the
    // ones they won would make the record flatter.
    await db
      .collection("users")
      .doc(landlordId)
      .collection("strikes")
      .doc(rentalId)
      .set(
        {
          type: "settlement_contested",
          rentalId,
          finding,
          note,
          tenantId: tenantId ?? null,
          propertyTitle,
          adminReviewed: true,
          reviewedBy: adminUid,
          reviewedAt: FieldValue.serverTimestamp(),
        },
        {merge: true},
      );

    if (penalty > 0 || suspendDays !== 0) {
      const userRef = db.collection("users").doc(landlordId);
      await db.runTransaction(async (tx) => {
        const uSnap = await tx.get(userRef);
        const current = Number(uSnap.get("rating") ?? 0);
        ratingBefore = current;
        const update: Record<string, unknown> = {
          updatedAt: FieldValue.serverTimestamp(),
        };
        if (penalty > 0) {
          // Clamped at zero, and the previous value goes to the audit log so
          // the penalty can be reversed with a real number rather than a guess.
          update.rating = Math.max(0, current - penalty);
          update.ratingPenaltyAt = FieldValue.serverTimestamp();
        }
        if (suspendDays === -1) {
          update.listingSuspended = true;
          update.listingSuspendedUntil = null;
        } else if (suspendDays > 0) {
          update.listingSuspended = true;
          update.listingSuspendedUntil = Timestamp.fromMillis(
            Date.now() + suspendDays * 24 * 60 * 60 * 1000,
          );
        }
        update.listingSuspendedReason = note;
        tx.set(userRef, update, {merge: true});
      });
    }

    await writeNotificationOnce(`handover_admin_L_${rentalId}`, {
      userId: landlordId,
      type: "handover_resolved",
      title: "Move-out dispute resolved",
      body:
        "ClearRent reviewed the caution-deposit dispute for " +
        `${propertyTitle}. ${note} You can list the property again.`,
      payload: {route: "/landlord/rentals", rentalId},
    });
  }

  if (tenantId) {
    await writeNotificationOnce(`handover_admin_T_${rentalId}`, {
      userId: tenantId,
      type: "handover_resolved",
      title: "Your deposit dispute was reviewed",
      body: `ClearRent reviewed your dispute over ${propertyTitle}. ${note}`,
      payload: {route: "/tenant/my-rentals", rentalId},
    });
  }

  const auditLogId = await writeAuditLog({
    actorId: adminUid,
    action: `admin_handover_${finding}`,
    targetCollection: "active_rentals",
    targetId: rentalId,
    amount: Number(rental.cautionDeductionAmount ?? 0),
    paymentReference: "handover_resolve",
    paymentNote:
      `${note}` +
      (penalty > 0 ? ` | rating ${ratingBefore} -${penalty}` : "") +
      (suspendDays !== 0 ? ` | suspended ${suspendDays}d` : ""),
  });

  logger.info("Handover adjudicated", {
    rentalId, finding, penalty, suspendDays, adminUid,
  });
  return {success: true, auditLogId};
});

interface SuspensionInput {
  landlordId?: unknown;
  suspend?: unknown;
  days?: unknown;
  reason?: unknown;
}

/**
 * Suspends or reinstates a landlord's ability to list.
 *
 * Separate from adjudication because the two are not the same decision: a
 * suspension may follow a pattern of strikes across several tenancies rather
 * than any single contested one, and lifting a suspension is not a finding
 * about anything.
 */
export const adminSetListingSuspension = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const adminUid = request.auth!.uid;
    const raw = (request.data ?? {}) as SuspensionInput;

    const landlordId = reqString(raw.landlordId, "landlordId");
    const suspend = raw.suspend === true;
    const reason = reqString(raw.reason, "reason");
    const days = Number(raw.days ?? -1);
    if (suspend && (!Number.isFinite(days) || days < -1 || days === 0)) {
      throw new HttpsError(
        "invalid-argument", "days must be -1 (indefinite) or positive.");
    }

    const db = getFirestore();
    const userRef = db.collection("users").doc(landlordId);
    if (!(await userRef.get()).exists) {
      throw new HttpsError("not-found", `users/${landlordId} not found.`);
    }

    await userRef.set(
      suspend ?
        {
          listingSuspended: true,
          listingSuspendedUntil: days > 0 ?
            Timestamp.fromMillis(Date.now() + days * 24 * 60 * 60 * 1000) :
            null,
          listingSuspendedReason: reason,
          listingSuspendedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        } :
        {
          listingSuspended: false,
          listingSuspendedUntil: null,
          listingSuspendedReason: null,
          updatedAt: FieldValue.serverTimestamp(),
        },
      {merge: true},
    );

    await writeNotificationOnce(
      `listing_suspension_${landlordId}_${Date.now()}`,
      {
        userId: landlordId,
        type: "listing_suspension",
        title: suspend ? "Listing suspended" : "Listing reinstated",
        body: suspend ?
          `You cannot publish new listings. ${reason}` :
          `You can publish listings again. ${reason}`,
        payload: {route: "/landlord/properties"},
      },
    );

    const auditLogId = await writeAuditLog({
      actorId: adminUid,
      action: suspend ? "admin_listing_suspend" : "admin_listing_reinstate",
      targetCollection: "users",
      targetId: landlordId,
      amount: 0,
      paymentReference: "listing_suspension",
      paymentNote: `${reason}${suspend ? ` | ${days}d` : ""}`,
    });

    logger.info("Listing suspension changed", {
      landlordId, suspend, days, adminUid,
    });
    return {success: true, auditLogId};
  },
);
