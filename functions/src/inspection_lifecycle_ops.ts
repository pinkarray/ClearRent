// ─────────────────────────────────────────────────────────────────────────────
// inspection_lifecycle_ops.ts — daily sweep that resolves inspections whose
// date has passed, so nothing hangs in limbo and the tenant's money is handled.
//
// Mirrors leaseLifecycleSweep. For every non-terminal request whose requested
// date is a PRIOR day (same-day is left alone — it may still happen):
//
//   pendingPayment        → cancelled (never paid; no money involved)
//   pendingVerification /
//   pending               → expiredUnapproved (paid but never approved in time;
//                           the tenant is offered reschedule or refund)
//   approved (not done)   → resolved by the arrival flags the day-of flow records:
//       • met                         → completed (they met, just forgot to tap)
//       • tenant came, handler didn't → awaitingOutcome (admin reviews — a
//                                       handler's *absence* is forgeable, so we
//                                       never auto-refund on it)
//       • handler came, tenant didn't → awaitingOutcome (admin confirms + pays
//                                       the handler; "I showed" is forgeable too)
//       • neither / unclear           → awaitingOutcome (admin reviews)
//
// This sweep no longer auto-refunds a handler no-show: a genuine one is
// confirmed by an admin, who issues the refund from the review queue. Setting
// paymentStatus='refunded' (now from that admin decision) still triggers
// onInspectionRefundTriggered to create the refund record for payout.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  DocumentData,
  DocumentReference,
} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

const TENANT_INSPECTIONS_ROUTE = "/tenant/inspections";

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

export const inspectionLifecycleSweep = onSchedule(
  {schedule: "every day 02:00", timeZone: "Africa/Lagos", timeoutSeconds: 540},
  async () => {
    const db = getFirestore();
    const today = startOfDay(new Date());

    // Non-terminal states that can go stale. Single-field "in" query (no
    // composite index needed); the date is filtered in code.
    const snap = await db
      .collection("inspection_requests")
      .where("status", "in", [
        "pendingPayment",
        "pendingVerification",
        "pending",
        "approved",
      ])
      .get();

    const counts = {expired: 0, cancelled: 0, completed: 0, refunded: 0, review: 0};

    for (const doc of snap.docs) {
      const data = doc.data();
      const reqTs = data.requestedDate as Timestamp | undefined;
      if (!reqTs) continue;
      if (startOfDay(reqTs.toDate()) >= today) continue; // not a prior day yet

      const status = data.status as string;
      const tenantId = data.tenantId as string | undefined;
      const propertyTitle =
        (data.propertyTitle as string | undefined) ?? "a property";

      try {
        if (status === "pendingPayment") {
          await doc.ref.update({
            status: "cancelled",
            cancelReason: "Inspection date passed before payment",
            updatedAt: FieldValue.serverTimestamp(),
          });
          counts.cancelled++;
        } else if (status === "pendingVerification" || status === "pending") {
          await doc.ref.update({
            status: "expiredUnapproved",
            updatedAt: FieldValue.serverTimestamp(),
          });
          if (tenantId) {
            await writeNotificationOnce(`insp_${doc.id}_expired_${tenantId}`, {
              userId: tenantId,
              type: "inspection_expired",
              title: "Inspection wasn't confirmed in time",
              body:
                `Your inspection for ${propertyTitle} wasn't approved before ` +
                `the date. Reschedule for free or get a refund.`,
              payload: {route: TENANT_INSPECTIONS_ROUTE},
            });
          }
          counts.expired++;
        } else if (status === "approved") {
          const outcome = await resolveApproved(doc.ref, data);
          counts[outcome]++;
        }
      } catch (e) {
        logger.error("Inspection sweep failed on a request", {
          id: doc.id,
          error: `${e}`,
        });
      }
    }

    logger.info("Inspection lifecycle sweep complete", counts);
  },
);

/**
 * Resolve an approved inspection whose date has passed, using the arrival flags
 * the day-of flow records.
 *
 * @param {DocumentReference} ref Inspection request ref.
 * @param {DocumentData} data Inspection request data.
 * @return {Promise<"completed" | "refunded" | "review">} The outcome bucket.
 */
async function resolveApproved(
  ref: DocumentReference,
  data: DocumentData,
): Promise<"completed" | "refunded" | "review"> {
  const met = data.met === true;
  const tenantArrived = data.tenantArrived === true;
  const handlerArrived = data.handlerArrived === true;
  const tenantId = data.tenantId as string | undefined;
  const propertyTitle =
    (data.propertyTitle as string | undefined) ?? "a property";

  if (met) {
    await ref.update({
      status: "completed",
      completedAt: FieldValue.serverTimestamp(),
      autoResolved: true,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return "completed";
  }

  if (tenantArrived && !handlerArrived) {
    // Tenant says they attended but the handler never confirmed arrival. This
    // is ALSO the exact signal a colluding tenant+handler can forge to conjure
    // a full refund on an inspection that really happened (the handler simply
    // doesn't tap "arrived"). So we NO LONGER auto-refund on handler absence —
    // it goes to admin review, who confirms the no-show with the handler (an
    // agent is one of our own) and issues the refund. Genuine handler no-shows
    // are rare, and the honest tenant is protected by the admin's decision.
    await ref.update({
      status: "awaitingOutcome",
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (tenantId) {
      await writeNotificationOnce(`insp_${ref.id}_noshow_review_${tenantId}`, {
        userId: tenantId,
        type: "inspection_under_review",
        title: "We're reviewing your inspection",
        body:
          `You marked that you attended the inspection at ${propertyTitle} ` +
          `but the handler didn't confirm. Our team is reviewing it and will ` +
          `sort out any refund.`,
        payload: {route: TENANT_INSPECTIONS_ROUTE},
      });
    }
    return "review";
  }

  if (handlerArrived && !tenantArrived) {
    // Handler confirmed arrival, tenant didn't: the fee should stand and be
    // paid to the handler (₦7k). But "I showed, they didn't" is a one-sided
    // claim the handler alone made — an agent could forge it to collect on a
    // genuine tenant no-show. So we don't auto-pay: admin confirms and marks it
    // completed (which credits the handler) from the review queue. tenantNoShow
    // is preserved so the queue shows the case.
    await ref.update({
      status: "awaitingOutcome",
      tenantNoShow: true,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return "review";
  }

  // Neither arrived / ambiguous → admin reviews.
  await ref.update({
    status: "awaitingOutcome",
    updatedAt: FieldValue.serverTimestamp(),
  });
  return "review";
}
