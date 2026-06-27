/**
 * Shared notification helper, extracted from index.ts so both index.ts
 * and admin_money_ops.ts can use it without a circular import between
 * the two CF entry modules. Mirrors the admin_helpers.ts pattern.
 */

import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

/**
 * Write a notification doc with a deterministic ID. Used for idempotent
 * creates from event triggers — avoids duplicate pushes when a Firestore
 * trigger re-fires for the same event.
 *
 * @param {string} notifId Deterministic notification doc ID.
 * @param {object} data Notification fields (userId, title, body,
 *   payload, type).
 * @return {Promise<boolean>} True if written, false if a doc with that
 *   ID already existed.
 */
export async function writeNotificationOnce(
  notifId: string,
  data: {
    userId: string;
    title: string;
    body: string;
    payload: Record<string, string>;
    type: string;
  },
): Promise<boolean> {
  const db = getFirestore();
  const ref = db.collection("notifications").doc(notifId);
  try {
    await ref.create({
      ...data,
      read: false,
      readAt: null,
      createdAt: FieldValue.serverTimestamp(),
    });
    return true;
  } catch (err) {
    const code = (err as {code?: number | string})?.code;
    // Firestore admin SDK throws ALREADY_EXISTS for duplicate create.
    if (code === 6 || code === "already-exists") {
      logger.info("Notification already exists, skipping", {notifId});
      return false;
    }
    throw err;
  }
}