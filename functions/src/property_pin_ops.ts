// ─────────────────────────────────────────────────────────────────────────────
// property_pin_ops.ts - a property pin confirmed by someone standing there.
//
// The listing pin is wherever the landlord tapped on a map, possibly from
// miles away, and web listings carry no pin at all. Video viewings prove the
// handler is at the property by comparing their GPS with the pin, which only
// works if the pin itself was taken on site. confirmPropertyPin records that
// reading as `confirmedPin` on properties/{id}/private/location and moves the
// pin to it. Rules stop clients writing `confirmedPin`; a pin moved by hand
// afterwards no longer matches it, which is what "unconfirmed" means.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

// A phone outdoors usually reports 5-20m. Indoors or under a roof it can be
// 30-60m. Beyond this the reading isn't worth confirming a pin with.
const MAX_ACCURACY_M = 50;

// Generous box around Nigeria: rejects a 0,0 or a swapped lat/lng.
const NG_BOUNDS = {minLat: 4, maxLat: 14, minLng: 2.6, maxLng: 14.7};

export const confirmPropertyPin = onCall(
  {enforceAppCheck: true, timeoutSeconds: 30},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

    const d = request.data as {
      propertyId?: unknown;
      latitude?: unknown;
      longitude?: unknown;
      accuracyM?: unknown;
      isMocked?: unknown;
    };
    const propertyId = typeof d?.propertyId === "string" ?
      d.propertyId.trim() : "";
    const lat = d?.latitude;
    const lng = d?.longitude;
    const accuracy = d?.accuracyM;
    if (!propertyId || typeof lat !== "number" || typeof lng !== "number" ||
        typeof accuracy !== "number" || !Number.isFinite(accuracy)) {
      throw new HttpsError("invalid-argument", "Missing location reading.");
    }
    if (d.isMocked === true) {
      throw new HttpsError(
        "failed-precondition",
        "Your phone is reporting a simulated location. Turn off any mock " +
          "location app and try again.",
      );
    }
    if (lat < NG_BOUNDS.minLat || lat > NG_BOUNDS.maxLat ||
        lng < NG_BOUNDS.minLng || lng > NG_BOUNDS.maxLng) {
      throw new HttpsError(
        "invalid-argument",
        "That location is outside Nigeria.",
      );
    }
    if (accuracy > MAX_ACCURACY_M) {
      throw new HttpsError(
        "failed-precondition",
        `Your location is only accurate to about ${Math.round(accuracy)}m. ` +
          "Step outside or near a window and try again.",
      );
    }

    const db = getFirestore();
    const propRef = db.collection("properties").doc(propertyId);
    const prop = (await propRef.get()).data();
    if (!prop) throw new HttpsError("not-found", "Listing not found.");

    let role: "landlord" | "agent" | "caretaker";
    if (prop.landlordId === uid) role = "landlord";
    else if (prop.assignedAgentId === uid) role = "agent";
    else if (prop.caretakerId === uid) role = "caretaker";
    else {
      throw new HttpsError(
        "permission-denied",
        "Only the landlord, agent or caretaker can confirm this pin.",
      );
    }

    await propRef.collection("private").doc("location").set({
      latitude: lat,
      longitude: lng,
      confirmedPin: {
        latitude: lat,
        longitude: lng,
        accuracyM: Math.round(accuracy),
        confirmedBy: uid,
        role,
        confirmedAt: FieldValue.serverTimestamp(),
      },
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});

    logger.info("Property pin confirmed on site", {
      propertyId, role, accuracyM: Math.round(accuracy),
    });
    return {ok: true, latitude: lat, longitude: lng};
  },
);
