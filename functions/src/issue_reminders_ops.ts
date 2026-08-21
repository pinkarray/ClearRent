// ─────────────────────────────────────────────────────────────────────────────
// issue_reminders_ops.ts — keeps a fixed issue from dying in
// `pending_confirmation`.
//
// The lifecycle pushes the tenant exactly once, at the moment the landlord
// marks a fix ready (onIssueUpdated → "Fix ready — please confirm"). If the
// tenant never opens it, nothing fires again: the issue is neither resolved
// nor disputed, the landlord has no sign-off, and the report quietly rots.
//
//   issuePendingConfirmationReminders — 09:00 WAT daily, one escalating ladder:
//     day 3  → remind the tenant
//     day 7  → remind the tenant again, and tell the landlord it's unconfirmed
//     day 14 → raise an admin alert; a fortnight of silence needs a human
//
// This deliberately does NOT auto-resolve a stale pending issue. Silence is
// not confirmation — the tenant may have given up precisely because the fix
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
// a backlog item first seen at day 20 gets one alert — not all three rungs.
const STAGES = [3, 7, 14] as const;

export const issuePendingConfirmationReminders = onSchedule(
  {schedule: "every day 09:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();

    // Single-field equality — no composite index needed. Pending is a
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
                `${propertyTitle} as fixed. Please confirm it's sorted — or ` +
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
        // unsigned-off — they may want to chase the tenant themselves.
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
