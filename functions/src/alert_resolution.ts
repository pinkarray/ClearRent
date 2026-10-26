// ─────────────────────────────────────────────────────────────────────────────
// alert_resolution.ts - an admin alert is an OPEN TASK, not a log entry.
//
// The feed had 19 alert types and only 10 of them ever closed. The rest were
// raised and left, so the queue filled with work that was long since done and
// an admin had to dismiss rows by hand to find the ones that still mattered -
// which is exactly backwards: dismissing should be the rare exception, not the
// routine. Four alerts about ONE tenancy were sitting open at the time this was
// written, including "₦15,000 is owed to the landlord" for a duplicate charge
// that was being refunded. That one could have got the landlord paid twice.
//
// Why a sweep rather than a resolver bolted onto each producer:
//
//   1. One table. A new alert type declares its "done" test in one place
//      instead of needing a new trigger wired into whichever function happens
//      to write its target.
//   2. It is the only shape that can close an alert whose TARGET WAS DELETED.
//      A per-collection trigger fires on the delete, but nothing fires for an
//      alert whose target vanished before the trigger existed - and a target
//      that no longer exists can never be actioned, so the alert is pure noise.
//   3. It backfills. Alerts raised before any of this existed are closed on the
//      first run, without hand-patching production documents.
//
// The cost of a sweep is latency: an alert can stay open until the next run.
// That is the right trade for an admin queue - nobody watches a payout alert
// second by second - and anything that must clear IMMEDIATELY gets a direct
// call to resolveAdminAlertsForTarget at the point the work finishes
// (markPaymentRefunded does this for the refund case above).
//
// A "done" test must be CONSERVATIVE. Leaving a finished alert open is untidy;
// closing one whose work is still outstanding hides money or a decision from
// the only person looking. When in doubt, leave it open.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

type Doc = FirebaseFirestore.DocumentData;

/**
 * How to tell whether the work behind an alert type is finished.
 *
 * `collection` is where its `targetId` lives; null means the type is judged
 * from the alert itself (no target to read). `done` is called with the TARGET
 * document. A target that has been deleted never reaches `done` - it is
 * treated as finished by the sweep, since it can no longer be acted on.
 */
interface Resolver {
  collection: string | null;
  done: (target: Doc, alert: Doc) => boolean;
}

/**
 * Terminal for the tenancy agreement: the tenant accepted and it was signed.
 *
 * @param {Doc} r The active_rentals document.
 * @return {boolean} True once the agreement is finalized.
 */
function agreementSettled(r: Doc): boolean {
  return r.agreementStatus === "finalized";
}

/**
 * A rent payout is settled when the landlord has been paid AND the agent has
 * been paid or was never owed anything. Both halves matter: closing on the
 * landlord alone would bury an unpaid agent commission, and the alert body
 * names both amounts.
 *
 * @param {Doc} r The active_rentals document.
 * @return {boolean} True when nothing is left to pay out.
 */
function payoutsSettled(r: Doc): boolean {
  const landlord = r.landlordPayoutStatus;
  const agent = r.agentPayoutStatus;
  return (
    landlord === "paid" &&
    (agent === "paid" || agent === "not_applicable" || agent === undefined)
  );
}

// The lifecycle alert walks one doc through meta.state. Only two states owe an
// admin anything; the rest are the record of what happened. Mirrors
// LIFECYCLE_PENDING in the dashboard's src/lib/alerts.ts - if these two lists
// disagree, the feed calls a row open work while its status says resolved.
const LIFECYCLE_OPEN = new Set(["requested", "paid"]);

const RESOLVERS: Record<string, Resolver> = {
  // The landlord decided (or the interest was cleaned up). Anything other than
  // pending_acceptance means nobody is waiting on them any more.
  rental_interest: {
    collection: "rental_interests",
    done: (t) => t.status !== "pending_acceptance",
  },

  agreement_ready: {collection: "active_rentals", done: agreementSettled},
  // Settled by an admin (resolveMoveInReport) or nothing left to settle.
  move_in_reported: {
    collection: "active_rentals",
    done: (r) => r.moveInCheck !== "reported",
  },
  agreement_disputed: {collection: "active_rentals", done: agreementSettled},
  agreement_rent_mismatch: {
    collection: "active_rentals",
    done: agreementSettled,
  },

  rent_payment: {collection: "active_rentals", done: payoutsSettled},

  // The landlord confirmed the handover, the sweep auto-confirmed it, or the
  // request was withdrawn: either way the tenancy is no longer waiting.
  moveout_requested: {
    collection: "active_rentals",
    done: (t) => t.status !== "moveout_pending",
  },

  // Decided from the inspection review queue: completed, refunded or
  // dismissed all move it out of awaitingOutcome.
  inspection_no_show: {
    collection: "inspection_requests",
    done: (t) => t.status !== "awaitingOutcome",
  },

  // Paid (or otherwise settled) from the Refunds page.
  refund_due: {
    collection: "refunds",
    done: (t) => t.status !== "pending",
  },
  // Raised by paymentReconciliationSweep; done once the payment is no longer
  // flagged, whether the sweep cleared it or an admin did.
  payment_unreconciled: {
    collection: "payments",
    done: (t) => t.needsReconciliation !== true,
  },

  // Raised by issueResponseReminders for one round of the response clock.
  // Done once the issue has moved on (fix offered, resolved), or a new round
  // has started - the landlord acknowledged it, or it was disputed or
  // re-opened, each of which is a response; a later silence raises its own.
  issue_unanswered: {
    collection: "issues",
    done: (t, alert) => {
      if (t.status !== "open" && t.status !== "in_progress") return true;
      const start = t.chaseFrom ?? t.createdAt;
      return start?.toMillis?.() !== alert.meta?.round;
    },
  },

  // The tenant said the fix did not hold, which sent the issue back to
  // in_progress. Done once the landlord offers a fix again or it is resolved.
  // These were closed only on `resolved` (onIssueUpdated), so an alert sat
  // open the whole time the landlord was visibly working the second fix.
  issue_fix_disputed: {
    collection: "issues",
    done: (t) => t.status !== "in_progress",
  },
  // A fix awaiting the tenant's word for 14 days. Done once they answer
  // either way, or an admin closes the issue.
  issue_pending_stale: {
    collection: "issues",
    done: (t) => t.status !== "pending_confirmation",
  },
  // "The caution deposit never reached me." Done once the handover is closed
  // - an admin resolved it, or the tenant confirmed. Nothing clears
  // tenantContested, so the stage is the only reliable signal.
  handover_settlement_contested: {
    collection: "active_rentals",
    done: (t) => t.handoverStage === "closed",
  },

  // Also closed at source by adminReviewPropertyDoc, but a listing approved
  // any other way (the review seed script) or deleted never passed through it,
  // and 10 of 11 open property_created alerts were exactly that on 2026-10-25.
  property_created: {
    collection: "properties",
    done: (t) => t.isVerified === true ||
      ["verified", "rejected", "inherited"].includes(t.ownershipDocStatus),
  },
  // Same shape: closed at source on a verification decision, missed by
  // accounts verified another way.
  user_signed_up: {
    collection: "users",
    done: (t) => t.verificationStatus === "verified",
  },
  verification_submitted: {
    collection: "users",
    done: (t) => t.verificationStatus === "verified" ||
      t.verificationStatus === "rejected",
  },

  // Judged from the alert's own meta - no target read needed.
  inspection_lifecycle: {
    collection: null,
    done: (_t, alert) =>
      !LIFECYCLE_OPEN.has(String(alert.meta?.state ?? "")),
  },

  // "Did this payout ever arrive?" - answered once the beneficiary confirms.
  // The role is in the alert id (payout_unconfirmed_<role>_<rentalId>), so the
  // right receipt field is checked rather than both.
  payout_unconfirmed: {
    collection: "active_rentals",
    done: (t, alert) => {
      const role = String(alert.__id ?? "").split("_")[2] ?? "";
      const receipt = t[`${role}PayoutReceipt`];
      return receipt === "confirmed";
    },
  },

  // A day's inspections, and only that day's. Closed once the day it describes
  // is over - it is a briefing, not a task, and it should not need dismissing.
  inspection_today_digest: {
    collection: null,
    done: (_t, alert) => {
      const created = alert.createdAt?.toDate?.() as Date | undefined;
      if (!created) return false;
      const endOfDay = new Date(created);
      endOfDay.setHours(23, 59, 59, 999);
      return Date.now() > endOfDay.getTime();
    },
  },
};

/**
 * Alert types that close WITHOUT a sweep resolver, and where. Every type a
 * function raises must be in RESOLVERS or here, or
 * scripts/verify_alert_resolvers.js fails. That is the point - two issue
 * alerts and the deposit dispute shipped with no way to close and sat in the
 * queue for good.
 *
 * "manual" means only a human can say it is finished, by design.
 */
export const CLOSED_ELSEWHERE: Record<string, string> = {
  issue_reported: "onIssueUpdated, when the issue is resolved",
  home_proof_submitted: "admin_alert_triggers, when the bill is reviewed",
  property_doc_missing: "property_integrity_ops, when the document arrives",
  inspection_dispute: "admin_review_ops, when the dispute is resolved",
  profile_identity_change: "admin_review_ops, when marked reviewed",
  rent_change_request: "rent_review_ops, when decided",
  payout_disputed: "payout_receipt, when the dispute is resolved",
  rental_end_contested: "manual: whether the tenant really left is a judgement",
};

/** Every alert type the sweep can close. */
export const RESOLVED_TYPES = Object.keys(RESOLVERS);

/**
 * `rent_payment` carries the payment REFERENCE as its targetId, not a rental
 * id, so its rental has to be found by query. Cached per run because two
 * alerts can point at the same tenancy.
 *
 * @param {FirebaseFirestore.Firestore} db Firestore.
 * @param {string} reference The rent payment reference.
 * @return {Promise<Doc | null>} The tenancy, or null if none matches.
 */
async function rentalForPayment(
  db: FirebaseFirestore.Firestore,
  reference: string,
): Promise<Doc | null> {
  const snap = await db
    .collection("active_rentals")
    .where("rentPaymentReference", "==", reference)
    .limit(1)
    .get();
  return snap.empty ? null : snap.docs[0].data();
}

export const alertHygieneSweep = onSchedule(
  {schedule: "every 60 minutes", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const open = await db
      .collection("admin_alerts")
      .where("status", "==", "open")
      .get();

    if (open.empty) {
      logger.info("Alert hygiene sweep: nothing open");
      return;
    }

    const toClose: {ref: FirebaseFirestore.DocumentReference; why: string}[] =
      [];

    for (const doc of open.docs) {
      const alert: Doc = {...doc.data(), __id: doc.id};
      const type = String(alert.type ?? "");
      const rule = RESOLVERS[type];
      // A type with no rule is one a human still owns (profile_identity_change
      // until its Reviewed action exists). Never guess on those.
      if (!rule) continue;

      try {
        if (rule.collection === null) {
          if (rule.done({}, alert)) {
            toClose.push({ref: doc.ref, why: `${type}: finished`});
          }
          continue;
        }

        const targetId = String(alert.targetId ?? "");
        if (!targetId) continue;

        let target: Doc | null;
        if (type === "rent_payment") {
          target = await rentalForPayment(db, targetId);
        } else {
          const snap = await db
            .collection(rule.collection)
            .doc(targetId)
            .get();
          target = snap.exists ? snap.data() ?? null : null;
        }

        // The target is gone. Whatever it was asking for, nobody can act on it
        // now - this is the orphan case a per-collection trigger cannot catch.
        if (target === null) {
          toClose.push({ref: doc.ref, why: `${type}: target gone`});
          continue;
        }

        if (rule.done(target, alert)) {
          toClose.push({ref: doc.ref, why: `${type}: finished`});
        }
      } catch (err) {
        // One malformed alert must not stop the sweep clearing the rest.
        logger.error("Alert hygiene: could not judge alert", {
          alertId: doc.id,
          type,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    if (toClose.length === 0) {
      logger.info("Alert hygiene sweep: nothing to close", {
        open: open.size,
      });
      return;
    }

    // Chunked: a batch takes 500 writes, and the FIRST run is a backfill of
    // everything the feed accumulated before any of this existed.
    for (let i = 0; i < toClose.length; i += 400) {
      const batch = db.batch();
      for (const {ref} of toClose.slice(i, i + 400)) {
        batch.update(ref, {
          status: "resolved",
          resolvedBy: "system",
          resolvedAt: FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }

    logger.info("Alert hygiene sweep closed finished alerts", {
      open: open.size,
      closed: toClose.length,
      reasons: toClose.map((c) => c.why),
    });
  },
);
