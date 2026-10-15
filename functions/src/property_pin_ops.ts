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
import {onDocumentWritten} from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {distanceM} from "./video_viewing_ops";

// A phone outdoors usually reports 5-20m. Indoors or under a roof it can be
// 30-60m. Beyond this the reading isn't worth confirming a pin with.
const MAX_ACCURACY_M = 50;

// Generous box around Nigeria: rejects a 0,0 or a swapped lat/lng.
const NG_BOUNDS = {minLat: 4, maxLat: 14, minLng: 2.6, maxLng: 14.7};

// How far the on-site reading may be from the pin set when listing. Loose
// enough for a pin dropped roughly on a map, tight enough that a Lekki listing
// can't be confirmed from Ikorodu (which made every presence check pass from
// the landlord's sofa). Measured against the FIRST listing pin, kept as
// `listingPin`, so repeated confirmations can't walk the pin away a km at a
// time. Support moves it by clearing `listingPin`.
const MAX_FROM_LISTING_M = 1000;

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

    const locRef = propRef.collection("private").doc("location");
    const loc = (await locRef.get()).data() ?? {};
    const ref = loc.listingPin ??
      (typeof loc.latitude === "number" && typeof loc.longitude === "number" ?
        {latitude: loc.latitude, longitude: loc.longitude} : null);
    // Web listings carry no pin, so there is nothing to compare with; the
    // admin address review is the check there.
    if (ref) {
      const away = distanceM(ref.latitude, ref.longitude, lat, lng);
      if (away > MAX_FROM_LISTING_M) {
        logger.warn("Pin confirmation refused: far from the listing pin", {
          propertyId, role, awayM: Math.round(away),
        });
        // The app tells them to contact support, so support needs to see
        // what happened: the admin pin panel shows this and can accept it.
        await locRef.set({
          lastPinRefusal: {
            latitude: lat,
            longitude: lng,
            accuracyM: Math.round(accuracy),
            awayM: Math.round(away),
            by: uid,
            role,
            at: FieldValue.serverTimestamp(),
          },
        }, {merge: true});
        throw new HttpsError(
          "failed-precondition",
          `You are about ${(away / 1000).toFixed(1)}km from where this ` +
            "listing is on the map. Confirm the pin while standing at the " +
            "property. If the map location itself is wrong, contact support.",
        );
      }
    }

    await locRef.set({
      latitude: lat,
      longitude: lng,
      ...(ref && !loc.listingPin ? {listingPin: ref} : {}),
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

// ─────────────────────────────────────────────────────────────────────────────
// acceptPinRefusal - admin's answer to "the app told me to contact support".
//
// A refusal means an accurate on-site reading landed more than 1km from the
// map pin. Either the map pin was wrong (common: dropped roughly, or listed
// from home) or the reading was taken somewhere else. Admin compares the
// reading with the address and, if it is the property, accepts it: it becomes
// the confirmed pin AND the new 1km reference, so later confirmations measure
// from the right place.
// ─────────────────────────────────────────────────────────────────────────────
export const acceptPinRefusal = onCall(
  {timeoutSeconds: 30},
  async (request) => {
    const t = request.auth?.token;
    if (t?.admin !== true && t?.superAdmin !== true) {
      throw new HttpsError("permission-denied", "Admins only.");
    }
    const propertyId = typeof request.data?.propertyId === "string" ?
      request.data.propertyId.trim() : "";
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "Missing propertyId.");
    }
    const locRef = getFirestore().collection("properties").doc(propertyId)
      .collection("private").doc("location");
    const r = (await locRef.get()).data()?.lastPinRefusal;
    if (!r) {
      throw new HttpsError("failed-precondition", "No refused pin to accept.");
    }
    const point = {latitude: r.latitude, longitude: r.longitude};
    await locRef.update({
      ...point,
      listingPin: point,
      confirmedPin: {
        ...point,
        accuracyM: r.accuracyM,
        confirmedBy: r.by,
        role: r.role,
        confirmedAt: r.at ?? FieldValue.serverTimestamp(),
        acceptedByAdmin: request.auth?.uid ?? null,
      },
      lastPinRefusal: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    logger.info("Admin accepted a refused pin", {
      propertyId, admin: request.auth?.uid, awayM: r.awayM,
    });
    return {ok: true};
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// onPropertyLocationWritten - keeps `videoViewingAvailable` on the listing in
// step with the pin. Tenants can't read private/location (it is the exact
// address), so the booking sheet needs a public answer to "can this be viewed
// by video?". True only while the live pin is the one confirmed on site; a
// hand-moved pin turns it off. firestore.rules make it server-only and refuse
// a video booking without it.
// ─────────────────────────────────────────────────────────────────────────────
export const onPropertyLocationWritten = onDocumentWritten(
  "properties/{propertyId}/private/location",
  async (event) => {
    const d = event.data?.after.data();
    const c = d?.confirmedPin as
      {latitude?: number; longitude?: number} | undefined;
    const available = !!c &&
      c.latitude === d?.latitude && c.longitude === d?.longitude;

    const propRef = getFirestore().collection("properties")
      .doc(event.params.propertyId);
    const prop = await propRef.get();
    if (!prop.exists) return; // the listing itself is being deleted
    if ((prop.get("videoViewingAvailable") === true) === available) return;
    await propRef.update({videoViewingAvailable: available});
    logger.info("videoViewingAvailable updated", {
      propertyId: event.params.propertyId, available,
    });
  },
);
