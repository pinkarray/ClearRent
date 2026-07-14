/**
 * Daily "inspections today" digest for the admin dashboard.
 *
 * The party-facing reminders (inspection_reminders_ops) tell the tenant and
 * handler about their own inspection. This complements them with the admin's
 * bird's-eye view: at 07:00 WAT, one admin_alert summarising every inspection
 * scheduled for today, so the team knows what to watch and can nudge / step in
 * on no-shows before they become disputes.
 *
 * Reuses the same source query + WAT day math as inspectionMorningReminders,
 * and a deterministic alert id so a re-run never double-posts.
 */

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, Timestamp} from "firebase-admin/firestore";
import {writeAdminAlertOnce} from "./admin_alerts";

// CF runtime is UTC; the app is Nigeria-only (WAT = UTC+1, no DST).
const WAT_OFFSET_MS = 60 * 60 * 1000;

/**
 * @param {number} ms Epoch millis.
 * @return {string} The instant's WAT calendar day as YYYY-MM-DD.
 */
function watDayKey(ms: number): string {
  return new Date(ms + WAT_OFFSET_MS).toISOString().slice(0, 10);
}

interface DigestItem {
  inspectionId: string;
  propertyTitle: string;
  slot: string;
  tenantName: string;
  handlerName: string;
}

export const inspectionTodayAdminDigest = onSchedule(
  {schedule: "every day 07:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const todayKey = watDayKey(Date.now());

    // Same single-field query as the morning reminders — approved is transient
    // so the set stays small; the date is filtered in code.
    const snap = await db
      .collection("inspection_requests")
      .where("status", "==", "approved")
      .get();

    const items: DigestItem[] = [];
    for (const doc of snap.docs) {
      const data = doc.data();
      const reqTs = data.requestedDate as Timestamp | undefined;
      if (!reqTs) continue;
      if (watDayKey(reqTs.toMillis()) !== todayKey) continue;

      const agentName = (data.agentName as string | undefined) ?? "";
      const landlordName = (data.landlordName as string | undefined) ?? "";
      const pTitle = (data.propertyTitle as string | undefined) ?? "a property";
      items.push({
        inspectionId: doc.id,
        propertyTitle: pTitle,
        slot: (data.requestedTimeDisplay as string | undefined) ?? "today",
        tenantName: (data.tenantName as string | undefined) ?? "a tenant",
        // Handler is the agent if assigned, else the self-handling landlord.
        handlerName: agentName || landlordName || "unassigned",
      });
    }

    if (items.length === 0) {
      logger.info("No inspections today — skipping admin digest", {todayKey});
      return;
    }

    const written = await writeAdminAlertOnce(`digest_today_${todayKey}`, {
      type: "inspection_today_digest",
      severity: "info",
      title: `${items.length} inspection${items.length === 1 ? "" : "s"} today`,
      body: items
        .map((i) => `${i.propertyTitle} (${i.slot}) — ${i.handlerName}`)
        .join("; "),
      meta: {date: todayKey, count: items.length, items},
    });

    logger.info("Inspection-today admin digest processed", {
      todayKey,
      count: items.length,
      written,
    });
  },
);
