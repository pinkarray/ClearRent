/**
 * Reusable admin-alert feed.
 *
 * `admin_alerts` is the single Firestore collection the web admin dashboard
 * (separate repo, `clearrent_admin`) subscribes to for its ping / badge /
 * queue. It is deliberately domain-agnostic: the dispute + today's-inspections
 * digest are the first two callers, and rent / tenancy-issue / profile /
 * agreement events become additional callers unchanged in the fast-follow.
 *
 * Writes are admin-SDK only (`create: if false` in firestore.rules); the
 * dashboard reads under the existing canRead() gate. Mirrors the
 * writeNotificationOnce helper: this module is to admin_alerts what
 * notification_helpers is to notifications.
 */

import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue} from "firebase-admin/firestore";

export type AlertSeverity = "info" | "warning" | "critical";

export interface AdminAlert {
  // Namespaced event type, e.g. "inspection_dispute" / "inspection_today".
  type: string;
  severity: AlertSeverity;
  title: string;
  body: string;
  // Deep-link target for the dashboard (collection + doc). Omitted for
  // aggregate alerts like the daily digest.
  targetCollection?: string;
  targetId?: string;
  // The people involved, so the dashboard can render / filter by party.
  actors?: {tenantId?: string; agentId?: string; landlordId?: string};
  // Domain payload (category, count, amount, per-item lists, ...).
  meta?: Record<string, unknown>;
}

/**
 * Strip undefined fields — Firestore rejects `undefined` values, and callers
 * pass optional fields (targetCollection, actors, meta) that may be absent.
 * @param {Record<string, unknown>} obj Object to clean.
 * @return {Record<string, unknown>} Same object without undefined keys.
 */
function pruneUndefined(
  obj: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined) out[k] = v;
  }
  return out;
}

/**
 * Create an admin alert with an auto id. Use for one-off events (e.g. a
 * dispute) where each call should produce a distinct alert.
 *
 * @param {AdminAlert} alert The alert payload.
 * @return {Promise<string>} The new alert doc id.
 */
export async function writeAdminAlert(alert: AdminAlert): Promise<string> {
  const db = getFirestore();
  const ref = await db.collection("admin_alerts").add(
    pruneUndefined({
      ...alert,
      actors: alert.actors ? pruneUndefined(alert.actors) : undefined,
      status: "open",
      read: false,
      resolvedBy: null,
      resolvedAt: null,
      createdAt: FieldValue.serverTimestamp(),
    }),
  );
  logger.info("Admin alert written", {type: alert.type, id: ref.id});
  return ref.id;
}

/**
 * Create an admin alert with a deterministic id, so re-runs of a scheduled /
 * triggered producer don't fan out duplicates (the daily digest uses this).
 *
 * @param {string} alertId Deterministic doc id.
 * @param {AdminAlert} alert The alert payload.
 * @return {Promise<boolean>} True if written, false if it already existed.
 */
export async function writeAdminAlertOnce(
  alertId: string,
  alert: AdminAlert,
): Promise<boolean> {
  const db = getFirestore();
  const ref = db.collection("admin_alerts").doc(alertId);
  try {
    await ref.create(
      pruneUndefined({
        ...alert,
        actors: alert.actors ? pruneUndefined(alert.actors) : undefined,
        status: "open",
        read: false,
        resolvedBy: null,
        resolvedAt: null,
        createdAt: FieldValue.serverTimestamp(),
      }),
    );
    return true;
  } catch (err) {
    const code = (err as {code?: number | string})?.code;
    if (code === 6 || code === "already-exists") {
      logger.info("Admin alert already exists, skipping", {alertId});
      return false;
    }
    throw err;
  }
}

/**
 * Upsert a single evolving alert keyed by a caller-chosen id. Used for the
 * inspection lifecycle, where one alert per inspection walks through
 * requested → paid → approved/declined rather than spawning a new alert (and
 * feed row) at every step. Re-opens the alert if a fresh transition arrives
 * after it was dismissed — a new state is new information.
 *
 * @param {string} alertId Stable id (e.g. "insplc_<requestId>").
 * @param {AdminAlert} alert The latest state of the alert.
 * @return {Promise<void>}
 */
export async function upsertAdminAlert(
  alertId: string,
  alert: AdminAlert,
): Promise<void> {
  const db = getFirestore();
  const ref = db.collection("admin_alerts").doc(alertId);
  const snap = await ref.get();
  const data = pruneUndefined({
    ...alert,
    actors: alert.actors ? pruneUndefined(alert.actors) : undefined,
    status: "open",
    read: false,
    updatedAt: FieldValue.serverTimestamp(),
    // Keep the original createdAt across updates; set it only on first write.
    ...(snap.exists ? {} : {createdAt: FieldValue.serverTimestamp()}),
  });
  await ref.set(data, {merge: true});
}

/**
 * Close every still-open alert pointing at a given target doc — called when an
 * admin resolves the underlying case (e.g. an inspection dispute) so the
 * dashboard queue doesn't keep showing it.
 *
 * @param {string} targetId The alerts' targetId (e.g. the inspection id).
 * @param {string} resolvedBy Admin uid that resolved it.
 * @return {Promise<number>} How many alerts were closed.
 */
export async function resolveAdminAlertsForTarget(
  targetId: string,
  resolvedBy: string,
): Promise<number> {
  const db = getFirestore();
  const snap = await db
    .collection("admin_alerts")
    .where("targetId", "==", targetId)
    .where("status", "==", "open")
    .get();
  if (snap.empty) return 0;

  const batch = db.batch();
  for (const doc of snap.docs) {
    batch.update(doc.ref, {
      status: "resolved",
      resolvedBy,
      resolvedAt: FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();
  return snap.size;
}
