/**
 * The daily admin email.
 *
 * WHY THIS EXISTS AND WHY IT IS NOT PER-EVENT. Web push (admin_push_ops)
 * handles the interruptions: warning/critical alerts that need someone now.
 * This is the other half — the picture. One send a day covering what happened,
 * what is still outstanding, and who is doing what next. A mail per event would
 * bury the recipient and get filtered within a week, which is the failure mode
 * this deliberately avoids.
 *
 * Sent through Resend over plain fetch (Node 22 has it global) rather than
 * adding the SDK — one HTTP call does not justify a dependency, and the repo
 * already talks to Paystack the same way.
 *
 * QUERY SHAPE. Every read here is a single-field filter with the rest narrowed
 * in code. That is deliberate: the composite indexes for
 * `where(...) + orderBy(...)` are not provisioned in this project, and a
 * missing index makes Firestore throw rather than degrade — which is how the
 * app's Payments tab ended up permanently empty once.
 */

import {onSchedule} from "firebase-functions/v2/scheduler";
import {defineSecret, defineString} from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {getFirestore, Timestamp} from "firebase-admin/firestore";

const resendApiKey = defineSecret("RESEND_API_KEY");

/**
 * Where the digest goes.
 *
 * Deliberately NOT info@verealtytech.com: that address is bound to a test
 * principal (agent + admin), so a summary of the platform landing in it mixes
 * operational mail with a test identity's inbox. Override per-environment
 * rather than editing this default.
 */
const digestRecipient = defineString("ADMIN_DIGEST_TO", {
  default: "oredugbamide@gmail.com",
});

// CF runtime is UTC; the product is Nigeria-only (WAT = UTC+1, no DST).
const WAT_OFFSET_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * @param {number} ms Epoch millis.
 * @return {string} That instant's WAT calendar day as YYYY-MM-DD.
 */
function watDayKey(ms: number): string {
  return new Date(ms + WAT_OFFSET_MS).toISOString().slice(0, 10);
}

/**
 * @param {number} ms Epoch millis.
 * @return {string} Human day label, e.g. "Fri 1 Aug".
 */
function watDayLabel(ms: number): string {
  return new Date(ms + WAT_OFFSET_MS).toLocaleDateString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });
}

interface InspectionRow {
  dayKey: string;
  propertyTitle: string;
  slot: string;
  tenantName: string;
  handlerName: string;
}

interface AlertRow {
  type: string;
  title: string;
  body: string;
  severity: string;
}

/**
 * Escape text for HTML interpolation. Names and property titles are
 * user-supplied, so they cannot go into the template raw.
 *
 * @param {string} s Raw text.
 * @return {string} HTML-safe text.
 */
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * @param {string} heading Section title.
 * @param {string[]} lines Pre-escaped list items.
 * @param {string} empty What to say when there is nothing.
 * @return {string} An HTML section.
 */
function section(heading: string, lines: string[], empty: string): string {
  const inner = lines.length > 0 ?
    `<ul style="margin:8px 0 0;padding-left:20px">${
      lines.map((l) => `<li style="margin:4px 0">${l}</li>`).join("")
    }</ul>` :
    `<p style="margin:8px 0 0;color:#6B7280">${esc(empty)}</p>`;
  return `<h3 style="margin:24px 0 0;font-size:15px;color:#1A1A2E">${
    esc(heading)
  }</h3>${inner}`;
}

export const adminDailyDigestEmail = onSchedule(
  {
    schedule: "every day 07:00",
    timeZone: "Africa/Lagos",
    timeoutSeconds: 300,
    secrets: [resendApiKey],
  },
  async () => {
    const db = getFirestore();
    const now = Date.now();
    const todayKey = watDayKey(now);
    const tomorrowKey = watDayKey(now + DAY_MS);

    // ── Approved inspections, bucketed by WAT day ──
    // `approved` is transient so the set stays small; dates filtered in code.
    const inspectionSnap = await db
      .collection("inspection_requests")
      .where("status", "==", "approved")
      .get();

    const inspections: InspectionRow[] = [];
    for (const doc of inspectionSnap.docs) {
      const d = doc.data();
      const ts = d.requestedDate as Timestamp | undefined;
      if (!ts) continue;
      const ms = ts.toMillis();
      // Only look forward a week; older approved rows are noise here.
      if (ms < now - DAY_MS || ms > now + 7 * DAY_MS) continue;

      const agentName = (d.agentName as string | undefined) ?? "";
      const landlordName = (d.landlordName as string | undefined) ?? "";
      inspections.push({
        dayKey: watDayKey(ms),
        propertyTitle: (d.propertyTitle as string | undefined) ?? "a property",
        slot: (d.requestedTimeDisplay as string | undefined) ?? "",
        tenantName: (d.tenantName as string | undefined) ?? "a tenant",
        // The handler is the assigned agent, else the self-handling landlord.
        handlerName: agentName || landlordName || "UNASSIGNED",
      });
    }

    const fmtInspection = (i: InspectionRow) =>
      `<strong>${esc(i.propertyTitle)}</strong>${
        i.slot ? ` (${esc(i.slot)})` : ""
      } — ${esc(i.tenantName)} with ${esc(i.handlerName)}`;

    const today = inspections.filter((i) => i.dayKey === todayKey);
    const tomorrow = inspections.filter((i) => i.dayKey === tomorrowKey);
    const later = inspections
      .filter((i) => i.dayKey > tomorrowKey)
      .sort((a, b) => a.dayKey.localeCompare(b.dayKey));

    // ── What happened in the last 24h, from the alert feed ──
    const since = Timestamp.fromMillis(now - DAY_MS);
    const recentSnap = await db
      .collection("admin_alerts")
      .where("createdAt", ">=", since)
      .get();

    const byType = new Map<string, number>();
    for (const doc of recentSnap.docs) {
      const t = (doc.get("type") as string | undefined) ?? "other";
      byType.set(t, (byType.get(t) ?? 0) + 1);
    }

    // ── The backlog: actionable and still open, at any age ──
    const openSnap = await db
      .collection("admin_alerts")
      .where("status", "==", "open")
      .get();

    const outstanding: AlertRow[] = [];
    for (const doc of openSnap.docs) {
      const severity = (doc.get("severity") as string | undefined) ?? "info";
      // Info alerts are awareness, not a queue — they do not belong here.
      if (severity === "info") continue;
      outstanding.push({
        type: (doc.get("type") as string | undefined) ?? "",
        title: (doc.get("title") as string | undefined) ?? "",
        body: (doc.get("body") as string | undefined) ?? "",
        severity,
      });
    }
    outstanding.sort((a, b) =>
      (a.severity === "critical" ? 0 : 1) - (b.severity === "critical" ? 0 : 1)
    );

    const html = `
<div style="font-family:system-ui,-apple-system,Segoe UI,sans-serif;
  max-width:600px;margin:0 auto;color:#1A1A2E">
  <h2 style="margin:0;font-size:18px">ClearRent — ${esc(watDayLabel(now))}</h2>
  <p style="margin:4px 0 0;color:#6B7280;font-size:14px">
    ${outstanding.length} item${outstanding.length === 1 ? "" : "s"} need
    your attention · ${today.length} inspection${
  today.length === 1 ? "" : "s"} today
  </p>

  ${section(
    "Needs your attention",
    outstanding.map(
      (a) =>
        `<strong>${esc(a.title)}</strong><br>` +
        `<span style="color:#6B7280">${esc(a.body)}</span>`
    ),
    "Nothing outstanding. Everything actionable has been dealt with."
  )}

  ${section(
    "Today",
    today.map(fmtInspection),
    "No inspections scheduled today."
  )}

  ${section(
    "Tomorrow",
    tomorrow.map(fmtInspection),
    "Nothing scheduled tomorrow."
  )}

  ${section(
    "Rest of the week",
    later.map((i) => `${esc(watDayLabel(
      Date.parse(i.dayKey + "T00:00:00Z") - WAT_OFFSET_MS
    ))}: ${fmtInspection(i)}`),
    "Nothing else booked in the next seven days."
  )}

  ${section(
    "Last 24 hours",
    [...byType.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([type, count]) => `${count} × ${esc(type.replace(/_/g, " "))}`),
    "No activity in the last 24 hours."
  )}

  <p style="margin:28px 0 0;font-size:12px;color:#9CA3AF">
    Urgent items are also pushed to your devices as they happen. This summary
    is sent once a day.
  </p>
</div>`.trim();

    const subject =
      outstanding.length > 0 ?
        `ClearRent: ${outstanding.length} need${
          outstanding.length === 1 ? "s" : ""
        } attention, ${today.length} inspection${
          today.length === 1 ? "" : "s"} today` :
        `ClearRent: ${today.length} inspection${
          today.length === 1 ? "" : "s"} today`;

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey.value()}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "ClearRent <noreply@verealtytech.com>",
        to: [digestRecipient.value()],
        subject,
        html,
      }),
    });

    if (!res.ok) {
      // Throwing lets the scheduler retry, and surfaces a broken key in the
      // Functions log rather than failing silently every morning.
      const detail = await res.text();
      logger.error("Admin digest email failed", {
        status: res.status,
        detail: detail.slice(0, 500),
      });
      throw new Error(`Resend returned ${res.status}`);
    }

    logger.info("Admin digest email sent", {
      todayKey,
      outstanding: outstanding.length,
      today: today.length,
      tomorrow: tomorrow.length,
      later: later.length,
    });
  },
);
