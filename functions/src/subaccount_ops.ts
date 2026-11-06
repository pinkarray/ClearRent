// ─────────────────────────────────────────────────────────────────────────────
// subaccount_ops.ts - a Paystack subaccount for every landlord and agent.
//
// Paystack will only activate ClearRent if each beneficiary's share of a
// payment goes to their own bank through a split, so ClearRent never holds it
// (review email, 30 Oct 2026). A split needs a subaccount per beneficiary, and
// this keeps one in step with the account on users/{uid}/private/bank.
//
// Driven by the server, not the clients: the app and the website already write
// private/bank, so an installed build needs no update. It runs when that doc
// changes and when an account becomes verified, whichever comes second.
//
// payout_accounts/{uid} is the server's record. It is separate from
// private/bank because the owner can write that doc, and a subaccount code they
// could edit would let them redirect a split. It holds no full account number.
//
// Nothing routes money here yet: initializePayment does not pass a split.
// ─────────────────────────────────────────────────────────────────────────────

import {createHash} from "crypto";
import {onDocumentWritten} from "firebase-functions/v2/firestore";
import {defineSecret} from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {writeAdminAlertOnce} from "./admin_alerts";

/** Same secret index.ts binds; defineSecret is keyed by name, not identity. */
const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

// Tenants keep bank details for refunds, but nothing is ever split to them.
const ELIGIBLE_ROLES = new Set(["landlord", "agent"]);

export type SubaccountResult =
  "skipped" | "unchanged" | "created" | "updated" | "failed";

/**
 * Fingerprint of an account, so a change can be spotted without storing the
 * number on a second document.
 * @param {string} bankCode The Paystack bank code.
 * @param {string} accountNumber The account number.
 * @return {string} A hex digest.
 */
function accountKey(bankCode: string, accountNumber: string): string {
  return createHash("sha256")
    .update(`${bankCode}|${accountNumber}`)
    .digest("hex");
}

/**
 * Creates or updates a subaccount on Paystack.
 * @param {string|null} code The existing subaccount code, or null to create.
 * @param {Record<string, unknown>} body The request body.
 * @return {Promise<string>} The subaccount code.
 */
async function callPaystack(
  code: string | null,
  body: Record<string, unknown>,
): Promise<string> {
  const resp = await fetch(
    "https://api.paystack.co/subaccount" +
      (code ? `/${encodeURIComponent(code)}` : ""),
    {
      method: code ? "PUT" : "POST",
      headers: {
        "Authorization": `Bearer ${paystackSecret.value()}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  const json = (await resp.json().catch(() => ({}))) as {
    status?: boolean;
    message?: string;
    data?: {subaccount_code?: string};
  };
  if (!resp.ok || json.status !== true) {
    throw new Error(json.message ?? `Paystack answered ${resp.status}`);
  }
  const returned = json.data?.subaccount_code ?? code;
  if (!returned) throw new Error("Paystack returned no subaccount code");
  return returned;
}

/**
 * Brings one user's subaccount in line with their saved bank account. Safe to
 * run any number of times. Never throws: a failure is recorded and raised to
 * an admin, because it must not fail the write that triggered it.
 * @param {string} uid The user.
 * @return {Promise<SubaccountResult>} What happened.
 */
export async function syncSubaccount(uid: string): Promise<SubaccountResult> {
  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);
  const [userSnap, bankSnap] = await Promise.all([
    userRef.get(),
    userRef.collection("private").doc("bank").get(),
  ]);
  const user = userSnap.data();
  const bank = bankSnap.data();
  if (!user || !bank) return "skipped";
  if (!ELIGIBLE_ROLES.has(user.accountType)) return "skipped";
  if (user.verificationStatus !== "verified") return "skipped";

  const accountNumber = String(bank.accountNumber ?? "").trim();
  const bankCode = String(bank.bankCode ?? "").trim();
  if (!accountNumber || !bankCode) return "skipped";

  const ref = db.collection("payout_accounts").doc(uid);
  const existing = (await ref.get()).data();
  const key = accountKey(bankCode, accountNumber);
  const code = typeof existing?.subaccountCode === "string" ?
    existing.subaccountCode : null;
  if (code && existing?.accountKey === key && existing?.status === "active") {
    return "unchanged";
  }

  const last4 = accountNumber.slice(-4);
  const name = String(bank.accountName ?? user.fullName ?? "ClearRent user");
  try {
    const subaccountCode = await callPaystack(code, {
      business_name: name,
      settlement_bank: bankCode,
      account_number: accountNumber,
      // The share ClearRent keeps when a charge names no amount. Every split
      // will state its own, so this only has to be a valid default.
      percentage_charge: 0,
      description: `ClearRent ${user.accountType} ${uid}`,
    });
    await ref.set({
      uid,
      role: user.accountType,
      subaccountCode,
      accountKey: key,
      bankCode,
      accountLast4: last4,
      accountName: name,
      status: "active",
      lastError: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    logger.info("Subaccount in step", {uid, subaccountCode, last4});
    return code ? "updated" : "created";
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Subaccount sync failed", {uid, last4, error: message});
    await ref.set({
      uid,
      role: user.accountType,
      status: "failed",
      lastError: message,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    await writeAdminAlertOnce(`subaccount_failed_${uid}_${last4}`, {
      type: "subaccount_failed",
      severity: "warning",
      title: "Payout account not set up",
      body: `Paystack would not accept the bank account ending ${last4} ` +
        `for ${name}: ${message}. They cannot be paid until it is fixed.`,
      targetCollection: "payout_accounts",
      targetId: uid,
    });
    return "failed";
  }
}

export const onBankDetailsWritten = onDocumentWritten(
  {document: "users/{uid}/private/bank", secrets: [paystackSecret]},
  async (event) => {
    if (!event.data?.after.exists) return;
    await syncSubaccount(event.params.uid);
  },
);
