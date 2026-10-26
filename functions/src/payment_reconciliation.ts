// ─────────────────────────────────────────────────────────────────────────────
// payment_reconciliation.ts - did the money do its job?
//
// paystackWebhook marks a payment `needsReconciliation` when Paystack reports
// a charge nobody had recorded yet. That is every web payment (the web never
// writes payments docs) and any app payment whose phone died after the charge,
// so the flag alone means nothing. What matters is whether the thing that was
// paid for happened: the inspection marked paid, the listing fee recorded,
// the rent recorded, the verification fee stamped. Each per-type confirm
// writes the payment reference onto its target, which is the test used here.
//
// The confirm can land before or after the webhook, so this is a sweep rather
// than a hook on either: after an hour, a flagged payment whose target carries
// its reference is cleared; one whose target doesn't becomes an admin alert,
// "charged, but nothing happened". The alert closes itself (alert_resolution)
// once the flag clears, by this sweep or by hand.
// ─────────────────────────────────────────────────────────────────────────────

import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeAdminAlertOnce} from "./admin_alerts";

type Doc = FirebaseFirestore.DocumentData;

// Long enough for any confirm still in flight to land.
const SETTLE_MS = 60 * 60 * 1000;

/**
 * Where a payment's effect is recorded, and the field that holds its
 * reference once it has happened. Null when the payment carries no id to
 * find its target by, which can't be judged and so goes to an admin.
 *
 * @param {Doc} p The payments document.
 * @return {{path: string, field: string} | null} Target and field.
 */
function targetOf(p: Doc): {path: string; field: string} | null {
  const id = (k: string) => (typeof p[k] === "string" && p[k] ? p[k] : null);
  switch (p.type) {
  case "inspection":
    return id("requestId") ?
      {path: `inspection_requests/${id("requestId")}`,
        field: "paymentReference"} : null;
  case "listing":
    return id("propertyId") ?
      {path: `properties/${id("propertyId")}`,
        field: "listingFeePaymentReference"} : null;
  case "rent":
    return id("rentalInterestId") ?
      {path: `rental_interests/${id("rentalInterestId")}`,
        field: "paymentReference"} : null;
  // Both record their reference on the rental they paid for. Renewal used
  // to share the verification case, which looked on the user doc and so
  // could never match.
  case "renewal":
    return id("sourceId") ?
      {path: `active_rentals/${id("sourceId")}`,
        field: "renewalPaymentReference"} : null;
  case "extension":
    return id("sourceId") ?
      {path: `active_rentals/${id("sourceId")}`,
        field: "lastExtensionReference"} : null;
  case "verification":
    return id("userId") ?
      {path: `users/${id("userId")}`,
        field: "verificationPaymentReference"} : null;
  default:
    return null;
  }
}

export const paymentReconciliationSweep = onSchedule(
  {schedule: "every 60 minutes", timeoutSeconds: 300},
  async () => {
    const db = getFirestore();
    const flagged = await db.collection("payments")
      .where("needsReconciliation", "==", true).get();
    const cutoff = Date.now() - SETTLE_MS;
    let cleared = 0;
    let raised = 0;

    for (const doc of flagged.docs) {
      const p = doc.data();
      const created = p.createdAt instanceof Timestamp ?
        p.createdAt.toMillis() : 0;
      if (created > cutoff) continue;

      const target = targetOf(p);
      const t = target ? (await db.doc(target.path).get()).data() : undefined;
      if (target && t?.[target.field] === doc.id) {
        await doc.ref.update({
          needsReconciliation: false,
          reconciledAt: FieldValue.serverTimestamp(),
        });
        cleared++;
        continue;
      }

      const amount = typeof p.gatewayAmount === "number" ?
        p.gatewayAmount : p.amount;
      const alertId = `payment_unreconciled_${doc.id}`;
      const written = await writeAdminAlertOnce(alertId, {
        type: "payment_unreconciled",
        severity: "critical",
        title: "Charged, but nothing happened",
        body: `A ₦${Number(amount ?? 0).toLocaleString("en-NG")} ` +
          `${p.type ?? "unknown"} payment went through over an hour ago, ` +
          "but what it paid for was never recorded. Check it and either " +
          "complete it or refund the payer.",
        targetCollection: "payments",
        targetId: doc.id,
        meta: {
          reference: doc.id,
          paymentType: p.type ?? null,
          amount: amount ?? null,
          userId: p.userId ?? null,
          target: target?.path ?? null,
        },
      });
      if (written) raised++;
    }

    logger.info("Payment reconciliation sweep", {
      flagged: flagged.size, cleared, raised,
    });
  },
);
