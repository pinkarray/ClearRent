// ─────────────────────────────────────────────────────────────────────────────
// payment_verify.ts — server-side proof that money actually moved.
//
// Several callables used to take a `paymentReference` as free text, store it,
// and grant the entitlement. Nothing ever asked Paystack whether that
// reference existed, whether it succeeded, or how much it was for — so a
// modified client could mark rent paid, or an inspection paid, without paying
// anything. The reference was decoration on a client-declared payment.
//
// Two things are enforced here, and they are separate concerns:
//
//   1. The charge is REAL. Paystack is asked directly; only `status: success`
//      counts, and the amount must cover what the server independently
//      computed. The client's own claim is never an input.
//
//   2. The charge is SPENT ONCE. A verified reference is written to
//      `payment_references/{reference}` with `.create()`, inside a
//      transaction. Paystack will happily verify the same successful
//      reference forever, so without a ledger one ₦X charge could be replayed
//      across many rentals — which is exactly the open renewal finding
//      (one payment renewing several grace-locked tenancies).
//
// Re-entry is distinguished from replay by `purposeId`: the SAME reference
// against the SAME target is an idempotent retry (a dropped response, a user
// tapping twice) and succeeds quietly. The same reference against a DIFFERENT
// target is the replay this exists to stop.
// ─────────────────────────────────────────────────────────────────────────────

import {HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

/** Where a spent reference is recorded. Admin-SDK only; see firestore.rules. */
const LEDGER = "payment_references";

interface VerifyResult {
  ok: boolean;
  amountPaid: number;
}

/**
 * Ask Paystack whether a reference is a real, successful charge.
 *
 * Mirrors the verify call in index.ts's verifyPayment. Kept here so the money
 * callables share one implementation rather than each growing their own.
 *
 * @param {string} reference The Paystack transaction reference.
 * @param {string} secret The Paystack secret key.
 * @return {Promise<VerifyResult>} ok + the amount actually paid, in Naira.
 */
export async function verifyPaystackReference(
  reference: string,
  secret: string,
): Promise<VerifyResult> {
  const resp = await fetch(
    "https://api.paystack.co/transaction/verify/" +
      encodeURIComponent(reference),
    {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
    },
  );
  const body = (await resp.json()) as {
    status?: boolean;
    data?: {status?: string; amount?: number};
  };
  if (resp.ok && body.status === true && body.data) {
    const txStatus = body.data.status ?? "failed";
    const kobo = typeof body.data.amount === "number" ? body.data.amount : 0;
    return {ok: txStatus === "success", amountPaid: kobo / 100};
  }
  return {ok: false, amountPaid: 0};
}

interface ConsumeInput {
  /** The Paystack reference the client handed us. */
  reference: string;
  /** Paystack secret, resolved by the calling function from Secret Manager. */
  secret: string;
  /** What the SERVER says this costs, in Naira. Never the client's figure. */
  expectedAmount: number;
  /** Coarse label for logs/audit, e.g. "rent" | "inspection". */
  purpose: string;
  /** The thing being paid for — rentalId, inspection requestId, … */
  purposeId: string;
  /** Who is paying, for the audit row. */
  uid: string;
}

/**
 * Verify a reference against Paystack and consume it, or throw.
 *
 * Throws HttpsError on every failure path, so a caller can simply await this
 * before granting anything. Returns the verified amount for the caller to
 * record.
 *
 * @param {ConsumeInput} input Reference, secret, expected amount and target.
 * @return {Promise<number>} The amount Paystack confirmed, in Naira.
 */
export async function verifyAndConsumeReference(
  input: ConsumeInput,
): Promise<number> {
  const {reference, secret, expectedAmount, purpose, purposeId, uid} = input;

  const verdict = await verifyPaystackReference(reference, secret);
  if (!verdict.ok) {
    logger.warn("Payment reference did not verify", {
      purpose, purposeId, uid,
    });
    throw new HttpsError(
      "failed-precondition",
      "We could not confirm that payment. If you were charged, " +
        "contact support.",
    );
  }

  // Under-payment is refused; over-payment is not our problem to adjudicate
  // here and is recorded as-is for admin to reconcile.
  if (verdict.amountPaid < expectedAmount) {
    logger.error("Payment reference is short of the expected amount", {
      purpose, purposeId, uid,
      expected: expectedAmount,
      paid: verdict.amountPaid,
    });
    throw new HttpsError(
      "failed-precondition",
      "The amount paid does not cover this charge. Contact support.",
    );
  }

  // Spend it. `.create()` fails if the doc exists, which is what makes this a
  // ledger rather than a log.
  const db = getFirestore();
  const ref = db.collection(LEDGER).doc(reference);
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(ref);
    if (existing.exists) {
      const prior = existing.data() ?? {};
      // Same target ⇒ this is a retry of the same payment, not a replay.
      if (prior.purposeId === purposeId && prior.purpose === purpose) {
        return;
      }
      logger.error("Payment reference replayed against a different target", {
        purpose, purposeId, uid,
        priorPurpose: prior.purpose,
        priorPurposeId: prior.purposeId,
      });
      throw new HttpsError(
        "failed-precondition",
        "That payment has already been used.",
      );
    }
    tx.create(ref, {
      purpose,
      purposeId,
      uid,
      amount: verdict.amountPaid,
      expectedAmount,
      consumedAt: FieldValue.serverTimestamp(),
    });
  });

  return verdict.amountPaid;
}

