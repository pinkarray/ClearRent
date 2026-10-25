// ─────────────────────────────────────────────────────────────────────────────
// issue_reminders_ops.ts - keeps a fixed issue from dying in
// `pending_confirmation`.
//
// The lifecycle pushes the tenant exactly once, at the moment the landlord
// marks a fix ready (onIssueUpdated → "Fix ready - please confirm"). If the
// tenant never opens it, nothing fires again: the issue is neither resolved
// nor disputed, the landlord has no sign-off, and the report quietly rots.
//
//   issuePendingConfirmationReminders - 09:00 WAT daily, one escalating ladder:
//     day 3  → remind the tenant
//     day 7  → remind the tenant again, and tell the landlord it's unconfirmed
//     day 14 → raise an admin alert; a fortnight of silence needs a human
//
// This deliberately does NOT auto-resolve a stale pending issue. Silence is
// not confirmation - the tenant may have given up precisely because the fix
// didn't hold, and auto-closing would bury the very case that needs looking
// at. The ladder ends at an admin, not at a status change.
//
// Notifications use writeNotificationOnce with deterministic ids, so re-runs
// and catch-up runs after an outage never double-send.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, Timestamp} from "firebase-admin/firestore";
import {caretakerFor, writeNotificationOnce} from "./notification_helpers";
import {upsertAdminAlert} from "./admin_alerts";

const TENANT_ISSUES_ROUTE = "/tenant/issue-history";
const LANDLORD_ISSUES_ROUTE = "/landlord/issues";
// A caretaker keeps their own accountType, so the landlord issues screen
// (which queries by landlordId) would render empty for them. Property health,
// reached from here, is their equivalent workbench.
const CARETAKER_ROUTE = "/caretaker/properties";

// Pending-confirmation tab on LandlordIssuesScreen (0=Open,1=In Progress,
// 2=Pending, 3=Resolved).
const LANDLORD_PENDING_TAB = "2";

const DAY_MS = 24 * 60 * 60 * 1000;

// Escalation thresholds, in days waiting. Highest reached wins on any run, so
// a backlog item first seen at day 20 gets one alert - not all three rungs.
const STAGES = [3, 7, 14] as const;

export const issuePendingConfirmationReminders = onSchedule(
  {schedule: "every day 09:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();

    // Single-field equality - no composite index needed. Pending is a
    // transient state, so this set stays small.
    const snap = await db
      .collection("issues")
      .where("status", "==", "pending_confirmation")
      .get();

    let sent = 0;
    let escalated = 0;

    for (const doc of snap.docs) {
      const data = doc.data();

      // pendingConfirmationAt is stamped when the landlord flips the status;
      // fall back for docs written before that field existed.
      const ts = (data.pendingConfirmationAt ??
        data.updatedAt ??
        data.createdAt) as Timestamp | undefined;
      if (!ts?.toMillis) continue;

      const days = Math.floor((now - ts.toMillis()) / DAY_MS);
      const stage = [...STAGES].reverse().find((s) => days >= s);
      if (!stage) continue; // still inside the grace period

      const tenantId = data.tenantId as string | undefined;
      const landlordId = data.landlordId as string | undefined;
      const propertyTitle =
        (data.propertyTitle as string | undefined) ?? "your property";
      const category = (data.category as string | undefined) ?? "maintenance";
      const propertyId = (data.propertyId as string | undefined) ?? "";

      try {
        if (tenantId && (stage === 3 || stage === 7)) {
          const body =
            stage === 3 ?
              `Your landlord marked the ${category} issue at ` +
                `${propertyTitle} as fixed. Please confirm it's sorted - or ` +
                "tell us it isn't." :
              `The ${category} issue at ${propertyTitle} has been waiting ` +
                `${days} days for your confirmation. If it's still not ` +
                "right, say so and we'll re-open it.";
          if (
            await writeNotificationOnce(
              `issue_${doc.id}_pending_d${stage}_${tenantId}`,
              {
                userId: tenantId,
                type: "issue_pending_reminder",
                title: "Is this fixed?",
                body,
                payload: {route: TENANT_ISSUES_ROUTE, issueId: doc.id},
              },
            )
          ) {
            sent++;
          }
        }

        // From a week out the landlord deserves to know their fix is still
        // unsigned-off - they may want to chase the tenant themselves.
        if (landlordId && stage >= 7) {
          if (
            await writeNotificationOnce(
              `issue_${doc.id}_pending_d${stage}_${landlordId}`,
              {
                userId: landlordId,
                type: "issue_pending_reminder",
                title: "Fix still unconfirmed",
                body:
                  `Your tenant hasn't confirmed the ${category} fix at ` +
                  `${propertyTitle} after ${days} days.`,
                payload: {
                  route: LANDLORD_ISSUES_ROUTE,
                  issueId: doc.id,
                  initialTab: LANDLORD_PENDING_TAB,
                  ...(propertyId ? {propertyId} : {}),
                },
              },
            )
          ) {
            sent++;
          }
        }

        // The caretaker is who would actually chase the tenant, so the
        // unconfirmed-fix nudge reaches them too. Read only at stage >= 7, so
        // the sweep does not take a property read per issue every day.
        if (stage >= 7) {
          const caretakerId = await caretakerFor(propertyId);
          if (
            caretakerId &&
            caretakerId !== landlordId &&
            caretakerId !== tenantId &&
            (await writeNotificationOnce(
              `issue_${doc.id}_pending_d${stage}_${caretakerId}`,
              {
                userId: caretakerId,
                type: "issue_pending_reminder",
                title: "Fix still unconfirmed",
                body:
                  `The tenant hasn't confirmed the ${category} fix at ` +
                  `${propertyTitle} after ${days} days.`,
                payload: {
                  route: CARETAKER_ROUTE,
                  issueId: doc.id,
                  ...(propertyId ? {propertyId} : {}),
                },
              },
            ))
          ) {
            sent++;
          }
        }

        if (stage === 14) {
          // Upsert (not writeAdminAlert) so a long-stale issue keeps one
          // evolving row in the feed instead of a new one every sweep.
          await upsertAdminAlert(`issuepend_${doc.id}`, {
            type: "issue_pending_stale",
            severity: "warning",
            title: "Fix unconfirmed for weeks",
            body:
              `A ${category} issue at ${propertyTitle} has sat awaiting ` +
              `tenant confirmation for ${days} days. Neither party has ` +
              "closed it out.",
            targetCollection: "issues",
            targetId: doc.id,
            actors: {tenantId, landlordId},
            meta: {category, propertyTitle, daysWaiting: days},
          });
          escalated++;
        }
      } catch (e) {
        logger.error("Pending-confirmation reminder failed for an issue", {
          id: doc.id,
          error: `${e}`,
        });
      }
    }

    logger.info("Issue pending-confirmation sweep complete", {
      scanned: snap.size,
      sent,
      escalated,
    });
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// issueResponseReminders - chases a landlord who leaves an issue at `open` or
// `in_progress`. Before this, only `pending_confirmation` was chased: a High
// issue could sit at Open for a month and nobody would know.
//
// Days since the clock started, by the urgency the tenant picked:
//     high    1 → remind landlord   2 → warn landlord + caretaker   3 → admin
//     medium  3 →                   5 →                             7 →
//     low     7 →                  14 →                            21 →
//
// The clock is `chaseFrom` (server-written by onIssueUpdated) or, before any
// restart, `createdAt`. Acknowledging restarts it once; a disputed fix or a
// re-opened issue restarts it as a new round. firestore.rules keeps every
// field read here out of the parties' hands, or a landlord could move their
// own deadline.
//
// Hourly in the daytime so a High issue is chased within the hour it falls
// due, not up to a day late, without pushing anyone at 3am.
//
// The current rung is written to the issue as `landlordChase` so the tenant
// can see that their complaint is being chased, not just hope it is.
// ─────────────────────────────────────────────────────────────────────────────

const RESPONSE_RUNGS: Record<string, readonly [number, number, number]> = {
  high: [1, 2, 3],
  medium: [3, 5, 7],
  low: [7, 14, 21],
};

const TENANT_RUNG_TEXT = [
  "",
  "We've reminded your landlord about it.",
  "We've warned your landlord that it is overdue.",
  "ClearRent's team has been alerted and will follow up.",
];

export const issueResponseReminders = onSchedule(
  {schedule: "0 8-20 * * *", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();

    const snap = await db
      .collection("issues")
      .where("status", "in", ["open", "in_progress"])
      .get();

    let sent = 0;
    let escalated = 0;

    for (const doc of snap.docs) {
      const data = doc.data();
      const start = (data.chaseFrom ?? data.createdAt) as Timestamp | undefined;
      if (!start?.toMillis) continue;
      const round = start.toMillis();

      const priority = String(data.priority ?? "medium");
      const rungs = RESPONSE_RUNGS[priority] ?? RESPONSE_RUNGS.medium;
      const days = Math.floor((now - round) / DAY_MS);
      // Highest rung reached wins, so a backlog item gets one push, not three.
      const rung = rungs[2] <= days ? 3 : rungs[1] <= days ? 2 :
        rungs[0] <= days ? 1 : 0;
      if (rung === 0) continue;

      const prior = data.landlordChase as {rung?: number; round?: number} |
        undefined;
      if (prior?.round === round && (prior.rung ?? 0) >= rung) continue;

      const tenantId = data.tenantId as string | undefined;
      const landlordId = data.landlordId as string | undefined;
      const propertyTitle =
        (data.propertyTitle as string | undefined) ?? "your property";
      const category = (data.category as string | undefined) ?? "maintenance";
      const propertyId = (data.propertyId as string | undefined) ?? "";
      const urgent = priority === "high" ? "urgent " : "";
      const what = `the ${urgent}${category} issue at ${propertyTitle}`;
      const idBase = `issue_${doc.id}_resp_${round}_r${rung}`;

      try {
        if (landlordId) {
          if (
            await writeNotificationOnce(`${idBase}_${landlordId}`, {
              userId: landlordId,
              type: "issue_response_reminder",
              title: rung === 1 ? "Your tenant is waiting" :
                rung === 2 ? "Issue overdue" : "Issue escalated to ClearRent",
              body: rung === 1 ?
                `Please respond to ${what}. It was reported ${days} ` +
                  `day${days === 1 ? "" : "s"} ago.` :
                rung === 2 ?
                  `${what[0].toUpperCase()}${what.slice(1)} has had no ` +
                  `progress for ${days} days. Your tenant has been told.` :
                  `${what[0].toUpperCase()}${what.slice(1)} is ${days} days ` +
                  "old with no fix. ClearRent's team will be in touch.",
              payload: {
                route: LANDLORD_ISSUES_ROUTE,
                issueId: doc.id,
                initialTab: data.status === "in_progress" ? "1" : "0",
                ...(propertyId ? {propertyId} : {}),
              },
            })
          ) {
            sent++;
          }
        }

        // The caretaker is who would actually fix it, so they hear from the
        // warning onward. Read only then, to spare a property read per issue
        // on every hourly run.
        if (rung >= 2) {
          const caretakerId = await caretakerFor(propertyId);
          if (
            caretakerId &&
            caretakerId !== landlordId &&
            caretakerId !== tenantId &&
            (await writeNotificationOnce(`${idBase}_${caretakerId}`, {
              userId: caretakerId,
              type: "issue_response_reminder",
              title: "Issue overdue",
              body: `${what[0].toUpperCase()}${what.slice(1)} has had no ` +
                `progress for ${days} days.`,
              payload: {
                route: CARETAKER_ROUTE,
                issueId: doc.id,
                ...(propertyId ? {propertyId} : {}),
              },
            }))
          ) {
            sent++;
          }
        }

        if (tenantId) {
          if (
            await writeNotificationOnce(`${idBase}_${tenantId}`, {
              userId: tenantId,
              type: "issue_response_reminder",
              title: "We're chasing your issue",
              body: `${TENANT_RUNG_TEXT[rung]} (${category}, ` +
                `${propertyTitle})`,
              payload: {route: TENANT_ISSUES_ROUTE, issueId: doc.id},
            })
          ) {
            sent++;
          }
        }

        if (rung === 3) {
          await upsertAdminAlert(`issueslow_${doc.id}_${round}`, {
            type: "issue_unanswered",
            severity: priority === "high" ? "critical" : "warning",
            title: "Landlord not responding to an issue",
            body: `A ${priority}-urgency ${category} issue at ` +
              `${propertyTitle} has had no progress for ${days} days ` +
              "after two reminders.",
            targetCollection: "issues",
            targetId: doc.id,
            actors: {tenantId, landlordId},
            meta: {category, propertyTitle, priority, daysWaiting: days, round},
          });
          escalated++;
        }

        await doc.ref.update({
          landlordChase: {rung, round, at: Timestamp.now()},
        });
      } catch (e) {
        logger.error("Issue response reminder failed for an issue", {
          id: doc.id,
          error: `${e}`,
        });
      }
    }

    logger.info("Issue response sweep complete", {
      scanned: snap.size,
      sent,
      escalated,
    });
  },
);
