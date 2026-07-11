// ─────────────────────────────────────────────────────────────────────────────
// inspection_reminders_ops.ts — day-of reminders so nobody forgets a scheduled
// inspection (a no-show is what turns into a dispute admin has to settle).
//
// Two schedulers, both notifying the tenant AND the handler (agent if assigned,
// else the landlord):
//
//   inspectionMorningReminders — 07:00 WAT daily. "Inspection today."
//   inspectionSoonReminders    — hourly, fires ~1h out. "Inspection soon."
//
// Both reuse writeNotificationOnce with deterministic IDs, so re-runs (or the
// overlapping hourly windows) never double-send. The onNotificationCreated
// trigger turns each notification doc into an FCM push.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, Timestamp, DocumentData} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

const TENANT_INSPECTIONS_ROUTE = "/tenant/inspections";
const AGENT_INSPECTIONS_ROUTE = "/agent/inspections";
const LANDLORD_INSPECTIONS_ROUTE = "/landlord/inspections";

// The Scheduled tab (index 1) on all three inspection screens.
const SCHEDULED_TAB = "1";

// The CF runtime is UTC; the app is Nigeria-only (WAT = UTC+1, no DST). Match
// the WAT wall-clock calendar day so "today" lines up with the user's day.
const WAT_OFFSET_MS = 60 * 60 * 1000;

/**
 * @param {number} ms Epoch millis.
 * @return {string} The instant's WAT calendar day as YYYY-MM-DD.
 */
function watDayKey(ms: number): string {
  return new Date(ms + WAT_OFFSET_MS).toISOString().slice(0, 10);
}

interface HandlerTarget {
  userId: string;
  route: string;
}

/**
 * Resolve the handler (whoever conducts the inspection) for a request: the
 * assigned agent if there is one, otherwise the landlord.
 *
 * @param {DocumentData} data Inspection request data.
 * @return {HandlerTarget | null} Handler user id + their inspections route.
 */
function resolveHandler(data: DocumentData): HandlerTarget | null {
  const agentId = data.agentId as string | undefined;
  if (typeof agentId === "string" && agentId.length > 0) {
    return {userId: agentId, route: AGENT_INSPECTIONS_ROUTE};
  }
  const landlordId = data.landlordId as string | undefined;
  if (typeof landlordId === "string" && landlordId.length > 0) {
    return {userId: landlordId, route: LANDLORD_INSPECTIONS_ROUTE};
  }
  return null;
}

/**
 * Write one reminder notification (deduped by notifId). Deep-links to the
 * recipient's Scheduled tab, highlighting the specific inspection.
 *
 * @param {string} notifId Deterministic id — dedupes re-runs.
 * @param {string} userId Recipient.
 * @param {string} route Recipient's inspections route.
 * @param {string} requestId Inspection request id (for the deep-link).
 * @param {string} title Push title.
 * @param {string} body Push body.
 * @return {Promise<boolean>} Whether a new doc was written.
 */
function sendReminder(
  notifId: string,
  userId: string,
  route: string,
  requestId: string,
  title: string,
  body: string,
): Promise<boolean> {
  return writeNotificationOnce(notifId, {
    userId,
    type: "inspection_reminder",
    title,
    body,
    payload: {route, param_requestId: requestId, initialTab: SCHEDULED_TAB},
  });
}

export const inspectionMorningReminders = onSchedule(
  {schedule: "every day 07:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const todayKey = watDayKey(Date.now());

    // Approved is a transient state (swept once the date passes), so this set
    // stays small. Single-field equality query — no composite index needed.
    const snap = await db
      .collection("inspection_requests")
      .where("status", "==", "approved")
      .get();

    let sent = 0;
    for (const doc of snap.docs) {
      const data = doc.data();
      const reqTs = data.requestedDate as Timestamp | undefined;
      if (!reqTs) continue;
      if (watDayKey(reqTs.toMillis()) !== todayKey) continue; // not today

      const title = (data.propertyTitle as string | undefined) ?? "a property";
      const slot = (data.requestedTimeDisplay as string | undefined) ?? "today";
      const tenantId = data.tenantId as string | undefined;
      const handler = resolveHandler(data);

      try {
        if (tenantId) {
          if (
            await sendReminder(
              `insp_${doc.id}_today_${todayKey}_${tenantId}`,
              tenantId,
              TENANT_INSPECTIONS_ROUTE,
              doc.id,
              "Inspection today",
              `Your inspection for ${title} is today (${slot}). See you there!`,
            )
          ) {
            sent++;
          }
        }
        if (handler) {
          if (
            await sendReminder(
              `insp_${doc.id}_today_${todayKey}_${handler.userId}`,
              handler.userId,
              handler.route,
              doc.id,
              "Inspection today",
              `You're showing ${title} today (${slot}). Please be on time.`,
            )
          ) {
            sent++;
          }
        }
      } catch (e) {
        logger.error("Morning reminder failed for a request", {
          id: doc.id,
          error: `${e}`,
        });
      }
    }

    logger.info("Inspection morning reminders complete", {sent});
  },
);

export const inspectionSoonReminders = onSchedule(
  {schedule: "every 1 hours", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();
    // Slots start on the hour (9/12/15/18 WAT) and this runs hourly, so the
    // run ~1h out lands in this window; the 2h-out run does not. The
    // deterministic id makes any overlap a no-op.
    const WINDOW_MIN = 0;
    // 100 minutes — tolerant of scheduler drift while catching the ~1h-out run.
    const WINDOW_MAX = 100 * 60 * 1000;

    const snap = await db
      .collection("inspection_requests")
      .where("status", "==", "approved")
      .get();

    let sent = 0;
    for (const doc of snap.docs) {
      const data = doc.data();
      const reqTs = data.requestedDate as Timestamp | undefined;
      if (!reqTs) continue;
      const msUntil = reqTs.toMillis() - now;
      if (msUntil <= WINDOW_MIN || msUntil > WINDOW_MAX) continue;

      const title = (data.propertyTitle as string | undefined) ?? "a property";
      const slot = (data.requestedTimeDisplay as string | undefined) ?? "soon";
      const tenantId = data.tenantId as string | undefined;
      const handler = resolveHandler(data);

      try {
        if (tenantId) {
          if (
            await sendReminder(
              `insp_${doc.id}_soon_${tenantId}`,
              tenantId,
              TENANT_INSPECTIONS_ROUTE,
              doc.id,
              "Inspection soon",
              `Your inspection for ${title} starts around ${slot} — ` +
                "time to head out.",
            )
          ) {
            sent++;
          }
        }
        if (handler) {
          if (
            await sendReminder(
              `insp_${doc.id}_soon_${handler.userId}`,
              handler.userId,
              handler.route,
              doc.id,
              "Inspection soon",
              `You're showing ${title} around ${slot} — time to head out.`,
            )
          ) {
            sent++;
          }
        }
      } catch (e) {
        logger.error("Soon reminder failed for a request", {
          id: doc.id,
          error: `${e}`,
        });
      }
    }

    logger.info("Inspection soon reminders complete", {sent});
  },
);
