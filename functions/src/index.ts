/**
 * Cloud Functions for ClearRent notifications.
 *
 * Listens for new docs in the `notifications` collection and sends FCM
 * pushes to all of the recipient's stored tokens. Stale tokens are removed
 * lazily on send failure.
 */

import {setGlobalOptions} from "firebase-functions";
import {onDocumentCreated} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";

initializeApp();
setGlobalOptions({maxInstances: 10, region: "us-central1"});

interface NotificationDoc {
  userId?: string;
  title?: string;
  body?: string;
  payload?: Record<string, string>;
}

export const onNotificationCreated = onDocumentCreated(
  "notifications/{notificationId}",
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("No snapshot on notification create event");
      return;
    }

    const notif = snap.data() as NotificationDoc;
    const {userId, title, body, payload} = notif;

    if (!userId || !title || !body) {
      logger.error("Notification doc missing required fields", {
        notificationId: event.params.notificationId,
        hasUserId: !!userId,
        hasTitle: !!title,
        hasBody: !!body,
      });
      return;
    }

    const db = getFirestore();
    const userSnap = await db.collection("users").doc(userId).get();
    if (!userSnap.exists) {
      logger.warn("Recipient user doc not found", {userId});
      return;
    }

    const tokens = (userSnap.get("fcmTokens") as string[] | undefined) ?? [];
    if (tokens.length === 0) {
      logger.info("User has no FCM tokens, skipping push", {userId});
      return;
    }

    // Stringify payload values — FCM data must be string-only.
    const data: Record<string, string> = {};
    if (payload) {
      for (const [k, v] of Object.entries(payload)) {
        data[k] = typeof v === "string" ? v : JSON.stringify(v);
      }
    }

    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {title, body},
      data,
    });

    logger.info("FCM send complete", {
      userId,
      successCount: response.successCount,
      failureCount: response.failureCount,
    });

    // Identify and remove invalid tokens.
    const invalidTokens: string[] = [];
    response.responses.forEach((resp, idx) => {
      if (resp.success) return;
      const code = resp.error?.code;
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token" ||
        code === "messaging/invalid-argument"
      ) {
        invalidTokens.push(tokens[idx]);
      } else if (resp.error) {
        logger.warn("FCM send error (token retained)", {
          token: tokens[idx].slice(0, 12),
          code,
          message: resp.error.message,
        });
      }
    });

    if (invalidTokens.length > 0) {
      await db.collection("users").doc(userId).update({
        fcmTokens: FieldValue.arrayRemove(...invalidTokens),
      });
      logger.info("Removed invalid FCM tokens", {
        userId,
        count: invalidTokens.length,
      });
    }
  },
);
