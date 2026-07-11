/**
 * Server-authoritative rating aggregation.
 *
 * Ratings were computed CLIENT-SIDE (inspection_service) as a plain mean and
 * written straight to the ratee's user doc — which meant (a) one 5★ rating
 * showed a perfect 5.0 off a single data point, and (b) any authed client
 * could write anyone's rating (security audit #2).
 *
 * This CF makes the rating server-owned. It fires when a tenant rates a
 * completed inspection (inspection_requests.tenantRated → true) and recomputes
 * the rated user's score from ALL their rated inspections, using a Bayesian
 * (weighted) average so a small number of ratings can't dominate:
 *
 *     adjusted = (C·m + sum) / (C + n)
 *
 * where m is a neutral prior mean and C is the prior weight (≈ how many
 * "average" ratings we assume before real ones arrive). One 5★ → 3.75; it
 * converges to the true mean as n grows. The raw mean is stored alongside for
 * reference/UI, and totalRatings (n) is surfaced so the count can be shown.
 *
 * The user doc's rating fields are locked to this CF in firestore.rules
 * (admin SDK bypasses rules).
 */

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

const PRIOR_MEAN = 3.5; // m — neutral starting point
const PRIOR_WEIGHT = 5; // C — how many prior "average" ratings to assume

/**
 * Recompute and persist a user's Bayesian rating from all their rated
 * inspections.
 * @param {string} userId The rated user (agent or landlord handler).
 * @return {Promise<void>}
 */
async function recomputeUserRating(userId: string): Promise<void> {
  const db = getFirestore();

  // ratedUserId is only written on rated inspections, so this returns exactly
  // this user's ratings — a single-field (auto-indexed) query, no composite
  // index required.
  const snap = await db
    .collection("inspection_requests")
    .where("ratedUserId", "==", userId)
    .get();

  let sum = 0;
  let n = 0;
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.tenantRated !== true) continue;
    const r = d.tenantRating;
    if (typeof r === "number" && r > 0) {
      sum += r;
      n++;
    }
  }

  const bayesian =
    n > 0 ? (PRIOR_WEIGHT * PRIOR_MEAN + sum) / (PRIOR_WEIGHT + n) : 0;
  const rawAvg = n > 0 ? sum / n : 0;

  await db.collection("users").doc(userId).set(
    {
      rating: Math.round(bayesian * 100) / 100,
      ratingRaw: Math.round(rawAvg * 100) / 100,
      totalRatings: n,
      updatedAt: FieldValue.serverTimestamp(),
    },
    {merge: true},
  );

  logger.info("User rating recomputed", {
    userId,
    totalRatings: n,
    bayesian: Math.round(bayesian * 100) / 100,
  });
}

export const onInspectionRated = onDocumentUpdated(
  "inspection_requests/{requestId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Fire only on the transition INTO rated.
    const wasRated = before.tenantRated === true;
    const isRated =
      after.tenantRated === true && typeof after.tenantRating === "number";
    if (wasRated || !isRated) return;

    const ratedUserId = after.ratedUserId;
    if (typeof ratedUserId !== "string" || ratedUserId.length === 0) {
      logger.warn("Rated inspection missing ratedUserId", {
        requestId: event.params.requestId,
      });
      return;
    }

    try {
      await recomputeUserRating(ratedUserId);
    } catch (err) {
      logger.error("Rating recompute failed", {
        ratedUserId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },
);
