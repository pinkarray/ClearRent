import {onCall, HttpsError} from "firebase-functions/v2/https";
import {getFirestore} from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import {normalizeNigerianPhone} from "./caretaker_ops";

const callableOptions = {enforceAppCheck: true, timeoutSeconds: 30};

// Same budget as the caretaker lookup, and for the same reason: this resolves
// a phone number to a real person's name, so it is only ever a courtesy to a
// landlord who already knows who they are looking for.
const LOOKUP_MAX_PER_WINDOW = 20;
const LOOKUP_WINDOW_MS = 60 * 60 * 1000;

/**
 * Resolve a phone number to the tenant a landlord wants to link to their unit.
 *
 * Replaces the client-side `searchTenantsByName`, which ran an UNBOUNDED
 * `users.where('accountType','==','tenant').get()` and filtered on the device.
 * That pulled every tenant's whole user document — nin, phone, email,
 * incomeRange, employer — to any landlord who opened the sheet, and let a
 * two-letter query enumerate the user base by name.
 *
 * The guards mirror `lookupCaretakerCandidate`, deliberately: the caller must
 * already OWN the property being linked, so a lookup can only ride along with
 * a tenancy the landlord is entitled to create — never a bare phone-to-name
 * query — and it is rate limited per caller on top of that. Only the three
 * fields the link sheet actually renders are returned.
 */
export const lookupTenantByPhone = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  const data = (request.data ?? {}) as {phone?: string; propertyId?: string};

  const propertyId = (data.propertyId ?? "").trim();
  if (!propertyId) {
    throw new HttpsError("invalid-argument", "Choose a property first.");
  }

  const trimmed = (data.phone ?? "").trim();
  if (!trimmed) {
    throw new HttpsError(
      "invalid-argument",
      "Enter the phone number of the tenant you want to link.",
    );
  }
  const phoneLocal = normalizeNigerianPhone(trimmed);
  if (phoneLocal === null) {
    throw new HttpsError(
      "invalid-argument",
      "That isn't a valid Nigerian mobile number.",
    );
  }
  const phoneE164 = "+234" + phoneLocal.slice(1);

  const db = getFirestore();

  // Ownership BEFORE the lookup — the check is what stops this being a bare
  // phone-to-name query, so it must gate the read, not follow it.
  const propSnap = await db.collection("properties").doc(propertyId).get();
  if (!propSnap.exists || propSnap.get("landlordId") !== uid) {
    throw new HttpsError(
      "permission-denied",
      "You can only link a tenant to your own property.",
    );
  }

  const limitRef = db.collection("_rate_limits").doc(`tl_lookup_${uid}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(limitRef);
    const now = Date.now();
    const windowStart = (snap.get("windowStart") as number | undefined) ?? 0;
    const count = (snap.get("count") as number | undefined) ?? 0;
    const fresh = now - windowStart > LOOKUP_WINDOW_MS;
    if (!fresh && count >= LOOKUP_MAX_PER_WINDOW) {
      throw new HttpsError(
        "resource-exhausted",
        "You've looked up too many numbers just now. Try again later.",
      );
    }
    tx.set(limitRef, {
      windowStart: fresh ? now : windowStart,
      count: fresh ? 1 : count + 1,
    });
  });

  const found = await db
    .collection("users")
    .where("phone", "==", phoneE164)
    .limit(1)
    .get();
  if (found.empty) {
    throw new HttpsError(
      "not-found",
      "No ClearRent account uses that number. Ask them to sign up first.",
    );
  }
  const doc = found.docs[0];
  if (doc.id === uid) {
    throw new HttpsError(
      "failed-precondition",
      "You can't link yourself as your own tenant.",
    );
  }

  logger.info("Tenant link candidate resolved", {uid, propertyId});
  return {
    tenantId: doc.id,
    tenantName: (doc.get("fullName") as string | undefined) ?? "",
    isVerified: doc.get("verificationStatus") === "verified",
  };
});
