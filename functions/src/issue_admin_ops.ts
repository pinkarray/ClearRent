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

  const status = (x.status as string) ?? "open";
  const tenantId = (x.tenantId as string) ?? "";
  const landlordId = (x.landlordId as string) ?? "";
  const propertyId = (x.propertyId as string) ?? "";
  const propertyTitle = (x.propertyTitle as string) ?? "your property";
  const category = (x.category as string) ?? "maintenance";

  // A resolved issue has no one left to chase; a tenant nudge only makes
  // sense while a fix is awaiting their confirm/dispute.
  if (status === "resolved") {
    throw new HttpsError(
      "failed-precondition",
      "This issue is already resolved",
    );
  }
  if (target === "tenant" && status !== "pending_confirmation") {
    throw new HttpsError(
      "failed-precondition",
      "The tenant is only waited on while a fix is pending confirmation",
    );
  }

  const recipientId = target === "landlord" ? landlordId : tenantId;
  if (!recipientId) {
    throw new HttpsError(
      "failed-precondition",
      `No ${target} is attached to this issue`,
    );
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
  const body = note ? `${base} — ${note}` : base;

  const payload: Record<string, string> =
    target === "landlord" ?
      {
        route: "/landlord/issues",
        issueId,
        initialTab: LANDLORD_TAB[status] ?? "0",
        ...(propertyId ? {propertyId} : {}),
      } :
      {route: "/tenant/issue-history", issueId};

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

  logger.info("Issue nudge sent", {issueId, target, recipientId, status});
  return {ok: true};
});
