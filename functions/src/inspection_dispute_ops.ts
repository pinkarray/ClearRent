/**
 * Tenant-initiated inspection dispute.
 *
 * The rating widget was the tenant's only post-inspection action, and it
 * reaches no admin. This callable is the missing on-ramp into the admin review
 * queue: a tenant who was wronged (misrepresented listing, handler no-show,
 * unprofessional conduct, safety issue, or a plain refund request) files a
 * dispute that (a) flags the inspection, (b) raises an admin_alert the web
 * dashboard sees, and (c) leaves an audit trail — WITHOUT letting the tenant
 * conjure their own refund. The admin decides the outcome from the queue via
 * adminResolveInspection (refund / complete / dismiss).
 *
 * Anti-collusion: we do NOT notify the accused agent/landlord here. They learn
 * of it only when the admin acts (the existing refund/complete notifications),
 * so a colluding pair can't align a cover story and the tenant isn't exposed to
 * retaliation before an admin steps in.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {assertSelf, writeAuditLog} from "./admin_helpers";
import {writeAdminAlert, AlertSeverity} from "./admin_alerts";

// App Check left off to match the other inspection callables in this codebase.
const callOpts = {timeoutSeconds: 30, enforceAppCheck: false};

const CATEGORIES = [
  "misrepresented",
  "no_show",
  "unprofessional",
  "safety",
  "refund_request",
] as const;
type Category = (typeof CATEGORIES)[number];

// Human labels for the alert body / dashboard.
const CATEGORY_LABEL: Record<Category, string> = {
  misrepresented: "Property was misrepresented",
  no_show: "Handler didn't show up",
  unprofessional: "Unprofessional conduct",
  safety: "Safety concern",
  refund_request: "Refund request",
};

// A dispute can only be raised on an inspection in one of these states. A
// completed inspection keeps its status (don't corrupt completed accounting);
// an approved (day-of) one is moved into the admin queue below.
const DISPUTABLE_STATUSES = ["approved", "completed", "awaitingOutcome"];

interface DisputeInput {
  requestId?: unknown;
  category?: unknown;
  details?: unknown;
}

interface ParsedDispute {
  requestId: string;
  category: Category;
  details: string;
}

/**
 * Validate + narrow the raw callable payload.
 * @param {unknown} data Raw request.data.
 * @return {ParsedDispute} The validated dispute fields.
 */
function parseInput(data: unknown): ParsedDispute {
  const d = (data ?? {}) as DisputeInput;
  const requestId = typeof d.requestId === "string" ? d.requestId.trim() : "";
  if (!requestId) {
    throw new HttpsError("invalid-argument", "requestId is required");
  }
  const category = d.category as Category;
  if (!CATEGORIES.includes(category)) {
    throw new HttpsError(
      "invalid-argument",
      `category must be one of: ${CATEGORIES.join(", ")}`,
    );
  }
  // Details are optional for structured categories but capped so a client
  // can't stuff the doc; safety/misrepresented benefit from context.
  const rawDetails = typeof d.details === "string" ? d.details.trim() : "";
  const details = rawDetails.slice(0, 1000);
  return {requestId, category, details};
}

export const reportInspectionIssue = onCall(callOpts, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  const {requestId, category, details} = parseInput(request.data);

  const db = getFirestore();
  const ref = db.collection("inspection_requests").doc(requestId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Inspection not found");
  }
  const data = snap.data() as Record<string, unknown>;

  // Only the tenant on THIS inspection may dispute it.
  const tenantId = (data.tenantId as string) ?? "";
  assertSelf(request.auth, tenantId);

  const status = (data.status as string) ?? "";
  if (!DISPUTABLE_STATUSES.includes(status)) {
    throw new HttpsError(
      "failed-precondition",
      `Cannot dispute an inspection in state "${status}".`,
    );
  }

  // Idempotent: a second submit while one is open is a no-op (not an error, so
  // a double-tap doesn't surface a scary message).
  if (data.disputeStatus === "open") {
    logger.info("Dispute already open, ignoring duplicate", {requestId});
    return {ok: true, alreadyOpen: true};
  }

  const agentId = (data.agentId as string) || undefined;
  const landlordId = (data.landlordId as string) || undefined;
  const propertyTitle = (data.propertyTitle as string) ?? "a property";

  const disputeFields: Record<string, unknown> = {
    disputed: true,
    disputeStatus: "open",
    disputeCategory: category,
    disputeDetails: details,
    disputedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  // An approved (not-yet-completed) inspection joins the admin review queue so
  // it can't silently expire; a completed one keeps its status.
  if (status === "approved") {
    disputeFields.status = "awaitingOutcome";
  }
  await ref.update(disputeFields);

  const severity: AlertSeverity =
    category === "safety" ? "critical" : "warning";
  await writeAdminAlert({
    type: "inspection_dispute",
    severity,
    title: `Inspection dispute: ${CATEGORY_LABEL[category]}`,
    body:
      `A tenant reported "${CATEGORY_LABEL[category]}" on the inspection for ` +
      `${propertyTitle}.` + (details ? ` Details: ${details}` : ""),
    targetCollection: "inspection_requests",
    targetId: requestId,
    actors: {tenantId, agentId, landlordId},
    meta: {category, propertyTitle, previousStatus: status},
  });

  await writeAuditLog({
    actorId: request.auth.uid,
    action: "inspection_dispute_filed",
    targetCollection: "inspection_requests",
    targetId: requestId,
    amount: 0,
    paymentReference: "inspection_dispute",
    paymentNote: `${category}${details ? `: ${details}` : ""}`,
  });

  logger.info("Inspection dispute filed", {requestId, category, tenantId});
  return {ok: true};
});
