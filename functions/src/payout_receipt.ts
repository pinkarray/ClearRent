/**
 * Payout receipt confirmation.
 *
 * Marking a payout "paid" only ever recorded that ClearRent *sent* money. The
 * beneficiary's side of that — whether it actually landed — was never captured,
 * so a transfer that silently failed looked identical to one that worked.
 *
 * These two callables close the loop: the beneficiary confirms or disputes, and
 * on a dispute an admin attaches evidence (a transfer screenshot) and resolves.
 *
 * WHY CALLABLES RATHER THAN CLIENT WRITES + A RULES ALLOWLIST:
 * the agent is not a party to `active_rentals` — not in the update rule and not
 * even in `read`/`list`. Letting an agent confirm their own commission by
 * writing that doc would mean widening both rules to `agentId`, exposing every
 * tenancy field to agents to collect a yes/no. The admin SDK bypasses rules, so
 * this needs no firestore.rules change at all. It also lets the dispute alert
 * be raised in the same call instead of via a second trigger.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import {assertAdmin, writeAuditLog} from "./admin_helpers";
import {writeAdminAlertOnce} from "./admin_alerts";
import {writeNotificationOnce} from "./notification_helpers";

const callableOptions = {
  timeoutSeconds: 30,
  enforceAppCheck: false,
};

type PayoutRole = "landlord" | "agent";

/** Receipt states. Absent on the doc means "awaiting the beneficiary". */
type ReceiptState = "confirmed" | "disputed" | "resolved";

/**
 * Field names for one role's receipt. Landlord and agent are exact mirrors, so
 * every read and write below goes through this rather than string-concatenating
 * field names at each site.
 * @param {PayoutRole} role Which beneficiary.
 * @return {Record<string, string>} The field names for that role.
 */
function fieldsFor(role: PayoutRole) {
  return {
    payoutStatus: `${role}PayoutStatus`,
    receipt: `${role}PayoutReceipt`,
    confirmedAt: `${role}PayoutConfirmedAt`,
    disputedAt: `${role}PayoutDisputedAt`,
    disputeReason: `${role}PayoutDisputeReason`,
    resolvedAt: `${role}PayoutDisputeResolvedAt`,
    resolvedBy: `${role}PayoutDisputeResolvedBy`,
    resolutionNote: `${role}PayoutDisputeResolutionNote`,
    proofPath: `${role}PayoutProofPath`,
    beneficiaryId: role === "landlord" ? "landlordId" : "agentId",
  };
}

/**
 * The deterministic receipt doc written by writeRentPayoutSideEffects. This is
 * the ONLY payout surface an agent can read — `payments` is scoped by `userId`,
 * which is the beneficiary — so the receipt state is mirrored onto it.
 * @param {PayoutRole} role Which beneficiary.
 * @param {string} rentalId The active_rentals doc id.
 * @return {string} The payments doc id.
 */
function receiptDocId(role: PayoutRole, rentalId: string): string {
  return role === "landlord" ?
    `PAYOUT_LANDLORD_${rentalId}` :
    `PAYOUT_AGENT_${rentalId}`;
}

/**
 * One dispute alert per rental per role. Deterministic so a retried call can't
 * fan out duplicates, and so resolution can target this exact doc instead of
 * resolveAdminAlertsForTarget, which would also close unrelated open alerts
 * (e.g. an agreement dispute) that happen to carry the same rentalId.
 * @param {PayoutRole} role Which beneficiary.
 * @param {string} rentalId The active_rentals doc id.
 * @return {string} The admin_alerts doc id.
 */
function disputeAlertId(role: PayoutRole, rentalId: string): string {
  return `payout_dispute_${role}_${rentalId}`;
}

/**
 * Read a non-empty trimmed string field, or throw invalid-argument.
 * @param {unknown} raw The candidate value.
 * @param {string} name Field name, for the error message.
 * @return {string} The trimmed value.
 */
function requireString(raw: unknown, name: string): string {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new HttpsError(
      "invalid-argument",
      `${name} must be a non-empty string.`,
    );
  }
  return raw.trim();
}

/**
 * Mirror the receipt state onto the beneficiary's `payments` receipt.
 * Best-effort: the authoritative state is on the rental, and failing this must
 * not roll back a confirmation the beneficiary already made.
 * @param {PayoutRole} role Which beneficiary.
 * @param {string} rentalId The active_rentals doc id.
 * @param {Record<string, unknown>} patch Fields to merge.
 * @return {Promise<void>} Resolves once attempted.
 */
async function mirrorOntoReceipt(
  role: PayoutRole,
  rentalId: string,
  patch: Record<string, unknown>,
): Promise<void> {
  try {
    await getFirestore()
      .collection("payments")
      .doc(receiptDocId(role, rentalId))
      .set(patch, {merge: true});
  } catch (err) {
    logger.error("Payout receipt mirror failed", {
      rentalId,
      role,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

// ============================================================
// 1. Beneficiary confirms or disputes that the payout landed.
// ============================================================
export const confirmPayoutReceipt = onCall(
  callableOptions,
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }
    const uid = request.auth.uid;
    const raw = (request.data ?? {}) as Record<string, unknown>;

    const rentalId = requireString(raw.rentalId, "rentalId");
    const action = raw.action;
    if (action !== "confirm" && action !== "dispute") {
      throw new HttpsError(
        "invalid-argument",
        "action must be 'confirm' or 'dispute'.",
      );
    }
    // A dispute without a reason is unactionable — admin would have nothing to
    // investigate and nothing to show the beneficiary when resolving.
    const reason = action === "dispute" ?
      requireString(raw.reason, "reason") :
      null;

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(rentalId);

    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", `Rental ${rentalId} not found.`);
      }
      const data = snap.data()!;

      // Role is derived from the doc, never taken from the client — this is
      // what stops an agent confirming the landlord's payout or vice versa.
      let role: PayoutRole;
      if (data.landlordId === uid) {
        role = "landlord";
      } else if (data.agentId === uid) {
        role = "agent";
      } else {
        throw new HttpsError(
          "permission-denied",
          "You are not a beneficiary of this payout.",
        );
      }
      const f = fieldsFor(role);

      if (data[f.payoutStatus] !== "paid") {
        throw new HttpsError(
          "failed-precondition",
          "This payout hasn't been sent yet.",
        );
      }
      // Terminal states. Re-confirming is a no-op worth surfacing rather than
      // silently overwriting a timestamp that is part of the money record.
      const current = data[f.receipt] as ReceiptState | undefined;
      if (current === "confirmed") {
        throw new HttpsError(
          "failed-precondition",
          "You already confirmed this payout.",
        );
      }
      if (current === "disputed") {
        throw new HttpsError(
          "failed-precondition",
          "You already reported this payout as missing — an admin is " +
            "looking into it.",
        );
      }
      if (current === "resolved") {
        throw new HttpsError(
          "failed-precondition",
          "This payout dispute has already been resolved. Contact support " +
            "if the money still hasn't arrived.",
        );
      }

      tx.update(ref, action === "confirm" ?
        {
          [f.receipt]: "confirmed",
          [f.confirmedAt]: FieldValue.serverTimestamp(),
        } :
        {
          [f.receipt]: "disputed",
          [f.disputedAt]: FieldValue.serverTimestamp(),
          [f.disputeReason]: reason,
        });

      return {
        role,
        propertyTitle: (data.propertyTitle as string | undefined) ??
          "your property",
        amount: Number(
          data[role === "landlord" ? "landlordPayout" : "agentPayout"] ?? 0,
        ),
        landlordId: (data.landlordId as string | undefined) ?? undefined,
        agentId: (data.agentId as string | undefined) ?? undefined,
        tenantId: (data.tenantId as string | undefined) ?? undefined,
      };
    });

    const {role} = result;
    await mirrorOntoReceipt(role, rentalId, action === "confirm" ?
      {
        receiptState: "confirmed",
        receiptConfirmedAt: FieldValue.serverTimestamp(),
      } :
      {
        receiptState: "disputed",
        receiptDisputedAt: FieldValue.serverTimestamp(),
        receiptDisputeReason: reason,
      });

    if (action === "dispute") {
      // CRITICAL, not info: `info` alerts do not push to admin devices, and
      // money reported missing is the case that most needs someone to look
      // today. Needs a matching TYPE_META entry in the admin /dashboard/alerts
      // or it renders as a generic bell with no click-through.
      await writeAdminAlertOnce(disputeAlertId(role, rentalId), {
        type: "payout_disputed",
        severity: "critical",
        title: role === "landlord" ?
          "Landlord says the rent payout never arrived" :
          "Agent says the commission payout never arrived",
        body:
          `₦${result.amount.toLocaleString("en-NG")} for ` +
          `${result.propertyTitle} was marked paid, but the ${role} reports ` +
          `it never landed. Reason: ${reason}`,
        targetCollection: "active_rentals",
        targetId: rentalId,
        actors: {
          landlordId: result.landlordId,
          agentId: result.agentId,
          tenantId: result.tenantId,
        },
        meta: {role, amount: result.amount, reason},
      });
    }

    logger.info("Payout receipt recorded", {rentalId, role, action});
    return {success: true, role};
  },
);

// ============================================================
// 2. Admin resolves a disputed payout, with evidence.
// ============================================================
export const resolvePayoutDispute = onCall(
  callableOptions,
  async (request) => {
    assertAdmin(request.auth);
    const adminUid = request.auth!.uid;
    const raw = (request.data ?? {}) as Record<string, unknown>;

    const rentalId = requireString(raw.rentalId, "rentalId");
    const role = raw.role;
    if (role !== "landlord" && role !== "agent") {
      throw new HttpsError(
        "invalid-argument",
        "role must be 'landlord' or 'agent'.",
      );
    }
    const note = requireString(raw.note, "note");
    // Evidence is optional — some disputes resolve because the beneficiary
    // gave the wrong account and the money is genuinely coming back — but when
    // present it must be an object path in our own bucket, never a URL. The
    // bytes are streamed to admins through /api/verification-image.
    let proofPath: string | null = null;
    if (raw.proofPath !== undefined && raw.proofPath !== null) {
      proofPath = requireString(raw.proofPath, "proofPath");
      if (!proofPath.startsWith("payout-proof/")) {
        throw new HttpsError(
          "invalid-argument",
          "proofPath must be under payout-proof/.",
        );
      }
    }

    const db = getFirestore();
    const ref = db.collection("active_rentals").doc(rentalId);
    const f = fieldsFor(role);

    const resolved = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", `Rental ${rentalId} not found.`);
      }
      const data = snap.data()!;
      if (data[f.receipt] !== "disputed") {
        throw new HttpsError(
          "failed-precondition",
          "This payout isn't under dispute.",
        );
      }
      tx.update(ref, {
        [f.receipt]: "resolved",
        [f.resolvedAt]: FieldValue.serverTimestamp(),
        [f.resolvedBy]: adminUid,
        [f.resolutionNote]: note,
        ...(proofPath !== null && {[f.proofPath]: proofPath}),
      });
      return {
        beneficiaryId: (data[f.beneficiaryId] as string | undefined) ?? null,
        amount: Number(
          data[role === "landlord" ? "landlordPayout" : "agentPayout"] ?? 0,
        ),
      };
    });
    const beneficiaryId = resolved.beneficiaryId;

    await writeAuditLog({
      actorId: adminUid,
      action: "resolve_payout_dispute",
      targetCollection: "active_rentals",
      targetId: rentalId,
      amount: resolved.amount,
      // The disputed payout's own receipt id — the reference this resolution
      // is about. There is no separate bank reference for a resolution.
      paymentReference: receiptDocId(role, rentalId),
      paymentNote: note,
    });

    await mirrorOntoReceipt(role, rentalId, {
      receiptState: "resolved",
      receiptResolvedAt: FieldValue.serverTimestamp(),
      receiptResolutionNote: note,
      ...(proofPath !== null && {receiptProofPath: proofPath}),
    });

    // Close the exact alert this dispute raised, not every open alert on the
    // rental.
    try {
      await db.collection("admin_alerts")
        .doc(disputeAlertId(role, rentalId))
        .update({
          status: "resolved",
          resolvedBy: adminUid,
          resolvedAt: FieldValue.serverTimestamp(),
        });
    } catch (err) {
      logger.warn("Payout dispute alert not closed", {
        rentalId,
        role,
        error: err instanceof Error ? err.message : String(err),
      });
    }

    if (beneficiaryId) {
      // Not keyed to the payout alone: a rental can only be resolved once per
      // role, so the rental+role pair is already unique.
      try {
        await writeNotificationOnce(
          `notif_payout_resolved_${role}_${rentalId}`,
          {
            userId: beneficiaryId,
            type: "rent_payout",
            title: "Payout dispute resolved",
            body: note,
            payload: {
              route: role === "agent" ?
                "/agent/documents" :
                "/landlord/earnings",
              rentalId,
            },
          },
        );
      } catch (err) {
        logger.error("Payout resolution notification failed", {
          rentalId,
          role,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    logger.info("Payout dispute resolved", {rentalId, role, adminUid});
    return {success: true};
  },
);
