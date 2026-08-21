// ─────────────────────────────────────────────────────────────────────────────
// caretaker_ops.ts — the caretaker invitation lifecycle.
//
// A caretaker is WHO MANAGES a unit, not a fact about it. They stand in for the
// landlord on the management surfaces (issues, maintenance, the tenant thread,
// opening the door for an inspection) and nowhere near the money.
//
// `properties.caretakerId` is written ONLY here, on the admin SDK, and never by
// a client. The owner-update rule in firestore.rules has no `hasOnly`, so every
// field it doesn't explicitly guard is owner-writable — so a landlord could
// otherwise appoint any user as caretaker with a single write, with no invite
// and no consent. The rule lets the owner CLEAR the field (that is revoking,
// which is theirs to do) and never set it.
//
//   inviteCaretaker            — landlord invites an existing user by phone,
//                                over one unit or every unit of a building.
//   respondToCaretakerInvite   — the invitee accepts or declines.
//   revokeCaretaker            — landlord or caretaker ends the arrangement.
// ─────────────────────────────────────────────────────────────────────────────

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {writeNotificationOnce} from "./notification_helpers";

// M4: enforced — the Flutter app sends Play Integrity App Check tokens.
const callableOptions = {enforceAppCheck: true, timeoutSeconds: 30};

// A tenant in one of these states still OCCUPIES the unit. Keep in sync with
// OCCUPYING_RENTAL_STATUSES in index.ts (same duplication rationale as
// account_ops.ts — importing from index.ts would be a circular entry-module
// import). Used to stop a landlord appointing their own sitting tenant as
// caretaker, which would let that tenant resolve their own issues.
const OCCUPYING_RENTAL_STATUSES = [
  "active",
  "expiring_soon",
  "grace_locked",
  "pending_payment",
  "moveout_pending",
];

// One landlord may not hold more than this many units under a single invite.
// Purely a blast-radius bound on the building bulk-apply path: an invite is one
// batched write and one accept, and nothing in the product has a building this
// large. It exists so a malformed propertyIds array can't fan out unbounded.
const MAX_PROPERTIES_PER_INVITE = 50;

// Bounds on the confirm-first lookup. It turns a phone number into a person's
// name, so without a cap it would be a PII harvester.
const LOOKUP_MAX_PER_WINDOW = 20;
const LOOKUP_WINDOW_MS = 60 * 60 * 1000;

/**
 * Normalise a Nigerian mobile number to local 0XXXXXXXXXX form.
 *
 * A deliberate copy of the identically-named helper in index.ts, which is
 * module-private there. Importing it would make index.ts and this module import
 * each other — the exact cycle notification_helpers.ts was extracted to avoid.
 *
 * @param {string} raw User-entered phone number, any common format.
 * @return {string | null} Local form, or null when it isn't a valid NG mobile.
 */
export function normalizeNigerianPhone(raw: string): string | null {
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

  if (!/^[789]\d{9}$/.test(subscriber)) return null;
  return "0" + subscriber;
}

/**
 * Open the three-party caretaker↔tenant thread for one unit, if it is occupied.
 *
 * Done SERVER-SIDE on acceptance, not from the app, because the caretaker has
 * no read access to `active_rentals` — that is where rent amounts and every
 * payout figure live, and the whole point of the role is that money is out of
 * reach. Without this they would have no way to discover who the tenant even
 * is. The thread simply appears in their existing inbox, which queries
 * `participants array-contains uid` and therefore needs no rules change.
 *
 * The landlord is a listed participant, not a hidden observer: they can read
 * AND speak, and the tenant can see they are there.
 *
 * Deterministic id so a retried accept doesn't open a second thread.
 *
 * @param {string} propertyId The unit.
 * @param {string} caretakerId The accepting caretaker.
 * @param {string} caretakerName Their display name.
 * @return {Promise<void>}
 */
export async function openCaretakerThread(
  propertyId: string,
  caretakerId: string,
  caretakerName: string,
): Promise<void> {
  const db = getFirestore();
  const rentals = await db
    .collection("active_rentals")
    .where("propertyId", "==", propertyId)
    .get();
  const live = rentals.docs.find((d) =>
    OCCUPYING_RENTAL_STATUSES.includes(d.get("status") as string),
  );
  if (!live) return;

  const tenantId = live.get("tenantId") as string | undefined;
  const landlordId = live.get("landlordId") as string | undefined;
  if (!tenantId || !landlordId) return;

  const propSnap = await db.collection("properties").doc(propertyId).get();
  const [tenantSnap, landlordSnap] = await Promise.all([
    db.collection("users").doc(tenantId).get(),
    db.collection("users").doc(landlordId).get(),
  ]);

  const images = (propSnap.get("images") as string[] | undefined) ?? [];
  const ref = db
    .collection("conversations")
    .doc(`caretaker_${propertyId}_${caretakerId}`);
  const now = Timestamp.now();

  await ref.set(
    {
      id: ref.id,
      propertyId,
      propertyTitle:
        (propSnap.get("title") as string | undefined) ?? "Your property",
      propertyImage: images.length > 0 ? images[0] : "",
      landlordId,
      landlordName:
        (landlordSnap.get("fullName") as string | undefined) ?? "Landlord",
      tenantId,
      tenantName:
        (tenantSnap.get("fullName") as string | undefined) ?? "Tenant",
      agentId: "",
      agentName: "",
      caretakerId,
      caretakerName,
      // arrayUnion, not a literal: a re-appointed caretaker was REMOVED from
      // this array on revoke, and a merge write with a literal array would be
      // fine — but the landlord and tenant may have changed nothing, so union
      // keeps this idempotent against a retried accept either way.
      participants: FieldValue.arrayUnion(landlordId, tenantId, caretakerId),
      lastMessage: "",
      lastMessageTime: now,
      lastMessageSenderId: "",
      unreadCounts: {[landlordId]: 0, [tenantId]: 0, [caretakerId]: 0},
      createdAt: now,
    },
    // Merge so a caretaker re-appointed to the same unit rejoins the existing
    // thread rather than losing its history — and so `removedParticipants`
    // from a previous revoke is cleared explicitly below rather than by a
    // blind overwrite.
    {merge: true},
  );
  await ref.update({removedParticipants: FieldValue.delete()});

  // Deterministic key, NOT Date.now(): this used to run once, at invite-accept,
  // so a unique key was harmless. It is now also called from the occupancy
  // triggers, which fire whenever a rental's occupying-ness changes — a
  // per-call key would send the tenant a fresh "your landlord appointed a
  // caretaker" on every one of those.
  await writeNotificationOnce(`caretaker_thread_${ref.id}`, {
    userId: tenantId,
    type: "caretaker_assigned",
    title: "Your landlord appointed a caretaker",
    body:
      `${caretakerName} will handle issues and maintenance for your home. ` +
      "You can message them here — your landlord is on the thread too.",
    // The route reads conversationId from the query string; without it the
    // chat route renders _MissingArgsScreen, so a bare "/chat" would have
    // dead-ended every tenant who tapped this push.
    payload: {route: `/chat?conversationId=${ref.id}`},
  });
}

/**
 * Everything the confirm-first lookup and the invite itself must agree on: who
 * this number belongs to, and whether they may take these units.
 *
 * Shared so the two cannot diverge — a lookup that said "yes, Musa Bello" and
 * an invite that then refused would be worse than no confirmation at all.
 *
 * Ownership of the units is checked BEFORE the phone is resolved to a person,
 * so this can never be used to turn arbitrary numbers into names: you have to
 * already own what you claim to be appointing for.
 *
 * @param {string} landlordId The calling landlord.
 * @param {string} rawPhone User-entered phone number.
 * @param {unknown} rawPropertyIds Candidate property ids from the client.
 * @return {Promise<object>} Resolved candidate plus the property snapshots.
 */
async function resolveCandidate(
  landlordId: string,
  rawPhone: string,
  rawPropertyIds: unknown,
) {
  const trimmed = (rawPhone ?? "").trim();
  if (!trimmed) {
    throw new HttpsError(
      "invalid-argument",
      "Enter the phone number of the person you want to invite.",
    );
  }
  const phoneLocal = normalizeNigerianPhone(trimmed);
  if (phoneLocal === null) {
    throw new HttpsError(
      "invalid-argument",
      "That isn't a valid Nigerian mobile number.",
    );
  }
  // users.phone is stored in E.164 everywhere (phone_utils.dart phoneToE164 at
  // every write site, plus scripts/backfill-phone-e164.ts).
  const phoneE164 = "+234" + phoneLocal.slice(1);

  const propertyIds = Array.isArray(rawPropertyIds) ?
    [...new Set(rawPropertyIds.filter(
      (p): p is string => typeof p === "string" && p.trim().length > 0,
    ))] :
    [];
  if (propertyIds.length === 0) {
    throw new HttpsError("invalid-argument", "Choose at least one property.");
  }
  if (propertyIds.length > MAX_PROPERTIES_PER_INVITE) {
    throw new HttpsError(
      "invalid-argument",
      `An invite can cover at most ${MAX_PROPERTIES_PER_INVITE} units.`,
    );
  }

  const db = getFirestore();

  // ── Every property must be the caller's, and free ───────────────────────
  const propertySnaps = await db.getAll(
    ...propertyIds.map((id) => db.collection("properties").doc(id)),
  );

  for (const snap of propertySnaps) {
    if (!snap.exists) {
      throw new HttpsError(
        "not-found",
        "One of those properties no longer exists.",
      );
    }
    if (snap.get("landlordId") !== landlordId) {
      throw new HttpsError(
        "permission-denied",
        "You can only appoint a caretaker on your own property.",
      );
    }
    // Replacement is revoke-then-invite, deliberately. Letting a second invite
    // silently overwrite a sitting caretaker would strand the first invite
    // pointing at a unit it no longer governs — and revoking THAT invite would
    // then clear the new caretaker.
    const existing = snap.get("caretakerId") as string | undefined;
    if (existing) {
      const name =
        (snap.get("caretakerName") as string | undefined) ?? "someone";
      throw new HttpsError(
        "failed-precondition",
        `${snap.get("title") ?? "That property"} is already managed by ` +
          `${name}. Remove them first, then invite someone new.`,
      );
    }
  }

  // ── Who is being invited ────────────────────────────────────────────────
  const userSnap = await db
    .collection("users")
    .where("phone", "==", phoneE164)
    .limit(1)
    .get();
  if (userSnap.empty) {
    throw new HttpsError(
      "not-found",
      "Nobody on ClearRent uses that number. A caretaker has to have an " +
        "account before you can invite them.",
    );
  }
  const caretakerDoc = userSnap.docs[0];
  const caretakerId = caretakerDoc.id;
  const caretakerName =
    (caretakerDoc.get("fullName") as string | undefined) ?? "Your caretaker";

  if (caretakerId === landlordId) {
    throw new HttpsError(
      "failed-precondition",
      "That's your own number — you already manage these properties.",
    );
  }

  // A caretaker acts on someone else's property and talks to their tenant, so
  // they carry the same identity bar a landlord clears to list. Reusing the
  // existing verification rather than inventing a caretaker-specific one; the
  // messaging rule (isVerified() in firestore.rules) would half-mute them
  // anyway.
  if (caretakerDoc.get("verificationStatus") !== "verified") {
    throw new HttpsError(
      "failed-precondition",
      `${caretakerName} hasn't verified their identity yet. They need to ` +
        "finish verification before they can manage a property.",
    );
  }

  // The sitting tenant must not become the caretaker — they would be triaging
  // and closing their own issues.
  const rentalSnaps = await Promise.all(
    propertyIds.map((id) =>
      db
        .collection("active_rentals")
        .where("propertyId", "==", id)
        .where("tenantId", "==", caretakerId)
        .get(),
    ),
  );
  const isSittingTenant = rentalSnaps.some((snap) =>
    snap.docs.some((d) =>
      OCCUPYING_RENTAL_STATUSES.includes(d.get("status") as string),
    ),
  );
  if (isSittingTenant) {
    throw new HttpsError(
      "failed-precondition",
      `${caretakerName} is your tenant in one of these units. A tenant can't ` +
        "be the caretaker of the property they rent.",
    );
  }

  return {caretakerId, caretakerName, phoneE164, propertyIds, propertySnaps};
}

/**
 * Resolve a number to the person about to be invited, so the app can ask
 * "Invite Musa Bello?" before anything is sent. A single mistyped digit would
 * otherwise hand a stranger standing access to a tenant's issues and messages,
 * and the invitee would be a real person who could simply accept.
 *
 * Rate-limited per caller, and resolveCandidate requires the caller to already
 * own the units named — so a lookup can only ride along with an appointment the
 * landlord is entitled to make, never a bare phone-to-name query.
 */
export const lookupCaretakerCandidate = onCall(
  callableOptions,
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const data = (request.data ?? {}) as {
      phone?: string;
      propertyIds?: unknown;
    };

    const db = getFirestore();
    const limitRef = db.collection("_rate_limits").doc(`ct_lookup_${uid}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(limitRef);
      const now = Date.now();
      const windowStart = (snap.get("windowStart") as number | undefined) ?? 0;
      const count = (snap.get("count") as number | undefined) ?? 0;
      const fresh = now - windowStart > LOOKUP_WINDOW_MS;
      if (!fresh && count >= LOOKUP_MAX_PER_WINDOW) {
        throw new HttpsError(
          "resource-exhausted",
          "You've looked up too many numbers just now. Try again later.",
        );
      }
      tx.set(limitRef, {
        windowStart: fresh ? now : windowStart,
        count: fresh ? 1 : count + 1,
      });
    });

    const candidate = await resolveCandidate(
      uid,
      data.phone ?? "",
      data.propertyIds,
    );
    logger.info("Caretaker candidate resolved", {uid});
    return {
      caretakerName: candidate.caretakerName,
      unitCount: candidate.propertyIds.length,
    };
  },
);

export const inviteCaretaker = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const landlordId = request.auth.uid;
  const data = (request.data ?? {}) as {
    phone?: string;
    propertyIds?: unknown;
    buildingId?: string | null;
  };

  // Re-run every check rather than trusting what the confirm dialog was told:
  // the lookup is a courtesy to the landlord, not an authorisation step.
  const {caretakerId, caretakerName, phoneE164, propertyIds, propertySnaps} =
    await resolveCandidate(landlordId, data.phone ?? "", data.propertyIds);
  const db = getFirestore();

  // A property may only have one invite in flight.
  const pendingSnap = await db
    .collection("caretaker_invites")
    .where("landlordId", "==", landlordId)
    .where("status", "==", "pending")
    .get();
  const alreadyPending = pendingSnap.docs.some((d) =>
    ((d.get("propertyIds") as string[] | undefined) ?? []).some((id) =>
      propertyIds.includes(id),
    ),
  );
  if (alreadyPending) {
    throw new HttpsError(
      "failed-precondition",
      "You already have a caretaker invite waiting on one of these units.",
    );
  }

  // ── Write the invite ────────────────────────────────────────────────────
  const landlordSnap = await db.collection("users").doc(landlordId).get();
  const landlordName =
    (landlordSnap.get("fullName") as string | undefined) ?? "Your landlord";

  const inviteRef = db.collection("caretaker_invites").doc();
  await inviteRef.set({
    landlordId,
    landlordName,
    caretakerId,
    caretakerName,
    caretakerPhone: phoneE164,
    propertyIds,
    buildingId: data.buildingId ?? null,
    // Denormalised for the invite card, so the invitee can see what they're
    // agreeing to without read access to a property they don't yet manage.
    propertyTitles: propertySnaps.map(
      (s) => (s.get("title") as string | undefined) ?? "Untitled property",
    ),
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
  });

  const unitCount = propertyIds.length;
  await writeNotificationOnce(`caretaker_invite_${inviteRef.id}`, {
    userId: caretakerId,
    type: "caretaker_invited",
    title: "You've been asked to manage a property",
    body:
      `${landlordName} wants you to be the caretaker for ` +
      (unitCount === 1 ?
        `${propertySnaps[0].get("title") ?? "their property"}.` :
        `${unitCount} units.`) +
      " You can accept or decline.",
    payload: {route: "/caretaker/invites"},
  });

  logger.info("Caretaker invited", {
    inviteId: inviteRef.id,
    landlordId,
    caretakerId,
    unitCount,
  });
  return {success: true, inviteId: inviteRef.id, caretakerName};
});

export const respondToCaretakerInvite = onCall(
  callableOptions,
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const data = (request.data ?? {}) as {inviteId?: string; action?: string};
    const inviteId = (data.inviteId ?? "").trim();
    const action = (data.action ?? "").trim();

    if (!inviteId) {
      throw new HttpsError("invalid-argument", "inviteId is required.");
    }
    if (action !== "accept" && action !== "decline") {
      throw new HttpsError(
        "invalid-argument",
        "action must be 'accept' or 'decline'.",
      );
    }

    const db = getFirestore();
    const inviteRef = db.collection("caretaker_invites").doc(inviteId);
    const inviteSnap = await inviteRef.get();
    if (!inviteSnap.exists) {
      throw new HttpsError("not-found", "That invitation no longer exists.");
    }
    const invite = inviteSnap.data()!;

    if (invite.caretakerId !== uid) {
      throw new HttpsError(
        "permission-denied",
        "That invitation wasn't sent to you.",
      );
    }
    if (invite.status !== "pending") {
      throw new HttpsError(
        "failed-precondition",
        invite.status === "revoked" ?
          "That invitation was withdrawn." :
          "You've already answered that invitation.",
      );
    }

    const landlordId = invite.landlordId as string;
    const caretakerName = (invite.caretakerName as string) ?? "Your caretaker";
    const propertyIds = (invite.propertyIds as string[] | undefined) ?? [];

    if (action === "decline") {
      await inviteRef.update({
        status: "declined",
        declinedAt: FieldValue.serverTimestamp(),
      });
      await writeNotificationOnce(`caretaker_declined_${inviteId}`, {
        userId: landlordId,
        type: "caretaker_declined",
        title: "Caretaker invitation declined",
        body: `${caretakerName} declined to manage your property.`,
        payload: {route: "/landlord/home"},
      });
      logger.info("Caretaker invite declined", {inviteId, uid});
      return {success: true, status: "declined"};
    }

    // ── Accept ────────────────────────────────────────────────────────────
    // Re-check ownership and vacancy at ACCEPT time, not just at invite time:
    // the landlord may have sold, deleted or re-caretakered a unit while the
    // invite sat unanswered. Anything that no longer qualifies is skipped
    // rather than failing the whole accept, so one stale unit in a building
    // bulk-invite doesn't block the rest.
    const propertyRefs = propertyIds.map((id) =>
      db.collection("properties").doc(id),
    );
    const propertySnaps = propertyRefs.length > 0 ?
      await db.getAll(...propertyRefs) :
      [];

    // Guards that held at invite time can stop holding while the invite sits
    // unanswered. Verification can be revoked, and — the one that matters —
    // the invitee may have MOVED IN to one of these units in the meantime, in
    // which case accepting would let them triage and close their own issues.
    const accepterSnap = await db.collection("users").doc(uid).get();
    if (accepterSnap.get("verificationStatus") !== "verified") {
      throw new HttpsError(
        "failed-precondition",
        "Your identity verification is no longer valid, so you can't take on " +
          "a property. Verify again and ask for a new invitation.",
      );
    }
    const tenancySnaps = await Promise.all(
      propertyIds.map((id) =>
        db
          .collection("active_rentals")
          .where("propertyId", "==", id)
          .where("tenantId", "==", uid)
          .get(),
      ),
    );
    const tenantOf = new Set<string>();
    tenancySnaps.forEach((snap) =>
      snap.docs.forEach((d) => {
        if (OCCUPYING_RENTAL_STATUSES.includes(d.get("status") as string)) {
          tenantOf.add(d.get("propertyId") as string);
        }
      }),
    );

    const batch = db.batch();
    const applied: string[] = [];
    for (const snap of propertySnaps) {
      if (!snap.exists) continue;
      if (snap.get("landlordId") !== landlordId) continue;
      if (snap.get("caretakerId")) continue;
      // You cannot be the caretaker of the home you rent.
      if (tenantOf.has(snap.id)) continue;
      batch.update(snap.ref, {
        caretakerId: uid,
        caretakerName,
        // The legacy display boolean and the real role answer different
        // questions, but a unit that now HAS a named caretaker plainly has one.
        hasCaretaker: true,
        updatedAt: FieldValue.serverTimestamp(),
      });
      applied.push(snap.id);
    }

    if (applied.length === 0) {
      await inviteRef.update({
        status: "revoked",
        revokedAt: FieldValue.serverTimestamp(),
        revokedReason: "No property on this invitation is still available.",
      });
      throw new HttpsError(
        "failed-precondition",
        "None of those properties are available to manage any more.",
      );
    }

    batch.update(inviteRef, {
      status: "accepted",
      acceptedAt: FieldValue.serverTimestamp(),
      // What was ACTUALLY applied, which is what revoke must later undo.
      appliedPropertyIds: applied,
    });
    await batch.commit();

    // Best-effort: a thread that fails to open must not undo an acceptance
    // that has already been written. The caretaker still manages the unit;
    // they just have no tenant thread until the next appointment.
    for (const propertyId of applied) {
      try {
        await openCaretakerThread(propertyId, uid, caretakerName);
      } catch (err) {
        logger.error("Failed to open caretaker thread", {
          propertyId,
          uid,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    await writeNotificationOnce(`caretaker_accepted_${inviteId}`, {
      userId: landlordId,
      type: "caretaker_accepted",
      title: "Caretaker accepted",
      body:
        `${caretakerName} is now managing ` +
        (applied.length === 1 ?
          "your property." :
          `${applied.length} of your units.`),
      payload: {route: "/landlord/home"},
    });

    logger.info("Caretaker invite accepted", {
      inviteId,
      uid,
      appliedCount: applied.length,
    });
    return {success: true, status: "accepted", propertyIds: applied};
  },
);

export const revokeCaretaker = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  const data = (request.data ?? {}) as {inviteId?: string; reason?: string};
  const inviteId = (data.inviteId ?? "").trim();
  if (!inviteId) {
    throw new HttpsError("invalid-argument", "inviteId is required.");
  }

  const db = getFirestore();
  const inviteRef = db.collection("caretaker_invites").doc(inviteId);
  const inviteSnap = await inviteRef.get();
  if (!inviteSnap.exists) {
    throw new HttpsError(
      "not-found",
      "That caretaker record no longer exists.",
    );
  }
  const invite = inviteSnap.data()!;

  const landlordId = invite.landlordId as string;
  const caretakerId = invite.caretakerId as string;
  // Either side may end it: the landlord removes a caretaker, and a caretaker
  // may step back — the same shape as agentUnassignFromProperty.
  const byLandlord = uid === landlordId;
  if (!byLandlord && uid !== caretakerId) {
    throw new HttpsError(
      "permission-denied",
      "You aren't a party to that caretaker arrangement.",
    );
  }
  if (invite.status !== "pending" && invite.status !== "accepted") {
    throw new HttpsError(
      "failed-precondition",
      "That caretaker arrangement has already ended.",
    );
  }

  const caretakerName = (invite.caretakerName as string) ?? "Your caretaker";
  const landlordName = (invite.landlordName as string) ?? "The landlord";
  const targetIds =
    (invite.appliedPropertyIds as string[] | undefined) ??
    (invite.propertyIds as string[] | undefined) ??
    [];

  const batch = db.batch();

  if (invite.status === "accepted" && targetIds.length > 0) {
    const snaps = await db.getAll(
      ...targetIds.map((id) => db.collection("properties").doc(id)),
    );
    for (const snap of snaps) {
      if (!snap.exists) continue;
      // Only clear a unit this invite actually still governs. Without this,
      // revoking a superseded invite would wipe whoever holds the unit NOW.
      if (snap.get("caretakerId") !== caretakerId) continue;
      batch.update(snap.ref, {
        caretakerId: FieldValue.delete(),
        caretakerName: FieldValue.delete(),
        // Falls back to landlord-handled. Leaving 'caretaker' here would point
        // the inspection flow at a uid the property no longer carries, and the
        // handler branch would have nobody to ask.
        ...(snap.get("inspectionHandler") === "caretaker" ?
          {inspectionHandler: "self", readyForInspections: false} :
          {}),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  }

  batch.update(inviteRef, {
    status: "revoked",
    revokedAt: FieldValue.serverTimestamp(),
    revokedBy: uid,
    revokedReason: (data.reason ?? "").trim() || null,
  });
  await batch.commit();

  // Close the caretaker out of the tenant threads they were added to. The
  // conversation rules already honour removedParticipants — nothing had ever
  // written it until now.
  const convSnap = await db
    .collection("conversations")
    .where("caretakerId", "==", caretakerId)
    .where("landlordId", "==", landlordId)
    .get();
  await Promise.all(
    convSnap.docs
      .filter((d) =>
        targetIds.includes((d.get("propertyId") as string | undefined) ?? ""),
      )
      .map((d) =>
        d.ref.update({
          // Drop them from `participants`, not just into
          // `removedParticipants`. The conversations LIST rule keys on
          // `participants` alone — only get/update consult
          // isActiveParticipant() — so a removed caretaker who stayed in the
          // array kept the thread in their inbox, with a live lastMessage
          // preview of what the tenant went on to say.
          participants: FieldValue.arrayRemove(caretakerId),
          removedParticipants: FieldValue.arrayUnion(caretakerId),
        }),
      ),
  );

  const notifyUserId = byLandlord ? caretakerId : landlordId;
  await writeNotificationOnce(`caretaker_revoked_${inviteId}`, {
    userId: notifyUserId,
    type: "caretaker_removed",
    title: byLandlord ?
      "You no longer manage this property" :
      "Caretaker stepped back",
    body: byLandlord ?
      `${landlordName} has ended your caretaker access.` :
      `${caretakerName} has stepped back from managing your property. ` +
        "It's back under your own management.",
    payload: {route: byLandlord ? "/caretaker/properties" : "/landlord/home"},
  });

  logger.info("Caretaker revoked", {inviteId, uid, byLandlord});
  return {success: true};
});
