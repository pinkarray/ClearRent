// ─────────────────────────────────────────────────────────────────────────────
// phone_otp_ops.ts - phone sign-in codes sent by us (Termii), not by Firebase.
//
// Firebase Phone Auth fails for Glo and Airtel numbers with 17499 / Error 39
// on Google's side (MTN and 9mobile work). Termii delivers to Glo, so the
// code is generated, sent and checked here, and a verified number is turned
// into a Firebase custom token. The Auth user still carries `phoneNumber`, so
// existing phone accounts keep their uid and lookupEmailByPhone keeps working.
//
// config/otp decides which path the clients take:
//   provider: "termii" | "firebase"   anything but "termii" means Firebase,
//                                     so a missing doc changes nothing.
//   senderId, channel                 Termii sender and route ("dnd").
//   appHashes                         SMS Retriever hashes; the Play-signed
//                                     app's is Rf8Bi5AnvRF. Without one in
//                                     the SMS, Android never hands it over.
//   webOtpDomain                      adds the "@domain #code" line Chrome on
//                                     Android uses to autofill on the website.
//   dailyCap                          SMS sends per day across all numbers.
//   testPhones                        E.164 numbers that get Termii even while
//                                     provider is "firebase", so a release
//                                     can be tested before everyone moves.
//
// The code itself is never stored, only a salted hash. phone_otps and
// _otp_limits have no rules, so clients cannot read or write them.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError, CallableRequest} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {defineSecret} from "firebase-functions/params";
import {getFirestore, Timestamp, FieldValue} from "firebase-admin/firestore";
import {getAuth} from "firebase-admin/auth";
import {createHash, randomBytes, randomInt, timingSafeEqual} from "crypto";

const termiiApiKey = defineSecret("TERMII_API_KEY");

const CODE_TTL_MS = 10 * 60 * 1000;
const RESEND_AFTER_MS = 60 * 1000;
const MAX_SENDS_PER_PHONE_PER_HOUR = 5;
const MAX_SENDS_PER_IP_PER_HOUR = 10;
const MAX_VERIFY_ATTEMPTS = 5;
const DEFAULT_DAILY_CAP = 2000;
const HOUR_MS = 60 * 60 * 1000;

interface OtpConfig {
  provider: "termii" | "firebase";
  senderId: string;
  channel: string;
  appHashes: string[];
  webOtpDomain: string | null;
  dailyCap: number;
}

/**
 * Read config/otp for one number. Anything malformed falls back to Firebase,
 * the path that already works for MTN and 9mobile.
 * @param {string} e164 The number the code is for.
 * @return {Promise<OtpConfig>} The effective config.
 */
async function readOtpConfig(e164: string): Promise<OtpConfig> {
  const d = (await getFirestore().collection("config").doc("otp").get())
    .data() ?? {};
  const senderId = typeof d.senderId === "string" ? d.senderId.trim() : "";
  const testing = Array.isArray(d.testPhones) && d.testPhones.includes(e164);
  return {
    provider: (d.provider === "termii" || testing) && senderId ?
      "termii" : "firebase",
    senderId,
    channel: typeof d.channel === "string" && d.channel ? d.channel : "dnd",
    appHashes: Array.isArray(d.appHashes) ?
      d.appHashes.filter((h: unknown) =>
        typeof h === "string" && /^[A-Za-z0-9+/]{11}$/.test(h)) :
      [],
    webOtpDomain: typeof d.webOtpDomain === "string" && d.webOtpDomain ?
      d.webOtpDomain : null,
    dailyCap: typeof d.dailyCap === "number" && d.dailyCap > 0 ?
      d.dailyCap : DEFAULT_DAILY_CAP,
  };
}

/**
 * Nigerian mobile number to E.164 (+234XXXXXXXXXX), or null.
 * @param {unknown} raw Caller input: 0803..., +234803..., 234803... or 803...
 * @return {string | null} E.164 number.
 */
function toE164(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const digits = raw.replace(/[\s\-()+]/g, "");
  if (!/^\d+$/.test(digits)) return null;
  let subscriber: string;
  if (digits.length === 11 && digits.startsWith("0")) {
    subscriber = digits.slice(1);
  } else if (digits.length === 13 && digits.startsWith("234")) {
    subscriber = digits.slice(3);
  } else if (digits.length === 10) {
    subscriber = digits;
  } else {
    return null;
  }
  return /^[789]\d{9}$/.test(subscriber) ? "+234" + subscriber : null;
}

/**
 * @param {string} s Input.
 * @return {string} Hex SHA-256.
 */
function sha256(s: string): string {
  return createHash("sha256").update(s).digest("hex");
}

/**
 * Caller IP, first x-forwarded-for hop. Only ever stored hashed.
 * @param {CallableRequest} request The callable request.
 * @return {string} The IP or "unknown".
 */
function callerIp(request: CallableRequest): string {
  const fwd = request.rawRequest.headers["x-forwarded-for"];
  const first = Array.isArray(fwd) ? fwd[0] : fwd;
  if (typeof first === "string" && first) return first.split(",")[0].trim();
  return request.rawRequest.ip ?? "unknown";
}

/**
 * The SMS body. The app hash must END the message: with the WebOTP line
 * after it, Android delivered the SMS to the inbox but not to the app
 * (tested 2026-10-13). So the hash rides at the end of the WebOTP line.
 * @param {string} code The 6-digit code.
 * @param {OtpConfig} cfg Effective config.
 * @return {string} Message text.
 */
function buildMessage(code: string, cfg: OtpConfig): string {
  const lines = [
    `Your ClearRent verification code is ${code}. ` +
      "It expires in 10 minutes. " +
      "Do not share it.",
  ];
  const last = [
    ...(cfg.webOtpDomain ? [`@${cfg.webOtpDomain} #${code}`] : []),
    ...cfg.appHashes,
  ];
  if (last.length) lines.push(last.join(" "));
  return lines.join("\n");
}

/**
 * Send one SMS through Termii.
 * @param {string} e164 Recipient.
 * @param {string} message Body.
 * @param {OtpConfig} cfg Sender and route.
 * @return {Promise<string>} Termii message id.
 */
async function sendViaTermii(
  e164: string,
  message: string,
  cfg: OtpConfig,
): Promise<string> {
  const resp = await fetch("https://v3.api.termii.com/api/sms/send", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      api_key: termiiApiKey.value(),
      to: e164.slice(1), // Termii wants 234..., no plus
      from: cfg.senderId,
      sms: message,
      type: "plain",
      channel: cfg.channel,
    }),
  });
  const body = (await resp.json().catch(() => ({}))) as {
    code?: string;
    message_id?: string;
    message?: string;
  };
  if (!resp.ok || body.code !== "ok" || !body.message_id) {
    throw new Error(`Termii ${resp.status}: ${body.message ?? "no message"}`);
  }
  return body.message_id;
}

/**
 * Count one send against a rolling hourly window, or refuse.
 * @param {string} docId _otp_limits doc id.
 * @param {number} max Sends allowed per hour.
 * @return {Promise<boolean>} True when allowed (and counted).
 */
async function takeHourlySlot(docId: string, max: number): Promise<boolean> {
  const db = getFirestore();
  const ref = db.collection("_otp_limits").doc(docId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const start = snap.get("windowStart") as Timestamp | undefined;
    const fresh = !start || now - start.toMillis() > HOUR_MS;
    const count = fresh ? 0 : (snap.get("count") as number) ?? 0;
    if (count >= max) return false;
    tx.set(ref, {
      windowStart: fresh ? Timestamp.fromMillis(now) : start,
      count: count + 1,
      expiresAt: Timestamp.fromMillis(now + 2 * HOUR_MS),
    });
    return true;
  });
}

/**
 * Count one send against today's global cap (Lagos day), or refuse. A cost
 * guard against SMS pumping, not a per-user limit.
 * @param {number} cap Sends allowed today.
 * @return {Promise<boolean>} True when allowed (and counted).
 */
async function takeDailySlot(cap: number): Promise<boolean> {
  const db = getFirestore();
  const day = new Date(Date.now() + 3600_000).toISOString().slice(0, 10);
  const ref = db.collection("_otp_limits").doc(`day_${day}`);
  return db.runTransaction(async (tx) => {
    const count = ((await tx.get(ref)).get("count") as number) ?? 0;
    if (count >= cap) return false;
    tx.set(ref, {count: count + 1}, {merge: true});
    return true;
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// requestPhoneOtp
//
// Returns {provider: "firebase"} when Termii is off, and the client carries on
// with Firebase Phone Auth exactly as before. Otherwise sends a code and
// returns {provider: "termii", resendAfterSeconds}.
// ─────────────────────────────────────────────────────────────────────────────
export const requestPhoneOtp = onCall(
  {enforceAppCheck: true, timeoutSeconds: 30, secrets: [termiiApiKey]},
  async (request) => {
    const e164 = toE164((request.data as {phone?: unknown})?.phone);
    if (!e164) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid Nigerian mobile number.",
      );
    }

    const cfg = await readOtpConfig(e164);
    if (cfg.provider !== "termii") return {provider: "firebase"};

    const db = getFirestore();
    const otpRef = db.collection("phone_otps").doc(e164);
    const last = (await otpRef.get()).get("sentAt") as Timestamp | undefined;
    if (last && Date.now() - last.toMillis() < RESEND_AFTER_MS) {
      const wait = Math.ceil(
        (RESEND_AFTER_MS - (Date.now() - last.toMillis())) / 1000);
      throw new HttpsError(
        "resource-exhausted",
        `Please wait ${wait}s before requesting another code.`,
      );
    }

    const ipHash = sha256(callerIp(request));
    if (!(await takeHourlySlot(`phone_${sha256(e164)}`,
      MAX_SENDS_PER_PHONE_PER_HOUR)) ||
        !(await takeHourlySlot(`ip_${ipHash}`, MAX_SENDS_PER_IP_PER_HOUR))) {
      logger.warn("requestPhoneOtp rate-limited", {ipHash});
      throw new HttpsError(
        "resource-exhausted",
        "Too many codes requested. Try again in an hour.",
      );
    }
    if (!(await takeDailySlot(cfg.dailyCap))) {
      logger.error("requestPhoneOtp daily cap reached", {cap: cfg.dailyCap});
      throw new HttpsError(
        "resource-exhausted",
        "We can't send codes right now. Please try again later.",
      );
    }

    const code = randomInt(0, 1_000_000).toString().padStart(6, "0");
    const salt = randomBytes(16).toString("hex");
    let messageId: string;
    try {
      messageId = await sendViaTermii(e164, buildMessage(code, cfg), cfg);
    } catch (err) {
      logger.error("Termii send failed", {
        error: err instanceof Error ? err.message : String(err),
      });
      throw new HttpsError(
        "unavailable",
        "We couldn't send the code. Please try again.",
      );
    }

    // Written after a successful send, so a failed send doesn't start the
    // resend cooldown. A new code replaces the old one and resets attempts.
    await otpRef.set({
      codeHash: sha256(`${salt}:${code}`),
      salt,
      attempts: 0,
      sentAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(Date.now() + CODE_TTL_MS),
      messageId,
    });
    logger.info("Phone OTP sent", {messageId});
    return {provider: "termii", resendAfterSeconds: RESEND_AFTER_MS / 1000};
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// verifyPhoneOtp
//
// Checks the code and returns a custom token for the account that owns the
// number, creating it when there is none. `isNewUser` mirrors what
// signInWithCredential reported, which the clients route on.
// ─────────────────────────────────────────────────────────────────────────────
export const verifyPhoneOtp = onCall(
  {enforceAppCheck: true, timeoutSeconds: 30},
  async (request) => {
    const data = request.data as {phone?: unknown; code?: unknown};
    const e164 = toE164(data?.phone);
    const code = typeof data?.code === "string" ? data.code.trim() : "";
    if (!e164 || !/^\d{6}$/.test(code)) {
      throw new HttpsError("invalid-argument", "Enter the 6-digit code.");
    }

    const db = getFirestore();
    const otpRef = db.collection("phone_otps").doc(e164);
    // Attempts are counted inside the transaction, so parallel guesses can't
    // each see the same count and slip past the limit.
    const outcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(otpRef);
      if (!snap.exists) return "missing" as const;
      const expiresAt = snap.get("expiresAt") as Timestamp;
      if (expiresAt.toMillis() < Date.now()) {
        tx.delete(otpRef);
        return "expired" as const;
      }
      const attempts = (snap.get("attempts") as number) ?? 0;
      if (attempts >= MAX_VERIFY_ATTEMPTS) {
        tx.delete(otpRef);
        return "locked" as const;
      }
      const expected = Buffer.from(snap.get("codeHash") as string, "hex");
      const actual = Buffer.from(
        sha256(`${snap.get("salt") as string}:${code}`), "hex");
      if (!timingSafeEqual(expected, actual)) {
        tx.update(otpRef, {attempts: attempts + 1});
        return "wrong" as const;
      }
      tx.delete(otpRef); // single use
      return "ok" as const;
    });

    if (outcome === "missing" || outcome === "expired") {
      throw new HttpsError(
        "failed-precondition",
        "This code has expired. Please request a new one.",
      );
    }
    if (outcome === "locked") {
      throw new HttpsError(
        "resource-exhausted",
        "Too many wrong attempts. Please request a new code.",
      );
    }
    if (outcome === "wrong") {
      throw new HttpsError(
        "permission-denied",
        "That code is incorrect. Please check and try again.",
      );
    }

    const auth = getAuth();
    let uid: string;
    let isNewUser = false;
    try {
      uid = (await auth.getUserByPhoneNumber(e164)).uid;
    } catch (err) {
      if ((err as {code?: string}).code !== "auth/user-not-found") throw err;
      uid = (await auth.createUser({phoneNumber: e164})).uid;
      isNewUser = true;
    }
    const token = await auth.createCustomToken(uid);
    logger.info("Phone OTP verified", {uid, isNewUser});
    return {token, isNewUser};
  },
);
