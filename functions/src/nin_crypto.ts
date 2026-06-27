/**
 * Field-level encryption for the NIN (National Identification Number).
 *
 * The raw 11-digit NIN is PII under the NDPA. It must never sit in
 * Firestore as plaintext. These helpers encrypt it with AES-256-GCM
 * before storage and decrypt it only inside a Cloud Function that holds
 * the key (loaded from Secret Manager, never shipped to the client).
 *
 * Ciphertext format (single string, colon-delimited):
 *
 *     v1:<base64 iv>:<base64 authTag>:<base64 ciphertext>
 *
 * The leading version tag is a deliberate escape hatch: if the key is
 * ever rotated or the scheme changes, old ciphertext stays decryptable
 * because each blob declares which scheme produced it. Today only v1
 * exists; decrypt rejects anything else loudly rather than guessing.
 *
 * Key: NIN_ENCRYPTION_KEY in Secret Manager. Expected value is 32 raw
 * bytes, base64-encoded (an AES-256 key). Generate with:
 *
 *     node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
 *
 * then `firebase functions:secrets:set NIN_ENCRYPTION_KEY` and paste it.
 */

import {createCipheriv, createDecipheriv, randomBytes} from "node:crypto";

const VERSION = "v1";
const ALGORITHM = "aes-256-gcm";
const IV_BYTES = 12; // GCM standard nonce length
const KEY_BYTES = 32; // AES-256

/**
 * Decode and validate the base64 key from Secret Manager into 32 bytes.
 *
 * @param {string} keyB64 the base64-encoded key string from Secret Manager
 * @return {Buffer} the 32-byte key
 */
function loadKey(keyB64: string): Buffer {
  const key = Buffer.from(keyB64, "base64");
  if (key.length !== KEY_BYTES) {
    throw new Error(
      `NIN_ENCRYPTION_KEY must decode to ${KEY_BYTES} bytes, ` +
        `got ${key.length}.`,
    );
  }
  return key;
}

/**
 * Encrypt a plaintext NIN into the versioned ciphertext format.
 *
 * @param {string} plaintext the raw NIN string
 * @param {string} keyB64 the base64-encoded key from Secret Manager
 * @return {string} the v1 versioned ciphertext blob
 */
export function encryptNin(plaintext: string, keyB64: string): string {
  const key = loadKey(keyB64);
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(ALGORITHM, key, iv);
  const ciphertext = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
  ]);
  const authTag = cipher.getAuthTag();
  return [
    VERSION,
    iv.toString("base64"),
    authTag.toString("base64"),
    ciphertext.toString("base64"),
  ].join(":");
}

/**
 * Decrypt a versioned ciphertext blob back to the plaintext NIN.
 *
 * Not called by any current function — the NIN is write-only until the
 * future NIN-verification-API integration consumes it. Shipped now so
 * the round-trip is testable and the field is never accidentally
 * write-only-forever.
 *
 * @param {string} blob the v1 versioned ciphertext blob
 * @param {string} keyB64 the base64-encoded key from Secret Manager
 * @return {string} the decrypted plaintext NIN
 */
export function decryptNin(blob: string, keyB64: string): string {
  const parts = blob.split(":");
  if (parts.length !== 4 || parts[0] !== VERSION) {
    throw new Error("Unrecognized NIN ciphertext format.");
  }
  const key = loadKey(keyB64);
  const iv = Buffer.from(parts[1], "base64");
  const authTag = Buffer.from(parts[2], "base64");
  const ciphertext = Buffer.from(parts[3], "base64");
  const decipher = createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(authTag);
  const plaintext = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]);
  return plaintext.toString("utf8");
}