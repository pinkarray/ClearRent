/**
 * Server-authoritative inspection-payment confirmation + reveal-on-payment.
 *
 * Pay-after-approve: the tenant requests an inspection UNPAID, the handler
 * approves, and ONLY THEN does the tenant pay. This callable records that
 * payment and unlocks the exact address — both of which must be server-side:
 *
 *   • The reveal grant (properties/{id}/reveals/{tenantId}) and the private
 *     location subdoc are handler-only by security rule. At payment time the
 *     actor is the tenant, so the grant + exact-address fill must run with the
 *     Admin SDK (which bypasses rules). Moving the reveal here — off approval —
 *     is what stops an approved-but-unpaid tenant getting the connection free.
 *
 * Gate: caller must be the tenant on the request, and the request must be
 * "approved" (handler accepted) and not already paid. Idempotent: a replay
 * after it's already paid is a no-op.
 *
 * Note (parity with recordRentPayment): this does not itself re-verify the
 * transaction with Paystack — the HMAC-verified paystackWebhook remains the
 * gateway-authoritative reconciler for the payments record.
 */

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

interface ConfirmInspectionPaymentInput {
  requestId?: unknown;
  paymentReference?: unknown;
}

export const confirmInspectionPayment = onCall(
  {timeoutSeconds: 30, enforceAppCheck: true},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;

    const data = request.data as ConfirmInspectionPaymentInput;
    const rawId = data.requestId;
    if (typeof rawId !== "string" || rawId.trim().length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "requestId must be a non-empty string.",
      );
    }
    const requestId = rawId.trim();

    let paymentReference: string | null = null;
    if (
      typeof data.paymentReference === "string" &&
      data.paymentReference.trim().length > 0
    ) {
      paymentReference = data.paymentReference.trim();
    }

    const db = getFirestore();
    const ref = db.collection("inspection_requests").doc(requestId);
    const snap = await ref.get();
    const insp = snap.data();
    if (!insp) {
      throw new HttpsError("not-found", "Inspection request not found.");
    }
    if (insp.tenantId !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only the tenant on this inspection can pay it.",
      );
    }

    // Idempotent replay: already paid → reveal already done.
    if (insp.paymentStatus === "paid") {
      return {success: true, alreadyPaid: true};
    }

    // Pay-after-approve: only a handler-approved inspection is payable.
    if (insp.status !== "approved") {
      throw new HttpsError(
        "failed-precondition",
        "This inspection isn't approved yet.",
      );
    }

    const propertyId = insp.propertyId as string | undefined;

    const update: Record<string, unknown> = {
      paymentStatus: "paid",
      paidAt: FieldValue.serverTimestamp(),
      paymentReference,
      locationRevealedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (propertyId) {
      // Reveal-on-payment: fill the exact address + coordinates from the gated
      // location subdoc so the tenant sees them only now that they've paid.
      try {
        const locSnap = await db
          .collection("properties")
          .doc(propertyId)
          .collection("private")
          .doc("location")
          .get();
        const loc = locSnap.data();
        if (loc) {
          const exactAddress = loc.address as string | undefined;
          if (exactAddress && exactAddress.length > 0) {
            update.propertyAddress = exactAddress;
          }
          if (typeof loc.latitude === "number") {
            update.propertyLatitude = loc.latitude;
          }
          if (typeof loc.longitude === "number") {
            update.propertyLongitude = loc.longitude;
          }
        }
      } catch (err) {
        logger.error("confirmInspectionPayment: could not read location", {
          requestId,
          error: err instanceof Error ? err.message : String(err),
        });
      }

      // Grant the tenant read access to the exact location (handler-only by
      // rule; the Admin SDK bypasses it). Best-effort — a failed grant is
      // logged, but the paid flip still stands.
      try {
        await db
          .collection("properties")
          .doc(propertyId)
          .collection("reveals")
          .doc(uid)
          .set(
            {
              revealedAt: FieldValue.serverTimestamp(),
              requestId,
              grantedBy: "system_payment",
            },
            {merge: true},
          );
      } catch (err) {
        logger.error("confirmInspectionPayment: reveal grant failed", {
          requestId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    await ref.update(update);

    logger.info("Inspection payment confirmed + address revealed", {
      requestId,
      uid,
    });
    return {success: true, alreadyPaid: false};
  },
);
