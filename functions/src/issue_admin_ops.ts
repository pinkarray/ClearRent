/**
 * Admin-facing maintenance-issue operations.
 *
 * `nudgeIssueParty` lets an admin send an on-demand push to whichever party
 * is holding up a reported issue — usually the landlord sitting on a tenant's
 * open report, occasionally the tenant sitting on a fix awaiting confirmation.
 * The issue lifecycle already pushes on every status change (onIssueCreated /
 * onIssueUpdated in index.ts); what it cannot do is prod a party who simply
 * never acted. That is what this is for.
 *
 * Mirrors inspection_admin_ops.ts: notifications are admin-SDK-only writes, so
 * the nudge must go server-side, and an auto-id create (not
 * writeNotificationOnce) is deliberate — an admin pressing "nudge" twice SHOULD
 * send twice. Unlike the inspection nudge, the nudge is also stamped onto the
 * issue doc (`lastNudgedAt` / `nudgeCount`) so the next admin to open the issue
 * can see it has already been chased, instead of piling on.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {assertAdmin, writeAuditLog} from "./admin_helpers";

// App Check is left off to match the other admin-web callables (the admin
// dashboard has no App Check configured). Caller is still admin-gated.
const callableOptions = {
  timeoutSeconds: 30,
  enforceAppCheck: false,
};

type NudgeTarget = "landlord" | "tenant";

interface NudgeInput {
  issueId: string;
  target: NudgeTarget;
  /** Optional admin note appended to the canned reminder. */
  note: string;
}

/**
 * Validate + narrow the nudgeIssueParty payload.
 * @param {unknown} data Raw request.data.
 * @return {NudgeInput} The validated issueId, target and note.
 */
function validateInput(data: unknown): NudgeInput {
  const d = (data ?? {}) as Record<string, unknown>;
  const issueId = d.issueId;
  const target = d.target;
  const note = typeof d.note === "string" ? d.note.trim() : "";
  if (typeof issueId !== "string" || issueId.length === 0) {
    throw new HttpsError("invalid-argument", "issueId is required");
  }
  if (target !== "landlord" && target !== "tenant") {
    throw new HttpsError(
      "invalid-argument",
      "target must be 'landlord' or 'tenant'",
    );
  }
  return {issueId, target, note: note.slice(0, 300)};
}

// The landlord's issues screen opens on a tab per status; keep these in step
// with LandlordIssuesScreen's tab order (open / in progress / pending / done).
const LANDLORD_TAB: Record<string, string> = {
  open: "0",
  in_progress: "1",
  pending_confirmation: "2",
  resolved: "3",
};

interface BuiltNudge {
  recipientId: string;
  title: string;
  body: string;
  payload: Record<string, string>;
}

/**
 * Work out who to nudge on an issue and what to say, or why we can't.
 *
 * Shared by the single and bulk callables so both enforce the same rules:
 * a resolved issue has nobody left to chase, and the tenant is only waited
 * on while a fix is pending their confirmation.
 *
 * @param {Record<string, unknown>} x The issue doc data.
 * @param {string} issueId The issue doc id (deep-linked).
 * @param {NudgeTarget} target Which party to nudge.
 * @param {string} note Optional admin note appended to the reminder.
 * @return {BuiltNudge | {reason: string}} The notification, or a skip reason.
 */
function buildNudge(
  x: Record<string, unknown>,
  issueId: string,
  target: NudgeTarget,
  note: string,
): BuiltNudge | {reason: string} {
  const status = (x.status as string) ?? "open";
  const propertyTitle = (x.propertyTitle as string) ?? "your property";
  const category = (x.category as string) ?? "maintenance";
  const propertyId = (x.propertyId as string) ?? "";

  if (status === "resolved") {
    return {reason: "This issue is already resolved"};
  }
  if (target === "tenant" && status !== "pending_confirmation") {
    return {
      reason: "The tenant is only waited on while a fix is pending " +
        "confirmation",
    };
  }

  const recipientId =
    target === "landlord" ?
      ((x.landlordId as string) ?? "") :
      ((x.tenantId as string) ?? "");
  if (!recipientId) {
    return {reason: `No ${target} is attached to this issue`};
  }

  const title =
    target === "landlord" ?
      "Reminder: tenant issue needs attention" :
      "Reminder: please confirm the fix";
  const base =
    target === "landlord" ?
      `A ${category} issue at ${propertyTitle} is still waiting on you. ` +
        "Please open it and let your tenant know where things stand." :
      `Your landlord marked the ${category} issue at ${propertyTitle} as ` +
        "fixed. Please confirm or dispute it.";

  const payload: Record<string, string> =
    target === "landlord" ?
      {
        route: "/landlord/issues",
        issueId,
        initialTab: LANDLORD_TAB[status] ?? "0",
        ...(propertyId ? {propertyId} : {}),
      } :
      {route: "/tenant/issue-history", issueId};

  return {
    recipientId,
    title,
    body: note ? `${base} — ${note}` : base,
    payload,
  };
}

export const nudgeIssueParty = onCall(callableOptions, async (request) => {
  assertAdmin(request.auth);
  const adminUid = request.auth!.uid;
  const {issueId, target, note} = validateInput(request.data);

  const db = getFirestore();
  const ref = db.collection("issues").doc(issueId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Issue not found");
  }
  const x = snap.data() as Record<string, unknown>;

  const built = buildNudge(x, issueId, target, note);
  if ("reason" in built) {
    throw new HttpsError("failed-precondition", built.reason);
  }
  const {recipientId, title, body, payload} = built;

  await db.collection("notifications").add({
    userId: recipientId,
    type: "issue_nudge",
    title,
    body,
    payload,
    read: false,
    readAt: null,
    createdAt: FieldValue.serverTimestamp(),
  });

  // Stamp the issue so the dashboard can show "already chased 2h ago". This
  // is not a status change, so onIssueUpdated ignores it.
  await ref.update({
    lastNudgedAt: FieldValue.serverTimestamp(),
    lastNudgedTarget: target,
    lastNudgedBy: adminUid,
    nudgeCount: FieldValue.increment(1),
  });

  await writeAuditLog({
    actorId: adminUid,
    action: `nudge_issue_${target}`,
    targetCollection: "issues",
    targetId: issueId,
    amount: 0,
    paymentReference: "",
    paymentNote: note ?
      `Admin nudged ${target} (${recipientId}): ${note}` :
      `Admin nudged ${target} (${recipientId})`,
  });

  logger.info("Issue nudge sent", {issueId, target, recipientId});
  return {ok: true};
});

// ── nudgeIssuesBulk ──────────────────────────────────────────────────────────
// Chase a whole backlog in one press — the stale pending-confirmation queue is
// the motivating case (a dozen fixes nobody signed off on, twelve panel-opens
// to chase them one at a time).
//
// Bulk sending to real people warrants guards the single nudge doesn't need:
//   • the caller passes explicit issue ids (never a server-side "everything
//     matching" sweep) so what got hit is exactly what the admin was shown
//   • capped per call
//   • a cooldown skips anyone already nudged recently — an admin pressing the
//     single button twice is deliberate; a bulk press catching the same person
//     two days running is just noise
//   • per-issue failures are collected and reported, never abort the batch
//
// The recipient is derived per issue from its own status, so a mixed selection
// nudges the landlord on open work and the tenant on pending fixes.

const BULK_MAX = 50;
const BULK_COOLDOWN_MS = 20 * 60 * 60 * 1000; // ~a day, tolerant of drift

interface BulkInput {
  issueIds: string[];
  note: string;
}

/**
 * Validate + narrow the nudgeIssuesBulk payload.
 * @param {unknown} data Raw request.data.
 * @return {BulkInput} The validated issue ids and note.
 */
function validateBulkInput(data: unknown): BulkInput {
  const d = (data ?? {}) as Record<string, unknown>;
  const raw = d.issueIds;
  const note = typeof d.note === "string" ? d.note.trim() : "";
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new HttpsError("invalid-argument", "issueIds is required");
  }
  const issueIds = Array.from(
    new Set(raw.filter((v): v is string => typeof v === "string" && !!v)),
  );
  if (issueIds.length === 0) {
    throw new HttpsError("invalid-argument", "issueIds is required");
  }
  if (issueIds.length > BULK_MAX) {
    throw new HttpsError(
      "invalid-argument",
      `Too many issues at once — ${BULK_MAX} is the limit`,
    );
  }
  return {issueIds, note: note.slice(0, 300)};
}

/**
 * Which party an issue is waiting on, or null if nobody.
 * @param {string} status The issue's current status.
 * @return {NudgeTarget | null} Party to chase, or null when resolved.
 */
function waitingOn(status: string): NudgeTarget | null {
  if (status === "open" || status === "in_progress") return "landlord";
  if (status === "pending_confirmation") return "tenant";
  return null;
}

export const nudgeIssuesBulk = onCall(
  {...callableOptions, timeoutSeconds: 120},
  async (request) => {
    assertAdmin(request.auth);
    const adminUid = request.auth!.uid;
    const {issueIds, note} = validateBulkInput(request.data);

    const db = getFirestore();
    const now = Date.now();

    let sent = 0;
    const skipped: {issueId: string; reason: string}[] = [];

    for (const issueId of issueIds) {
      const ref = db.collection("issues").doc(issueId);
      try {
        const snap = await ref.get();
        if (!snap.exists) {
          skipped.push({issueId, reason: "Issue not found"});
          continue;
        }
        const x = snap.data() as Record<string, unknown>;

        // Re-read status per issue: the list the admin was looking at may be
        // seconds stale, and a tenant may have just confirmed.
        const target = waitingOn((x.status as string) ?? "open");
        if (!target) {
          skipped.push({issueId, reason: "Already resolved"});
          continue;
        }

        const last = x.lastNudgedAt as {toMillis?: () => number} | undefined;
        if (last?.toMillis && now - last.toMillis() < BULK_COOLDOWN_MS) {
          skipped.push({issueId, reason: "Nudged in the last day"});
          continue;
        }

        const built = buildNudge(x, issueId, target, note);
        if ("reason" in built) {
          skipped.push({issueId, reason: built.reason});
          continue;
        }

        await db.collection("notifications").add({
          userId: built.recipientId,
          type: "issue_nudge",
          title: built.title,
          body: built.body,
          payload: built.payload,
          read: false,
          readAt: null,
          createdAt: FieldValue.serverTimestamp(),
        });
        await ref.update({
          lastNudgedAt: FieldValue.serverTimestamp(),
          lastNudgedTarget: target,
          lastNudgedBy: adminUid,
          nudgeCount: FieldValue.increment(1),
        });
        sent++;
      } catch (e) {
        logger.error("Bulk nudge failed for an issue", {
          issueId,
          error: `${e}`,
        });
        skipped.push({issueId, reason: "Send failed"});
      }
    }

    // One audit row for the batch — fifty rows for one press buries the log.
    await writeAuditLog({
      actorId: adminUid,
      action: "nudge_issues_bulk",
      targetCollection: "issues",
      targetId: issueIds[0],
      amount: 0,
      paymentReference: "",
      paymentNote:
        `Admin bulk-nudged ${sent} of ${issueIds.length} issues` +
        (note ? `: ${note}` : ""),
    });

    logger.info("Bulk issue nudge complete", {
      requested: issueIds.length,
      sent,
      skipped: skipped.length,
    });
    return {ok: true, sent, skipped};
  },
);
