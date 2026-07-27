import 'active_rental_model.dart';
import 'tenancy_link_model.dart';

/// Unified lifecycle state across both rental sources — what the switcher reads
/// to decide normal-render vs. grey-out. Computed from the underlying source
/// status so widgets don't re-derive per card.
enum RentalLifecycle {
  /// Normal, full dashboard.
  active,

  /// Within the lease-end reminder window; still full dashboard.
  expiringSoon,

  /// Term lapsed, tenant hasn't acted — greyed, renew-only.
  graceLocked,
}

/// Origin of a rental shown in the multi-rental tenant dashboard.
enum RentalOrigin {
  /// Backed by an `active_rentals` doc (full inspection + rent funnel).
  active,

  /// Backed by a confirmed `tenancy_links` doc (landlord-added, rent off-platform).
  linked,
}

/// View-layer wrapper unifying the two rental sources a tenant can hold
/// (active_rentals + tenancy_links) into one switchable list. The dashboard
/// reads [rental] for display; [origin] decides which dashboard widget renders
/// and which fields are real vs. adapted-from-link.
class TenantRental {
  /// Display-shape rental. For linked origin this is adapted via
  /// [ActiveRental.fromLink] — its lease/payout fields are synthetic and must
  /// not be trusted (check [origin] before reading them).
  final ActiveRental rental;

  final RentalOrigin origin;

  /// Source doc id — the `active_rentals` id or the `tenancy_links` id.
  /// Equals [rental].id, surfaced explicitly so callers don't depend on that.
  final String sourceId;

  /// The raw link, present only when [origin] == [RentalOrigin.linked].
  /// Kept for accurate rent dates and the linked dashboard.
  final TenancyLinkModel? link;

  const TenantRental({
    required this.rental,
    required this.origin,
    required this.sourceId,
    this.link,
  });

  bool get isLinked => origin == RentalOrigin.linked;
  bool get isActive => origin == RentalOrigin.active;

  /// Unified lifecycle, derived per origin. Active rentals read their status
  /// enum directly; linked rentals derive from the link's lifecycle (a confirmed
  /// link whose term has lapsed is graceLocked; within the reminder window it's
  /// expiringSoon; otherwise active). Reminder window kept in sync with the
  /// scheduled CF threshold.
  RentalLifecycle get lifecycle {
    if (origin == RentalOrigin.active) {
      switch (rental.status) {
        case ActiveRentalStatus.graceLocked:
          return RentalLifecycle.graceLocked;
        case ActiveRentalStatus.expiringSoon:
          return RentalLifecycle.expiringSoon;
        case ActiveRentalStatus.active:
        case ActiveRentalStatus.expired:
        case ActiveRentalStatus.terminated:
        case ActiveRentalStatus.endedByTenant:
        case ActiveRentalStatus.endedByLandlord:
        // pendingPayment (accepted, rent not yet paid) never reaches this
        // stream — streamTenantRentals only pulls occupying statuses — but the
        // switch must stay exhaustive.
        case ActiveRentalStatus.pendingPayment:
          return RentalLifecycle.active;
      }
    }
    // Linked origin — derive from the raw link.
    final l = link;
    if (l == null) return RentalLifecycle.active;
    if (l.status == 'grace_locked' || l.isLeaseEnded) {
      return RentalLifecycle.graceLocked;
    }
    if (l.status == 'expiring_soon' || l.daysUntilLeaseEnd <= 30) {
      return RentalLifecycle.expiringSoon;
    }
    return RentalLifecycle.active;
  }

  bool get isGraceLocked => lifecycle == RentalLifecycle.graceLocked;

  factory TenantRental.fromActive(ActiveRental rental) => TenantRental(
        rental: rental,
        origin: RentalOrigin.active,
        sourceId: rental.id,
      );

  factory TenantRental.fromLink(TenancyLinkModel link) => TenantRental(
        rental: ActiveRental.fromLink(link),
        origin: RentalOrigin.linked,
        sourceId: link.id,
        link: link,
      );
}