/**
 * The furnished-stay move-in check.
 *
 * A furnished stay is paid in full up front, so the landlord's payout waits
 * for the tenant to see the place: 48 hours from move-in day (or from payment,
 * if that comes later) to confirm the place and its item list match the
 * listing, or to report what does not. Silence counts as a yes. A report holds
 * the payout until an admin resolves it. The hold is short on purpose: the
 * money is ours to hold only briefly.
 *
 * States on active_rentals/{id}.moveInCheck:
 *   awaiting -> confirmed (tenant)
 *   awaiting -> reported (tenant, before the deadline) -> resolved (admin)
 */
import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {assertAdmin, assertSelf, writeAuditLog} from "./admin_helpers";
import {writeNotificationOnce} from "./notification_helpers";
import {writeAdminAlertOnce} from "./admin_alerts";

export const MOVE_IN_CHECK_HOURS = 48;
const MAX_REPORT_CHARS = 2000;

/**
 * When the check closes: 48 hours from move-in day, or from payment if the
 * tenant paid after moving in.
 * @param {Date} leaseStart The move-in day (Lagos midnight).
 * @param {Date} paidAt When the rent was recorded.
 * @return {Date} The deadline.
 */
export function moveInCheckDeadline(leaseStart: Date, paidAt: Date): Date {
  const from = Math.max(leaseStart.getTime(), paidAt.getTime());
  return new Date(from + MOVE_IN_CHECK_HOURS * 3600_000);
}

/**
 * Why a furnished stay's landlord payout cannot go yet, or null when it can.
 * A yearly lease, or a rental from before the check existed, is never held.
 * @param {FirebaseFirestore.DocumentData} r The active_rentals document.
 * @param {Date} now Injected for tests.
 * @return {string | null} The admin-facing reason, or null.
 */
export function moveInHoldReason(
  r: FirebaseFirestore.DocumentData,
  now: Date = new Date(),
): string | null {
  if (r.stayType !== "furnished") return null;
  const check = r.moveInCheck;
  if (check === undefined || check === "confirmed" || check === "resolved") {
    return null;
  }
  if (check === "reported") {
    return "The tenant reported a problem at move-in. Resolve it before " +
      "paying the landlord.";
  }
  const deadline = (r.moveInCheckDeadline as Timestamp | undefined)?.toDate();
  if (check === "awaiting" && deadline && now.getTime() >= deadline.getTime()) {
    return null;
  }
  return "The tenant's 48-hour move-in check is still open" +
    (deadline ? ` (until ${deadline.toISOString()}).` : ".");
}

/**
 * The rentalId a callable was sent, or an invalid-argument error.
 * @param {unknown} rentalId As received.
 * @return {string} The active_rentals id.
 */
function readRentalId(rentalId: unknown): string {
  if (typeof rentalId !== "string" || rentalId.trim().length === 0) {
    throw new HttpsError("invalid-argument", "rentalId is required.");
  }
  return rentalId;
}

export const confirmMoveIn = onCall(
  {timeoutSeconds: 30},
  async (request) => {
    const rentalId = readRentalId(request.data?.rentalId);
    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(rentalId);

    const landlord = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const r = snap.data();
      if (!r) throw new HttpsError("not-found", "Rental not found.");
      assertSelf(request.auth, r.tenantId as string);
      if (r.moveInCheck === "confirmed") return null;
      if (r.moveInCheck !== "awaiting") {
        throw new HttpsError(
          "failed-precondition",
          "There is no move-in check open on this stay.",
        );
      }
      const start = (r.leaseStartDate as Timestamp | undefined)?.toDate();
      if (start && Date.now() < start.getTime()) {
        throw new HttpsError(
          "failed-precondition",
          "You can confirm once you have moved in.",
        );
      }
      tx.update(ref, {
        moveInCheck: "confirmed",
        moveInCheckedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return {
        landlordId: r.landlordId as string | undefined,
        title: (r.propertyTitle as string | undefined) || "your property",
      };
    });

    if (landlord?.landlordId) {
      await writeNotificationOnce(`movein_${rentalId}_confirmed`, {
        userId: landlord.landlordId,
        type: "move_in_confirmed",
        title: "Tenant confirmed move-in",
        body: `Your tenant confirmed ${landlord.title} and its items match ` +
          "the listing. Your payout can now be sent.",
        payload: {route: "/landlord/rentals"},
      });
    }
    return {success: true};
  },
);

export const reportMoveInProblem = onCall(
  {timeoutSeconds: 30},
  async (request) => {
    const rentalId = readRentalId(request.data?.rentalId);
    const text = typeof request.data?.text === "string" ?
      request.data.text.trim() :
      "";
    if (text.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Say what does not match the listing.",
      );
    }
    if (text.length > MAX_REPORT_CHARS) {
      throw new HttpsError(
        "invalid-argument",
        `Keep it under ${MAX_REPORT_CHARS} characters.`,
      );
    }
    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(rentalId);

    const r = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const data = snap.data();
      if (!data) throw new HttpsError("not-found", "Rental not found.");
      assertSelf(request.auth, data.tenantId as string);
      if (data.moveInCheck !== "awaiting") {
        throw new HttpsError(
          "failed-precondition",
          "There is no move-in check open on this stay.",
        );
      }
      const start = (data.leaseStartDate as Timestamp | undefined)?.toDate();
      if (start && Date.now() < start.getTime()) {
        throw new HttpsError(
          "failed-precondition",
          "You can report once you have moved in.",
        );
      }
      const deadline =
        (data.moveInCheckDeadline as Timestamp | undefined)?.toDate();
      if (deadline && Date.now() >= deadline.getTime()) {
        throw new HttpsError(
          "failed-precondition",
          "The 48-hour move-in check has closed. Report it as an issue " +
            "instead.",
        );
      }
      tx.update(ref, {
        moveInCheck: "reported",
        moveInReport: text,
        moveInCheckedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return data;
    });

    const title = (r.propertyTitle as string | undefined) || "a furnished stay";
    await writeAdminAlertOnce(`move_in_reported_${rentalId}`, {
      type: "move_in_reported",
      severity: "warning",
      title: "Move-in problem reported",
      body: `${r.tenantName || "The tenant"} says ${title} does not match ` +
        `the listing: ${text.slice(0, 300)}`,
      targetCollection: "active_rentals",
      targetId: rentalId,
      actors: {
        tenantId: r.tenantId as string | undefined,
        landlordId: r.landlordId as string | undefined,
      },
      meta: {landlordPayout: r.landlordPayout ?? null},
    });
    if (typeof r.landlordId === "string") {
      await writeNotificationOnce(`movein_${rentalId}_reported`, {
        userId: r.landlordId,
        type: "move_in_reported",
        title: "Tenant reported a move-in problem",
        body: `Your tenant says ${title} does not match the listing. ` +
          "ClearRent will contact you; your payout waits until it is settled.",
        payload: {route: "/landlord/rentals"},
      });
    }
    logger.info("Move-in problem reported", {rentalId});
    return {success: true};
  },
);

export const resolveMoveInReport = onCall(
  {timeoutSeconds: 30, enforceAppCheck: false},
  async (request) => {
    assertAdmin(request.auth);
    const rentalId = readRentalId(request.data?.rentalId);
    const note = typeof request.data?.note === "string" ?
      request.data.note.trim() :
      "";
    if (note.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Say how it was settled.",
      );
    }
    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(rentalId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const r = snap.data();
      if (!r) throw new HttpsError("not-found", "Rental not found.");
      if (r.moveInCheck !== "reported") {
        throw new HttpsError(
          "failed-precondition",
          "There is no open move-in report on this rental.",
        );
      }
      tx.update(ref, {
        moveInCheck: "resolved",
        moveInResolution: note,
        moveInResolvedBy: request.auth!.uid,
        moveInResolvedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
    await writeAuditLog({
      actorId: request.auth!.uid,
      action: "resolve_move_in_report",
      targetCollection: "active_rentals",
      targetId: rentalId,
      amount: 0,
      paymentReference: "",
      paymentNote: note,
    });
    return {success: true};
  },
);
