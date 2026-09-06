// ─────────────────────────────────────────────────────────────────────────────
// property_integrity_ops.ts — server-side invariant for the ownership document.
//
// A standalone listing that says `ownershipDocStatus: 'pending'` is a promise
// that there is a document waiting to be reviewed. The listing
// nWITGF9Lpa043V3PbZ6J ("Room & Parlour") broke that promise:
// `ownershipDocType: 'deed'`, no `ownershipDocUrl`, status 'pending'. The
// Storage upload had 403'd (an unregistered App Check debug token),
// uploadOwnershipDoc swallowed the exception and returned null, and the
// publish carried on regardless.
//
// Both fixes for that are on the CLIENT — add-property and edit-property now
// abort the publish when the upload returns null. Neither helps a listing
// written by an older build, a modified client, or the web listing form. This
// trigger is the invariant the other two only approximate: whatever wrote the
// doc, a review that cannot happen is not left sitting in the admin queue
// pretending it can.
//
// Scoped deliberately to 'pending':
//   - 'none' / 'not_uploaded' / 'rejected' honestly say there is no document.
//   - 'inherited' belongs to a grouped unit, whose document lives on its
//     BUILDING — excluded by the buildingId guard below.
//   - 'verified' with no URL is unreachable: an admin can only verify from the
//     dashboard's document panel, which has nothing to approve when the URL is
//     missing. Repairing it here would mean silently delisting a live property,
//     which is a human's call, not a trigger's.
// ─────────────────────────────────────────────────────────────────────────────

import {onDocumentWritten} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {FieldValue} from "firebase-admin/firestore";
import {upsertAdminAlert, resolveAdminAlertsForTarget} from "./admin_alerts";

const ALERT_TYPE = "property_doc_missing";

// Mirrors OwnershipDocTypes in the app
// (core/constants/ownership_doc_types.dart).
// The stored value is a key, so an unmapped one reads as "a c_of_o" in a
// sentence written for a human.
const DOC_TYPE_LABELS: Record<string, string> = {
  c_of_o: "Certificate of Occupancy",
  deed: "Deed of Assignment",
  governors_consent: "Governor's Consent",
  conveyance: "Deed of Conveyance",
  excision_gazette: "Excision / Gazette",
  other: "document",
};

/**
 * Read the ownership-doc shape off a property snapshot's data.
 *
 * @param {FirebaseFirestore.DocumentData | undefined} d Property doc data.
 * @return {{url: string, type: string, status: string, grouped: boolean}}
 *   Normalised doc fields; missing strings become "".
 */
function docShape(d: FirebaseFirestore.DocumentData | undefined) {
  return {
    url: ((d?.ownershipDocUrl as string | undefined) ?? "").trim(),
    type: ((d?.ownershipDocType as string | undefined) ?? "").trim(),
    status: (d?.ownershipDocStatus as string | undefined) ?? "none",
    grouped: !!(d?.buildingId as string | undefined),
  };
}

export const onPropertyOwnershipDocWritten = onDocumentWritten(
  "properties/{propertyId}",
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) return; // deleted — onPropertyDeleted handles cascade

    const propertyId = event.params.propertyId;
    const d = after.data();
    const now = docShape(d);
    const was = docShape(event.data?.before?.data());

    // A grouped unit owns no document; its building holds the reviewed one.
    if (now.grouped) return;

    // The document arrived (or was replaced) — close the standing alert.
    // Guarded on the transition so this doesn't query admin_alerts on every
    // unrelated property write.
    if (now.url && !was.url) {
      const closed = await resolveAdminAlertsForTarget(
        propertyId, "system", [ALERT_TYPE],
      ).catch(() => 0);
      if (closed > 0) {
        logger.info("Ownership doc arrived, alert closed", {propertyId});
      }
      return;
    }

    // 'pending' with no file is the whole invariant. The doc TYPE is not
    // part of the test — a landlord who set neither is just as un-reviewable
    // as one whose upload failed — it only changes what the alert says.
    if (now.url || now.status !== "pending") return;

    // Repair first: until the status moves, the listing occupies the admin's
    // "docs pending review" queue with nothing to review.
    await after.ref.update({
      ownershipDocStatus: "none",
      updatedAt: FieldValue.serverTimestamp(),
    });

    const title = (d?.title as string | undefined) ?? "A property";
    const landlordName =
      (d?.landlordName as string | undefined) ?? "A landlord";

    // Reads after the "but" in the sentence below, so neither branch may
    // carry its own conjunction.
    const chose = now.type ?
      `the ${DOC_TYPE_LABELS[now.type] ?? now.type} file itself never arrived` :
      "no document was attached at all";

    await upsertAdminAlert(`propdoc_${propertyId}`, {
      type: ALERT_TYPE,
      severity: "warning",
      title: "Ownership document never arrived",
      body:
        `"${title}" was queued for document review, but ${chose}, so there ` +
        "is nothing to review. It has been taken out of the queue — reject " +
        `it from Properties to ask ${landlordName} for the document.`,
      targetCollection: "properties",
      targetId: propertyId,
      actors: {
        landlordId: (d?.landlordId as string | undefined) ?? undefined,
      },
      meta: {
        ownershipDocType: now.type,
        previousStatus: now.status,
      },
    });

    logger.warn("Ownership doc missing — status forced to none", {
      propertyId,
      ownershipDocType: now.type,
    });
  },
);
