// ─────────────────────────────────────────────────────────────────────────────
// handover_ops.ts — resolving a move-out so the property can be relisted.
//
// The tenancy has already ended by the time anything here runs. What is still
// open is the caution deposit, and ClearRent never holds it: the money moves
// landlord-to-tenant off-platform, so the platform cannot return it, release
// it, or compel it. Withholding the RELIST is the only leverage there is, and
// `properties.handoverPending` is that lever.
//
// The hard problem is that the lever must not become a weapon for either side.
//   - A landlord who never settles would keep the deposit and, since the unit
//     stays dark, lose the income. That is self-enforcing and needs no sweep.
//   - An outgoing tenant who never confirms would freeze the property forever.
//     A tenant who has moved on, or is simply aggrieved, must not be able to
//     do that. Hence the silence path below.
//
// So: confirm → closed. Silent for SILENCE_DAYS with proof of transfer on
// file → closed, with the landlord's claim RECORDED against them. Contest →
// admin adjudicates, and only an admin may suspend a landlord or touch their
// rating. Nothing here punishes anyone automatically; it only writes down what
// happened, which is the whole design.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import {onDocumentWritten} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

/** How long the outgoing tenant has to confirm or contest a settlement. */
const SILENCE_DAYS = 7;

/** Days after settlement on which the tenant is chased. Both land before
 *  SILENCE_DAYS so silence is a real choice rather than an accident. */
const REMIND_DAYS = [2, 5];

const dayMs = 24 * 60 * 60 * 1000;

/**
 * Records a strike against a landlord whose settlement went unconfirmed.
 *
 * Deliberately NOT a punishment. The tenant may simply have moved on, and the
 * proof of transfer is an uploaded image nobody has verified — so this writes
 * the claim down and leaves every consequence to a human. Suspension and any
 * rating penalty are admin actions, never automatic: an automatic listing ban
 * driven by unverified photo evidence would eventually hit an honest landlord,
 * and the reputational half of that cannot be undone.
 *
 * @param {string} landlordId The landlord to record against.
 * @param {string} rentalId The tenancy the claim belongs to.
 * @param {Record<string, unknown>} detail What was claimed.
 * @return {Promise<void>}
 */
async function recordUnconfirmedSettlement(
  landlordId: string,
  rentalId: string,
  detail: Record<string, unknown>,
): Promise<void> {
  const db = getFirestore();
  // Strike id is the rental, so replaying the sweep can never inflate a
  // landlord's count for the same tenancy.
  await db
    .collection("users")
    .doc(landlordId)
    .collection("strikes")
    .doc(rentalId)
    .set(
      {
        type: "settlement_unconfirmed",
        rentalId,
        ...detail,
        recordedAt: FieldValue.serverTimestamp(),
        // An admin reviewing this decides whether it stands. Until then it is
        // an unexamined allegation, and reads as one.
        adminReviewed: false,
      },
      {merge: true},
    );
}

/**
 * Closes settlements the outgoing tenant never answered, and chases the ones
 * still inside the window.
 *
 * Runs after the move-out sweeps so a tenancy that ended this morning is not
 * also settled and closed in the same pass.
 */
export const handoverSilenceSweep = onSchedule(
  {schedule: "every day 10:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();

    const snap = await db
      .collection("active_rentals")
      .where("handoverStage", "==", "awaiting_confirm")
      .get();

    let closed = 0;
    let reminded = 0;

    for (const doc of snap.docs) {
      const d = doc.data();
      const rentalId = doc.id;
      const settledAt = d.handoverSettledAt as Timestamp | undefined;
      if (!settledAt) continue;

      // A tenant who contested is not silent — that is the admin's to resolve,
      // and closing it here would decide the dispute by timeout.
      if (d.tenantContested === true) continue;

      const ageDays = Math.floor((now - settledAt.toMillis()) / dayMs);
      const landlordId = d.landlordId as string | undefined;
      const tenantId = d.tenantId as string | undefined;
      const propertyTitle =
        (d.propertyTitle as string | undefined) ?? "your former home";

      try {
        if (ageDays >= SILENCE_DAYS) {
          // Proof of transfer is what separates "the tenant stopped replying"
          // from "the landlord never paid and waited it out". Without it the
          // property stays gated: the landlord can end this whenever they like
          // by uploading it, so nobody is trapped except by their own inaction.
          const proof = (d.handoverProofUrl as string | undefined) ?? "";
          if (!proof) {
            logger.info("Settlement unconfirmed, no proof — still gated", {
              rentalId,
            });
            continue;
          }

          await doc.ref.update({
            handoverStage: "closed",
            handoverClosedBy: "silence",
            handoverClosedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          closed++;

          if (landlordId) {
            await recordUnconfirmedSettlement(landlordId, rentalId, {
              deductionAmount: d.cautionDeductionAmount ?? 0,
              deductionReason: d.cautionDeductionReason ?? null,
              proofUrl: proof,
              tenantId: tenantId ?? null,
              propertyTitle,
            });
            await writeNotificationOnce(`handover_silence_L_${rentalId}`, {
              userId: landlordId,
              type: "handover_closed",
              title: "Move-out settled",
              body:
                `Your former tenant did not respond within ${SILENCE_DAYS} ` +
                `days, so the handover for ${propertyTitle} is closed and ` +
                "you can list it again. Your proof of transfer is on record.",
              payload: {route: "/landlord/rentals", rentalId},
            });
          }

          if (tenantId) {
            await writeNotificationOnce(`handover_silence_T_${rentalId}`, {
              userId: tenantId,
              type: "handover_closed",
              title: "Deposit settlement closed",
              body:
                `The deposit settlement for ${propertyTitle} closed after ` +
                `${SILENCE_DAYS} days without a reply. If you were not paid, ` +
                "contact support — the landlord's claim is on record.",
              payload: {route: "/tenant/my-rentals", rentalId},
            });
          }

          logger.info("Handover closed on tenant silence", {
            rentalId, landlordId,
          });
          continue;
        }

        if (REMIND_DAYS.includes(ageDays) && tenantId) {
          const daysLeft = SILENCE_DAYS - ageDays;
          const wrote = await writeNotificationOnce(
            `handover_confirm_T${ageDays}_${rentalId}`,
            {
              userId: tenantId,
              type: "handover_confirm_reminder",
              title: "Did you get your deposit back?",
              body:
                `Confirm the deposit settlement for ${propertyTitle}, or say ` +
                `it is wrong. If you do nothing it closes in ${daysLeft} ` +
                `day${daysLeft === 1 ? "" : "s"}.`,
              payload: {route: "/tenant/my-rentals", rentalId},
            },
          );
          if (wrote) reminded++;
        }
      } catch (err) {
        logger.error("Handover silence sweep failed for rental", {
          rentalId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    logger.info("handoverSilenceSweep complete", {
      scanned: snap.size, closed, reminded,
    });
  },
);

/**
 * Chases a landlord who has not settled a deposit on a unit they cannot relist.
 *
 * The gate is self-enforcing — an unsettled unit earns nothing — but silence
 * here is far more often forgetfulness than obstruction, and a landlord who
 * has simply not realised the unit is off-market is badly served by leaving
 * them to work it out.
 */
export const handoverSettlementReminders = onSchedule(
  {schedule: "every day 11:00", timeZone: "Africa/Lagos", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const now = Date.now();

    const snap = await db
      .collection("active_rentals")
      .where("handoverStage", "in", ["awaiting_evidence", "awaiting_condition"])
      .get();

    let sent = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      const endedAt = d.endedAt as Timestamp | undefined;
      if (!endedAt) continue;

      const ageDays = Math.floor((now - endedAt.toMillis()) / dayMs);
      if (!REMIND_DAYS.includes(ageDays)) continue;

      const rentalId = doc.id;
      const propertyTitle =
        (d.propertyTitle as string | undefined) ?? "your property";
      const stage = d.handoverStage as string;

      try {
        // Whose turn it is depends on the stage: evidence is the tenant's,
        // checking the unit is the landlord's.
        if (stage === "awaiting_evidence") {
          const tenantId = d.tenantId as string | undefined;
          if (!tenantId) continue;
          const wrote = await writeNotificationOnce(
            `handover_evidence_T${ageDays}_${rentalId}`,
            {
              userId: tenantId,
              type: "handover_evidence_reminder",
              title: "Record the condition you left it in",
              body:
                `Your walkthrough of ${propertyTitle} is what protects your ` +
                "caution deposit. Without it a deduction cannot be argued.",
              payload: {route: "/tenant/my-rentals", rentalId},
            },
          );
          if (wrote) sent++;
        } else {
          const landlordId = d.landlordId as string | undefined;
          if (!landlordId) continue;
          const wrote = await writeNotificationOnce(
            `handover_condition_L${ageDays}_${rentalId}`,
            {
              userId: landlordId,
              type: "handover_condition_reminder",
              title: "Check the unit to list it again",
              body:
                `${propertyTitle} stays off the market until you confirm you ` +
                "have checked it and settled the caution deposit.",
              payload: {route: "/landlord/rentals", rentalId},
            },
          );
          if (wrote) sent++;
        }
      } catch (err) {
        logger.error("Handover settlement reminder failed", {
          rentalId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    logger.info("handoverSettlementReminders complete", {
      scanned: snap.size, sent,
    });
  },
);

/**
 * Tells the other party when a condition recording is sealed.
 *
 * The gap this closes: a tenant films the move-out condition while they still
 * have keys, which is DURING the notice period — before the tenancy ends and
 * therefore before the handover screen exists for the landlord at all. Nothing
 * announced it, so a walkthrough could sit unwatched until the landlord
 * happened to open the tenancy days later, by which point they may already
 * have formed a view about the deposit.
 *
 * Fires on the SEAL, never on the pending open. A record whose upload has not
 * landed may never finish, and "your tenant recorded the condition" would then
 * be a claim about evidence that does not exist.
 */
export const onConditionEvidenceSealed = onDocumentWritten(
  "active_rentals/{rentalId}/condition/{stage}/parties/{partyId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!after) return;

    // Only the transition INTO sealed. Rules forbid editing a sealed record,
    // but triggers are at-least-once, so a redelivery must not re-notify.
    if (!after.capturedAt || before?.capturedAt) return;

    const {rentalId, stage, partyId} = event.params;

    const db = getFirestore();
    const snap = await db.collection("active_rentals").doc(rentalId).get();
    const r = snap.data();
    if (!r) return;

    const tenantId = r.tenantId as string | undefined;
    const landlordId = r.landlordId as string | undefined;

    // Whoever did NOT record it is who needs to hear about it.
    const fromTenant = partyId === tenantId;
    const recipient = fromTenant ? landlordId : tenantId;
    if (!recipient) return;

    const propertyTitle =
      (r.propertyTitle as string | undefined) ?? "your property";
    const isMoveOut = stage === "move_out";

    await writeNotificationOnce(
      `condition_${stage}_${partyId}_${rentalId}`,
      {
        userId: recipient,
        type: "condition_recorded",
        title: isMoveOut ?
          "Move-out condition recorded" :
          "Move-in condition recorded",
        body: fromTenant ?
          `Your tenant recorded the condition of ${propertyTitle} on ` +
            "video. It is sealed — neither of you can change it — and any " +
            "claim on the caution deposit is argued against it." :
          `Your landlord recorded the condition of ${propertyTitle} on ` +
            "video. It is sealed, and you can watch it.",
        payload: {
          route: fromTenant ? "/landlord/rentals" : "/tenant/my-rentals",
          rentalId,
        },
      },
    );

    logger.info("Condition evidence notification sent", {
      rentalId, stage, partyId, recipient,
    });
  },
);
