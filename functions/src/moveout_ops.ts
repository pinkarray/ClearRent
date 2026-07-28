// ─────────────────────────────────────────────────────────────────────────────
// moveout_ops.ts — auto-confirm stale tenant move-out requests.
//
// The tenant-initiated move-out (request + acknowledge) parks the rental in
// `moveout_pending` until the landlord confirms handover. If the landlord never
// acts, the tenant would be trapped — so this sweep confirms any request older
// than AUTO_CONFIRM_DAYS. There is deliberately NO landlord veto.
//
// The status flip to `ended_by_tenant` is all this does. Downstream triggers do
// the rest: onActiveRentalStatusOccupancy frees the property and clears the
// tenant's active-rental flag, and onActiveRentalUpdated pushes the tenant the
// "move-out confirmed" notification. This sweep additionally tells the landlord
// their inaction auto-confirmed it.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

const AUTO_CONFIRM_DAYS = 7;

export const moveoutAutoConfirmSweep = onSchedule(
  {schedule: "every day 08:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const cutoffMs = Date.now() - AUTO_CONFIRM_DAYS * 24 * 60 * 60 * 1000;

    // Single-field equality query (auto-indexed) + in-memory age filter.
    const snap = await db
      .collection("active_rentals")
      .where("status", "==", "moveout_pending")
      .get();

    let confirmed = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      const requestedAt = d.moveOutRequestedAt as Timestamp | undefined;
      // No timestamp yet (just written) or still inside the grace window.
      if (!requestedAt || requestedAt.toMillis() > cutoffMs) continue;

      const rentalId = doc.id;
      const landlordId = d.landlordId as string | undefined;
      const propertyTitle =
        (d.propertyTitle as string | undefined) ?? "your property";

      try {
        // Terminal transition. Downstream triggers free the unit, clear the
        // tenant flag, and push the tenant the "confirmed" notification.
        await doc.ref.update({
          status: "ended_by_tenant",
          endedAt: FieldValue.serverTimestamp(),
          moveOutAutoConfirmed: true,
          updatedAt: FieldValue.serverTimestamp(),
        });
        confirmed++;

        if (landlordId) {
          await writeNotificationOnce(`moveout_auto_${rentalId}`, {
            userId: landlordId,
            type: "moveout_auto_confirmed",
            title: "Move-out auto-confirmed",
            body:
              `A move-out request for ${propertyTitle} went unconfirmed for ` +
              `${AUTO_CONFIRM_DAYS} days, so ClearRent confirmed the handover ` +
              "and the tenancy is now ended.",
            payload: {route: "/landlord/rentals", rentalId},
          });
        }
        logger.info("Move-out auto-confirmed", {rentalId, landlordId});
      } catch (err) {
        logger.error("Move-out auto-confirm failed", {
          rentalId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    logger.info("moveoutAutoConfirmSweep complete", {
      scanned: snap.size,
      confirmed,
    });
  },
);
