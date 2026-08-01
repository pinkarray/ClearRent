/**
 * Web push for admins.
 *
 * The gap this closes: `admin_alerts` was a dashboard-only feed. Nothing left
 * the browser, so an admin learned that a verification was waiting — or a
 * dispute had opened — only by having the dashboard open and looking at it.
 *
 * WHY A DEVICE REGISTRY RATHER THAN A USER QUERY. Admins are identified by the
 * custom claims `admin` / `superAdmin` (firestore.rules:10, admin_helpers.ts).
 * Custom claims live on the auth token, not in Firestore, so there is no query
 * that returns "all admins" — the only alternative is paginating `listUsers()`
 * on every alert, which is a full user-directory scan for a push. Instead each
 * admin's browser registers its own FCM token into `admin_devices/{uid}`, which
 * is one cheap read per alert and doubles as a view of who is actually
 * reachable.
 *
 * WHAT GETS PUSHED. Only `warning` and `critical`. `info` alerts (signups,
 * inspection lifecycle, rent payments, the daily digest) are pipeline
 * awareness, not interruptions — they belong in the feed and the daily digest
 * email, not on someone's lock screen at 2am. This is the same split the
 * attention banner already makes.
 */

import {onDocumentCreated} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";

/** Severities worth interrupting someone for. */
const PUSH_SEVERITIES = new Set(["warning", "critical"]);

interface AdminDevice {
  uid: string;
  tokens: string[];
}

/** The subset of an FCM per-token result this module reads. */
interface SendResult {
  success: boolean;
  error?: {code?: string};
}

/**
 * Every registered admin device.
 *
 * @return {Promise<AdminDevice[]>} One entry per admin with at least one token.
 */
async function adminDevices(): Promise<AdminDevice[]> {
  const db = getFirestore();
  const snap = await db.collection("admin_devices").get();
  const out: AdminDevice[] = [];
  for (const doc of snap.docs) {
    const tokens = (doc.get("tokens") as string[] | undefined) ?? [];
    if (tokens.length > 0) out.push({uid: doc.id, tokens});
  }
  return out;
}

/**
 * Drop tokens FCM has told us are dead, so a stale browser profile does not
 * accumulate failures forever. Mirrors the per-user cleanup in index.ts.
 *
 * @param {string} uid Admin uid whose device doc to prune.
 * @param {string[]} tokens Tokens that were sent to, in send order.
 * @param {SendResult[]} responses Per-token results, same order as tokens.
 * @return {Promise<void>}
 */
async function pruneTokens(
  uid: string,
  tokens: string[],
  responses: SendResult[],
): Promise<void> {
  const dead: string[] = [];
  responses.forEach((resp, idx) => {
    if (resp.success) return;
    const code = resp.error?.code;
    if (
      code === "messaging/registration-token-not-registered" ||
      code === "messaging/invalid-registration-token" ||
      code === "messaging/invalid-argument"
    ) {
      dead.push(tokens[idx]);
    }
  });
  if (dead.length === 0) return;

  await getFirestore()
    .collection("admin_devices")
    .doc(uid)
    .update({tokens: FieldValue.arrayRemove(...dead)});
  logger.info("Pruned dead admin tokens", {uid, count: dead.length});
}

export const onAdminAlertCreated = onDocumentCreated(
  "admin_alerts/{alertId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const alert = snap.data();

    const severity = (alert.severity as string | undefined) ?? "info";
    if (!PUSH_SEVERITIES.has(severity)) {
      logger.debug("Admin alert not push-worthy", {
        alertId: event.params.alertId,
        severity,
      });
      return;
    }

    const devices = await adminDevices();
    if (devices.length === 0) {
      logger.warn(
        "Actionable admin alert with no registered admin devices — " +
          "nobody was notified outside the dashboard",
        {alertId: event.params.alertId, type: alert.type},
      );
      return;
    }

    const title = (alert.title as string | undefined) ?? "ClearRent admin";
    const body = (alert.body as string | undefined) ?? "";

    // FCM data must be string-only. These drive the click-through target in
    // the service worker.
    const data: Record<string, string> = {
      alertId: event.params.alertId,
      type: (alert.type as string | undefined) ?? "",
      severity,
      targetCollection: (alert.targetCollection as string | undefined) ?? "",
      targetId: (alert.targetId as string | undefined) ?? "",
    };

    for (const device of devices) {
      try {
        const response = await getMessaging().sendEachForMulticast({
          tokens: device.tokens,
          notification: {title, body},
          data,
          // Urgency drives how aggressively the browser wakes to deliver;
          // the link is where a click lands.
          webpush: {
            headers: {Urgency: severity === "critical" ? "high" : "normal"},
            fcmOptions: {link: "/dashboard/alerts"},
          },
        });
        await pruneTokens(device.uid, device.tokens, response.responses);
        logger.info("Admin push sent", {
          uid: device.uid,
          successCount: response.successCount,
          failureCount: response.failureCount,
        });
      } catch (err) {
        // One admin's dead device must not stop the others being told.
        logger.error("Admin push failed for one device doc", {
          uid: device.uid,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  },
);
