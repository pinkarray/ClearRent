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
//       • tenant came, handler didn't → refunded (handler no-show)
//       • handler came, tenant didn't → completed + tenantNoShow (fee stands)
//       • neither / unclear           → awaitingOutcome (admin reviews)
//
// Refunds set paymentStatus='refunded'; onInspectionRefundTriggered then creates
// the refund record for the admin to pay out.
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
    // Handler no-show → refund the tenant.
    await ref.update({
      status: "refunded",
      paymentStatus: "refunded",
      refundReason: "Handler did not show up for the inspection",
      refundedAt: FieldValue.serverTimestamp(),
      autoResolved: true,
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (tenantId) {
      await writeNotificationOnce(`insp_${ref.id}_noshow_refund_${tenantId}`, {
        userId: tenantId,
        type: "inspection_refunded",
        title: "Refund on the way",
        body:
          `The handler didn't show for your inspection at ${propertyTitle}, ` +
          `so you're being refunded.`,
        payload: {route: TENANT_INSPECTIONS_ROUTE},
      });
    }
    return "refunded";
  }

  if (handlerArrived && !tenantArrived) {
    // Tenant no-show → handler showed up; fee stands.
    await ref.update({
      status: "completed",
      completedAt: FieldValue.serverTimestamp(),
      tenantNoShow: true,
      autoResolved: true,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return "completed";
  }

  // Neither arrived / ambiguous → admin reviews.
  await ref.update({
    status: "awaitingOutcome",
    updatedAt: FieldValue.serverTimestamp(),
  });
  return "review";
}
