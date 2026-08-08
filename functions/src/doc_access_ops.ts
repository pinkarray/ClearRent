// ─────────────────────────────────────────────────────────────────────────────
// doc_access_ops.ts — authorized access to private documents that can't be
// gated by Storage rules alone.
//
// getSignedAgreementUrl
//   A tenancy agreement is uploaded by the landlord to private Storage
//   (agreements/{landlordId}/…), but the TENANT must also be able to read it.
//   Storage rules can't authorize the tenant (they can't read Firestore to
//   check rental membership), so this callable does it server-side: it loads
//   the rental/link, verifies the caller is the landlord, the tenant, or an
//   admin, then returns a short-lived signed URL to the stored object.
//
//   Legacy agreements still on Cloudinary are public http URLs — those are
//   returned as-is (nothing to sign).
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore} from "firebase-admin/firestore";
import {getStorage} from "firebase-admin/storage";

const callableOptions = {
  enforceAppCheck: true, // M4: Flutter sends Play Integrity App Check tokens.
  timeoutSeconds: 30,
};

const ALLOWED_COLLECTIONS = ["active_rentals", "tenancy_links"];
const SIGNED_URL_TTL_MS = 15 * 60 * 1000; // 15 minutes

// The three documents a tenancy can carry, and the field each lives in.
//
//   original     — what the landlord sent, unsigned
//   tenantSigned — the copy the tenant printed, signed and uploaded
//   executed     — counter-signed by the landlord; the agreement of record
//
// Both signed copies are uploaded under their OWN uid's storage folder, so
// Storage rules deny the counterparty a direct read. Serving them is exactly
// what this callable exists for: it checks membership against the tenancy and
// then signs, which storage rules cannot do.
const AGREEMENT_FIELDS: Record<string, string> = {
  original: "agreementUrl",
  tenantSigned: "tenantSignedUrl",
  executed: "executedAgreementUrl",
};

export const getSignedAgreementUrl = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  // Read access mirrors canRead() in firestore.rules: full admins OR a
  // read-only viewer. Viewing a signed agreement is a read, so viewers pass.
  const canRead =
    request.auth.token?.admin === true ||
    request.auth.token?.superAdmin === true ||
    request.auth.token?.viewer === true;

  const data = (request.data ?? {}) as {
    collection?: string;
    docId?: string;
    which?: string;
  };
  const collection = data.collection ?? "";
  const docId = data.docId ?? "";
  // Which document on the tenancy to serve. Defaults to the original so every
  // existing caller keeps working unchanged.
  const which = data.which ?? "original";
  if (!ALLOWED_COLLECTIONS.includes(collection) || !docId) {
    throw new HttpsError(
      "invalid-argument",
      "A valid collection ('active_rentals' | 'tenancy_links') and docId are required.",
    );
  }
  // Plain lookup rather than Object.hasOwn — this codebase targets below
  // ES2022, where hasOwn does not exist.
  if (AGREEMENT_FIELDS[which] === undefined) {
    throw new HttpsError(
      "invalid-argument",
      "which must be 'original', 'tenantSigned' or 'executed'.",
    );
  }

  const db = getFirestore();
  const snap = await db.collection(collection).doc(docId).get();
  if (!snap.exists) {
    throw new HttpsError("not-found", `${collection}/${docId} not found.`);
  }
  const doc = snap.data()!;

  // Authorize: a party to the agreement (landlord or tenant) or an admin.
  const isParty =
    doc.landlordId === uid || doc.tenantId === uid;
  if (!isParty && !canRead) {
    throw new HttpsError(
      "permission-denied",
      "You are not a party to this agreement.",
    );
  }

  const field = AGREEMENT_FIELDS[which];
  const agreementUrl = (doc[field] as string | undefined) ?? "";
  if (!agreementUrl) {
    throw new HttpsError(
      "not-found",
      which === "original" ?
        "No agreement is attached." :
        "That copy has not been uploaded yet.",
    );
  }

  // Legacy Cloudinary docs are public http URLs — return as-is.
  if (/^https?:\/\//i.test(agreementUrl)) {
    return {url: agreementUrl};
  }

  // Private Storage path — mint a short-lived signed URL.
  try {
    const [url] = await getStorage()
      .bucket()
      .file(agreementUrl)
      .getSignedUrl({
        action: "read",
        expires: Date.now() + SIGNED_URL_TTL_MS,
      });
    return {url};
  } catch (e) {
    logger.error("Failed to sign agreement URL", {
      collection, docId, error: `${e}`,
    });
    throw new HttpsError("internal", "Could not generate the document link.");
  }
});
