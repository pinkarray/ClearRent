// ─────────────────────────────────────────────────────────────────────────────
// landlord_record_ops.ts - the public side of how a landlord treats tenants.
//
// Two records, both server-written on users/{landlordId} and copied to
// public_profiles by its allowlist:
//
//   issueRecord {received, answeredInTime, escalated}
//     received        a VERIFIED issue was filed against them
//     answeredInTime  their first response came before the admin rung
//     escalated       an issue reached ClearRent unanswered (rung 3)
//
//   landlordRating / landlordRatingCount
//     stars a tenant gave when their tenancy ENDED, one per tenancy
//     (rateLandlord). Not the handler rating from inspections, which is
//     users.rating.
//
// Whether listings SHOW either is an admin switch (config/features
// publicLandlordRecord / publicLandlordRatings). The data accrues regardless,
// so switching on shows the full history, not a fresh start.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

const ENDED = ["ended_by_tenant", "ended_by_landlord"];

/**
 * Adds one to a landlord's issue record.
 *
 * @param {string} landlordId The landlord.
 * @param {string} field received | answeredInTime | escalated.
 * @return {Promise<void>}
 */
export async function bumpIssueRecord(
  landlordId: string,
  field: "received" | "answeredInTime" | "escalated",
): Promise<void> {
  await getFirestore().doc(`users/${landlordId}`).set(
    {issueRecord: {[field]: FieldValue.increment(1)}},
    {merge: true},
  );
}

export const rateLandlord = onCall(
  {timeoutSeconds: 30},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
    const data = (request.data ?? {}) as {
      rentalId?: unknown; stars?: unknown; comment?: unknown;
    };
    const rentalId = typeof data.rentalId === "string" ? data.rentalId : "";
    const stars = Number(data.stars);
    const comment = typeof data.comment === "string" ?
      data.comment.trim().slice(0, 500) : "";
    if (!rentalId || !Number.isInteger(stars) || stars < 1 || stars > 5) {
      throw new HttpsError(
        "invalid-argument", "A tenancy and 1 to 5 stars are required.");
    }

    const db = getFirestore();
    const rentalRef = db.doc(`active_rentals/${rentalId}`);
    const reviewRef = db.doc(`landlord_reviews/${rentalId}`);

    const landlordId = await db.runTransaction(async (tx) => {
      const rental = await tx.get(rentalRef);
      if (!rental.exists || rental.get("tenantId") !== uid) {
        throw new HttpsError(
          "permission-denied", "Only the tenant of this tenancy can rate it.");
      }
      if (!ENDED.includes(String(rental.get("status")))) {
        throw new HttpsError(
          "failed-precondition",
          "You can rate the landlord once you move out.");
      }
      if ((await tx.get(reviewRef)).exists) {
        throw new HttpsError(
          "already-exists", "You have already rated this tenancy.");
      }
      const lid = String(rental.get("landlordId") ?? "");
      const userRef = db.doc(`users/${lid}`);
      const user = await tx.get(userRef);
      const sum = Number(user.get("landlordRatingSum") ?? 0) + stars;
      const count = Number(user.get("landlordRatingCount") ?? 0) + 1;

      tx.create(reviewRef, {
        landlordId: lid,
        tenantId: uid,
        propertyId: rental.get("propertyId") ?? null,
        propertyTitle: rental.get("propertyTitle") ?? null,
        stars,
        comment,
        createdAt: FieldValue.serverTimestamp(),
      });
      tx.set(userRef, {
        landlordRatingSum: sum,
        landlordRatingCount: count,
        landlordRating: Math.round((sum / count) * 10) / 10,
      }, {merge: true});
      return lid;
    });

    logger.info("Landlord rated", {rentalId, landlordId, stars});
    return {success: true};
  },
);
