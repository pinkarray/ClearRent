# ClearRent — Pre-Release Top-to-Bottom Test Plan

Run each item and tick it off. Note the **ID** of anything that fails + what you
saw. Split by how many phones each part needs.

**App Check note (M4):** these steps need a valid App Check token — on a
`flutter run` (debug) build register the token the app prints once (Firebase
console → App Check → Manage debug tokens), or test them on the **Play build**:
NIN submit, any payment, account deletion, agreement view, agent-unassign.

**Watch everywhere:** no "permission denied" / red error screens (the tightened
Firestore list rules from the audit).

---

## PART A — Single phone (your number) + admin web in a browser

Drive one account (suggest **Landlord**) + do admin steps in the dashboard.

### A1 — Auth & onboarding
- [ ] A1.1 Phone OTP sign-in on your real number → lands in app
- [ ] A1.2 Email verification flow
- [ ] A1.3 Profile setup (landlord) saves; resume-after-restart (profile draft) works
- [ ] A1.4 NIN submit *(App Check)* → no error; admin sees it pending

### A2 — Bank details (C1 — security)
- [ ] A2.1 Save bank details → success
- [ ] A2.2 Reopen the bank form → it prefills (reads the locked subcollection)
- [ ] A2.3 Home "set up your bank" nudge disappears after saving (`hasBankDetails` flag)

### A3 — Landlord: property & docs
- [ ] A3.1 Add property + upload images (Cloudinary) → appears in your list
- [ ] A3.2 Upload ownership / C-of-O doc (building) → status pending
- [ ] A3.3 Edit property (rent/details) saves
- [ ] A3.4 Property Health opens: issues tab + maintenance log loads with NO error (H1-rest + new index)
- [ ] A3.5 Add a maintenance log entry → it persists

### A4 — Browsing & images (the caching fix)
- [ ] A4.1 Properties list → open a property → go back → images DON'T reload (instant)
- [ ] A4.2 Property detail: gallery swipes, occupancy card shows, no spinner on revisit
- [ ] A4.3 Save / unsave a property

### A5 — Inspection request + payment (tenant-side, solo up to payment)
- [ ] A5.1 Request an inspection on a property → fee shown
- [ ] A5.2 Pay inspection fee *(App Check / Paystack)* → records; Documents → Payments shows it

### A6 — Notifications & account
- [ ] A6.1 Receive a push (e.g. after an admin action) + in-app bell
- [ ] A6.2 Settings, edit profile work
- [ ] A6.3 Delete account *(App Check)* on a throwaway account → removes cleanly

### A7 — Admin web (browser) — pairs with the above
- [ ] A7.1 Sign in to dashboard as admin; a non-admin is redirected away from `/dashboard`
- [ ] A7.2 Verify the landlord / approve NIN & ownership doc → app reflects "verified"
- [ ] A7.3 Payouts / Rent-payouts / Refunds pages show bank details (C1 read from locked subcollection)
- [ ] A7.4 View a verification image (secure API route)

### A8 — Web headers (optional, 1 min)
- [ ] A8.1 Devtools on privacy/terms site → Response Headers show `Strict-Transport-Security`, `X-Frame-Options: DENY`, CSP

---

## PART B — Two phones (Monday: Phone 1 = Account 1, Phone 2 = driver's number = Account 2)

Suggested: **Phone 1 = Landlord**, **Phone 2 = Tenant**, you = Admin in browser.
Bring in **Agent** by re-using Phone 2 or a third account where noted.

### B1 — Second-number OTP
- [ ] B1.1 OTP sign-in works on the driver's real number

### B2 — Chat (M3 — security)
- [ ] B2.1 Tenant → Landlord chat: messages deliver both ways in real time
- [ ] B2.2 Agent-initiated chat (agent → tenant/landlord) works, NO permission error (the M3 case — important)
- [ ] B2.3 Reopen an existing conversation → no duplicate created

### B3 — Inspection coordination (full lifecycle)
- [ ] B3.1 Tenant requests + pays inspection (Phone 2) → Landlord gets push (Phone 1)
- [ ] B3.2 Landlord approves → tenant notified
- [ ] B3.3 "On the way" / "Arrived" from both sides → the "met" handshake completes
- [ ] B3.4 Handler marks complete → tenant prompted to rate → rating saves

### B4 — Reschedule
- [ ] B4.1 One side proposes reschedule → other approves / counters / declines
- [ ] B4.2 On decline → refund triggered and visible to the tenant

### B5 — Agent flows
- [ ] B5.1 Landlord assigns an agent to a property → agent sees it
- [ ] B5.2 Agent pitch conversation to a landlord
- [ ] B5.3 Agent-handled inspection (agent is the handler in B3)
- [ ] B5.4 Agent unassign *(App Check)*

### B6 — Rent loop (the money path)
- [ ] B6.1 Tenant expresses interest → pays rent *(App Check)* → Landlord gets "review & accept" push
- [ ] B6.2 Landlord accepts the winning tenant → tenant gets "you got the place"
- [ ] B6.3 Losing applicants → refund appears in their Documents + admin Refunds queue
- [ ] B6.4 Admin marks refund/payout Paid → beneficiary sees "Paid" + gets push
- [ ] B6.5 Landlord Earnings populates after the rent payment

### B7 — Lease management
- [ ] B7.1 Agreement upload (landlord) → tenant notified, can view *(App Check signed URL)*
- [ ] B7.2 Rent review / change request (landlord) → admin approves/rejects → reflected
- [ ] B7.3 Renewal / move-out / contest flow

### B8 — Issues
- [ ] B8.1 Tenant reports an issue → Landlord sees it in Property Health → resolve → tenant confirms

---

## Highest-risk items for audit regressions (extra attention)
- **A3.4 / A4** — Property Health + image caching
- **A7.3** — admin bank reads (C1)
- **B2.2** — agent-initiated chat (M3)
- **B6** — rent + refunds money path
