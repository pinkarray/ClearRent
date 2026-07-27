// ─────────────────────────────────────────────────────────────────────────────
// rent_interest_ops.ts — strand sweep for rental interests (money-flow gap G1).
//
// Pay-after-accept: the landlord accepts ONE applicant (unpaid); the interest
// sits at `accepted` while the tenancy agreement is finalized and the accepted
// tenant pays. If that stalls — agreement never finalized, or finalized but the
// tenant never pays — the deal is stranded with no money moved. This daily
// sweep, mirroring leaseLifecycleSweep / inspectionLifecycleSweep:
//   • day 3 & day 6 → remind BOTH parties to complete the rental (deduped).
//   • day 7 → flag `strandedForReview` on the interest + reassure the tenant.
//
// (The old flow stranded a PAID tenant waiting for the landlord to accept, at
// `payment_verified`. New interests never reach that state; this now watches the
// unpaid-but-accepted limbo instead.)
//
// Deliberately moves NO money (policy: reminder → admin review queue). A flagged
// interest surfaces on the admin "Rent Attention" view, where an admin chases
// the parties.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

const LANDLORD_INSPECTIONS_ROUTE = "/landlord/inspections";
const TENANT_INSPECTIONS_ROUTE = "/tenant/inspections";

// Days after the landlord accepted the applicant.
const REMIND_DAYS = [3, 6];
const STRAND_DAYS = 7;

export const rentalInterestStrandSweep = onSchedule(
  {schedule: "0 9 * * *", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();
    const dayMs = 24 * 60 * 60 * 1000;

    // Only interests the landlord has accepted but that haven't completed
    // (finalized + paid → rent_paid) can strand. rent_paid / not_selected /
    // lost_to_other no longer match.
    const snap = await db
      .collection("rental_interests")
      .where("status", "==", "accepted")
      .get();

    let reminders = 0;
    let stranded = 0;

    for (const doc of snap.docs) {
      const data = doc.data();
      const acceptedTs =
        (data.acceptedAt as Timestamp | undefined) ??
        (data.updatedAt as Timestamp | undefined) ??
        (data.createdAt as Timestamp | undefined);
      if (!acceptedTs) continue;

      const landlordId = data.landlordId as string | undefined;
      const tenantId = data.tenantId as string | undefined;
      const propertyTitle =
        (data.propertyTitle as string | undefined) ?? "a rental";
      const ageDays = Math.floor((now - acceptedTs.toMillis()) / dayMs);

      try {
        // ── Day 7+: release, or escalate ──
        if (ageDays >= STRAND_DAYS) {
          // Find the held rental for this interest.
          const rentalQ = await db
            .collection("active_rentals")
            .where("rentalInterestId", "==", doc.id)
            .limit(1)
            .get();
          const rentalDoc = rentalQ.docs[0];
          const rental = rentalDoc?.data();
          const holding = rental?.status === "pending_payment";
          const couldPay = rental?.agreementStatus === "finalized";

          // Only AUTO-RELEASE when the tenant genuinely had the chance to pay
          // (agreement finalized) and didn't. No money was ever taken —
          // pay-after-accept means an unpaid accept involves zero charge — so
          // this is pure cleanup: free the slot and close the reservation.
          if (holding && couldPay) {
            await rentalDoc.ref.update({
              status: "terminated",
              endReason: "accept_lapsed_unpaid",
              endedBy: "system",
              endedAt: FieldValue.serverTimestamp(),
              updatedAt: FieldValue.serverTimestamp(),
            });
            await doc.ref.update({
              status: "expired",
              updatedAt: FieldValue.serverTimestamp(),
            });
            stranded++;

            if (tenantId) {
              await writeNotificationOnce(`rental_expired_${doc.id}`, {
                userId: tenantId,
                type: "rental_expired",
                title: "Reservation expired",
                body:
                  `Rent for ${propertyTitle} wasn't paid in time, so your ` +
                  "reservation was released. You were not charged.",
                payload: {route: TENANT_INSPECTIONS_ROUTE},
              });
            }
            if (landlordId) {
              await writeNotificationOnce(
                `rental_expired_landlord_${doc.id}`,
                {
                  userId: landlordId,
                  type: "rental_expired",
                  title: "Reservation released — back on the market",
                  body:
                    `The tenant you accepted for ${propertyTitle} didn't pay ` +
                    "in time. The unit is available again.",
                  payload: {route: LANDLORD_INSPECTIONS_ROUTE},
                },
              );
            }
            continue;
          }

          // Otherwise the deal stalled for another reason (agreement never
          // finalized, or no rental record) — don't auto-release, since it may
          // be the landlord who's slow. Flag it for admin + reassure the tenant.
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
                  `Your rental for ${propertyTitle} hasn't been completed ` +
                  "yet. Our team is now following it up on your behalf.",
                payload: {route: TENANT_INSPECTIONS_ROUTE},
              },
            );
            if (wrote) reminders++;
          }
          continue;
        }

        // ── Remind both parties to complete the rental ──
        // Finalize the agreement, then the accepted tenant pays. Nudge each
        // side to their own next step (deduped per day per doc).
        if (REMIND_DAYS.includes(ageDays)) {
          if (landlordId) {
            const wrote = await writeNotificationOnce(
              `rental_complete_reminder_L_T${ageDays}_${doc.id}`,
              {
                userId: landlordId,
                type: "rental_accept_reminder",
                title: "A tenant is waiting to move in",
                body:
                  `Finalize the tenancy agreement for ${propertyTitle} so ` +
                  "your accepted tenant can pay and complete the rental.",
                payload: {route: LANDLORD_INSPECTIONS_ROUTE},
              },
            );
            if (wrote) reminders++;
          }
          if (tenantId) {
            const wrote = await writeNotificationOnce(
              `rental_complete_reminder_T_T${ageDays}_${doc.id}`,
              {
                userId: tenantId,
                type: "rental_accept_reminder",
                title: "Complete your move-in",
                body:
                  `You've been accepted for ${propertyTitle}. Review and ` +
                  "finalize your agreement, then pay to secure your new home.",
                payload: {route: TENANT_INSPECTIONS_ROUTE},
              },
            );
            if (wrote) reminders++;
          }
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
