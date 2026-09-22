/**
 * Handler reports that the tenant never turned up.
 *
 * On the day the handler's only button was Cancel, which refunds the tenant
 * and forfeits the handler's fee, so a landlord who had waited it out and
 * pressed the one button there paid the no-show tenant back. The nightly sweep
 * reached the right outcome (admin review, tenantNoShow) but only the next day,
 * and told nobody.
 *
 * This moves the inspection to admin review straight away. It never pays
 * anyone: the claim is one-sided (an agent could make it to collect on a
 * tenant who did come), so the admin still decides from the review queue via
 * adminResolveInspection. The notifications for the review are sent by
 * onInspectionRequestUpdated, so the sweep's own no-show path gets them too.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";

// App Check left off to match the other inspection callables in this codebase.
const callOpts = {timeoutSeconds: 30, enforceAppCheck: false};

/** How long after the slot starts the tenant has before a no-show report. */
const NO_SHOW_GRACE_MS = 60 * 60 * 1000;

export const reportTenantNoShow = onCall(callOpts, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  const requestId = (request.data as {requestId?: unknown})?.requestId;
  if (typeof requestId !== "string" || requestId.length === 0) {
    throw new HttpsError("invalid-argument", "requestId is required");
  }

  const db = getFirestore();
  const ref = db.collection("inspection_requests").doc(requestId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Inspection not found");
    }
    const d = snap.data() ?? {};
    const agentId = d.agentId as string | null | undefined;
    const handlerId = agentId || (d.landlordId as string | undefined);
    if (handlerId !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only the person showing the property can report this.",
      );
    }
    if (d.status !== "approved") {
      throw new HttpsError("failed-precondition", "This viewing is not open.");
    }
    if (d.paymentStatus !== "paid" && d.paymentStatus !== "not_required") {
      throw new HttpsError(
        "failed-precondition",
        "This viewing was never paid for.",
      );
    }
    if (d.handlerArrived !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Mark that you have arrived first.",
      );
    }
    if (d.tenantArrived === true) {
      throw new HttpsError(
        "failed-precondition",
        "The tenant has marked that they arrived.",
      );
    }
    const start = (d.requestedDate as Timestamp | undefined)?.toMillis();
    if (!start || Date.now() < start + NO_SHOW_GRACE_MS) {
      throw new HttpsError(
        "failed-precondition",
        "Give the tenant until an hour after the viewing starts.",
      );
    }

    tx.update(ref, {
      status: "awaitingOutcome",
      tenantNoShow: true,
      noShowReportedBy: uid,
      noShowReportedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return {ok: true};
});
