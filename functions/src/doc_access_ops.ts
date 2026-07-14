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

  const data = (request.data ?? {}) as {collection?: string; docId?: string};
  const collection = data.collection ?? "";
  const docId = data.docId ?? "";
  if (!ALLOWED_COLLECTIONS.includes(collection) || !docId) {
    throw new HttpsError(
      "invalid-argument",
      "A valid collection ('active_rentals' | 'tenancy_links') and docId are required.",
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

  const agreementUrl = (doc.agreementUrl as string | undefined) ?? "";
  if (!agreementUrl) {
    throw new HttpsError("not-found", "No agreement is attached.");
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
