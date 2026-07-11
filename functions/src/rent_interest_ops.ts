// ─────────────────────────────────────────────────────────────────────────────
// rent_interest_ops.ts — strand sweep for rental interests (money-flow gap G1).
//
// A tenant pays for a rental → admin verifies → the interest sits at
// `payment_verified` waiting for the LANDLORD to accept. If the landlord never
// taps Accept, the tenant's money is locked in with no recourse and nothing
// happens. This daily sweep, mirroring leaseLifecycleSweep / inspectionLifecycleSweep:
//   • day 3 & day 6 → remind the landlord to accept (deduped notifications).
//   • day 7 → flag `strandedForReview` on the interest + reassure the tenant.
//
// Deliberately moves NO money (policy: reminder → admin review queue). A flagged
// interest surfaces on the admin "Rent Attention" view, where an admin chases
// the landlord or refunds the tenant via the existing refund flow.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

const LANDLORD_INSPECTIONS_ROUTE = "/landlord/inspections";
const TENANT_INSPECTIONS_ROUTE = "/tenant/inspections";

// Days after payment verification.
const REMIND_DAYS = [3, 6];
const STRAND_DAYS = 7;

export const rentalInterestStrandSweep = onSchedule(
  {schedule: "0 9 * * *", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();
    const dayMs = 24 * 60 * 60 * 1000;

    // Only interests that are paid + verified but not yet accepted can strand.
    const snap = await db
      .collection("rental_interests")
      .where("status", "==", "payment_verified")
      .get();

    let reminders = 0;
    let stranded = 0;

    for (const doc of snap.docs) {
      const data = doc.data();
      const verifiedTs =
        (data.paymentVerifiedAt as Timestamp | undefined) ??
        (data.updatedAt as Timestamp | undefined) ??
        (data.createdAt as Timestamp | undefined);
      if (!verifiedTs) continue;

      const landlordId = data.landlordId as string | undefined;
      const tenantId = data.tenantId as string | undefined;
      const propertyTitle =
        (data.propertyTitle as string | undefined) ?? "a rental";
      const ageDays = Math.floor((now - verifiedTs.toMillis()) / dayMs);

      try {
        // ── Escalate: flag for admin review + reassure the tenant ──
        if (ageDays >= STRAND_DAYS) {
          if (data.strandedForReview !== true) {
            await doc.ref.update({
              strandedForReview: true,
              strandedAt: FieldValue.serverTimestamp(),
              updatedAt: FieldValue.serverTimestamp(),
            });
            stranded++;
          }
          if (tenantId) {
            const wrote = await writeNotificationOnce(
              `rental_stranded_${doc.id}`,
              {
                userId: tenantId,
                type: "rental_under_review",
                title: "We're following up on your rental",
                body:
                  `The landlord for ${propertyTitle} hasn't confirmed yet. ` +
                  "Our team is now following it up on your behalf.",
                payload: {route: TENANT_INSPECTIONS_ROUTE},
              },
            );
            if (wrote) reminders++;
          }
          continue;
        }

        // ── Remind the landlord to accept ──
        if (landlordId && REMIND_DAYS.includes(ageDays)) {
          const wrote = await writeNotificationOnce(
            `rental_accept_reminder_T${ageDays}_${doc.id}`,
            {
              userId: landlordId,
              type: "rental_accept_reminder",
              title: "A paid tenant is waiting",
              body:
                `A tenant has paid for ${propertyTitle} and is waiting for ` +
                "you to accept. Please confirm to complete the rental.",
              payload: {route: LANDLORD_INSPECTIONS_ROUTE},
            },
          );
          if (wrote) reminders++;
        }
      } catch (e) {
        logger.error("rentalInterestStrandSweep failed on a doc", {
          id: doc.id,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }

    logger.info("rentalInterestStrandSweep complete", {reminders, stranded});
  },
);
