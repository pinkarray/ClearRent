// ─────────────────────────────────────────────────────────────────────────────
// property_cleanup_ops.ts — cascade cleanup when a property is deleted.
//
// Deleting a property (property_service.deleteProperty) is a raw doc delete
// with no cascade, so admin-queue items that pointed at it are left orphaned.
// An orphaned pending rent-review then 500s when an admin tries to approve it,
// because the callable updates a property doc that no longer exists.
//
// This trigger clears those orphans so nothing dangling reaches the admin.
// Sitting-tenant properties can't be deleted (guarded client-side), so only
// vacant/immediate rent-review requests are ever affected here.
// ─────────────────────────────────────────────────────────────────────────────

import {onDocumentDeleted} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

export const onPropertyDeleted = onDocumentDeleted(
  "properties/{propertyId}",
  async (event) => {
    const propertyId = event.params.propertyId;
    const db = getFirestore();

    // Single-field equality query (auto-indexed — no composite index); filter
    // to still-pending in code.
    const snap = await db
      .collection("rent_review_requests")
      .where("propertyId", "==", propertyId)
      .get();

    const pending = snap.docs.filter((d) => d.data().status === "pending");
    if (pending.length === 0) return;

    const batch = db.batch();
    for (const doc of pending) {
      batch.update(doc.ref, {
        status: "rejected",
        decidedBy: "system",
        decisionReason:
          "Property was deleted before this request was reviewed.",
        decidedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();

    logger.info("Cleared pending rent reviews for deleted property", {
      propertyId,
      count: pending.length,
    });
  },
);
