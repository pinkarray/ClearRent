// ─────────────────────────────────────────────────────────────────────────────
// video_viewing_ops.ts - a viewing held as a live video call (Agora), with the
// handler at the property.
//
// The fee and the split are the in-person ones, because the handler still
// travels: the call can only start once the handler's GPS puts them at the
// property's confirmed pin (confirmPropertyPin). That makes the evidence
// stronger than an in-person "I've arrived" tap, which checks nothing.
//
// Arrival is recorded on the SAME fields an in-person viewing uses, so the
// lifecycle sweep, no-show rules, completion and payout need no video branch:
//   handlerArrived  <- startVideoViewing, after the presence check
//   tenantArrived   <- joinVideoViewing, when the tenant joins the call
// Firestore rules refuse both taps on a video viewing, so only these can set
// them. The meeting is still confirmed by both sides as usual.
//
// Evidence lives under `video` on the request and in its `video_presence`
// subcollection; Agora's own join/leave notifications are added separately.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {defineSecret} from "firebase-functions/params";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  DocumentData,
} from "firebase-admin/firestore";
import {RtcTokenBuilder, RtcRole} from "agora-token";

const agoraCertificate = defineSecret("AGORA_APP_CERTIFICATE");

// Public by design: it ships in the app. The certificate is the secret.
export const AGORA_APP_ID = "e1407de77b264f03aa7fa48952c0a0ff";

// Fixed per-channel Agora uids, so join/leave notifications map to a party.
export const TENANT_UID = 1;
export const HANDLER_UID = 2;

// The call may start this long before the slot, and runs until it ends.
const EARLY_START_MS = 30 * 60 * 1000;
const SLOT_LENGTH_MS = 3 * 60 * 60 * 1000;

// Presence: the reading's uncertainty is given the benefit of the doubt, but
// the result must still land within this distance of the confirmed pin. The
// pin rule is stricter (50m accuracy) because it is taken once, outdoors; the
// handler starts the call at the gate and indoor GPS is far worse (tested
// 2026-10-13: no fix at all indoors in 15s).
const PRESENCE_RADIUS_M = 100;
const MAX_PRESENCE_ACCURACY_M = 100;

type Reading = {lat: number; lng: number; accuracyM: number; isMocked: boolean};

/**
 * @param {unknown} d Callable data.
 * @return {Reading} A validated GPS reading.
 */
function readReading(d: Record<string, unknown>): Reading {
  const {latitude, longitude, accuracyM, isMocked} = d;
  if (typeof latitude !== "number" || typeof longitude !== "number" ||
      typeof accuracyM !== "number" || !Number.isFinite(accuracyM)) {
    throw new HttpsError("invalid-argument", "Missing location reading.");
  }
  return {
    lat: latitude, lng: longitude, accuracyM, isMocked: isMocked === true,
  };
}

/**
 * Great-circle distance in metres.
 * @param {number} lat1 Latitude A.
 * @param {number} lng1 Longitude A.
 * @param {number} lat2 Latitude B.
 * @param {number} lng2 Longitude B.
 * @return {number} Metres.
 */
export function distanceM(
  lat1: number, lng1: number, lat2: number, lng2: number,
): number {
  const r = 6371000;
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLng = (lng2 - lng1) * rad;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(a));
}

/**
 * The person conducting the viewing: the assigned agent, else the landlord.
 * Mirrors isHandler() in firestore.rules.
 * @param {DocumentData} req Inspection request.
 * @return {string | null} Handler uid.
 */
function handlerOf(req: DocumentData): string | null {
  return (req.agentId as string | null) ?? (req.landlordId as string | null);
}

/**
 * Load the request and check it is a paid, approved video viewing inside its
 * call window.
 * @param {string} requestId Inspection request id.
 * @return {Promise<DocumentData>} The request data.
 */
async function loadLiveVideoViewing(requestId: string): Promise<DocumentData> {
  const snap = await getFirestore()
    .collection("inspection_requests").doc(requestId).get();
  const req = snap.data();
  if (!req) throw new HttpsError("not-found", "Viewing not found.");
  if (req.viewingMode !== "video") {
    throw new HttpsError("failed-precondition", "This is not a video viewing.");
  }
  if (req.status !== "approved" || req.paymentStatus !== "paid") {
    throw new HttpsError(
      "failed-precondition",
      "This viewing is not approved and paid.",
    );
  }
  const start = (req.requestedDate as Timestamp | undefined)?.toMillis();
  const now = Date.now();
  if (start === undefined || now < start - EARLY_START_MS) {
    throw new HttpsError(
      "failed-precondition",
      "The call opens 30 minutes before the viewing time.",
    );
  }
  if (now > start + SLOT_LENGTH_MS) {
    throw new HttpsError("failed-precondition", "This viewing slot has ended.");
  }
  return req;
}

/**
 * An Agora token for one party, valid until the slot ends (plus a margin for
 * a call that runs over).
 * @param {string} requestId Request id, also the channel name.
 * @param {number} uid TENANT_UID or HANDLER_UID.
 * @param {DocumentData} req Request data.
 * @return {object} What the client needs to join.
 */
function callCredentials(requestId: string, uid: number, req: DocumentData) {
  const start = (req.requestedDate as Timestamp).toMillis();
  const expiresAtMs = start + SLOT_LENGTH_MS + 30 * 60 * 1000;
  const ttl = Math.max(60, Math.round((expiresAtMs - Date.now()) / 1000));
  const channel = `insp_${requestId}`;
  const token = RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID, agoraCertificate.value(), channel, uid,
    RtcRole.PUBLISHER, ttl, ttl,
  );
  return {appId: AGORA_APP_ID, channel, uid, token, expiresAtMs};
}

// ─────────────────────────────────────────────────────────────────────────────
// startVideoViewing - the handler, at the property, opens the call.
// ─────────────────────────────────────────────────────────────────────────────
export const startVideoViewing = onCall(
  {enforceAppCheck: true, timeoutSeconds: 30, secrets: [agoraCertificate]},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const data = (request.data ?? {}) as Record<string, unknown>;
    const requestId = typeof data.requestId === "string" ? data.requestId : "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "Missing viewing.");
    }
    const reading = readReading(data);

    const req = await loadLiveVideoViewing(requestId);
    if (handlerOf(req) !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only the person hosting this viewing can start the call.",
      );
    }

    const db = getFirestore();
    const reqRef = db.collection("inspection_requests").doc(requestId);

    // Already started (a dropped call, a second phone): presence was proven.
    if (req.video?.startedAt) {
      return callCredentials(requestId, HANDLER_UID, req);
    }

    const loc = (await db.collection("properties").doc(req.propertyId)
      .collection("private").doc("location").get()).data();
    const pin = loc?.confirmedPin as {latitude: number; longitude: number} |
      undefined;
    if (!pin) {
      throw new HttpsError(
        "failed-precondition",
        "This property's pin has not been confirmed on site, so a video " +
          "viewing can't prove you are there.",
      );
    }

    const dist =
      distanceM(reading.lat, reading.lng, pin.latitude, pin.longitude);
    const effective = Math.max(0, dist - reading.accuracyM);
    const ok = !reading.isMocked &&
      reading.accuracyM <= MAX_PRESENCE_ACCURACY_M &&
      effective <= PRESENCE_RADIUS_M;

    // Every attempt is kept, failed ones too: a handler trying from far away
    // is itself evidence.
    await reqRef.collection("video_presence").add({
      stage: "start",
      ok,
      distanceM: Math.round(dist),
      accuracyM: Math.round(reading.accuracyM),
      isMocked: reading.isMocked,
      at: FieldValue.serverTimestamp(),
    });

    if (reading.isMocked) {
      throw new HttpsError(
        "failed-precondition",
        "Your phone is reporting a simulated location. Turn off any mock " +
          "location app and try again.",
      );
    }
    if (reading.accuracyM > MAX_PRESENCE_ACCURACY_M) {
      throw new HttpsError(
        "failed-precondition",
        "Your location is only accurate to about " +
          `${Math.round(reading.accuracyM)}m. Step outside, at the gate or ` +
          "in the compound, and try again.",
      );
    }
    if (!ok) {
      throw new HttpsError(
        "failed-precondition",
        `You seem to be about ${Math.round(dist)}m from the property. ` +
          "Start the call when you are there.",
      );
    }

    await reqRef.update({
      "handlerArrived": true,
      "handlerArrivedAt": FieldValue.serverTimestamp(),
      "video.startedAt": FieldValue.serverTimestamp(),
      "video.channel": `insp_${requestId}`,
      "video.startDistanceM": Math.round(dist),
      "video.startAccuracyM": Math.round(reading.accuracyM),
      "updatedAt": FieldValue.serverTimestamp(),
    });
    logger.info("Video viewing started", {
      requestId, distanceM: Math.round(dist),
    });
    return callCredentials(requestId, HANDLER_UID, req);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// joinVideoViewing - the tenant joins a call the handler has opened. Also how
// the handler rejoins after a drop, without a second presence check.
// ─────────────────────────────────────────────────────────────────────────────
export const joinVideoViewing = onCall(
  {enforceAppCheck: true, timeoutSeconds: 30, secrets: [agoraCertificate]},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const requestId = typeof request.data?.requestId === "string" ?
      request.data.requestId : "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "Missing viewing.");
    }

    const req = await loadLiveVideoViewing(requestId);
    const isTenant = req.tenantId === uid;
    const isHandler = handlerOf(req) === uid;
    if (!isTenant && !isHandler) {
      throw new HttpsError("permission-denied", "This is not your viewing.");
    }
    if (!req.video?.startedAt) {
      throw new HttpsError(
        "failed-precondition",
        isTenant ?
          "Your host hasn't started the call yet. You'll be notified when " +
            "they do." :
          "Start the call from the property first.",
      );
    }

    if (isTenant && req.tenantArrived !== true) {
      await getFirestore().collection("inspection_requests").doc(requestId)
        .update({
          "tenantArrived": true,
          "tenantArrivedAt": FieldValue.serverTimestamp(),
          "video.tenantJoinedAt": FieldValue.serverTimestamp(),
          "updatedAt": FieldValue.serverTimestamp(),
        });
    }
    return callCredentials(requestId, isTenant ? TENANT_UID : HANDLER_UID, req);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// recordVideoPresence - the handler's phone reports its position during the
// call. Never refuses: indoors there may be no fix at all, and a call must not
// drop because of it. The samples are evidence for review, not a gate.
// ─────────────────────────────────────────────────────────────────────────────
export const recordVideoPresence = onCall(
  {enforceAppCheck: true, timeoutSeconds: 15},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const data = (request.data ?? {}) as Record<string, unknown>;
    const requestId = typeof data.requestId === "string" ? data.requestId : "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "Missing viewing.");
    }

    const db = getFirestore();
    const reqRef = db.collection("inspection_requests").doc(requestId);
    const req = (await reqRef.get()).data();
    if (!req || handlerOf(req) !== uid || !req.video?.startedAt) {
      throw new HttpsError("permission-denied", "Not a live call you host.");
    }

    const sample: Record<string, unknown> = {
      stage: "during",
      at: FieldValue.serverTimestamp(),
    };
    if (typeof data.latitude === "number") {
      const reading = readReading(data);
      const loc = (await db.collection("properties").doc(req.propertyId)
        .collection("private").doc("location").get()).data();
      const pin = loc?.confirmedPin;
      if (pin) {
        sample.distanceM = Math.round(
          distanceM(reading.lat, reading.lng, pin.latitude, pin.longitude));
      }
      sample.accuracyM = Math.round(reading.accuracyM);
      sample.isMocked = reading.isMocked;
    } else {
      sample.noFix = true;
    }
    await reqRef.collection("video_presence").add(sample);
    return {ok: true};
  },
);
