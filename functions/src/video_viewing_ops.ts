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

import {onCall, onRequest, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {defineSecret} from "firebase-functions/params";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  DocumentData,
} from "firebase-admin/firestore";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {RtcTokenBuilder, RtcRole} from "agora-token";
import {createHmac, timingSafeEqual} from "crypto";
import {writeNotificationOnce} from "./notification_helpers";

const agoraCertificate = defineSecret("AGORA_APP_CERTIFICATE");

// Public by design: it ships in the app. The certificate is the secret.
export const AGORA_APP_ID = "e1407de77b264f03aa7fa48952c0a0ff";

// Fixed per-channel Agora uids, so join/leave notifications map to a party.
export const TENANT_UID = 1;
export const HANDLER_UID = 2;

// The call may start this long before the slot, and runs until it ends.
const EARLY_START_MS = 30 * 60 * 1000;

/**
 * How long the booked slot runs: the evening slot is 6-8 PM, the others three
 * hours (timeSlotDisplay in inspection_service.dart).
 * @param {DocumentData} req Inspection request.
 * @return {number} Milliseconds.
 */
function slotLengthMs(req: DocumentData): number {
  return (req.requestedTimeSlot === "evening" ? 2 : 3) * 60 * 60 * 1000;
}

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
  if (now > start + slotLengthMs(req)) {
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
  const expiresAtMs = start + slotLengthMs(req) + 30 * 60 * 1000;
  const ttl = Math.max(60, Math.round((expiresAtMs - Date.now()) / 1000));
  const channel = `insp_${requestId}`;
  const token = RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID, agoraCertificate.value(), channel, uid,
    RtcRole.PUBLISHER, ttl, ttl,
  );
  return {appId: AGORA_APP_ID, channel, uid, token, expiresAtMs};
}

/**
 * Check the host is at the property: their GPS against the confirmed pin.
 * Every attempt is logged, failed ones too: a host trying from far away is
 * itself evidence. Throws a user-facing error when the check fails.
 * @param {string} requestId Inspection request id.
 * @param {DocumentData} req Request data.
 * @param {Reading} reading The host's GPS reading.
 * @param {string} stage "checkin" or "start", for the log.
 * @return {Promise<{dist: number, accuracy: number}>} Rounded metres.
 */
async function verifyPresence(
  requestId: string,
  req: DocumentData,
  reading: Reading,
  stage: string,
): Promise<{dist: number; accuracy: number}> {
  const db = getFirestore();
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

  await db.collection("inspection_requests").doc(requestId)
    .collection("video_presence").add({
      stage,
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
        "Check in when you are there.",
    );
  }
  return {dist: Math.round(dist), accuracy: Math.round(reading.accuracyM)};
}

/**
 * Refuse anyone but the host of a request.
 * @param {DocumentData} req Request data.
 * @param {string} uid Caller.
 */
function assertHost(req: DocumentData, uid: string): void {
  if (handlerOf(req) !== uid) {
    throw new HttpsError(
      "permission-denied",
      "Only the person hosting this viewing can do this.",
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// checkInVideoViewing - "I'm at the property".
//
// Split from starting the call on purpose: this is one tiny request that gets
// through on weak 2G, where video would not. It is what the 30-minute grace
// rule and the automatic payouts look at, so a host who is there but cannot
// get a video connection is never treated as absent.
// ─────────────────────────────────────────────────────────────────────────────
export const checkInVideoViewing = onCall(
  {enforceAppCheck: true, timeoutSeconds: 30},
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
    assertHost(req, uid);
    if (req.video?.checkedInAt) return {ok: true, alreadyCheckedIn: true};

    const {dist, accuracy} =
      await verifyPresence(requestId, req, reading, "checkin");
    await getFirestore().collection("inspection_requests").doc(requestId)
      .update({
        "handlerArrived": true,
        "handlerArrivedAt": FieldValue.serverTimestamp(),
        "video.checkedInAt": FieldValue.serverTimestamp(),
        "video.checkInDistanceM": dist,
        "video.checkInAccuracyM": accuracy,
        "updatedAt": FieldValue.serverTimestamp(),
      });
    logger.info("Video viewing check-in", {requestId, distanceM: dist});
    return {ok: true};
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// startVideoViewing - the host, checked in at the property, opens the call.
// A host who skipped the check-in is checked here instead, so either order
// works. The tenant can join only after this.
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

    const req = await loadLiveVideoViewing(requestId);
    assertHost(req, uid);

    // Already started (a dropped call, a second phone): presence was proven.
    if (req.video?.startedAt) {
      return callCredentials(requestId, HANDLER_UID, req);
    }

    const update: Record<string, unknown> = {
      "video.startedAt": FieldValue.serverTimestamp(),
      "video.channel": `insp_${requestId}`,
      "updatedAt": FieldValue.serverTimestamp(),
    };
    if (!req.video?.checkedInAt) {
      const {dist, accuracy} =
        await verifyPresence(requestId, req, readReading(data), "start");
      Object.assign(update, {
        "handlerArrived": true,
        "handlerArrivedAt": FieldValue.serverTimestamp(),
        "video.checkedInAt": FieldValue.serverTimestamp(),
        "video.checkInDistanceM": dist,
        "video.checkInAccuracyM": accuracy,
      });
    }
    await getFirestore().collection("inspection_requests").doc(requestId)
      .update(update);

    if (req.tenantId) {
      const title = req.propertyTitle ?? "the property";
      await writeNotificationOnce(`req_${requestId}_videoStarted`, {
        userId: req.tenantId,
        type: "video_started",
        title: "Your Video Viewing Has Started",
        body: `Your host has started the call from ${title}. Join now.`,
        payload: {
          route: "/tenant/inspections",
          initialTab: "1",
          param_requestId: requestId,
        },
      });
    }
    logger.info("Video viewing started", {requestId});
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

// ─────────────────────────────────────────────────────────────────────────────
// markVideoViewingReady - the tenant says they are waiting for the call.
//
// The tenant can't join before the host starts, so without this nothing
// records that they turned up. It is what makes a host no-show provable, and
// so refundable automatically (videoViewingNoShowSweep). Server time, inside
// the call window only.
// ─────────────────────────────────────────────────────────────────────────────
export const markVideoViewingReady = onCall(
  {enforceAppCheck: true, timeoutSeconds: 15},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const requestId = typeof request.data?.requestId === "string" ?
      request.data.requestId : "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "Missing viewing.");
    }

    const req = await loadLiveVideoViewing(requestId);
    if (req.tenantId !== uid) {
      throw new HttpsError("permission-denied", "This is not your viewing.");
    }
    if (req.tenantReadyAt) return {ok: true, alreadyReady: true};

    await getFirestore().collection("inspection_requests").doc(requestId)
      .update({
        tenantReadyAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    const hostId = handlerOf(req);
    if (hostId && !req.video?.startedAt) {
      await writeNotificationOnce(`req_${requestId}_tenantReady_${hostId}`, {
        userId: hostId,
        type: "video_tenant_ready",
        title: "Your Tenant Is Ready",
        body: `${req.tenantName ?? "The tenant"} is waiting for the video ` +
          `viewing of ${req.propertyTitle ?? "the property"}. Start the call ` +
          "from the property.",
        payload: {
          route: req.agentId ? "/agent/inspections" : "/landlord/inspections",
          initialTab: "1",
          param_requestId: requestId,
        },
      });
    }
    return {ok: true};
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// videoViewingNoShowSweep - settles video viewings nobody needs to judge.
//
// The host's presence is proven by GPS (checkInVideoViewing) and the tenant's
// by "I'm ready" or joining, so three outcomes are certain enough to act on at
// once, every 15 minutes, instead of the nightly sweep:
//
//  1. Host absent. The tenant is ready and the host has not checked in 30
//     minutes after the slot started: refunded (fee minus the booking
//     charge, via onInspectionRefundTriggered), exactly as if the host had
//     cancelled.
//  2. Tenant absent. The host checked in, the slot has ended, and the tenant
//     neither said they were ready nor joined: completed as a tenant no-show,
//     which pays the host (creditInspectionEarnings) as admin review did.
//  3. Call never connected. Both were there (host checked in, tenant ready)
//     but the tenant never got into the call: nobody's fault. Sent to admin
//     review with a free reschedule offered, no automatic money either way.
//
// Anything else (no check-in and no ready tap) proves nothing and is left to
// the nightly inspectionLifecycleSweep, which sends it to admin review.
// ─────────────────────────────────────────────────────────────────────────────
const GRACE_MS = 30 * 60 * 1000;

export const videoViewingNoShowSweep = onSchedule(
  {schedule: "every 15 minutes", timeZone: "Africa/Lagos", timeoutSeconds: 120},
  async () => {
    const db = getFirestore();
    const snap = await db.collection("inspection_requests")
      .where("viewingMode", "==", "video")
      .where("status", "==", "approved")
      .get();

    const counts = {hostAbsent: 0, tenantAbsent: 0, callFailed: 0};
    for (const doc of snap.docs) {
      const d = doc.data();
      const start = (d.requestedDate as Timestamp | undefined)?.toMillis();
      if (start === undefined || d.paymentStatus !== "paid") continue;
      const now = Date.now();
      const checkedIn = !!d.video?.checkedInAt;
      const ready = !!d.tenantReadyAt;
      const joined = d.tenantArrived === true;
      const slotOver = now > start + slotLengthMs(d);
      const title = d.propertyTitle ?? "the property";
      const hostId = handlerOf(d);
      const hostRoute =
        d.agentId ? "/agent/inspections" : "/landlord/inspections";

      if (!checkedIn && ready && now > start + GRACE_MS) {
        await doc.ref.update({
          status: "cancelled",
          paymentStatus: "refunded",
          hostNoShow: true,
          refundReason: "Your host did not arrive for the video viewing",
          cancelledAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        counts.hostAbsent++;
        await writeNotificationOnce(`req_${doc.id}_hostNoShow_${d.tenantId}`, {
          userId: d.tenantId,
          type: "video_host_no_show",
          title: "Video Viewing Refunded",
          body: `Your host didn't arrive for the video viewing of ${title}. ` +
            "We're refunding you.",
          payload: {
            route: "/tenant/inspections",
            initialTab: "2",
            param_requestId: doc.id,
          },
        });
        if (hostId) {
          await writeNotificationOnce(`req_${doc.id}_hostNoShow_${hostId}`, {
            userId: hostId,
            type: "video_host_no_show",
            title: "Missed Video Viewing",
            body: `You hadn't checked in at ${title} 30 minutes after the ` +
              "viewing time while the tenant was waiting, so it has been " +
              "cancelled and refunded.",
            payload: {
              route: hostRoute,
              initialTab: "2",
              param_requestId: doc.id,
            },
          });
        }
        continue;
      }

      if (!slotOver || !checkedIn || joined) continue;

      if (!ready) {
        await doc.ref.update({
          status: "completed",
          completedAt: FieldValue.serverTimestamp(),
          agentPayoutStatus: "pending",
          tenantNoShow: true,
          autoResolved: true,
          updatedAt: FieldValue.serverTimestamp(),
        });
        counts.tenantAbsent++;
        if (hostId) {
          await writeNotificationOnce(`req_${doc.id}_tenantNoShow_${hostId}`, {
            userId: hostId,
            type: "video_tenant_no_show",
            title: "You'll Be Paid for This Viewing",
            body: `The tenant didn't join the video viewing of ${title}. ` +
              "You were at the property, so your fee stands.",
            payload: {
              route: hostRoute,
              initialTab: "2",
              param_requestId: doc.id,
            },
          });
        }
        continue;
      }

      await doc.ref.update({
        status: "awaitingOutcome",
        videoCallFailed: true,
        updatedAt: FieldValue.serverTimestamp(),
      });
      counts.callFailed++;
      await writeNotificationOnce(`req_${doc.id}_callFailed_${d.tenantId}`, {
        userId: d.tenantId,
        type: "video_call_failed",
        title: "Your Video Viewing Didn't Connect",
        body: `Your host was at ${title} but the call didn't connect. ` +
          "We'll help you rebook it at no cost.",
        payload: {
          route: "/tenant/inspections",
          initialTab: "2",
          param_requestId: doc.id,
        },
      });
    }
    logger.info("Video viewing sweep", {checked: snap.size, ...counts});
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// agoraWebhook - Agora's own record of who joined each call, and for how long.
//
// Everything else about a video viewing is reported by our own apps. This is
// Agora's independent account (Notifications, "107 user joined" / "108 user
// left"), so a dispute over whether a call happened has evidence neither
// party controls. Channel `insp_{requestId}`, uid 1 = tenant, 2 = host.
//
// Signed with HMAC-SHA256 over the raw body (Agora-Signature-V2). Agora needs
// a 200 within 10s and retries otherwise, so this always answers 200 and
// simply refuses to RECORD anything unsigned. Events can repeat and arrive
// out of order: each is stored once under its noticeId.
// ─────────────────────────────────────────────────────────────────────────────
const agoraNcsSecret = defineSecret("AGORA_NCS_SECRET");

export const agoraWebhook = onRequest(
  {secrets: [agoraNcsSecret], timeoutSeconds: 10},
  async (req, res) => {
    const signature = String(req.get("Agora-Signature-V2") ?? "");
    const expected = createHmac("sha256", agoraNcsSecret.value())
      .update(req.rawBody ?? Buffer.alloc(0))
      .digest("hex");
    const a = Buffer.from(signature, "utf8");
    const b = Buffer.from(expected, "utf8");
    const valid = a.length === b.length && timingSafeEqual(a, b);

    const body = (req.body ?? {}) as {
      noticeId?: string;
      eventType?: number;
      payload?: {
        channelName?: string;
        uid?: number;
        ts?: number;
        duration?: number;
        reason?: number;
        platform?: number;
        clientSeq?: number;
      };
    };
    if (!valid) {
      logger.warn("agoraWebhook: unsigned or bad signature, not recorded", {
        eventType: body.eventType,
      });
      res.status(200).json({ok: true});
      return;
    }

    const p = body.payload ?? {};
    const requestId = p.channelName?.startsWith("insp_") ?
      p.channelName.slice(5) : null;
    if (!requestId || !body.noticeId ||
        (body.eventType !== 107 && body.eventType !== 108)) {
      res.status(200).json({ok: true});
      return;
    }

    const who = p.uid === TENANT_UID ? "tenant" :
      p.uid === HANDLER_UID ? "host" : "other";
    try {
      const reqRef = getFirestore().collection("inspection_requests")
        .doc(requestId);
      await reqRef.collection("video_events").doc(body.noticeId).create({
        event: body.eventType === 107 ? "joined" : "left",
        who,
        uid: p.uid ?? null,
        agoraTs: p.ts ?? null,
        durationS: p.duration ?? null,
        reason: p.reason ?? null,
        platform: p.platform ?? null,
        clientSeq: p.clientSeq ?? null,
        receivedAt: FieldValue.serverTimestamp(),
      });
      // Running total of time in the call per party, from Agora's own
      // durations. create() above already refused a duplicate noticeId.
      if (body.eventType === 108 && typeof p.duration === "number" &&
          who !== "other") {
        await reqRef.update({
          [`video.agora.${who}Seconds`]: FieldValue.increment(p.duration),
        });
      }
    } catch (err) {
      // ALREADY_EXISTS is a repeat delivery: fine. Anything else is logged
      // but still acknowledged, so Agora does not hammer us with retries.
      if ((err as {code?: number}).code !== 6) {
        logger.error("agoraWebhook: failed to record", {
          requestId, error: err instanceof Error ? err.message : String(err),
        });
      }
    }
    res.status(200).json({ok: true});
  },
);
