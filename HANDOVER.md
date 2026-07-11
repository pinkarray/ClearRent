# ClearRent — Session Handover

> Paste into a new session to continue. Two repos:
> **app** = `c:\Users\MIDE\clearrent` (Flutter) · **admin** = `c:\Users\MIDE\clearrent_admin` (Next.js).

---

## ▶ START HERE — 2026-07-11e (app bug fixes — arrival activities, tenant-home crash, agent scheduling, browse filters)

`flutter analyze` ✓ (full), rules **95/95** ✓. **NOT committed.** Mostly
client-only (app rebuild); the agent-scheduling item is a **rules** change
(`firebase deploy --only firestore:rules`).

**3. Assigned agent couldn't set inspection days (PERMISSION_DENIED).** The
properties rules granted the assigned agent only the readiness fields, so their
`inspectionDays`/`inspectionTimeSlots` write (agent_property_detail
`_EditScheduleSheet` → `updateProperty`) was denied. Added a parallel
agent-scoped clause: `assignedAgentId == uid` may write ONLY
`['inspectionDays','inspectionTimeSlots','updatedAt']` (field-scoped, like the
readiness clause). +3 rules tests (allowed; rent-change-alongside denied;
non-assigned denied) → **95/95**. **Needs `firebase deploy --only firestore:rules`.**

**4. Dead "more filters" (tune) button on tenant browse.** It was a decorative
`Container` with no `onTap`. Now opens a "Filters" bottom sheet:
price/rent RangeSlider (bound = max rent rounded to ₦100k; max=bound ⇒ no cap),
bedrooms (Any/1+/2+/3+/4+), bathrooms (Any/1+/2+/3+), and amenities (multi-select
chips derived from the listings in view, AND-matched). Edits are local until
Apply; the button shows a dot when extra filters are active; Apply shows a live
match count. Wired into the existing `_filterProperties()` (before the search
block so they always apply). State: `_minRent/_maxRent/_minBedrooms/_minBathrooms/
_filterAmenities`.

---

## ▶ START HERE — 2026-07-11e-i (app bug fixes — arrival activities + tenant-home crash)

Client-only (app rebuild). `flutter analyze` ✓ (full). **NOT committed.**

**1. Handler/tenant not told "on the way" / "arrived".** `markTenantOnWay`
(`inspection_service.dart`) wrote the flag but created NO activity → the handler
(landlord when self-handled, +agent) never saw it in Recent Activities. Fixed to
`_createActivity('tenant_on_way')` for landlord (+agent). Mirrored the symmetric
gap: `markHandlerOnWay` now notifies the tenant (`handler_on_way`). Also
`activity_model._parseType` didn't map `tenant_on_way`/`tenant_arrived`/
`handler_on_way`/`handler_arrived` → they fell to the `propertyViewed` default
(wrong icon, tapped through to the property). Mapped all four to
`inspectionApproved` (event icon, routes to /inspections; the stored title/message
carry the specific wording). `markTenantArrived` already created the landlord
activity — it just rendered mislabeled; now correct.

**FCM push added (2026-07-11e-ii):** the in-app activities aren't enough for a
time-sensitive alert, so `onInspectionRequestUpdated` (index.ts) now turns each
arrival flag's false→true transition into an FCM push (deduped
`insp_{id}_{event}_{recipient}`): tenantOnWay/tenantArrived → push the handler
(agentId ?? landlordId); handlerOnWay/handlerArrived → push the tenant. Client
still writes the activity feed item; the CF adds the push (notifications is
`create:if false`, so pushes must be server-side). **Deploy:**
`firebase deploy --only functions:onInspectionRequestUpdated`.

**2. Tenant home crash: "Stream has already been listened to"**
(`tenant_home_screen.dart:485`). The multi-rental `StreamBuilder` read the stored
single-subscription `_tenantRentalsStream`; that branch unmounts/remounts on nav
tab switches, so the remounted StreamBuilder re-listened the already-listened
stream → crash. Replaced with a lifetime subscription (`_tenantRentalsSub` in
initState, cancelled in dispose) caching `_tenantRentals`/`_tenantRentalsLoaded`;
build reads cached state (no StreamBuilder). Survives remounts.

---

## ▶ START HERE — 2026-07-11d (audit gap — admin review actions now audited)

Verified: functions `tsc` ✓, admin `tsc` ✓ + `next build` ✓. **NOT committed.
NOT deployed** (functions + admin Vercel).

**Gap (money-flow cert, Medium):** admin property-doc verify/reject and
inspection-review resolve were raw client `updateDoc`s → never hit the immutable
`admin_audit_log` (which is `create: if false`, admin-SDK-only), so there was no
record of which admin made these trust/money decisions.

**Fix — route them through admin-SDK callables** (NEW `admin_review_ops.ts`):
- `adminReviewPropertyDoc({propertyId, action:'verify'|'reject'|'publish', reason?})`
  — derives the building link server-side, updates property (+building) in a txn,
  writes `admin_property_doc_{action}` audit entry.
- `adminResolveInspection({requestId, action:'refund'|'complete', refundAmount?})`
  — refund re-validates amount ≤ totalFee server-side and sets
  paymentStatus=refunded (still triggers `onInspectionRefundTriggered`); complete
  marks completed; writes `admin_inspection_{action}` audit entry (amount =
  refund amount).
- Admin repo rewired: `properties/page.tsx` (verify/reject/publish → one
  `reviewDoc` helper calling the CF) and `inspection-reviews/page.tsx`
  (submitRefund/markCompleted → CF). Removed the now-unused firestore write
  imports.

No rules change (kept `allow update: if isAdmin()`; the fix is accountability for
the normal admin workflow, not blocking a trusted admin from a direct write).

**DEPLOY:** `cd functions && npm run build && firebase deploy --only functions:adminReviewPropertyDoc,functions:adminResolveInspection` + admin Vercel.

**Follow-up (noted):** the USER-verification approve/reject
(`verifications/page.tsx` handleApprove/handleReject) is the same pattern and
still writes client-side without an audit entry — extend with an
`adminReviewUserVerification` callable if you want full audit coverage.

---

## ▶ START HERE — 2026-07-11c (rent gaps G1–G4 — full)

Verified: functions `tsc` ✓, firestore rules **92/92** ✓, admin `next build` ✓.
**NOT committed. NOT deployed** (functions + rules + admin Vercel + app rebuild
for the sweep's notifications to route — client unchanged though).
User policy decisions: G1 = reminder→admin-review-queue (no auto money);
payout escape hatch = admin force-finalize.

**G2/G3 — payout gate (`admin_money_ops.ts`).** `markRentLandlordPayoutPaid` /
`markRentAgentCommissionPaid` only guarded payout-status idempotency — nothing
checked the agreement, so admin could pay before finalize or DURING a dispute.
New `assertAgreementFinalized(data)` in both txns: payout allowed ONLY when
`agreementStatus == 'finalized'`; `disputed` → distinct block; other/absent →
"not finalized yet." Agreement lifecycle (active_rentals): uploaded →
pending_review → (tenant) accepted → (landlord) **finalized**; dispute → disputed.

**G1 — strand sweep (NEW `rent_interest_ops.ts` → `rentalInterestStrandSweep`,
09:00 Africa/Lagos).** For `rental_interests` at `payment_verified` (paid, not
yet accepted): day 3 & 6 → remind the LANDLORD to accept; day 7 → set
`strandedForReview: true` + `strandedAt` and reassure the tenant. Moves NO money
(policy). Mirrors leaseLifecycleSweep (deduped `writeNotificationOnce`).

**Escape hatch — `adminForceFinalizeAgreement` callable (`admin_money_ops.ts`).**
assertAdmin + required reason; sets `agreementStatus:'finalized'` +
`agreementFinalizedByAdmin` + `adminFinalizedReason/By`, clears dispute reason;
audit-logged (`admin_force_finalize_agreement`); blocks if already finalized.
Unblocks the payout gate for offline-settled / stuck deals.

**G4 — admin "Rent Attention" view (`clearrent_admin`
`dashboard/rent-attention/page.tsx`, nav item after Inspection Reviews).**
Realtime: (1) **stranded** — `rental_interests` at `payment_verified`, sorted
longest-waiting, flagged ones float up; (2) **disputed** — `active_rentals`
`agreementStatus=='disputed'` with the tenant's reason + payout-held amount + a
**Resolve & force-finalize** action (calls the callable with a reason).
Tenant/landlord cross-link to `/dashboard/users/{uid}`.

**Rules:** reordered `rental_interests` read to put `isAdmin()` FIRST (short-
circuits before per-doc `get()`s for admin list) — 92/92 still pass.

**DEPLOY:**
```
cd functions && npm run build && firebase deploy --only functions:markRentLandlordPayoutPaid,functions:markRentAgentCommissionPaid,functions:adminForceFinalizeAgreement,functions:rentalInterestStrandSweep
firebase deploy --only firestore:rules
# admin Vercel deploy
```

**Follow-ups (noted, not built):** (a) rental-refund tooling — for a truly
unresponsive landlord the admin currently refunds the stranded tenant OUT OF BAND
(no in-app rental-refund action yet; inspection refunds have one, rentals don't);
(b) a distinct "tenant moved in" signal — the gate uses `finalized` as the
move-in proxy.

---

## ▶ START HERE — 2026-07-11b (admin repo — Phase-2b address fix)

Repo: **admin** (`clearrent_admin`). Verified: `tsc` ✓, `next build` ✓.
**NOT committed. NOT deployed (Vercel).** Clears the required 2b follow-up.

**Why:** Phase 2b moved the exact street address off the world-readable property
doc into the gated `properties/{id}/private/location` subdoc, so the admin
dashboard (which read `property.address`) showed blank addresses.

**Fix (mirrors the app's list-vs-detail split; admin is entitled by rules):**
- `properties/page.tsx` — list card + search now use area-level (city/state);
  the **detail slide-over** (`PropertyDetailPanel`) fetches the
  `private/location` subdoc via `getDoc` and shows the exact address (falls back
  to `property.address` for un-migrated docs, then area-level). Search placeholder
  updated.
- `users/[uid]/page.tsx` — owned/handled property rows show area-level (added
  `city`/`state` to `PropertyRow`).
- `payments/page.tsx` — listing-fee row `propertyAddress` now area-level.
- `types/index.ts` Property.address left as-is (still exists on legacy parents;
  used only as fallback). No rules change (2b rules already allow admin subdoc read).

**DEPLOY:** admin Vercel. Phase-4 admin dependency CONFIRMED OK (no change
needed): `verifications/page.tsx` `handleReject` writes `rejectionReason` via
`updateDoc` (partial update → `verificationPaymentReference` preserved), so the
app shows the reason and detects free re-apply.

---

## ▶ START HERE — 2026-07-11 (G6 — Paystack webhook / server-authoritative payments)

Verified: functions `tsc` ✓, `flutter analyze` (paystack_service) ✓, HMAC signature
logic unit-checked (accepts genuine, rejects tampered/wrong-secret/empty).
**NOT committed. NOT deployed.**

**Context:** Paystack business **not yet approved** — app is on TEST keys (user
has submitted everything, awaiting Paystack). This is fully buildable/testable on
TEST keys now (test mode delivers webhooks + verify API); go-live just needs the
live webhook URL + live `PAYSTACK_SECRET_KEY`.

**The gap (G6, from money-flow certification):** the app already has server-side
`initializePayment`/`verifyPayment` CFs, BUT the `payments` record + all
downstream effects are CLIENT-written and there was NO webhook — so a charge
could succeed with the app then dying/offline/tampered ⇒ money moved, no record.

**What changed:**
- **NEW `paystackWebhook` CF** (`index.ts`, `onRequest`, binds `PAYSTACK_SECRET_KEY`).
  Verifies the `x-paystack-signature` (HMAC-SHA512 over `req.rawBody`,
  `timingSafeEqual`) BEFORE any work — that signature is the only auth (App Check
  can't apply; caller is Paystack). On `charge.success` it idempotently
  reconciles `payments/{reference}` in a txn:
  - record present → stamps gateway-authoritative `gatewayStatus`/`gatewayAmount`/
    `gatewayPaidAt` + `webhookVerified:true`; sets `amountMismatch` (+`clientAmount`)
    if the client's amount differs (tamper/underpay signal).
  - record MISSING → creates it (`source:"webhook"`, `status:"completed"`,
    `clientRecorded:false`, `needsReconciliation:true`) so no charge goes
    untracked and admin can finish the downstream effect the client missed.
- **`paystack_service.dart` `recordPayment`** now writes with `SetOptions(merge:true)`
  so a webhook-first record isn't clobbered by the later client write.

**DEPLOY:**
```
cd functions && npm run build && firebase deploy --only functions:paystackWebhook
# app rebuild (client recordPayment merge change)
```
Then in the **Paystack dashboard → Settings → API Keys & Webhooks**, set the
Webhook URL to the deployed function URL (gen2 Cloud Run URL, e.g.
`https://paystackwebhook-<hash>-uc.a.run.app` — copy the exact URL from the
deploy output / console) for **both test and live** modes. `PAYSTACK_SECRET_KEY`
secret must match the active mode.

**Scope note (deliberate):** this guarantees a server-authoritative payment
RECORD + tamper/omission flags. It does NOT yet auto-drive the per-type downstream
effect (verification submit / inspection create / rent record) from the webhook —
a `needsReconciliation` payment is surfaced for admin to finish. Fuller
webhook-driven fulfilment per payment type = follow-up. Also optional: a
reconciliation view/filter on the admin Payments page for
`needsReconciliation`/`amountMismatch`.

---

## ▶ START HERE — 2026-07-10g (Admin collusion-analytics VIEW — consumes Phase 3)

Repo: **admin** (`clearrent_admin`, Next.js/Vercel). Verified: `next build` ✓
(route compiled, lint clean). **NOT committed. NOT deployed** (Vercel).

**What:** new route `src/app/dashboard/collusion/page.tsx` — "Collusion Watch"
(nav item added to `dashboard-shell.tsx`, ShieldAlert icon, between Inspection
Day and Properties). Consumes the Phase-3 pairing key.

**How it works:** one-shot `getDocs` of `inspection_requests` + `active_rentals`
(both allow admin `list`). Groups inspections by the **tenant↔handler pair**
(`handlerId` from the doc, or derived `agentId ?? landlordId` so it works even
before the backfill runs). Per inspection it derives an outcome from the raw
signals (paymentStatus=refunded + arrival flags → handler_no_show / no_show_both;
completed + met → met; completed + handler-only → tenant_no_show; etc.) and joins
`active_rentals` by `tenantId+propertyId` to know if the tenant actually rented
the property they inspected.

**Signals per pair** (only pairs with ≥2 inspections and ≥1 signal shown):
- **Met, no rental** — distinct properties the pair confirmed a meeting on but the
  tenant never rented on ClearRent (repeat = off-platform dealing).
- **Handler no-show refunds** — tenant-attended/handler-absent refunds (the
  forgeable collusion refund).
- Risk tiers: high (metNoRental≥3 or refunds≥2), medium (≥2 / ≥1 / ≥4 insp & 0
  rentals), low. Sorted by risk then a transparent score. Summary tiles +
  search + per-pair expandable inspection list; tenant & handler cross-link to
  `/dashboard/users/{uid}`. Advisory, not proof (stated on-page).

**DEPLOY:** admin **Vercel** deploy. Reads only — no rules/functions change.
Scale note: full-collection client reads are fine pre-launch; if inspections
grow large, move aggregation server-side (CF or scheduled rollup).

**This closes the inspection-integrity track end-to-end** (capture in the app →
view in admin). Next open item: **G6** Paystack webhook / server-authoritative
payments (pre-launch gate, from money-flow certification).

---

## ▶ START HERE — 2026-07-10f (Phase 4 — verification rejection reason + free re-apply)

Verified: `flutter analyze` ✓ (full tree). **NOT committed. NOT deployed.**
Client-only (app rebuild); no functions, no rules change.

**Finding:** "show reason" was ALREADY done — `verification_center_screen`
`_buildRejectedState` renders `rejectionReason` (stored on the user doc + the
`verification_request` by `VerificationService.rejectVerification`). The gap was
**free re-apply**: the rejected "Try Again" reset the form back to the full
pay-again flow.

**What changed (`verification_center_screen.dart` only):**
- "Try Again" now calls `_startReapply()`: if the user has a prior payment
  reference (they paid, then got rejected), it sets `_isFreeReapply=true` and
  carries the original `paymentReference`/`amount`.
- Free re-apply skips Paystack, submits the corrected docs with the original
  payment reference, and does NOT record a new `payments` entry (no money
  moved). First-time applicants are unchanged (still pay).
- Upload form swaps the fee/Paystack section for a green "No payment needed —
  resubmitting is free" note; the sticky button reads "Resubmit for free".
- Detection is client-side off `_verificationData.paymentReference`; a user
  can't reach `rejected` without having submitted (+paid) once, so the gate is
  sound on the happy path. First-time / never-paid → `paymentReference` absent →
  falls back to paying (safe default).

**No rules change:** the user self-update rule already allows setting
`verificationStatus:'pending'` (only `verified`/`rejected` are admin-gated), and
a free re-apply writes the exact same shape as a first-time submit.

**DEPLOY:** app rebuild only.

**⚠️ Admin-repo dependency (verify):** the admin dashboard's REJECT action
(`clearrent_admin`) must (a) write `rejectionReason` on the user doc — so the
app shows it — and (b) PRESERVE `verificationPaymentReference` (don't clear it) —
so free re-apply is detected. The in-app `rejectVerification` already does both;
confirm the admin repo mirrors it.

**Inspection-integrity roadmap COMPLETE (Phases 1–4).** Next candidates: the
admin collusion-analytics VIEW (consumes Phase 3 signals, lives in
`clearrent_admin`); G6 Paystack webhook / server-authoritative payments
(pre-launch gate, per money-flow certification).

---

## ▶ START HERE — 2026-07-10e (Phase 3 — collusion-analytics data capture)

Verified: functions `tsc` ✓. **NOT committed. NOT deployed.** Small phase.

**Finding first:** two of the three Phase-3 signals were ALREADY captured —
- **Arrival flags**: on the inspection doc (`tenantArrived`/`handlerArrived`/
  `tenantOnWay`/`handlerOnWay` + timestamps, `met`/`metBy`, `tenantNoShow`).
- **Refund reason**: normalized on the `refunds` doc (`source`+`reason` via
  `deriveRefundReason`, `admin_money_ops.ts`), joinable to the inspection by
  `requestId` (= refund doc id / `sourceDocId`).

The genuine gap was **tenant↔handler pairing**: the handler is `agentId`
(agent-handled) OR `landlordId` (self-handled), so you couldn't group
inspections by pair. Fixed:

**What changed (functions only):** `onInspectionRequestCreated` (index.ts) now
stamps `handlerId` (= `agentId ?? landlordId`) + `handlerType`
(`'agent'`|`'landlord'`) on every inspection, server-authoritative, before the
`pendingPayment` early-return. Admin analytics can now query
`where('handlerId','==',X)` and group by `tenantId` in code to surface
repeat-pairing collusion (met-but-never-rents; ₦7k farming with fake tenants).
No composite index introduced (single-field auto-index + in-code grouping; the
project has no `firestore.indexes.json` and I didn't want to change deploy
behavior). No rules change (inspection reads already allow `isAdmin()`; the
stamp is an admin-SDK write).

**DEPLOY:** `cd functions && npm run build && firebase deploy --only functions:onInspectionRequestCreated`.
Optional backfill for existing inspections (test data):
`npx ts-node scripts/backfill-inspection-handler.ts [--apply]`.

**NOT built (this is capture only):** the admin analytics VIEW that scores
pairs / flags collusion lives in `clearrent_admin` (next phase). The raw
signals are now all present: pairing key (inspection) + arrival flags
(inspection) + refund reason (refunds) + rental join (active_rentals by
tenantId+propertyId, for met-but-no-rental).

**Remaining:** Phase 4 = verification rejection reason + free re-apply.

---

## ▶ START HERE — 2026-07-10d (Phase 2b — reveal-on-approval, server-enforced)

Verified: `flutter analyze` ✓ (full tree), firestore rules tests **92/92** ✓
(was 81; +11 new). **NOT committed. NOT deployed.** Functions `src/` untouched.

**Decision (user):** full server enforcement. The old reveal was cosmetic — the
client hid the address but the exact street `address` + precise `lat/lng` were
still in the world-readable property doc (`firestore.rules:142` = any authed
user) AND were written into the tenant's own inspection_request at booking
(pre-approval). Both closed.

**Design:** exact street `address` + `latitude`/`longitude` no longer live on
the parent `properties/{id}` doc. They move to a gated subdoc
`properties/{id}/private/location`. A **reveal grant** `properties/{id}/reveals/{tenantId}`
is written when the handler approves that tenant's inspection; the subdoc's read
rule honors it. Parent doc keeps only area-level `city`/`state`/`lga`.

**What changed (app):**
- **`property_service.dart`** — new `getExactLocation(propertyId)` (reads the
  subdoc; returns null when not entitled). `createProperty` writes parent first
  then the subdoc (can't batch — the subdoc write rule `get()`s the parent's
  landlordId, invisible for a same-batch create). `updateProperty` intercepts
  `address`/`latitude`/`longitude` and routes them to the subdoc (batched; parent
  pre-exists).
- **`inspection_service.dart`** — `approveRequest` now (1) reads the exact
  location from the subdoc (handler is entitled) and fills `propertyAddress` +
  coords into the request = the reveal, so handler & tenant both see the exact
  address post-approval and it flows into the rental chain; (2) writes the
  reveal grant. `createInspectionRequest` writes `property.approximateAddress`
  at booking (was exact). Fee calc (`calculateInspectionFee`) now prefers the
  public `inspectionPropertyCluster` (address is hidden; cluster is area-level).
- **`property_model.dart`** — already tolerated absent `address`/coords (defaults
  ''/null). Added public `inspectionPropertyCluster` (field + fromFirestore +
  copyWith) for the fee calc.
- **Entitled read sites** now fetch the subdoc: property_detail (tenant reveal
  when `_addressUnlocked`, + owner), edit_property (prefill in
  `_loadFreshPropertyData`; save guarded so a failed load can't blank the
  address), property_health, agent_property_detail. Agent assigned-list +
  tenant_home search show area-level only (no per-row subdoc reads).
- **Rules** — new `match /properties/{pid}/private/{doc}` (read: owner /
  assigned agent / admin / reveal-grant; write: owner or assigned agent) and
  `match /properties/{pid}/reveals/{tid}` (read: tenant / handler / admin;
  create/update: handler only). Helpers `propertyOwner()`/`propertyAgent()`.

**DEPLOY:**
```
firebase deploy --only firestore:rules
# app rebuild (flutter run / appbundle). NO functions/src change this phase.
```
⚠️ **MIGRATION:** existing properties still have `address`/`lat/lng` on the parent
and NO subdoc → after rules deploy, entitled screens show blank/area-level for
them and their tenants can't get an exact address. **All property data is test
data** (user confirmed — only the super-admin *user* `oredugbamide@gmail.com` is
real), so this is a non-issue; recreate listings or run the optional backfill:
`cd functions && npx ts-node scripts/backfill-gated-location.ts [--apply]`
(moves exact fields into the subdoc, strips them from the parent; dry-run default).

**⚠️ ADMIN-REPO FOLLOW-UP (required, separate repo `clearrent_admin`):** the admin
dashboard reads `property.address` off the parent doc — now absent, so addresses
render blank. Admin must fetch `properties/{id}/private/location` (rules already
allow `isAdmin()`). Sites: properties list/detail + the users/[uid] correlation
page. Not doable from this repo.

**Follow-up (out of scope, noted):** `buildings/{id}.address` (compound address)
is still world-readable — a parallel leak if a tenant reads the building doc.
Not part of 2b.

**Remaining inspection-integrity phases:** 3 = collusion analytics capture
(per-inspection arrival flags, refund reason, tenant↔handler pairing);
4 = verification rejection reason + free re-apply.

---

## ▶ START HERE — 2026-07-10c (Phase 2 — property readiness gate)

Verified clean: functions `tsc` ✓, `flutter analyze` ✓ (full), admin `tsc` ✓,
firestore rules tests **81/81** ✓. **NOT committed. NOT deployed.**

**Decision (user):** EVERY property — agent-handled AND self-handled — must be
vetted by its handler before it's bookable for inspection. Short checklist.
Unvetted ⇒ block the tenant with a message. (Caveat: self-handled = the landlord
self-attests, not an independent check; a true independent vet would be a
separate admin/agent physical-vetting flow — not built.)

**What it does:** a property is only bookable once `readyForInspections == true`.
- **Model:** `property.readyForInspections` (bool, default false) +
  `readinessCheckedAt`/`readinessCheckedBy` (`property_model.dart`). Absent ⇒ not
  ready (legacy properties must be vetted).
- **Resets to false on ANY handler change** — `assignAgent`, `removeAgent`,
  `updateInspectionHandler` (`property_service.dart`) and CF
  `revertPropertyToSelf` (`agent_property_ops.ts`, used by
  `agentUnassignFromProperty` + the delete cascade) — so a new handler re-vets.
- **Vet action:** `PropertyService.markReadyForInspections` +
  `readinessChecklistItems` (4 items). New sheet
  `lib/shared/widgets/property_readiness_sheet.dart`. Shown to the **agent**
  (`agent_property_detail_screen._buildReadinessCard`) and the **landlord**
  (`property_detail_screen._buildReadinessCard`: self-handled → vet CTA;
  agent-handled → "waiting on your agent" info; ready → confirmation).
- **Gate:** tenant is blocked BEFORE payment in `request_inspection_sheet`
  (`_notReady` → button disabled + banner); `createInspectionRequest` also
  returns `property_not_ready`. **Rules:** `propertyIsReady()` on
  `inspection_requests` create + an agent-scoped readiness-update clause on
  `properties` (the agent doesn't own the doc). Admin properties page shows a
  **Vetted / Not vetted** badge.

**DEPLOY:**
```
cd functions && npm run build && firebase deploy --only functions:agentUnassignFromProperty,functions:deleteMyAccount
firebase deploy --only firestore:rules
# app rebuild (flutter run / appbundle) + admin Vercel deploy
```
⚠️ **MIGRATION CLIFF:** the moment the rules deploy, every EXISTING property (no
`readyForInspections` field) becomes **unbookable** until its handler opens it
and confirms readiness. Intended per "every property must be checked." If you'd
rather grandfather existing listings, run a one-off backfill setting
`readyForInspections: true` on current properties BEFORE deploying the rules.

**Deploy status (2026-07-10):** ✅ rules deployed · ✅ functions deployed
(`agentUnassignFromProperty`, `deleteMyAccount`). Pending: app rebuild + admin push.

**Follow-ups added while testing (2026-07-10):**
- Landlord readiness card (agent-handled, not-ready) now NAMES the agent +
  a **Message agent** button → `getOrCreateAgentLandlordConversation` → `/chat`,
  so the landlord can ask when the agent will come review
  (`property_detail_screen._messageAssignedAgent`). **Client-only** (app rebuild).
- Agent-assignment push copy (`onPropertyAgentAssigned`, index.ts) now says
  "confirm it's ready — tenants can't book until you do." **Needs deploy:**
  `firebase deploy --only functions:onPropertyAgentAssigned`.

---

## ▶ START HERE — 2026-07-10b (admin observability A + inspection-day awareness B)

Both repos build clean: functions `tsc` ✓, admin `next build` ✓. **NOT committed.**
**Deploy:** `cd functions && npm run build && firebase deploy --only functions:nudgeInspectionParty`
(new callable) + admin **Vercel** deploy. **No firestore.rules change** (all reads already
allow `isAdmin()`; pin uses the blanket admin update rule at `firestore.rules:709`).

**A) Admin correlation layer (relationship-navigable).** New route
`clearrent_admin/src/app/dashboard/users/[uid]/page.tsx`: a per-user profile that
one-shot parallel-loads everything touching a user and stitches it together —
properties **owned** (`landlordId`) / **handled** as agent (`assignedAgentId`);
**active_rentals + tenancy_links** both as tenant AND as landlord (who's in each
unit); **inspections** across tenant/agent/landlord roles; **issues**
(tenant+landlord); **payments** (`userId`); **refunds** (`beneficiaryId`).
Counterparty names resolve into clickable `PersonLink`s → `/dashboard/users/{uid}`,
so admin can walk the graph ("who's tenant where, who owns where, who inspects
where"). Role-adaptive: only non-empty sections render. Reached via a new
"View full profile" button in the existing Users-list slide-over.

**B) Inspection-day awareness.** New route `.../dashboard/inspections/page.tsx`
(nav item **"Inspection Day"**): realtime `inspection_requests where
status=='approved'`, grouped **Pinned / Overdue / Today / Upcoming**, with
tenant+handler arrival-progress pills (onWay → arrived). Two admin actions:
- **Nudge** tenant or handler → NEW callable **`nudgeInspectionParty`**
  (`functions/src/inspection_admin_ops.ts`, exported in index.ts). A CF is
  REQUIRED because notifications carry `create: if false` (admin SDK only).
  It's admin-gated (`assertAdmin`), resolves the recipient (tenant→tenantId,
  handler→agentId ?? landlordId), writes a `notifications` doc (auto-id — a
  double-press SHOULD send twice) that `onNotificationCreated` turns into an FCM
  push, and audit-logs. Complements the existing AUTO reminders
  (`inspectionMorningReminders` 07:00, `inspectionSoonReminders` hourly).
- **Pin** to follow up → admin `updateDoc adminPinned` on the inspection (pinned
  rows float to the top group).

---

## ▶ START HERE — 2026-07-10 (money-flow certification + inspection anti-collusion Phase 1 + bank visibility)

Both repos `tsc` ✓. **NOT committed. Functions `lib/` rebuilt — re-run `firebase deploy --only functions`; admin needs a Vercel deploy.**

⚠️ **Deploy gotcha (new):** `firebase.json` has NO predeploy build hook. You MUST
`cd functions && npm run build` BEFORE `firebase deploy --only functions`, or it
ships the stale `lib/` and reports "No changes detected" (happened first try).

**Money-flow certification** (memory: `money-flow-certification-2026-07`): traced
every money flow. Clean = renewals, rent-review, payout mechanics, refund
creation, earnings ledger, inspection + lease sweeps. Gap register G1–G7.
**G6 = PRE-LAUNCH GATE:** every Paystack payment is client-recorded, there is NO
webhook, so on live keys a charge can succeed with no record. G1–G4 = rent
(abandoned `payment_verified` interest never swept/refunded; landlord payout not
gated on move-in; disputed agreement only notifies). G7 = verification no refund.

**Phase 1 — inspection anti-collusion refund (DONE in tree, needs deploy):**
- **Invariant:** money auto-moves ONLY when both parties confirm they met
  (`met===true` → auto-completed, handler credited ₦7k). EVERY one-sided/no-show
  outcome now → admin review queue (`awaitingOutcome`). Changed the sweep
  (`functions/src/inspection_lifecycle_ops.ts`): handler-absence AND
  tenant-no-show branches → `awaitingOutcome` (were auto-refund / auto-complete).
  Closes the collusion honeypot (handler *absence* was a forgeable free-refund).
- Fee always **₦10k = handler ₦7k + ClearRent ₦3k flat**. Admin resolves in
  Inspection Reviews: tenant-showed/handler-didn't → **Full refund ₦10k**;
  neither showed → **Minus ₦3k** (tenant ₦7k, ClearRent ₦3k); handler-showed/
  tenant-no-show → **Mark completed** (agent ₦7k, tenant ₦0).
- `onInspectionRefundTriggered` (`admin_money_ops.ts`) honors a `refundAmount`
  override (clamped ≤ totalFee); refund source tagged `inspection_admin_review`.
  Admin inspection-reviews page: refund modal with Full / Minus-₦3k presets.

**Bank-visibility fix (admin only, DONE):** `MarkPaidModal` now shows a "Send to"
block (account **name** + bank + number + copy) — wired into refunds, payouts,
rent-payouts. Inspection-review refund modal loads the tenant's bank + a note
that the transfer completes in the Refunds tab.

**NEXT (planned, specced in memory `inspection-integrity-build-2026-07`):**
- **A) Admin observability / correlation layer** (user's pick) — per-user view:
  who owns / occupies / handles which property, + their issues/payments.
- **B) Admin inspection-day awareness** — today's inspections view + nudge
  tenant/handler + pin. NOTE tenant+handler auto-reminders already exist
  (`inspectionMorningReminders` 07:00, `inspectionSoonReminders` hourly).
- Remaining: agent readiness gate (vet at assignment → bookable), reveal-on-
  approval, collusion analytics capture, verification rejection reason + free
  re-apply.

---

## ▶ START HERE — 2026-07-07 (security-audit fixes + Naira glyph + occupancy)

All committed to `develop` and pushed. Flutter `analyze` ✓, functions `tsc` ✓.

**Shipped to prod this session (deployed):**
- 🔴 **Security — users self-verify bypass CLOSED.** The `users` owner-update
  rule had no field allowlist, so a modified client could set
  `verificationStatus:'verified'` and list properties without paying/review.
  `firestore.rules` now blocks self-assigning verified/rejected + earnings;
  `agent_ratings` create requires `raterId==uid`. **Deployed.**
- **`resolveAccount` CF** — Paystack 429 now maps to `resource-exhausted`
  (was a generic "unavailable"). **Deployed.**

**Committed (client — needs an app rebuild/release to ship):**
- **Naira sign (₦) renders app-wide.** Outfit has no ₦ glyph; a *system*
  'Roboto' fallback isn't resolved reliably (MIUI). Fix bundles Roboto
  (Apache-2.0, from the Flutter SDK) as an asset family + `fontFamilyFallback`
  on all `AppTextStyles`/theme. Verified on a Redmi. See `text_styles.dart`,
  `theme_provider.dart`, `pubspec.yaml`, `assets/fonts/Roboto-*`.
- **Payment callables** — App-Check `unauthenticated` / 429 now surface
  accurate messages instead of "network error" (`paystack_service.dart`).
- **Property detail** — action bar padded above the gesture/nav bar
  (`Scaffold.bottomSheet` doesn't inset); Request Inspection shows disabled
  "Not Available" on occupied units.

**In progress (approved, NOT built yet):**
- **Rating system → Bayesian + count, server-side.** Today it's a plain mean
  computed client-side, so one 5★ = 5.0 AND anyone can write anyone's rating
  (audit #2). Plan: a CF on `inspection_requests` tenantRating write computes
  `(C·m+sum)/(C+n)` (m=3.5, C=5) → user doc; lock user-doc rating to CF-only;
  show the count. `agent_service.rateAgent`/`agent_ratings` is DEAD (no callers).
- **Inspection request → agent readiness reminder** at approval (non-blocking).

**Gotchas confirmed this session (see memory):**
- App Check **debug token is per-device** — register each test device's token
  (Console → App Check → Manage debug tokens) or the enforced callables fail.
- Paystack **test key** rate-limits `/bank/resolve` hard (429) — not an outage.
- Phone-auth on a **sideloaded debug** build falls back to reCAPTCHA (18002)
  and dies with "missing initial state" on MIUI — use a Play internal track.

**Open audit follow-ups:** #2 rating (in progress), #4 client-set money amounts
(H2), #5 renewal ref reuse, #6 user PII read scope, #7 payments forgeable,
enable App Check on `lookupEmailByPhone`, strip `setVerificationExempt`.

---

## ▶ START HERE — 2026-06-26 (refund close-out + Play internal-testing)

Two threads this session: (A) the refund system was finished end-to-end, and
(B) the app was pushed to a Play **internal-testing** track to test real-number
OTP. All code clean: Flutter `analyze` ✓, functions `tsc` ✓, admin `tsc` ✓.

### 1. PENDING DEPLOYS (do these)
```bash
# app repo (c:\Users\MIDE\clearrent) — the two CFs changed AFTER the earlier deploy
firebase deploy --only functions:onRentalInterestAccepted,functions:markRefundPaid --project clearrent-app
flutter build appbundle --release   # or flutter run — tenant loser-refund card + refund_service changed

# admin repo (c:\Users\MIDE\clearrent_admin) — NEW Refunds page + nav + banner count
cd ..\clearrent_admin && vercel --prod
```
(Earlier this session the 5-CF guided-UX batch was already deployed successfully:
`onActiveRentalUpdated,onRentPaymentRecorded,onRentalInterestPaid,onInspectionRequestUpdated,onRentalInterestAccepted`.)

### 2. Refund system — now symmetric end-to-end
Was: only **inspection** refunds had a payout lifecycle; **rental-loser** refunds
were a dead-end (status flip only, no admin processing, no tenant "Paid").
- **NEW admin Refunds queue** (`clearrent_admin/src/app/dashboard/refunds/page.tsx`):
  lists the `refunds` collection (Pending/Paid), shows beneficiary + bank details
  + reason, marks paid via the existing `MarkPaidModal`→`markRefundPaid`. Added to
  the sidebar (`dashboard-shell.tsx`) and the **Attention banner** now counts
  `refunds where status=='pending'` (`attention-banner.tsx`) — closes the §4(a)
  follow-up. (Sorted client-side — no composite index.)
- **#1 Loser refunds now enter the queue** (`admin_money_ops.ts` `onRentalInterestAccepted`):
  each loser also `.create()`s a `refunds/{interestId}` doc (`source: rental_loser`,
  `beneficiaryRole: tenant`, amount=`paymentAmount`). Best-effort + idempotent;
  the `lost_to_other` flip stays the source of truth.
- **#3 `markRefundPaid` now notifies + receipts** (`admin_money_ops.ts`): on payout it
  writes a `refund_paid` push (deep-link `/tenant/documents`) + a `payments/REFUND_{id}`
  receipt, matching the other 3 `mark*Paid` CFs (was silent before).
- **#2 Tenant "Paid" parity for losers** (`tenant_inspections_screen.dart` +
  `refund_service.dart` `streamForRental`): the loser card streams `refunds/{interestId}`
  and shows Processing → Paid, like the inspection-refund card.
- **Caveats:** pre-existing `lost_to_other` losers won't backfill (trigger is
  forward-looking); a loser refund shows in BOTH the Refunds queue and Payments→
  Refunded tab (consistent with inspection refunds — queue is where you *process*).

### 3. Play internal-testing — real-number OTP — ✅ RESOLVED (2026-06-26)
**Real-number OTP now works** from the Play internal-testing build (verified on
2 real Nigerian numbers, not a fluke). Root cause of the earlier failure was NOT
config — every piece was already correct (SHA-256 registered + matches Play
Console, Play Integrity passes on-device, App Check unenforced, SMS region =
Allow+Nigeria, Blaze billing healthy). A brand-new, freshly Play-recognized app
sending real SMS (esp. to Nigeria) just needed **time** for Google's phone-auth
anti-abuse to warm up and trust it; it cleared after a few more hours. The
`17499 internal error` was that backend warm-up window, not a code/config bug.
No code change was required. (Debug-sideload OTP still can't work — must be the
Play install. Test numbers like the Itel's own number bypass real SMS by design.)

Build/config side is DONE: release signing wired (`clearrent-release.jks` at repo
root, `android/app/key.properties`), `com.verealtytech.clearrent` registered in
`google-services.json`, ProGuard covers Firebase + Play Core, **release AAB builds
clean** (`flutter build appbundle --release` → 34.8 MB).
- App is uploaded to the **Internal testing** track (Active), testers added.
- **App signing key SHA registered in Firebase** (project `clearrent-app`, app
  `com.verealtytech.clearrent`) — the OTP-critical step:
  - SHA-1  `0F:86:E2:3D:58:DC:1F:91:66:D2:26:40:D0:ED:BB:E0:51:51:B9:CD`
  - SHA-256 `AB:4D:D6:DB:80:05:16:96:8D:53:A0:D6:6B:12:BD:95:F4:84:38:F7:6A:EC:6D:9F:F7:F0:7F:EE:7A:D4:78:66`
  - (Upload key cert is different: SHA-1 `2F:80:74:A2:…`, SHA-256 `D3:95:54:0F:…`.)
- **To test:** UNINSTALL the `flutter run` debug build first (signature conflict +
  debug can't pass Play Integrity), then install from the Play internal-testing
  **opt-in link** on the **Itel (Android)** and sign in with a real Nigerian number.
  The iPhone can't run the Android AAB. If the Itel's number is rate-limited from
  earlier attempts, move the friend's SIM into the Itel.
- ⚠️ Still `AndroidProvider.debug` for App Check (`main.dart`) — fine for OTP
  (phone auth uses Play Integrity, not App Check; App Check unenforced). Switch to
  `playIntegrity` before public launch. Bump `pubspec` version (`1.0.0+1`→`+2`)
  for any re-upload.

---

## ▶▶ SECURITY AUDIT — IN PROGRESS (2026-06-26)

Full adversarial audit across app + admin + web + functions + rules. Findings
and remediation status below. **Threat model:** for this money app the UIs are
NOT the security boundary — the **Firestore rules + money-CFs are** — so the
real severity clusters there.

### Findings (severity → status)
- 🔴 **C1 — `users` doc exposes all bank details + PII.** `users/{uid}` is
  readable/listable by any authed user (rules lines 30/35) and contained
  `bankDetails.accountNumber`, `phone`, `email`. **CODE FIXED 2026-06-26**
  (bankDetails only; phone/email deferred — see note). Bank data moved to the
  locked `users/{uid}/private/bank` subcollection (owner + admin read, owner
  write — new rule + 5 tests, suite **69/69**). Surfaces:
  • Rules — added `match /users/{userId}/private/{docId}`.
  • Flutter write+read — `auth_service.saveBankDetails`/`getBankDetails`
    (subcollection + non-sensitive `hasBankDetails` flag on the user doc);
    `bank_details_screen` uses them; agent-home + tenant-home nudges read the
    flag (no extra read, nothing sensitive on the user doc).
  • Admin — new shared `src/lib/bank.ts` `fetchBankDetails(uid)`
    (subcollection-first, **legacy fallback** so it's safe pre-migration);
    payouts / rent-payouts / refunds pages use it (`tsc` clean).
  • Migration — `migrate_bank_details.js` (admin SDK, `--dry-run`): copies
    `bankDetails` → `private/bank`, sets `hasBankDetails:true`, deletes the
    field. Idempotent. **USER must run it** (needs `serviceAccountKey.json`).
  ⚠️ **phone/email still readable on the user doc by any authed user** — NOT
  done here (tightening the whole `users` read rule risks breaking the many
  legit cross-user name/phone/rating/verification reads). Treat as a separate
  medium. C1's account-number exposure (the sharp edge) is closed.
- 🟠 **H1 — broad `list` rules expose whole collections.** ~11 collections had
  `allow list: if request.auth != null` (any user dumps the collection).
  **MOSTLY FIXED 2026-06-26:** `payments`, `notifications`, `transactions`,
  `refunds`, `rent_review_requests` (first slice), then `issues`,
  `maintenance_logs`, `inspection_requests`, `active_rentals` (H1-rest) now
  require owner-scoped queries. firestore-tests **56/56** pass. Per-collection:
  • `issues` — added `landlordId` filter to PropertyHealth ([property_health_screen.dart:108]); rule = tenant/landlord/admin.
  • `maintenance_logs` — added `landlordId` filter to PropertyHealth ([:716]); rule = landlord/admin. ⚠️ **NEW COMPOSITE INDEX REQUIRED (user):** `maintenance_logs (landlordId ASC, propertyId ASC, loggedAt DESC)` — the app throws an index-link error on the Property-Health maintenance list until it's created.
  • `inspection_requests` — NO query change (all live queries already scope by tenant/landlord/agentId; the 3 propertyId/status-only methods `getPropertyRequests`/`getPendingVerificationRequests`/`getPendingAgentPayouts` are **dead code**, Flutter admin screens removed); rule = tenant/landlord/agent/admin.
  • `active_rentals` — added `landlordId` filter to the owner-only occupancy/management queries ([property_service.dart] + [rent_review_service.dart] `propertyHasSittingTenant`, property_detail `_buildTenantManagementSection`); the tenant-facing `_buildOccupancyInfoCard` now reads the property's server-maintained `currentTenantsCount` instead of listing `active_rentals`; `_loadOccupancy` now guarded to owner-only. rule = tenant/landlord/admin. (No new index — all-equality queries.)
  ⚠️ **Two unwired dead-code utilities would fail the tightened active_rentals rule if ever invoked:** `ActiveRentalService.updateRentalStatuses()` ([active_rental_service.dart:830]) and `fix_zero_rent_amounts.dart` — both do collection-wide queries; neither has any caller. Run via admin SDK if needed, or delete.
  **STILL OPEN:** `conversations` — DEFERRED to M3 (2026-06-26 decision). The
  agent-initiated `getOrCreateConversation` dedup query ([conversation_service.dart:162])
  filters `propertyId+landlordId+tenantId` with no agentId/participants
  constraint, so an owner-scoped rule rejects it for agent callers. Closing it
  needs that query refactored to `participants arrayContains uid` + client-filter
  (subtle dedup behaviour change) — handle under M3.
- 🟠 **H2 — clients can fabricate financial state.** Unconstrained `create` on
  `inspection_requests`/`rental_interests`/`active_rentals`/`payments` lets a
  tampered client write `paymentStatus:'paid'`, payout amounts, etc. Confirmed:
  `onRentPaymentRecorded` ([index.ts:794-803]) falls back to client-supplied
  `landlordPayout`/`landlordId`, so a forged payment writes an earnings row.
  Chain: forge paid inspection w/ high `totalFee` → self-refund → fabricated
  pending refund in the admin Refunds queue. **NOT FIXED** — constrain creates +
  make `onRentPaymentRecorded` derive money only from `rental_interests`.
- 🟠 **H3 — committed Paystack secret.** `backfill_payments.js:26` hardcodes a
  `sk_test_…` key and is tracked in git (commit `5fd7b80`). Also
  `functions/serviceAccountKey.json` is a real admin key on disk (gitignored,
  never committed, but unnecessary — Functions use ADC). **FILE FIX DONE
  2026-06-26** — `backfill_payments.js` now reads `PAYSTACK_SECRET_KEY` from env.
  ⚠️ STILL TODO (user): the key is in git history (commit `5fd7b80`) so it MUST
  be **rotated in the Paystack dashboard**; optionally delete `serviceAccountKey.json`.
- 🟡 Mediums: M1 `activities` fully open · M2 `rental_interests` update no
  field-allowlist · M3 `conversations` list enumerable · M4 App Check off on all
  callables (`enforceAppCheck:false`; enable post-`playIntegrity`) · M5
  `setVerificationExempt` identity backdoor (strip before launch) · M6
  `serviceAccountKey.json` on disk · M7 website has no security headers
  (`next.config.ts` no CSP/HSTS/X-Frame) · M8 admin app has no `middleware.ts`
  (mitigated by rules + the API route's own check).
- 🟢 Good posture confirmed: admin-claim model (superAdmin-gated `setAdminClaim`,
  blocks self-escalation), `/api/verification-image` (token+claim+path-prefix),
  prod secrets in Secret Manager, `.env.local` gitignored, Flutter client has no
  secret keys (only Paystack public key).

### Remediation order (recommended)
1. ✅ H1 verified-safe slice (payments/notifications/transactions/refunds/rent_review_requests) — DONE, tested (40/40).
2. ✅ H3 secrets file fix — DONE (env var). ⚠️ user must still ROTATE the Paystack key.
3. ✅ H1-rest — owner-filters + tightened `list` rules for issues, maintenance_logs, inspection_requests, active_rentals — DONE 2026-06-26, tested (56/56). `conversations` deferred to M3. ⚠️ user: create the new `maintenance_logs` composite index (see H1 above).
4. H2 — **IN PROGRESS 2026-06-26.** ✅ `onRentPaymentRecorded` ([index.ts]) now
   derives money + payee identity ONLY from the linked `rental_interest` and
   writes NO earnings if `rentalInterestId` is absent/missing (was falling back
   to client-supplied `pay.landlordId`/`pay.landlordPayout`). `tsc` clean.
   ⚠️ needs `firebase deploy --only functions:onRentPaymentRecorded`.
   ✅ **Defense-in-depth create/update locks DONE 2026-06-26** (decision: rules-only,
   no payment-flow breakage). Tested **64/64**. Changes:
   • `rental_interests` create — must be `tenantId == uid` AND start
     `status:'pending_payment'` (can't mint an already-verified interest).
   • `rental_interests` update (M2) — added a field allowlist: parties may touch
     only the payment/acceptance lifecycle fields (status, paymentReceiptUrl,
     paymentUploadedAt, paymentRejectionReason, isPaymentVerified,
     paymentReference, paymentVerifiedAt, paidAt, acceptedAt, updatedAt);
     payouts/amounts/fees/identity ids are now immutable post-create. Admin
     still updates freely. (Verified against all live update sites in
     rental_interest_service.dart: 108/160/185/224; `verifyRentalPayment`@136 is dead.)
   • `active_rentals` create — only the landlord, and only when the referenced
     `rentalInterestId` resolves to an interest they own that's
     `payment_verified`/`accepted`. (Sole creator is the landlord via
     `createActiveRental`; `createRental`@149 is dead.)
   ⚠️ needs `firebase deploy --only firestore:rules`.
   **STILL the real fix (deferred, pre-launch):** payments are client-asserted —
   tenant writes `status:'payment_verified'` ([rental_payment_screen.dart:106]) and
   `paymentStatus:'paid'` on inspections client-side; payout figures are
   client-computed. A `verifyPayment` CF EXISTS ([paystack_service.dart:170]) but
   is NOT the sole writer of paid/verified state. True fix = make a CF verify the
   Paystack reference and be the only writer of paid/verified/earnings (Option B —
   touches payment screens). Tracked for pre-launch.
5. ✅ C1 — `users` bankDetails → locked `private/bank` subcollection + migration
   script — CODE DONE 2026-06-26, tested (69/69). ⚠️ user: deploy rules + app
   rebuild + admin redeploy, then RUN `node migrate_bank_details.js` (try
   `--dry-run` first). phone/email exposure deferred to mediums.
6. Mediums + legal — **IN PROGRESS 2026-06-26.**
   • ✅ **M1 `activities`** — read/list/update now owner-scoped (`landlordId == uid
     || actorId == uid || isAdmin()`; create left auth-gated — heterogeneous
     actor shapes). Tested **75/75**. ⚠️ needs rules deploy.
   • ✅ **M7 web security headers** — `clearrent_web/next.config.ts` now sets
     HSTS, X-Frame-Options DENY, X-Content-Type-Options, Referrer-Policy,
     Permissions-Policy, and a CSP (allows Google Fonts + inline for
     Next/next-themes). `tsc` clean. ⚠️ needs `vercel --prod` (clearrent_web).
   • ✅ **Legal audit** done (report-only, no text changed) — see "LEGAL AUDIT"
     section below. Headline: **location permissions in AndroidManifest but
     geolocator is unused** → remove the permissions (Play blocker) or disclose.
   • ✅ **Location cleanup** (legal #1) — removed `ACCESS_FINE/COARSE_LOCATION`
     from AndroidManifest + dropped the unused `geolocator` dep (`pub get` +
     full `flutter analyze` clean). Closes the Play location mismatch.
   • ✅ **M3 conversations** — refactored the agent-path dedup query in
     `getOrCreateConversation` to `participants array-contains caller` +
     client-filter (no new index), then tightened the `list` rule to
     participant/party-scoped. Tested **81/81**. (Other dedup queries already
     scope by agentId==caller — unchanged.) ⚠️ rules deploy + app rebuild.
   • ⏸️ **M8 admin middleware — assessed, NOT built (recommend accept).**
     `/dashboard` is already client-guarded (`DashboardShell` redirects
     non-admins + renders nothing until the admin claim resolves) AND the data
     is rules-protected (isAdmin). Real Edge-middleware auth needs a Firebase
     session-cookie pipeline (admin SDK `createSessionCookie` + login API route
     + cookie verify) — a sizable feature guarding only the UI shell, no data.
     Low marginal value; left as a documented accept.
   • ✅ **M4 App Check — STAGED 2026-06-26** (decision: stage now, verify on
     Play). `main.dart` → `AndroidProvider.playIntegrity`. Enforcement
     (`enforceAppCheck:true`) flipped on EXACTLY the **8 Flutter-invoked
     callables**: `resolveAccount`, `initializePayment`, `verifyPayment`,
     `refundPayment` (index.ts), `deleteMyAccount` (account_ops),
     `getSignedAgreementUrl` (doc_access_ops), `submitNin` (nin_ops),
     `agentUnassignFromProperty` (agent_property_ops). `tsc` clean.
     **Left UNENFORCED on purpose** (would break otherwise): admin-web callables
     `markInspectionAgentPayoutPaid`/`markRentLandlordPayoutPaid`/
     `markRentAgentCommissionPaid`/`markRefundPaid` (admin_money_ops) +
     `approveRentReview`/`rejectRentReview`/`approveImmediateRentChange`
     (rent_review_ops) + `setAdminClaim` (the admin web app has NO App Check);
     `lookupEmailByPhone` (runs at sign-in); `setVerificationExempt` (M5);
     `completeActiveRenewal`/`completeLinkedPromotion` (renewal_ops — caller
     unconfirmed; enforce later if Flutter-only). iOS App Check not configured
     (separate step when iOS ships).
     🔴 **VERIFY ON A PLAY BUILD before trusting:** a `flutter run`/sideload
     install FAILS Play Integrity, so the 8 enforced callables (payments, NIN,
     account delete, agreement view, agent unassign) will reject on non-Play
     builds — expected. Test them on the Play internal-testing AAB. Needs
     `firebase deploy --only functions` for the 8 + the rules; app rebuild.
   • M5 — keep `setVerificationExempt` until public launch (still using test
     accounts). M6 — delete `serviceAccountKey.json` only AFTER the C1 migration.

### LEGAL AUDIT (2026-06-26) — privacy/terms vs NDPR + Play Data-safety
Content in `clearrent_web/components/LegalContent.tsx` (privacy/terms/cookies).
**Baseline is strong** — already NDPA-2023 aligned: named controller (Verealty
Technologies Ltd, RC 9435442), data categories incl. bank/NIN/income, lawful
basis, processors (Firebase/Cloudinary/Paystack/Vercel), int'l transfers, data-
subject rights, retention (30d post-delete / 6yr financial), children <18,
thorough cookie policy. Gaps (no edits made — review + approve text yourself):
1. **🔴 Location (Play blocker).** `android/.../AndroidManifest.xml` declares
   `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION`, but `geolocator` (pubspec
   dep) has **zero usage** in `lib/` — the map picker uses tap-to-pin
   (`latlong2`/`flutter_map`), not device GPS. An unused FINE_LOCATION permission
   triggers a Play Data-safety mismatch / review flag. **Either** remove both
   permissions + the `geolocator` dep (recommended — likely vestigial), **or**,
   if device location is intended, disclose it in the privacy policy + declare
   it on the Play form. Decide before the Data-safety submission.
2. **Post-C1 wording (minor).** Privacy §5 says "we are implementing additional
   field-level protection for identification numbers; until then…". After C1,
   bank details ARE access-restricted (locked subcollection); tighten that line
   for bank data (NIN field-level protection is still pending — keep that part).
3. **Breach notification (minor NDPA).** No clause on the 72-hour NDPC breach
   notification / how users are told. Consider adding one.
4. **DPO (minor).** Single generic `info@verealtytech.com`. NDPA expects a
   designated DPO + (controllers of major importance) NDPC registration within
   6 months. Consider a `privacy@` alias; confirm NDPC registration (operational,
   not text).
5. **Play Data-safety mapping** — the policy supports completing the form:
   Personal (name/email/phone/NIN), Financial (bank account + payment history),
   Photos/videos, Messages (in-app chat), App activity/device/IP. Mark
   "encrypted in transit" = yes, "users can request deletion" = yes (30-day),
   and align Location with #1.

### ⚠️ Deploy note
The H1 rule edits are **working-tree only** — live only after
`firebase deploy --only firestore:rules --project clearrent-app`. Validate with:
`npx -y firebase-tools@latest emulators:exec --only firestore --project demo-clearrent "npm --prefix firestore-tests test"` (currently **56/56**).
⚠️ **Before deploying the H1-rest rules, create the `maintenance_logs`
composite index** (landlordId, propertyId, loggedAt DESC) or the Property-Health
maintenance list breaks. The active_rentals/issues/inspection_requests Dart
changes ship on the next app rebuild.

### Also pending (non-audit, from earlier this session)
- Refund CFs + admin Vercel deploy + app rebuild (see ▶ START HERE §1 — the
  `firebase deploy --only functions:onRentalInterestAccepted,functions:markRefundPaid`
  hit a transient "retrieving Firestore database" error; just re-run).
- Phone-field fix (`login_screen.dart`: maxLength 10, rejects leading 0) — client-only, needs rebuild.

---

## ▶ START HERE — 2026-06-21 (guided-UX pass + test-feedback fixes)

All code analyzes clean (Flutter) and the functions compile clean (`tsc`). The
full detail is in the **"Session 2026-06-21"** section below; this is the
deploy + test summary.

### 1. Deploy the new/changed Cloud Functions
```bash
# app repo (c:\Users\MIDE\clearrent)
firebase deploy --only functions:onActiveRentalUpdated,functions:onRentPaymentRecorded,functions:onRentalInterestPaid,functions:onInspectionRequestUpdated,functions:onRentalInterestAccepted --project clearrent-app
```
⚠️ Deploys sometimes hit *"Cannot determine backend specification. Timeout after
10000"* — harmless, just re-run. (Lint is not a deploy gate; the repo-wide CRLF
lint errors are pre-existing — `tsc` build is what matters and it's clean.)

### 2. Rebuild the app
`flutter run` (full restart — model getter + many screens changed). **Everything
this session that isn't in the deploy list above is client-only and lands on the
rebuild alone.**

### 3. Big things to verify this session
- **Notifications now cover the full rent loop:** tenant pays → landlord push +
  Recent-Activities ("review & accept"); landlord accepts → winning tenant push
  ("you got the place"); losing applicants refunded (existing); agreement
  uploaded → tenant push. Plus the corrected "Tenant Confirmed Meeting" wording
  (landlord on an agent-handled inspection gets an FYI, not "you met").
- **Multiple active rentals per tenant** now allowed (the pay-then-block guard is
  gone). My Rentals lists all; the home still *features* one (follow-up to add a
  switcher).
- **Tenant Documents → Payments** populates (was a swallowed composite-index
  error); **Landlord Earnings** populates after a rent payment (new
  `onRentPaymentRecorded` ledger CF).
- **Inspection tabs** (tenant) badge Pending / Upcoming / History (rate nudge).
- **Notification deep-links** open the right inspection tab (the `initialTab`
  String-cast crash is fixed).
- **Phone OTP on real numbers:** see the ⚠️ note at the end of the 2026-06-21
  section — needs a **Play internal-testing build** (debug sideload can't pass
  Play Integrity). Not a code bug.

### 4. Open decisions / follow-ups
- **Home multi-rental switcher** — home features one rental; bridging the
  `ActiveRental` dashboard to the existing `streamTenantRentals()`/`TenantRental`
  multi-type + `resolveDefaultRental` is the remaining piece.
- **Historical earnings backfill** — `onRentPaymentRecorded` is forward-looking;
  pre-existing rent payments won't show until a one-off backfill is run.
- **Pre-Play-Store checklist** discussed (signing ✓ exists, Play-signing SHA →
  Firebase, App Check enforcement, remove test phone numbers + test backdoors,
  Paystack live keys — business approval still pending on their side).

---

## ▶▶ PRE-PLAY-STORE FULL REGRESSION TEST PLAN (head-to-toe)

Goal: confirm the whole app is error-free before a Play Store push. Deploy the
CFs (START HERE §1) + rebuild first. **Real-number OTP needs a Play
internal-testing build** (debug sideload fails Play Integrity) — do auth testing
there; everything else works on a debug build with test phone numbers.
Convention: every state change should produce **one** push that **deep-links**
to the right screen, and the in-app badge/empty-state should reflect it too.

### 0. Infra / launch gates (do before/around testing)
- [ ] Real-number OTP works from a **Play internal-testing** build (Nigeria SMS).
- [ ] App Check debug token registered (silences 403s); decide enforcement for launch.
- [ ] Release signing config builds an AAB; Play App Signing SHA-1/256 added to Firebase.
- [ ] Remove test phone numbers + test backdoors (`setVerificationExempt`, superadmin bootstrap) before launch.
- [ ] Paystack live keys (when business approved); until then payments use the manual-proof / test path.
- [ ] Privacy policy URL + Play Data-safety form.

### 1. Auth & onboarding (all 3 roles)
- [ ] Sign up via phone OTP → account-type → profile setup → lands on the right home.
- [ ] Phone field rejects wrong length / non-digits (max 11, digits only).
- [ ] Log in (phone + password) and email sign-in. Biometric if enabled.
- [ ] Verification flow per role (tenant/landlord/agent); unverified gating where expected.

### 2. Tenant — core journey (end to end)
- [ ] Browse, search, save/unsave (Saved count correct).
- [ ] Request inspection → pay → **Pending** tab badges; landlord/agent gets a push.
- [ ] Approved → **Upcoming** tab badges (without tapping the push); push deep-links to Upcoming.
- [ ] Inspection day: I'm on my way → I've arrived → "I've met the agent/landlord" (correct wording); handler completes.
- [ ] Completed → **History** tab badges (rate nudge) + "Inspection Complete" push; rate → unlocks decision.
- [ ] "I want to rent" → pay → **landlord** gets "tenant paid, review & accept" push + Recent-Activities row.
- [ ] Landlord accepts → tenant gets "You got the place 🎉" push; losing applicants notified + refund record created.
- [ ] Agreement: landlord uploads → tenant push → view/sign; finalize → tenant push.
- [ ] Rent payment → recorded; tenant Documents → **Payments** lists verification + inspection + rent.
- [ ] **Multiple active rentals**: a 2nd accepted rental shows in My Rentals; "Rentals" stat = real count.
- [ ] Report issue (photos; sentence-cased text) → landlord push; track in Issue History stepper; confirm/dispute fix.
- [ ] Notifications inbox: tap each → deep-links correctly (no crash on inspection items).
- [ ] Empty states (no rentals / no inspections / no saved) show guidance + a working button.

### 3. Landlord — core journey
- [ ] Add property: standalone (with C of O) + building/compound (one C of O covers units).
- [ ] Assign agent → reads back as Agent + agent push; unassign ("step back") reverts + fee preserved; re-assign restores fee.
- [ ] Inspection requests: approve / decline / reschedule; can't approve a past-dated request.
- [ ] Accept a paid applicant (Inspections → History) → creates rental; winner + losers notified.
- [ ] Agreements screen: upload / re-upload after dispute / finalize.
- [ ] Rent change: occupied → file → admin approves → push + "applies at renewal"; vacant edits rent directly.
- [ ] **Earnings**: after a rent payment, a landlord transaction row appears (new ledger CF).
- [ ] Issues: Open/In-Progress badges; move issue → tenant push; tabs follow the issue.
- [ ] Rentals: Active badges expiring-soon/grace-locked; Past tab; can't delete an occupied property.
- [ ] Recent Activities shows views/inquiries/payments/issues + "tenant paid to rent".

### 4. Agent — core journey
- [ ] Not-verified empty state → "Complete Verification"; no-assignments → "Discover Properties".
- [ ] Discover properties / tenants; service areas; availability.
- [ ] Assigned a property → push; appears in Properties.
- [ ] Inspections: Pending badge; approve/decline; conduct (on-way/arrived/"I've met the tenant"/complete); Scheduled badge (today/upcoming).
- [ ] Earnings shown in Completed (inspection earnings); payout status.
- [ ] Step back from a property (blocked mid-inspection).

### 5. Admin (web — clearrent_admin, Vercel)
- [ ] "Attention Needed" banner on every screen counts pending docs/verifications/payments/issues/inspection-reviews.
- [ ] Verify/reject property docs (building targets all units); verifications; payments.
- [ ] **Refunds: every pending refund is processable** (inspection refunds + rental losers) and `markRefundPaid` works. ⚠️ banner does NOT yet count refunds — see follow-up.
- [ ] Rent reviews approve/reject; Inspection Reviews resolve (refund / mark completed).

### 6. Cross-cutting
- [ ] Chat works for tenant/landlord/agent; message push + deep-link.
- [ ] Account deletion (each role): blocked with active obligations (real reason); clean account fully purged (Firestore + auth + Storage + Cloudinary).
- [ ] Every empty state uses the shared guidance widget; no RenderFlex overflows on a narrow device.
- [ ] No swallowed errors leaving a list permanently empty (payments-tab class of bug).

---

## Earlier test plan (prior features — may already be covered)

**A. Notifications (every push below should ping the phone AND deep-link on tap)**
- [ ] Each notification = an FCM push + opens the right screen on tap (inbox + system push).

**B. Profile / misc**
- [ ] Profile tab (all 3 roles): no "Profile" title; settings gear top-right.
- [ ] "Ade Compound" building shows address "Ajegunle".

**C. Agent assignment + fee**
- [ ] Landlord → Edit Property → Agent → pick agent → reads back as **Agent**; agent gets a push.
- [ ] Agent → property → "Step back from this property" → reason → reverts to landlord +
      landlord notified; **blocked** if a scheduled/pending inspection on it.
- [ ] After an agent leaves, landlord re-assigns an agent → **agent fee is restored** (not re-entered).
- [ ] Switch a property to "Myself" → clears the agent.

**D. Ownership doc re-verification**
- [ ] Edit a standalone property's C of O → it goes **pending + delisted**; appears in the admin
      "Attention Needed" banner (on ANY admin screen) + Properties review.

**E. Account deletion (try as tenant, landlord, AND agent)**
- [ ] Blocked with an active rental / confirmed OR pending link / pending-scheduled inspection —
      shows the real reason, **deletes nothing**.
- [ ] Agent with assigned properties (no in-flight inspection) → deletes; properties revert to
      landlord (fee preserved) + landlords notified.
- [ ] Clean account (no obligations) → deletes fully: Firestore + auth + Storage
      (verification/ownership/agreements) + Cloudinary (`properties`/`profiles/{uid}`).

**F. Rent change**
- [ ] Vacant property: NO "Request Rent Change" in the ⋯ menu (edit rent on Edit Property, applies now).
- [ ] Occupied: file → admin approves → landlord notif → My Rentals shows
      "New rent ₦X applies when this tenant renews (lease-end date)".
- [ ] Vacant immediate approve → landlord notif deep-links to that property's detail.

**G. Property deletion**
- [ ] Can't delete a property with a sitting/linked tenant (clear message).

**H. Linked tenant**
- [ ] Add linked tenant → set rent due (e.g. Apr 4) → lease term auto-shows
      "Apr 4, 2026 → Apr 4, 2027" read-only (no separate lease-date field).

**I. Inspection lifecycle**
- [ ] Agent can't approve a request whose date already passed.
- [ ] Sweep (runs 02:00 Lagos; or trigger manually): a paid-but-unapproved past request →
      "Expired — Action Needed" in tenant Requests tab with **Reschedule** / **Get Refund**.
- [ ] Reschedule → re-enters approval with the new date (no re-charge). Refund → refund record
      created (admin Payments → Refunded).
- [ ] A passed approved inspection auto-resolves by arrival flags; ambiguous ones land on the
      admin **Inspection Reviews** page → Refund tenant / Mark completed.

**J. Issue reporting (your next test)**
- [ ] Tenant reports an issue (with photos) → submit succeeds → **landlord gets a push** that
      deep-links to `/landlord/issues` for that property. (Needs `onIssueCreated` deployed.)

**K. Agreements / private storage**
- [ ] Tenant "View Agreement" opens (signing works). Uploads land in private Storage; admin can view.

---

## Session 2026-06-21 — guided-UX pass (client-only EXCEPT one new CF)

Goal: make the app self-explanatory — users always know what to do next. Four
mechanisms applied across roles. **All client changes analyze clean; functions
build clean.** One new Cloud Function needs a deploy (below).

**Phase 0 — shared widgets (new):**
- `lib/shared/widgets/guidance_empty_state.dart` — `GuidanceEmptyState` (icon +
  title + next-step line + optional **filled** action button). Replaces the
  duplicated per-screen `_EmptyState` classes (3 inspection screens + landlord
  issues) and two bespoke full-screen empties (my_rentals, agent properties tab).
- `lib/shared/widgets/what_happens_now_hint.dart` — `WhatHappensNowHint`
  (reusable info strip, color-tinted) for post-action "what happens now" copy.

**Phase 1 — attention tab badges (uses existing `TabBadge`):**
- **Upcoming/Scheduled** tab badges the count of **upcoming approved
  inspections** on tenant + landlord + agent screens (each mirrors its own
  tab filter: tenant/landlord = `isApproved`; agent = `isApproved` and not
  past). So a freshly-approved inspection lights the dot immediately — even if
  the user never taps the push — and it clears once nothing's upcoming. (Was
  briefly "today only"; widened on test feedback. The `isToday` model getter
  added for the first cut was removed once unused.)
- **Landlord Rentals → Active** tab badges **expiring-soon / grace-locked**
  leases (`_expiringCount`).

**Phase 2 — actionable empty states (button only where there's a real next step):**
- Tenant **My Rentals** + empty **Upcoming inspections** → "Browse Properties".
- Landlord **no properties** → "Add Property". Agent **not verified** →
  "Complete Verification"; agent **no assignments** → "Discover Properties"
  (switches to Discover tab). Passive states (history, tenant-initiated lists)
  left button-free by design.

**Phase 3 — "what happens now" hints:**
- Tenant inspection **pending card** (awaiting response / verifying / under
  review) now carries a persistent hint.
- **Report-issue form** shows what happens after submitting (notified →
  trackable → confirm step).

**Phase 4 — notifications: made the Cloud Function the single source.**
- Found that `activities` (landlord-only in-app feed, queried solely by field
  `landlordId`) and `notifications` (push + bell inbox, written by CFs) are
  **separate systems**. Many `activities` writes used a field `userId` that
  **nothing reads** → those events silently notified no one.
- **Issue domain:** removed the dead `tenantId` `activities` write in
  `landlord_issues._updateStatus` — `onIssueUpdated` already pushes the tenant.
- **GAP FIXED — agreement lifecycle + rental end.** New CF
  **`onActiveRentalUpdated`** (`functions/src/index.ts`, onDocumentUpdated
  `active_rentals/{rentalId}`) notifies the right party on: agreement
  → pending_review (tenant) / accepted (landlord) / disputed (landlord) /
  finalized (tenant); bare agreement-url attach (tenant); rental ended_by_tenant
  (landlord) / ended_by_landlord (tenant); tenant contests (landlord). Dedup IDs
  embed the doc's `updatedAt` revision so a real re-cycle (dispute → re-upload →
  dispute) re-notifies while trigger retries don't double-send. Deep-links:
  tenant → `/tenant/documents` or `/tenant/my-rentals`; landlord →
  `/landlord/agreements` or `/landlord/rentals`.
- Removed the **9 dead** `activities` writes in `active_rental_service.dart`
  (now covered by the CF).
- **DEPLOY:** `firebase deploy --only functions:onActiveRentalUpdated --project clearrent-app`
  + app rebuild (full restart — model getter + many screens changed).

**Multi-rental enabled (a tenant can now hold >1 active rental):**
- Removed the one-rental-per-tenant **accept guard** in
  `landlord_inspections_screen` (`_acceptRental`) — it fired *after* the tenant
  had already paid, so a paid application could be blocked at acceptance
  ("can't take their money then refuse"). A paid application now always becomes
  a real rental. Deleted the orphaned `ActiveRentalService.tenantHasActiveRental`.
- Profile **"Rentals" stat** now shows the real active-rental count
  (`_loadActiveRentalCount`, was hardcoded 1/0).
- My Rentals already lists **all** active rentals; the home dashboard still
  *features one* (via `streamTenantActiveRental` limit 1). The user-doc
  `hasActiveRental` / `currentRentalId` / `currentPropertyId` fields are written
  but **read by nothing**, so they were left as-is (dead) rather than reworked.
- **Follow-up (optional):** make the home dashboard feature a *default* among
  several + a switcher — needs bridging the `ActiveRental` dashboard to the
  existing `streamTenantRentals()`/`TenantRental` multi-type + `resolveDefaultRental`.

**Payments / earnings fixes:**
- **Tenant Documents → Payments was always empty.** The query was
  `payments.where(userId==me).orderBy(createdAt)` — that needs a composite
  index that isn't provisioned, so it threw and the `catch` silently returned
  `[]`. Switched to query-by-userId + client-side sort (the pattern the rest of
  the app already uses). `/landlord/documents` + `/agent/documents` reuse the
  SAME `DocumentsScreen`, so this fixes all three roles' payment lists.
- **Landlord Earnings was structurally broken** — it reads the `transactions`
  collection, which **nothing ever wrote** (the code even said
  `// Will come from payments later`). Built it the intended way (Option B):
  new CF **`onRentPaymentRecorded`** (`functions/src/index.ts`,
  onDocumentCreated `payments/{reference}`) — on a completed `type=='rent'`
  payment it writes a landlord `transactions` row (`landlordId`, amount =
  `landlordPayout`) and, when there's an agent, an agent row (`agentId` only,
  amount = `agentPayout`). Amounts are recomputed from the authoritative
  `rental_interests` doc, not the client-written payment fields. Deterministic
  IDs (`txn_{ref}_landlord` / `_agent`) via `.create()` keep it idempotent.
  `transactions` rules already allowed party reads + CF-only writes (this was
  the original design intent). **earnings_screen needs no change.**
  ⚠️ Forward-looking only — pre-existing payments won't appear without a
  one-off backfill. No agent UI reads the agent row yet (rules allow it).
- **DEPLOY (new CFs):**
  `firebase deploy --only functions:onActiveRentalUpdated,functions:onRentPaymentRecorded --project clearrent-app`

**Inspection / rent test-feedback fixes (functions — need deploy):**
- **Tenant inspection History tab now badges** completed-but-unrated inspections
  (the "go rate it" nudge) — client-only, alongside the existing Pending +
  Upcoming badges and the `inspection_completed` push.
- **"Tenant Confirmed Meeting" wording fixed** (`onInspectionRequestUpdated`).
  On `met`, both agent + landlord got "{tenant} confirms meeting **you**" — wrong
  for the landlord on an agent-handled inspection (they weren't there). Now the
  party who met (agent, or landlord if self-handled) gets the
  "complete the inspection" prompt; the landlord on an agent-handled inspection
  gets an accurate FYI ("{tenant} has met {agent} …").
- **GAP FIXED — landlord wasn't told when a tenant pays to rent.** New CF
  **`onRentalInterestPaid`** (`rental_interests/{id}`, on → `payment_verified`)
  pushes the landlord ("{tenant} paid to rent {property} — review & accept",
  deep-link `/landlord/inspections` History tab) **and** writes a Recent-
  Activities row (type `payment`). Idempotent IDs. Before this, a paid applicant
  produced no push and nothing in Recent Activities — the landlord only found it
  by digging into Inspections → History.
- **GAP FIXED — winning tenant wasn't told they were accepted.**
  `onRentalInterestAccepted` only notified the *losing* applicants; the accepted
  tenant got nothing (acceptance was a silent surprise). Added a winner push at
  the top of that CF: "You got the place! 🎉 … review your tenancy agreement,"
  deep-link `/tenant/my-rentals`. Idempotent key.
- **DEPLOY (all current new/changed CFs):**
  `firebase deploy --only functions:onActiveRentalUpdated,functions:onRentPaymentRecorded,functions:onRentalInterestPaid,functions:onInspectionRequestUpdated,functions:onRentalInterestAccepted --project clearrent-app`

**Follow-ups — DONE this session:**
- Fixed the issue-confirm `activities` write at `tenant_rental_dashboard.dart`
  (`_confirm`): was `userId: landlordId` (dead — the feed only queries
  `landlordId`), so the landlord's "Fix Confirmed" never appeared in Recent
  Activities while "Fix Disputed" did. Corrected to `landlordId` + type
  `issue_confirmed` + actor fields, matching tenant_home's confirm and the
  dispute sibling. (Push itself is still sent by `onIssueUpdated`.)
- Consolidated the passive empty states onto `GuidanceEmptyState` (button-free):
  notifications inbox, tenant Documents (agreements + payments tabs), landlord
  Agreements, chat messages list, in-conversation chat empty. Removed each
  screen's bespoke `_buildEmptyState`.

**Empty-state consolidation — now complete.** Also migrated recent_activities
(passive), select_agent (keeps its "I'll Handle Inspections" action) and
agent_selection (keeps its conditional "Show all agents" filter reset) onto
`GuidanceEmptyState`. **earnings_screen left as-is on purpose** — its empty
state is an inline bordered card (not a full-screen Center) with an extra
"Add your bank details to receive payouts" tip box; `GuidanceEmptyState` would
break that layout and drop the tip. Every full-screen empty state in the app
now uses the shared widget.

**Client-only UI / bug fixes this session (just need an app rebuild):**
- **Inspection Upcoming/Scheduled badge** now counts **upcoming approved**
  inspections (was "today only") so the dot lights the moment one's approved,
  push or not; mirrors each tab's filter. (Removed the now-unused
  `InspectionRequest.isToday`.)
- **`TabBadge` overflow fix** — long labels ("In Progress") + the count pill
  overflowed narrow tabs; the label is now `Flexible` + ellipsis.
- **Report-issue** title + description fields use
  `TextCapitalization.sentences`.
- **Phone field strict** (`login_screen`, both sign-in + sign-up tabs):
  `digitsOnly` + `maxLength: 11` so no wrong-length / non-digit numbers.
- **Removed the "My Rental" heading** under "Welcome home, {name}" on the tenant
  rental dashboard.
- **Notification deep-link crash fixed** — route builders cast
  `initialTab as int?`, but notification payloads deliver it as a **String**
  (`"2"`); added `_initialTab()` coercion in `routes.dart` (4 inspection routes).
- **Issue-details header overflow fixed** (`tenant_issue_history_screen`) — the
  status chip now ellipsizes within a bounded row on narrow screens.

**⚠️ Phone OTP on real numbers — diagnosed, NOT a code bug.** Root cause chain
(see the long debug logs): a **sideloaded debug build can't pass Play Integrity**
(`SmsRetrieverHelper … 18002 Invalid PlayIntegrity token; app not Recognized by
Play Store`), so Firebase falls back to reCAPTCHA, which is also unconfigured
(`No Recaptcha Enterprise siteKey`). Config that WAS wrong and is now fixed by
the user: SHA-1/256 (debug+release) added under `com.verealtytech.clearrent`;
**SMS region policy switched from Deny → Allow (Nigeria)**; on Blaze. **To test
real-number OTP you must use a Play *internal-testing* build** (Play Integrity
only trusts Play-installed apps) — debug sideload will always fall to the broken
reCAPTCHA path. Test numbers bypass all of this. App Check uses
`AndroidProvider.debug`; register the debug token
(`ca400409-05c5-430d-9bfa-a752d2fdcd38`) in Firebase → App Check to silence the
403s (separate from OTP; App Check is unenforced so it doesn't block).

---

## Current state (what's LIVE)

Everything below is deployed and runtime-tested **except where marked**. Deploy
commands + remaining follow-ups are at the bottom.

### Rent-review feature — LIVE & tested
- **Filing** (`request_rent_change_screen.dart`): occupied → scheduled (staged to the
  sitting tenant's renewal); vacant → immediate. Mandatory revised agreement on a
  scheduled review. Auto-staged effective date with a ≥6-month notice guard.
- **CFs** (`rent_review_ops.ts`):                  `approveRentReview` (stages `pendingRentForRenewal`
  on the active_rental **or** tenancy_link; bumps `property.rent`; pushes the revised
  agreement), `rejectRentReview`, `approveImmediateRentChange` (vacant; re-checks
  occupancy).
- **Notifications on a decision:**
  - **Tenant** is notified on **approval only** (never on rejection — nothing changed on
    their tenancy). Deep-links to `/tenant/home` for a **linked** tenant, `/tenant/my-rentals`
    for an active-rental tenant.
  - **Landlord** is notified on **every outcome** — approve (scheduled *and* immediate) and
    reject (with the admin's reason). Deep-links (updated 2026-06-19): scheduled-approve +
    reject → `/landlord/rentals`; vacant/immediate-approve → `/landlord/property/{propertyId}`
    (that unit's detail). See the 2026-06-19 session section below.
- **Renewal** (`renewal_ops.ts`): `completeLinkedPromotion` applies the staged rent +
  carries the agreement into the promoted rental.
- **Admin** (`clearrent_admin` → `dashboard/rent-reviews`): pending list, approve/reject,
  live fairness panel (issues/maintenance + health score).

### Notifications inbox — LIVE & tested
- `notifications_screen.dart`: tapping an item opens a **detail sheet** (full untruncated
  body + timestamp) with a **deep-link button** when the notification carries
  `payload.route` (e.g. "Go to My Rentals" / "Go to My Tenancy"). Passes the whole
  payload as go_router `extra` so param-routes like `/chat` get their `conversationId`.
- Push pipeline already existed: `notifications/{id}` onCreate trigger → FCM
  (`index.ts`). The inbox doc is written immediately on approval (no 6-month delay).

### Notification bell — LIVE & tested
- **Bell** on the linked dashboard (`tenant_home_screen.dart`) **and** the active-rental
  dashboard (`tenant_rental_dashboard.dart`). All roles' home screens have it.

### Linked-tenant surfaces — LIVE & tested
- **Revised-agreement card** on both linked-home variants + a "View Revised Agreement"
  button in the linked lease-details sheet (reads `link.agreementUrl`).
- **My Rentals** (`my_rentals_screen.dart`) shows a linked-tenancy card (via
  `getTenantActiveLink()`) instead of an empty browse state.
- **Documents** (`documents_screen.dart`) surfaces the link's agreement in the
  Agreements tab.
- **Rent-due card fix** (`linked_rent_due_card.dart`): shows `link.rentAmount` (the
  tenant's protected rent), **not** `property.rent` — fixes the old flicker where a
  rent-review bump made the amount jump between old/new values. (The active-rental
  dashboard already reads `rental.rentAmount` and never fetched `property.rent`, so it
  was never affected — confirmed.)

### Account deletion — DEPLOYED, **NOT runtime-tested yet**
- `deleteMyAccount` CF (`account_ops.ts`): admin SDK deletes all the user's Firestore
  data + conversations/messages (`recursiveDelete`) + the auth account + the
  `verification/{uid}/` Storage prefix. No re-auth needed.
- Client (`auth_service.deleteAccount`) now just calls the CF then signs out. The old
  email/password re-auth dialog was removed (it silently failed for phone-OTP users —
  the original bug). **Cloudinary images ARE now purged** (2026-06-19) — see the session
  section below.

### Building-group feature (Steps 1–4) — COMPLETE & tested
One building/compound groups multiple unit listings of the same owner; **one C of O is
verified once and covers every unit**. Each unit stays its own `PropertyModel` (own rent,
own tenant, own tenancy agreement — Model A).
- **Step 1**: `BuildingModel`, `PropertyModel.buildingId`, `building_service.dart`,
  `buildings` rules.
- **Step 2** (`add_property_screen.dart`): "Property Grouping" choice — Standalone vs In a
  building (create new: name + address + C of O · or join existing via
  `streamLandlordBuildings`). Grouped units **skip** the per-property doc and store
  `buildingId`; `ownershipDocStatus = 'inherited'`. Building address **prefills** from the
  unit address. `createProperty` gained a `buildingId` param.
  **Security guard** (`firestore.rules`): `buildingOwnedByCaller()` — a property's
  `buildingId` must belong to the same landlord (closes borrowing another owner's verified
  C of O). On property create + owner-update.
- **Step 3** (`property_detail_screen.dart`): `_effectiveDocStatus` = building's status when
  grouped, else property's — drives the inspection gate + doc banners.
- **Step 4** (admin `properties/page.tsx`): subscribes to `buildings`, resolves a grouped
  unit's doc from its building, **verify/reject targets the building** (covers all units),
  plus a per-unit "Publish this unit" action once the building doc is verified.
- **Rules tests** (`firestore-tests/`): 27 passing (incl. 4 cross-owner guard tests). Run:
  `npx -y firebase-tools@latest emulators:exec --only firestore --project demo-clearrent "npm --prefix firestore-tests test"`

### C of O moved to private storage — DEPLOYED PENDING (built, needs deploy + test)
- Ownership docs (C of O / deed) now upload to **private Firebase Storage**
  (`ownership/{uid}/…`) via `PropertyService.uploadOwnershipDoc`, **not Cloudinary** —
  it's title-level PII. `ownershipDocUrl` now holds a storage **path**, not a public URL.
  Used by both `add_property_screen` and `edit_property_screen`.
- `storage.rules`: new `ownership/{uid}` match (owner write, owner+admin read) mirroring
  `verification/`.
- Admin (`properties/page.tsx`) streams the doc through the authenticated
  `/api/verification-image` route (broadened to allow `ownership/` paths) — no public
  URL. Legacy Cloudinary docs (http URLs) still open directly for back-compat.
- `deleteMyAccount` now also purges `ownership/{uid}/`.
- **Deploy:** `firebase deploy --only storage,functions:deleteMyAccount` + app rebuild +
  admin deploy. (Existing test docs remain Cloudinary http URLs — handled gracefully.)

### Agreements moved to private storage — BUILT, needs deploy + test
- Tenancy agreements now upload to **private Firebase Storage** (`agreements/{landlordId}/…`)
  via `PropertyService.uploadAgreementDoc`, not Cloudinary. Wired at all 3 upload sites
  (request_rent_change, landlord_agreements, landlord_inspections). `agreementUrl` /
  `revisedAgreementUrl` now hold a storage **path**.
- **Multi-party read** is the wrinkle: a tenant must read their own agreement, but storage
  rules can't check rental membership (rules can't read Firestore). So:
  `storage.rules` adds `agreements/{uid}` (owner write, owner+admin read), and a new CF
  **`getSignedAgreementUrl`** (`doc_access_ops.ts`) authorizes the caller as a party to the
  `active_rentals`/`tenancy_links` doc, then returns a 15-min **signed URL** (passes legacy
  Cloudinary http URLs through unchanged).
- App reads go through `AgreementAccessService.resolveUrl(collection, docId)` → the CF.
  Updated read sites: tenant_home, my_rentals, documents (rental + linked, view/share),
  lease_details, landlord_agreements.
- Admin reads the revised agreement via the authenticated `/api/verification-image` route
  (broadened to allow `ownership/` + `agreements/`) — rent-reviews page streams it.
- `deleteMyAccount` now purges `verification/` + `ownership/` + `agreements/` by `{uid}`.
- **Deploy:** `firebase deploy --only storage,functions:getSignedAgreementUrl,functions:deleteMyAccount`
  + app rebuild + admin deploy.
  ✅ **RESOLVED 2026-06-19** — `getSignedUrl` was failing with
  `SigningError: Permission 'iam.serviceAccounts.signBlob' denied`. Granted
  `roles/iam.serviceAccountTokenCreator` to the runtime SA
  (`513996752248-compute@developer.gserviceaccount.com`). Server-side only, no redeploy.
  "View Agreement" now signs. (App Check `INVALID` warnings in logs are harmless —
  enforcement is disabled, the call proceeds.)

### Other (LIVE, earlier this work)
- **Model A**: one unit = one listing = one rent; `maxTenants` fixed at 1 (multi-tenant
  plumbing left inert, not deleted).
- Rules: `active_rentals` + `tenancy_links` updates are allowlists; F1.13 tenancy_links
  queries scoped by `landlordId`.

---

## Deploy

```bash
# app repo (c:\Users\MIDE\clearrent) — full deploy covering everything below
firebase deploy --only storage,firestore:rules,functions:approveRentReview,functions:rejectRentReview,functions:approveImmediateRentChange,functions:completeLinkedPromotion,functions:deleteMyAccount,functions:getSignedAgreementUrl
flutter run            # rebuild / reinstall the app (full restart, not hot reload)

# admin repo (c:\Users\MIDE\clearrent_admin) — Vercel
cd ..\clearrent_admin && vercel --prod      # or: git push origin <vercel production branch>
```

✅ **`getSignedUrl` (agreements) IAM is now granted** (2026-06-19) — the runtime SA has
`roles/iam.serviceAccountTokenCreator`, so signing works. If signing ever regresses, the
fix is to re-grant that role to `513996752248-compute@developer.gserviceaccount.com`.

---

## Session 2026-06-19 — fixes (functions DEPLOYED; app NOT rebuilt yet)

Functions deployed today: `approveRentReview`, `rejectRentReview`,
`approveImmediateRentChange`. IAM grant applied. **The Flutter changes below need an app
rebuild (hot RESTART — routes changed) and are not yet runtime-tested.**

1. **Agreement signing — FIXED (server-side).** Granted
   `roles/iam.serviceAccountTokenCreator` to the runtime SA; "View Agreement" now signs.
   (See the resolved ⚠️ in the Agreements section. No redeploy needed.)
2. **Landlord rent-review notification routing — changed + deployed.** Was `/landlord/home`
   for every outcome (a poor target: unhelpful, and it self-suppressed the foreground push
   banner since home is the default screen). Now:
   - scheduled-approve + reject → `/landlord/rentals`
   - vacant/immediate-approve → `/landlord/property/{propertyId}` (the unit's detail)
   Removed the now-unused `LANDLORD_HOME_ROUTE` constant (`rent_review_ops.ts`).
   ⚠️ Existing notifications keep the route baked in at creation — only **new** decisions
   carry the new routes.
3. **New client route `/landlord/property/:id`** (`routes.dart`) →
   `PropertyDetailLoaderScreen` (new file in `features/property/.../screens/`) which loads
   the property via `PropertyService.getProperty(id)` then shows `PropertyDetailScreen`.
   (Notifications only carry an id, not the full `PropertyModel`.)
4. **Landlord My Rentals — scheduled rent-change banner** (`landlord_rentals_screen.dart`
   `_RentalCard`). Shows on any rental with `pendingRentForRenewal`:
   "New rent ₦X applies when this tenant renews (`leaseEndDate`)". **Uses `leaseEndDate`,
   NOT `pendingRentEffectiveDate`** — the latter is the filing-time marker (≈ now) and was
   misleading as a display date. The current rent stays protected until renewal; the
   property's asking rent is already bumped for new/future tenants.
5. **Notification CTA labels** (`notifications_screen.dart` `_actionLabel`): added
   "View Property" and "Go to My Rentals".
6. **Add-property draft now persists building selection** (`add_property_screen.dart`) —
   `_collectFormState` + `_restoreDraft` cover `isInBuilding` / `creatingNewBuilding` /
   `selectedBuildingId` / building name + address. (Was follow-up "draft resets grouping".)
7. **`CLAUDE.md`** added at repo root — behavioral guidelines (think-before-coding,
   simplicity, surgical changes, goal-driven). Auto-loaded each session.
8. **Cloudinary cleanup on delete — DONE + DEPLOYED.** `deleteMyAccount` (`account_ops.ts`)
   now purges the user's Cloudinary media by prefix: `clearrent/properties/{uid}/` (images
   + videos) and `clearrent/profiles/{uid}/` (profile photos). Creds in Secret Manager
   (`CLOUDINARY_API_KEY` / `CLOUDINARY_API_SECRET`, set 2026-06-19; cloud `den5t1dai` is a
   constant); `cloudinary` dep added to functions. Verified the stored creds with an API
   `ping` (status ok). The runtime SA was auto-granted `secretAccessor` on both secrets at
   deploy. (Sensitive *docs* were already on private Storage + purged; this closes the
   non-sensitive image gap. Chat/issue-report images use other folders, still not purged.)
9. **Model A UI polish — DONE (needs app rebuild).** `property_detail_screen.dart`:
   removed the owner "Tenants" card's `N/N occupied` pill + capacity bar; replaced the
   tenant card's "Max occupants" + "spots left" rows with a single "Availability:
   Available/Occupied" row.
10. **First test building empty address — FIXED (data).** "Ade Compound"
    (`buildings/l1Ds1gUN1VJU6W7sZ3AB`) had `address: ""`; set to `"Ajegunle"` (matches its
    units). Firestore only, no deploy.
11. **Agent self/agent selection wasn't persisting — FIXED.** Root cause: after assigning
    an agent, `select_agent_screen.dart`'s success dialog did `context.go('/landlord/home')`
    — discarding the edit screen before its Save ran — and `assignAgent` never set
    `inspectionHandler`. So the handler read back as 'self'. Now: `PropertyService.assignAgent`
    also sets `inspectionHandler: 'agent'` (data stays consistent), and the dialog returns
    `context.pop(true)` to the edit screen instead of jumping home.
12. **Agent-assignment notification — NEW CF, DEPLOYED.** `onPropertyAgentAssigned`
    (`index.ts`, onDocumentUpdated `properties/{id}`) fires when `assignedAgentId` changes to
    a new agent → notifies the agent ("…handling inspections for X. Reach out to the
    landlord, visit, get it photo-/viewing-ready."), deep-link `/agent/property/{id}`. Dedup
    key `property_{id}_agent_{agentId}` (re-assigning the *same* agent after removal won't
    re-notify — minor). The broader staging workflow (agent marks "ready", status tracking)
    is NOT built — notification only.
13. **Ownership-doc re-verification on edit — FIXED.** `edit_property_screen.dart`: when a
    NEW ownership doc is uploaded (standalone units), it now sets `ownershipDocStatus:
    'pending'` **and** `isAvailable: false`, so a swapped C of O goes back through admin
    review instead of silently keeping 'verified'. (Note: properties rules don't restrict
    `ownershipDocStatus` like buildings do — a hardening candidate, see below.)
14. **Admin "Attention Needed" banner now on every screen.** Extracted to
    `components/layout/attention-banner.tsx` and mounted in `dashboard-shell.tsx` (was only
    on `dashboard/page.tsx`). Counts pending property docs + verifications + payments +
    issues. Surfaces the re-uploaded docs from #13. **Admin repo — needs a Vercel deploy.**
15. **Profile tab title removed** — the "Profile" header text dropped from all three role
    profile tabs (`landlord/tenant/agent_home_screen.dart`); the settings gear stays
    right-aligned. Bottom-nav "Profile" labels untouched.

**Functions deployed 2026-06-19 (all):** `approveRentReview`, `rejectRentReview`,
`approveImmediateRentChange`, `deleteMyAccount`, `onPropertyAgentAssigned`. Plus IAM grant
+ 2 Cloudinary secrets.

**Admin (clearrent_admin) needs a Vercel deploy** for the shell banner (#14).

**Still to test (need the app rebuild):** occupied-renewal banner shows correct date;
fresh vacant rent change → notification lands on the property detail + push banner appears;
draft restore keeps the building selection; Model A cards no longer show capacity framing;
delete-account also clears the Cloudinary `clearrent/properties|profiles/{uid}/` media;
**agent assign persists as 'agent' + the agent gets a notification; re-uploading a C of O
sends the property back to pending + delists it + shows in the admin banner on any screen;
profile tabs have no "Profile" title.**

---

## Session 2026-06-19 (round 2) — test-feedback fixes

Three client-only bug fixes (rebuild) + four decided features (functions DEPLOYED, app
needs rebuild). Policy decisions captured inline.

**Bug fixes (client-only, no deploy):**
1. **Agent "History" shortcut** (`agent_home_screen.dart`) was opening the Scheduled tab
   (`initialTab: 1`) → now Completed (`initialTab: 2`).
2. **Notification deep-link back button dead** — the in-app inbox used `context.go`
   (replaces stack). Now `context.push` (`notifications_screen.dart`) so Back works. (FCM
   tap path already pushed.)
3. **Property deletion blocked when occupied** — `PropertyService.propertyHasSittingTenant`
   (occupying active_rental OR confirmed link); `deleteProperty` refuses, and both delete
   sites (`landlord_home_screen`, `property_detail_screen`) pre-check with a clear message.
   ⚠️ Client/service guard only — strict server enforcement would need a delete CF (Firestore
   rules can't query related docs).

**Decided features:**
4. **Vacant rent = direct edit** (Q3). "Request Rent Change" is now gated to **occupied**
   units only (`property_detail_screen._hasSittingTenant`); vacant units edit rent directly
   on Edit Property (applies immediately, no admin). The `approveImmediateRentChange` CF is
   left in place but no longer reachable from the UI for vacant.
5. **Account-deletion safety** (Q1) — **DEPLOYED.** `deleteMyAccount` (`account_ops.ts`) now
   **blocks** deletion (HttpsError `failed-precondition`) for ANY role if: party to an
   occupying active_rental / confirmed tenancy_link (landlord or tenant), OR has an in-flight
   inspection (tenant/agent/landlord; statuses pending/pendingVerification/pendingPayment/
   approved). Guards fetch by single-field equality + filter in code (no composite index).
6. **Agent cascade on deletion** (Q2) — **DEPLOYED.** If an agent passes the guards (no
   in-flight inspection), `deleteMyAccount` reverts every property they're assigned to →
   landlord-handled, **preserves the agent fee** in `savedAgentFee` (zeros live `agentFee`
   so the tenant isn't charged with no agent — rent-payment treats `agentFee>0` as "has
   agent"), notifies each landlord. Shared helper `revertPropertyToSelf` in new
   `agent_property_ops.ts`.
7. **Agent self-unassign** (Q4) — **DEPLOYED.** New CF `agentUnassignFromProperty(propertyId,
   reason)` (`agent_property_ops.ts`): verifies caller is the assigned agent, **blocks** if
   an in-flight inspection on that property, else `revertPropertyToSelf` (+ landlord
   notification with the reason). UI: "Step back from this property" in the
   `agent_property_detail_screen` app-bar overflow → reason sheet →
   `PropertyService.agentUnassignFromProperty`. Must be a CF because the agent isn't the
   property owner (rules block direct writes).
8. **Agent fee preserved on re-assign** — `PropertyService.assignAgent` now restores
   `agentFee` from `savedAgentFee` (and clears it) when a landlord assigns a new agent, so
   the fee never has to be re-entered after an agent left.

**Functions deployed (round 2):** `deleteMyAccount` (updated), `agentUnassignFromProperty`
(new). **App needs a rebuild** for items 1–4, 7-UI, 8.

**Still to test (round 2):** agent History → Completed; notification Back works; can't delete
an occupied property; vacant unit has no "Request Rent Change" (edit rent on Edit Property);
account deletion blocked with active tenancy/inspection; agent self-unassign (with reason)
reverts to landlord + notifies + blocked mid-inspection; re-assigning an agent restores the
saved fee.

**Round 2 follow-ups (client-only, no deploy — rebuild):**
- **Delete-account error now surfaces the server reason** (`auth_service.deleteAccount` returns
  `e.message` instead of a generic string), so the active-tenancy/inspection block message is
  shown. The guard runs server-side BEFORE any deletion — a confirmed linked tenant ⇒ nothing
  deleted. Block now covers **pending AND confirmed** links (decided 2026-06-19, deployed) —
  any open link must be cancelled/declined first. (Property-delete guard still blocks only on
  confirmed links + occupying rentals — open question whether to extend pending there too.)
- **Linked-tenant lease term auto-derives from the rent due date** (the "Configure Rent" sheet
  in `property_detail_screen`): removed the separate lease-start date picker; `_leaseStart` is
  now a getter = most recent past occurrence of the due month/day, `_leaseEnd` = +1yr, shown
  read-only. Fixes lease dates that could contradict the rent due date.

---

## Session 2026-06-19 (round 3) — inspection lifecycle + misc

**Misc fixes (client-only, rebuild):**
- **Tab count badges — `TabWithDot` → `TabBadge`** (renamed file `tab_badge.dart`, deleted
  `tab_with_dot.dart`). Now count-aware: 0 → nothing, 1 → dot, 2+ → numbered pill (99+ cap).
  Migrated the 3 inspection screens' Pending tab (bool → `count: list.length`). **Landlord
  Issues**: Open + In Progress tabs now show live count badges (the landlord-actionable
  ones; Pending/Resolved intentionally unbadged), driven by a live `issues` subscription
  (`landlord_issues_screen._listenIssues`) that also powers the initial-tab pick. This is the
  discoverability fix — the once-off tab slide was easy to miss; the badge persists.
- **"My Rentals" title removed** (`my_rentals_screen.dart`) — kept the AppBar/back button,
  dropped the title text (reclaims space). Same idea as the earlier Profile-title removal.
- **Landlord Issues — tabs follow the action.** `landlord_issues_screen.dart`: changing an
  issue's status now `animateTo`s the destination tab (Open→In Progress→Pending→Resolved) via
  an `onMoved` callback threaded parent→`_IssuesTab`→`_IssueCard`; and on open (when no
  explicit tab requested) it selects the tab of the most recently-updated issue
  (`_selectLatestTab`, fetches by landlordId + sorts in code — no composite index).
  TENANT side is a read-only progress **stepper** (`tenant_issue_history_screen.dart`, no
  tabs / no status action there), so it already shows the stage inline — nothing to switch.
- **Linked-tenant lease term auto-derives from the rent due date** (Configure Rent sheet) —
  removed the separate lease-start picker; `_leaseStart` = most recent past occurrence of the
  due month/day, `_leaseEnd` = +1yr, read-only.
- **Delete-account error surfaces the server reason** (`auth_service`).
- **Account-deletion block now covers pending AND confirmed links** (`account_ops.ts`,
  redeployed).
- **"Request Rent Change" gated to occupied** units (vacant edits rent on Edit Property).

**Inspection lifecycle (Phases 1–3) — CODE DONE; deploy `firestore:rules` +
`functions:inspectionLifecycleSweep`; app rebuild needed.** Policy decided with user:
- **Phase 1:** `InspectionService.approveRequest` refuses a request whose date is a prior day
  (compare by day; same-day OK).
- **New statuses** (`inspection_request_model.dart`): `expiredUnapproved`, `awaitingOutcome`
  (+ display + getters). Firestore stores the enum `.name`.
- **`inspectionLifecycleSweep`** (`inspection_lifecycle_ops.ts`, onSchedule daily 02:00
  Africa/Lagos): prior-day non-terminal requests →
  `pendingPayment`→`cancelled`; `pending`/`pendingVerification`→`expiredUnapproved` + notify
  tenant; `approved` (not done) → arrival-flag resolution: `met`→`completed`; tenant-arrived
  only → **refund** (paymentStatus='refunded' → existing `onInspectionRefundTriggered` →
  refund record); handler-arrived only → `completed` (+`tenantNoShow`); neither → `awaitingOutcome`.
- **Tenant UI** (`tenant_inspections_screen.dart`): `expiredUnapproved` shows in Requests tab
  with Reschedule (reuses `ReschedulePropoSheet` → `rescheduleExpiredInspection`, payment kept)
  / Get Refund (`refundExpiredInspection`). `awaitingOutcome` shows in History.
- **Rules** (`firestore.rules` rows 25–26): tenant may move `expiredUnapproved`→`pending`
  (reschedule, field-scoped) or →`refunded` (refund, field-scoped).
- **Notifications**: confirmed the existing `onNotificationCreated` FCM trigger already pushes
  AND forwards `payload.route` as data, so every `writeNotificationOnce` auto-pushes +
  deep-links. No per-notification push code needed.
- **Issue loop — fully closed (notifications + tenant confirm/dispute).**
  - **`onIssueCreated`** (`index.ts`): new issue → landlord push + deep-link `/landlord/issues`.
  - **`onIssueUpdated`** (`index.ts`, onDocumentUpdated `issues/{id}`): pushes the right party
    on every status change — landlord acknowledges/marks-fixed → tenant push; tenant
    confirms/disputes → landlord push. Deep-links tenant→`/tenant/issue-history`,
    landlord→`/landlord/issues`. Dedup key includes from+to+recipient.
  - **Tenant confirm/dispute UI** (`tenant_issue_history_screen.dart`): the issue **detail**
    now threads `issueId` (group→tile→detail) and, on `pending_confirmation`, shows
    `_ConfirmFixButtons` — **Yes, fixed** (→ resolved) / **Not fixed** (→ in_progress with a
    `tenantDisputeReason`). Rules already allow the tenant to update their own issue.
  - Issue reporting itself already worked (rules allow create). **Deploy
    `functions:onIssueCreated,onIssueUpdated`.**
- **Phase 3 admin — BUILT (needs Vercel deploy).** New admin page
  `clearrent_admin/src/app/dashboard/inspection-reviews/page.tsx` subscribes to
  `inspection_requests` where `status=='awaitingOutcome'`, shows tenant/handler + arrival
  flags + fee, and resolves each: **Refund tenant** (status/paymentStatus→refunded, reason →
  existing refund trigger) or **Mark completed** (fee stands). Added to the sidebar nav
  (`dashboard-shell.tsx`) and the "Attention Needed" banner (`attention-banner.tsx`,
  counts awaitingOutcome). Admin writes allowed by the existing `isAdmin()` inspection rule.

---

## Remaining follow-ups / flags
- **Test the 2026-06-19 app changes** — see the list directly above (needs a hot restart).
- **Test the earlier private-storage batch** — C of O + agreements now upload to private
  Storage and signing works (IAM granted). Confirm: uploads land in private Storage,
  tenant/admin can view, rent-review notifies both parties, active rent doesn't flicker.
- **Delete-account runtime test** — never run end-to-end. Throwaway phone-OTP account;
  confirm Firestore data + auth user + Storage (`verification/`+`ownership/`+`agreements/`)
  **and** Cloudinary (`clearrent/properties|profiles/{uid}/`) all gone.
- **Cloudinary chat / issue-report images — INVESTIGATED, NOT a gap (closed 2026-06-19).**
  Issue-report images upload via `PropertyService.uploadImage` → `clearrent/properties/{uid}`,
  which `deleteMyAccount` already purges. Chat has an inert `imageUrl` field but **no image
  upload UI exists**, so there's nothing to clean up. No code needed.
- **Rules hardening (properties.ownershipDocStatus) — DONE 2026-06-19 + DEPLOYED.** The
  `properties` owner-update rule now denies the owner setting `ownershipDocStatus` to
  `'verified'`/`'rejected'` (admin-only); `'pending'`/`'not_uploaded'`/`'inherited'` still
  allowed so add-property + re-upload keep working. Rules tests now 29 passing (added
  owner-self-verify-denied + owner-re-upload-allowed). `firestore.rules` deployed.
- **Dead code left intentionally**: multi-tenancy plumbing inert under `maxTenants = 1`;
  monthly rent is a v2 item (leases hardcode +1 year).
