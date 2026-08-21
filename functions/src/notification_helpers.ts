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

/**
 * Write an activity-feed row with a deterministic ID.
 *
 * The feed is queried by `landlordId`, which is really "whose feed is this" —
 * `inspection_service._createActivity` writes the recipient's uid there
 * regardless of role, and the read rule accepts landlordId or actorId.
 *
 * Deterministic IDs because Firestore triggers are at-least-once and the Dart
 * side's `.add()` would duplicate a row on redelivery. Mirrors
 * `writeNotificationOnce`: false means a row was already there.
 *
 * @param {string} activityId Deterministic activity doc ID.
 * @param {object} data Feed fields.
 * @return {Promise<boolean>} True if written, false if it already existed.
 */
export async function writeActivityOnce(
  activityId: string,
  data: {
    landlordId: string;
    type: string;
    title: string;
    subtitle: string;
    propertyId?: string;
    propertyTitle?: string;
    actorId?: string;
    actorName?: string;
    relatedId?: string;
  },
): Promise<boolean> {
  const db = getFirestore();
  const ref = db.collection("activities").doc(activityId);
  try {
    await ref.create({
      ...data,
      // The Dart writer sets both; ActivityModel reads `subtitle`, some
      // older screens read `message`. Keep them in step.
      message: data.subtitle,
      userId: data.landlordId,
      isRead: false,
      createdAt: FieldValue.serverTimestamp(),
    });
    return true;
  } catch (err) {
    const code = (err as {code?: number | string})?.code;
    if (code === 6 || code === "already-exists") {
      logger.info("Activity already exists, skipping", {activityId});
      return false;
    }
    throw err;
  }
}

/**
 * The caretaker appointed to a property, if any.
 *
 * `properties.caretakerId` is written only by the caretaker callables, so its
 * presence already means the invitee accepted. Returns null on a missing or
 * unreadable property — a notification is never worth failing a trigger for.
 *
 * Lives here because both the issue trigger and the reminder sweep need it,
 * and a caretaker who hears about a new issue but not its reminders is worse
 * than one who hears about neither.
 *
 * @param {string} propertyId The property in question.
 * @return {Promise<string|null>} The caretaker's uid, or null.
 */
export async function caretakerFor(
  propertyId: string,
): Promise<string | null> {
  if (!propertyId) return null;
  try {
    const snap = await getFirestore()
      .collection("properties")
      .doc(propertyId)
      .get();
    const id = snap.get("caretakerId") as string | undefined;
    return id && id.length > 0 ? id : null;
  } catch (err) {
    logger.warn("Could not read caretakerId", {propertyId, err});
    return null;
  }
}
