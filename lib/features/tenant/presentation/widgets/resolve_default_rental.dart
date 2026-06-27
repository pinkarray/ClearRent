import '../../../../shared/models/tenant_rental.dart';

/// Picks which rental the multi-rental switcher opens on by default.
///
/// Pure function — ranks purely on fields [TenantRental] already carries
/// synchronously, so it stays unit-testable and never touches Firestore.
///
/// Priority (first match wins):
///   1. Agreement awaiting tenant review (active origin only — linked rentals
///      have no in-app agreement workflow, so [isAgreementPendingReview] is
///      always false for them via [ActiveRental.fromLink]).
///   2. grace_locked — term lapsed, tenant hasn't renewed (needs action).
///   3. expiring_soon — within the lease-end reminder window.
///   4. Fallback — earliest-acquired (oldest [ActiveRental.createdAt];
///      for linked origin this is the link's accepted/created date).
///
/// POST-LAUNCH TIER 0: "issue reported AND landlord responded" should rank
/// above everything here. That signal isn't denormalized onto the rental/link
/// doc today (it lives in the issues collection), so a sync resolver can't read
/// it. When an issue-status field lands on the rental doc, insert that check as
/// tier 0 — the tiers below stay unchanged.
TenantRental? resolveDefault(List<TenantRental> rentals) {
  if (rentals.isEmpty) return null;
  if (rentals.length == 1) return rentals.first;

  // Tier 1 — agreement pending tenant review.
  for (final r in rentals) {
    if (r.rental.isAgreementPendingReview) return r;
  }

  // Tier 2 — grace_locked.
  for (final r in rentals) {
    if (r.lifecycle == RentalLifecycle.graceLocked) return r;
  }

  // Tier 3 — expiring soon.
  for (final r in rentals) {
    if (r.lifecycle == RentalLifecycle.expiringSoon) return r;
  }

  // Tier 4 — earliest-acquired.
  final sorted = [...rentals]
    ..sort((a, b) => a.rental.createdAt.compareTo(b.rental.createdAt));
  return sorted.first;
}