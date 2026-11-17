/**
 * Five-year retention of identity and transaction records after an account
 * is deleted.
 *
 * The Money Laundering (Prevention and Prohibition) Act 2022 requires a
 * reporting entity to keep customer identification and transaction records
 * for at least five years after the business relationship ends. deleteMyAccount
 * used to erase them on the spot, so it now copies them here first, and the
 * deletion aborts if the copy fails.
 *
 * Firestore: retained_records/{uid} (who, when, retainUntil) with the copies
 * under retained_records/{uid}/items/{collection}__{docId}. No rule matches
 * this collection, so only the server (admin SDK) can read or write it.
 * Storage: retained/{uid}/... copies of the identity, ownership and agreement
 * files; the catch-all storage rule denies every client.
 *
 * retentionPurgeSweep deletes both once retainUntil has passed.
 */
import * as logger from "firebase-functions/logger";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {
  getFirestore, FieldValue, Timestamp,
} from "firebase-admin/firestore";
import {getStorage} from "firebase-admin/storage";

export const RETENTION_YEARS = 5;

/** Collections holding identity or transaction records, by owner field. */
const RETAINED: Array<[string, string]> = [
  ["verification_requests", "userId"],
  ["payments", "userId"],
  ["rental_interests", "tenantId"],
  ["rental_interests", "landlordId"],
  ["active_rentals", "tenantId"],
  ["active_rentals", "landlordId"],
  ["active_rentals", "agentId"],
  ["inspection_requests", "tenantId"],
  ["inspection_requests", "landlordId"],
  ["inspection_requests", "agentId"],
  ["tenancy_links", "tenantId"],
  ["tenancy_links", "landlordId"],
];

/** Storage prefixes holding identity, ownership and agreement files. */
const RETAINED_PREFIXES = ["verification", "ownership", "agreements"];

/**
 * The date five years from now.
 * @param {Date} from Start of the retention period.
 * @return {Date} When the records may be deleted.
 */
export function retainUntil(from: Date): Date {
  const d = new Date(from);
  d.setFullYear(d.getFullYear() + RETENTION_YEARS);
  return d;
}

/**
 * Copy a user's identity and transaction records into the retention store.
 * Throws on any failure so the caller can refuse to delete.
 * @param {string} uid The account being deleted.
 * @return {Promise<number>} How many documents were copied.
 */
export async function archiveForRetention(uid: string): Promise<number> {
  const db = getFirestore();
  const root = db.collection("retained_records").doc(uid);
  const items = root.collection("items");

  const copies: Array<{id: string; data: Record<string, unknown>}> = [];
  const seen = new Set<string>();
  const add = (collection: string, docId: string,
    data: FirebaseFirestore.DocumentData) => {
    const id = `${collection}__${docId}`;
    if (seen.has(id)) return;
    seen.add(id);
    copies.push({id, data: {collection, docId, data}});
  };

  // The profile and its private subcollection (bank details).
  const user = await db.collection("users").doc(uid).get();
  if (user.exists) add("users", uid, user.data() ?? {});
  const priv = await db.collection("users").doc(uid)
    .collection("private").get();
  for (const d of priv.docs) add("users_private", d.id, d.data());

  for (const [collection, field] of RETAINED) {
    const snap = await db.collection(collection)
      .where(field, "==", uid).get();
    for (const d of snap.docs) add(collection, d.id, d.data());
  }

  for (let i = 0; i < copies.length; i += 400) {
    const batch = db.batch();
    for (const c of copies.slice(i, i + 400)) {
      batch.set(items.doc(c.id), {
        ...c.data,
        archivedAt: FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  const bucket = getStorage().bucket();
  let files = 0;
  for (const prefix of RETAINED_PREFIXES) {
    const [found] = await bucket.getFiles({prefix: `${prefix}/${uid}/`});
    for (const f of found) {
      await f.copy(bucket.file(`retained/${uid}/${f.name}`));
      files++;
    }
  }

  const now = new Date();
  await root.set({
    uid,
    fullName: user.get("fullName") ?? null,
    accountType: user.get("accountType") ?? null,
    email: user.get("email") ?? null,
    phone: user.get("phone") ?? null,
    deletedAt: Timestamp.fromDate(now),
    retainUntil: Timestamp.fromDate(retainUntil(now)),
    documents: copies.length,
    files,
  });
  logger.info("Records archived for retention", {
    uid, documents: copies.length, files,
  });
  return copies.length;
}

/** Deletes retained records once their five years are up. */
export const retentionPurgeSweep = onSchedule(
  {schedule: "every day 03:30", timeZone: "Africa/Lagos", timeoutSeconds: 540},
  async () => {
    const db = getFirestore();
    const due = await db.collection("retained_records")
      .where("retainUntil", "<=", Timestamp.now())
      .limit(50)
      .get();
    const bucket = getStorage().bucket();
    for (const d of due.docs) {
      await bucket.deleteFiles({prefix: `retained/${d.id}/`});
      await db.recursiveDelete(d.ref);
      logger.info("Retained records purged", {uid: d.id});
    }
  },
);
