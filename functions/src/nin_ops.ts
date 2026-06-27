/**
 * NIN submission (tenant/landlord/agent-facing).
 *
 *   submitNin
 *     Caller: any authenticated user, writing only to their OWN user doc.
 *     Validates the NIN server-side (exactly 11 digits — never trust the
 *     client regex), encrypts it with AES-256-GCM via nin_crypto, and
 *     writes the versioned ciphertext to users/{uid}.nin.
 *
 *     This replaces the old client-side `updateUserProfile({'nin': ...})`
 *     write, which stored the raw 11-digit number as plaintext. The raw
 *     NIN now exists on the client only momentarily, in transit over TLS
 *     to this function; it is never persisted in the clear.
 *
 * Design notes:
 *   - Auth guard is assertSelf(auth, auth.uid): enforces an authenticated
 *     caller and writes scoped to that caller's own document. There is no
 *     other party's uid in play (a user submits their own NIN), so this is
 *     the natural use of the helper — auth-present + self-scoped.
 *   - enforceAppCheck: false to match the debug-build workaround used by
 *     the payment and renewal callables (Play Integrity fails before a
 *     Play Store upload; re-enable across all callables post-submission).
 *   - The key is read from Secret Manager (NIN_ENCRYPTION_KEY) and passed
 *     into the pure crypto helper, mirroring how renewal_ops resolves
 *     paystackSecret.value() at the call site.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {defineSecret} from "firebase-functions/params";
import {assertSelf} from "./admin_helpers";
import {encryptNin} from "./nin_crypto";

const ninKey = defineSecret("NIN_ENCRYPTION_KEY");

const callableOptions = {
  secrets: [ninKey],
  timeoutSeconds: 30,
  enforceAppCheck: true, // M4: Flutter sends Play Integrity App Check tokens.
};

const NIN_PATTERN = /^\d{11}$/;

export const submitNin = onCall(callableOptions, async (request) => {
  assertSelf(request.auth, request.auth?.uid ?? "");
  const uid = request.auth!.uid;

  const raw = (request.data ?? {}) as {nin?: unknown};
  if (typeof raw.nin !== "string" || !NIN_PATTERN.test(raw.nin.trim())) {
    throw new HttpsError(
      "invalid-argument",
      "NIN must be exactly 11 digits.",
    );
  }
  const nin = raw.nin.trim();

  const ciphertext = encryptNin(nin, ninKey.value());

  const db = getFirestore();
  await db.collection("users").doc(uid).update({
    nin: ciphertext,
    updatedAt: FieldValue.serverTimestamp(),
  });

  logger.info("NIN stored (encrypted)", {uid});
  return {success: true};
});