// ─────────────────────────────────────────────────────────────────────────────
// public_profile_ops.ts - the part of a user that other users may see.
//
// users/{uid} is readable by every signed-in account, and on prod it carries
// email, phone, employer, income, marital status, an agent's home
// coordinates, which property a tenant lives in, ID-document paths and payment
// references. Locking it to its owner breaks every screen that shows another
// person, so those screens read this mirror instead:
//
//   1. this trigger keeps public_profiles/{uid} in step with users/{uid};
//   2. the clients read public_profiles for anyone but themselves;
//   3. firestore.rules locks users/{uid} to owner + admin once
//      config/security.lockUserProfiles is true - flipped from the admin
//      dashboard when every supported app build reads the mirror, because
//      builds that predate it read users/{uid} directly.
//
// The allowlist is the whole point: a field is public only if it is named
// here. Phone is public for agents (a tenant must reach the handler on viewing
// day) and for anyone who switched on allowsCalls; home coordinates are
// rounded to ~1km, enough for distance and fee clusters, not for a doorstep.
// ─────────────────────────────────────────────────────────────────────────────

import {onDocumentWritten} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore} from "firebase-admin/firestore";

type Doc = FirebaseFirestore.DocumentData;

const COPIED = [
  "fullName", "fullNameLower", "profileImageUrl", "accountType",
  "isVerified", "verificationStatus", "rating", "totalRatings",
  "completedInspections", "totalInspections", "createdAt",
  // Handler (agent / landlord / caretaker) scheduling and coverage.
  "baseLocation", "serviceAreas", "availableDays", "availableTimeSlots",
  "blockedDates", "workMode", "allowsCalls",
  // Tenant search preferences: the agent leads feature runs on these.
  "budgetMin", "budgetMax", "preferredAreas",
] as const;

/**
 * Rounds a coordinate to 2 decimals, ~1.1km at the equator.
 *
 * @param {unknown} n The raw coordinate.
 * @return {number|undefined} The rounded value, or undefined if not a number.
 */
function round2(n: unknown): number | undefined {
  return typeof n === "number" ? Math.round(n * 100) / 100 : undefined;
}

/**
 * The public view of a user document.
 *
 * @param {Doc} d The users/{uid} data.
 * @return {Doc} Only the fields other users may read.
 */
export function publicProfileOf(d: Doc): Doc {
  const out: Doc = {};
  for (const k of COPIED) {
    if (d[k] !== undefined) out[k] = d[k];
  }
  if (d.phone && (d.accountType === "agent" || d.allowsCalls === true)) {
    out.phone = d.phone;
  }
  const lat = round2(d.baseLatitude);
  const lng = round2(d.baseLongitude);
  if (lat !== undefined && lng !== undefined) {
    out.baseLatitude = lat;
    out.baseLongitude = lng;
  }
  return out;
}

export const onUserWrittenPublicProfile = onDocumentWritten(
  "users/{uid}",
  async (event) => {
    const uid = event.params.uid;
    const ref = getFirestore().doc(`public_profiles/${uid}`);
    const after = event.data?.after.data();
    if (!after) {
      await ref.delete();
      return;
    }
    const next = publicProfileOf(after);
    const before = event.data?.before.data();
    // Most user writes (lastSeenAt, fcmTokens) touch nothing public.
    if (before &&
        JSON.stringify(publicProfileOf(before)) === JSON.stringify(next)) {
      return;
    }
    await ref.set(next);
    logger.info("Public profile refreshed", {uid});
  },
);
