// ─────────────────────────────────────────────────────────────────────────────
// account_ops.ts — user-initiated account deletion.
//
// Replaces the old client-side delete (auth_service.deleteAccount), which had
// two bugs:
//   1. It re-authenticated with email/password only, so phone-OTP users (the
//      majority) could never clear `requires-recent-login` and the delete
//      failed silently.
//   2. It deleted Firestore data BEFORE the auth account, so a failure on the
//      final auth.delete() left a half-deleted account that could still log in.
//
// Running server-side with the admin SDK fixes both: no re-auth is required to
// delete a user, and data + auth are removed in one server pass. The caller can
// only delete THEIR OWN account (uid is taken from the verified auth context,
// never from the payload).
//
// Three rules govern what happens to the user's data:
//   1. GUARD — anything mid-obligation (live tenancy, open inspection, rent
//      payment in flight) blocks the delete outright. The counterparty must not
//      be left holding a dangling link or a stranded payment.
//   2. CASCADE — records that only exist to serve this user are removed.
//   3. RETAIN + TOMBSTONE — financial records survive for audit, and
//      `deleted_accounts/{uid}` records who the uid was, so the admin dashboard
//      can render them as a deleted party rather than a live-looking ghost.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import {defineSecret} from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {getFirestore, Query, FieldValue} from "firebase-admin/firestore";
import {getAuth} from "firebase-admin/auth";
import {getStorage} from "firebase-admin/storage";
import {v2 as cloudinary} from "cloudinary";
import {
  ACTIVE_INSPECTION_STATUSES,
  revertPropertyToSelf,
} from "./agent_property_ops";

// Cloudinary credentials live in Secret Manager (set via
// `firebase functions:secrets:set`). The cloud name is public.
const CLOUDINARY_CLOUD_NAME = "den5t1dai";
const CLOUDINARY_API_KEY = defineSecret("CLOUDINARY_API_KEY");
const CLOUDINARY_API_SECRET = defineSecret("CLOUDINARY_API_SECRET");

const callableOptions = {
  enforceAppCheck: true, // M4: Flutter sends Play Integrity App Check tokens.
  timeoutSeconds: 120,
  secrets: [CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET],
};

// Delete every doc matched by a query, in batches (Firestore caps a batch at
// 500 writes). Returns the number deleted.
async function deleteByQuery(query: Query): Promise<number> {
  const snap = await query.get();
  if (snap.empty) return 0;
  const db = getFirestore();
  const docs = snap.docs;
  for (let i = 0; i < docs.length; i += 400) {
    const batch = db.batch();
    for (const doc of docs.slice(i, i + 400)) {
      batch.delete(doc.ref);
    }
    await batch.commit();
  }
  return docs.length;
}

export const deleteMyAccount = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  const db = getFirestore();

  logger.info("Account deletion started", {uid});

  // ── Safety guards: never delete an account that's mid-obligation. Applies to
  // every role — a landlord/tenant with a live tenancy, or anyone with an
  // in-flight inspection, must resolve it first (otherwise the counterparty is
  // stranded). All guards fetch by a single equality field (auto-indexed) and
  // filter status in code, so no composite index is required. ──
  const OCCUPYING = ["active", "expiring_soon", "grace_locked"];
  const occupies = (s: FirebaseFirestore.QuerySnapshot) =>
    s.docs.some((d) => OCCUPYING.includes(d.get("status")));
  // A confirmed tenancy OR a still-open invitation (pending) both count — the
  // link must be resolved (cancelled / declined) before the account is removed,
  // otherwise the counterparty is left with a dangling link.
  const hasOpenLink = (s: FirebaseFirestore.QuerySnapshot) =>
    s.docs.some((d) => ["pending", "confirmed"].includes(d.get("status")));

  const [arLandlord, arTenant, tlLandlord, tlTenant] = await Promise.all([
    db.collection("active_rentals").where("landlordId", "==", uid).get(),
    db.collection("active_rentals").where("tenantId", "==", uid).get(),
    db.collection("tenancy_links").where("landlordId", "==", uid).get(),
    db.collection("tenancy_links").where("tenantId", "==", uid).get(),
  ]);
  if (
    occupies(arLandlord) ||
    occupies(arTenant) ||
    hasOpenLink(tlLandlord) ||
    hasOpenLink(tlTenant)
  ) {
    throw new HttpsError(
      "failed-precondition",
      "You have an active tenancy or rental. End it before deleting your " +
        "account.",
    );
  }

  const hasActiveInsp = (s: FirebaseFirestore.QuerySnapshot) =>
    s.docs.some((d) =>
      ACTIVE_INSPECTION_STATUSES.includes(d.get("status")));
  const [inspTenant, inspAgent, inspLandlord] = await Promise.all([
    db.collection("inspection_requests").where("tenantId", "==", uid).get(),
    db.collection("inspection_requests").where("agentId", "==", uid).get(),
    db.collection("inspection_requests").where("landlordId", "==", uid).get(),
  ]);
  if (
    hasActiveInsp(inspTenant) ||
    hasActiveInsp(inspAgent) ||
    hasActiveInsp(inspLandlord)
  ) {
    throw new HttpsError(
      "failed-precondition",
      "You have a pending or scheduled inspection. Resolve it before " +
        "deleting your account.",
    );
  }

  // Money-in-flight guard. A rental interest past `payment_uploaded` means the
  // tenant has paid real money that has not yet resolved into a tenancy — the
  // exact state rentalInterestStrandSweep escalates to the admin Rent Attention
  // queue. Letting either party walk away here strands the payment against a
  // uid that no longer resolves: the admin sees a ghost row with a
  // denormalized name and no way to reach the human. The counterparty must
  // accept, or the tenant must be refunded, before the account can go.
  const IN_FLIGHT_INTEREST = ["payment_uploaded", "payment_verified"];
  const hasMoneyInFlight = (s: FirebaseFirestore.QuerySnapshot) =>
    s.docs.some((d) => IN_FLIGHT_INTEREST.includes(d.get("status")));
  const [riTenant, riLandlord] = await Promise.all([
    db.collection("rental_interests").where("tenantId", "==", uid).get(),
    db.collection("rental_interests").where("landlordId", "==", uid).get(),
  ]);
  if (hasMoneyInFlight(riTenant) || hasMoneyInFlight(riLandlord)) {
    throw new HttpsError(
      "failed-precondition",
      "You have a rent payment still being processed. It must be completed " +
        "or refunded before you can delete your account.",
    );
  }

  // Agent cascade: revert every property this user is the assigned agent on to
  // landlord-handled (agent fee preserved) and notify each landlord. Safe here
  // because we've confirmed there are no in-flight inspections above. These are
  // OTHER landlords' properties, so they're reverted, not deleted.
  const assignedProperties = await db
    .collection("properties")
    .where("assignedAgentId", "==", uid)
    .get();
  for (const propDoc of assignedProperties.docs) {
    await revertPropertyToSelf(propDoc.ref, propDoc.data(), {cause: "deleted"});
  }

  // Every collection the user touches, keyed by the ownership field(s). Mirrors
  // the old client-side list, plus rent_review_requests (added later).
  await deleteByQuery(
    db.collection("properties").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("activities").where("userId", "==", uid));
  await deleteByQuery(
    db.collection("activities").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("active_rentals").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("active_rentals").where("tenantId", "==", uid));
  await deleteByQuery(
    db.collection("tenancy_links").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("tenancy_links").where("tenantId", "==", uid));
  await deleteByQuery(
    db.collection("verification_requests").where("userId", "==", uid));
  await deleteByQuery(
    db.collection("inspection_requests").where("tenantId", "==", uid));
  await deleteByQuery(
    db.collection("inspection_requests").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("payments").where("userId", "==", uid));
  await deleteByQuery(
    db.collection("issues").where("tenantId", "==", uid));
  await deleteByQuery(
    db.collection("issues").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("notifications").where("userId", "==", uid));
  await deleteByQuery(
    db.collection("rent_review_requests").where("landlordId", "==", uid));
  await deleteByQuery(
    db.collection("rent_review_requests").where("tenantId", "==", uid));
  // The agent leg of an inspection — the tenant/landlord legs are queried
  // above, but an agent deleting their account used to leave every inspection
  // they ever handled pointing at a dead uid.
  await deleteByQuery(
    db.collection("inspection_requests").where("agentId", "==", uid));
  await deleteByQuery(
    db.collection("agent_ratings").where("agentId", "==", uid));
  await deleteByQuery(
    db.collection("agent_ratings").where("raterId", "==", uid));
  await deleteByQuery(
    db.collection("maintenance_logs").where("landlordId", "==", uid));
  // Buildings group a landlord's own units; their properties are deleted above,
  // so the grouping doc has nothing left to cover.
  await deleteByQuery(
    db.collection("buildings").where("landlordId", "==", uid));
  // Rental interests that never touched money — an expression of interest the
  // tenant abandoned, or one the landlord turned down. Explicit allowlist, not
  // a "not payment_*" test: `accepted` also means money changed hands and must
  // survive as a financial record, same as payment_uploaded/payment_verified.
  // Those states are blocked outright by the in-flight guard above; `accepted`
  // and pre-guard legacy rows are deliberately retained, and the
  // deleted_accounts tombstone below is what lets the admin queue render them
  // honestly instead of as a ghost.
  const NO_MONEY_INTEREST = ["interested", "pending", "rejected", "cancelled"];
  for (const field of ["tenantId", "landlordId"]) {
    const snap = await db
      .collection("rental_interests").where(field, "==", uid).get();
    const stale = snap.docs.filter(
      (d) => NO_MONEY_INTEREST.includes(d.get("status")));
    for (let i = 0; i < stale.length; i += 400) {
      const batch = db.batch();
      for (const doc of stale.slice(i, i + 400)) batch.delete(doc.ref);
      await batch.commit();
    }
  }

  // Conversations carry a `messages` subcollection — recursiveDelete clears the
  // subcollection and the parent doc together.
  const convSnap = await db
    .collection("conversations")
    .where("participants", "array-contains", uid)
    .get();
  for (const doc of convSnap.docs) {
    await db.recursiveDelete(doc.ref);
  }

  // Capture the identity fields BEFORE the profile goes — the tombstone is
  // written at the very end, once the account is definitively gone, but by then
  // there is nothing left to read them from.
  const userSnap = await db.collection("users").doc(uid).get();
  const tombstone = {
    uid,
    fullName: userSnap.get("fullName") ?? null,
    accountType: userSnap.get("accountType") ?? null,
  };

  // The user profile doc itself. recursiveDelete, NOT delete: `users/{uid}` has
  // `private/{docId}` (bank details) and `savedProperties/` subcollections, and
  // a plain doc delete leaves both behind, orphaned and unreachable.
  await db.recursiveDelete(db.collection("users").doc(uid));

  // Cloud Storage: verification documents (verification/{uid}/) and ownership
  // documents — C of O / deed (ownership/{uid}/) + agreements/{uid}/. (Profile
  // and property images are on Cloudinary, purged separately below.)
  // Non-fatal: nothing to delete is fine.
  try {
    const bucket = getStorage().bucket();
    await bucket.deleteFiles({prefix: `verification/${uid}/`});
    await bucket.deleteFiles({prefix: `ownership/${uid}/`});
    await bucket.deleteFiles({prefix: `agreements/${uid}/`});
  } catch (e) {
    logger.warn("Storage cleanup failed (non-fatal)", {uid, error: `${e}`});
  }

  // Cloudinary: purge the user's uploaded media. All uploads are namespaced by
  // uid — property images under clearrent/properties/{uid}/, property videos
  // under the same prefix (resource_type video), profile photos under
  // clearrent/profiles/{uid}/. delete_resources_by_prefix clears each.
  // Non-fatal: a missing prefix / no images is fine.
  try {
    cloudinary.config({
      cloud_name: CLOUDINARY_CLOUD_NAME,
      api_key: CLOUDINARY_API_KEY.value(),
      api_secret: CLOUDINARY_API_SECRET.value(),
    });
    await cloudinary.api.delete_resources_by_prefix(
      `clearrent/properties/${uid}/`, {resource_type: "image"});
    await cloudinary.api.delete_resources_by_prefix(
      `clearrent/properties/${uid}/`, {resource_type: "video"});
    await cloudinary.api.delete_resources_by_prefix(
      `clearrent/profiles/${uid}/`, {resource_type: "image"});
  } catch (e) {
    logger.warn("Cloudinary cleanup failed (non-fatal)", {uid, error: `${e}`});
  }

  logger.info("Firestore data deleted, removing auth account", {uid});

  // Auth account last. The admin SDK has no recent-login requirement.
  await getAuth().deleteUser(uid);

  // Tombstone, only now that the account is definitively gone. Financial
  // records (transactions, refunds, retained rental interests) outlive it for
  // audit, carrying a denormalized name and a uid that no longer resolves — so
  // the admin dashboard used to show a live-looking party who had long since
  // left. This row is where those screens look up "this uid was deleted, here's
  // who it was and when".
  //
  // Written after the delete, not before: an earlier write would mark a still
  // live account as deleted if any step above threw, and a viewer would see a
  // real user struck through. A missing tombstone degrades gracefully (the
  // screen falls back to the denormalized name); a false one does not.
  await db.collection("deleted_accounts").doc(uid).set({
    ...tombstone,
    deletedAt: FieldValue.serverTimestamp(),
  });

  logger.info("Account deletion complete", {uid});
  return {success: true};
});
