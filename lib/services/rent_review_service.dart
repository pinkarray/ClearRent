import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../shared/models/active_rental_model.dart';
import '../shared/models/rent_review_request_model.dart';
import '../shared/models/tenancy_link_model.dart';

/// Landlord-initiated rent change requests (scheduled review + immediate).
/// Writes rent_review_requests; the approveRentReview / approveImmediateRentChange
/// CFs read those docs. Occupancy checks here MIRROR the CF's server-side
/// re-check — the client decides which form to show, the CF re-verifies.
class RentReviewService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Must match OCCUPYING_RENTAL_STATUSES in functions/src/index.ts and the
  // existing client queries (active_rental_service.dart:400).
  static const _occupyingRentalStatuses = [
    'active',
    'expiring_soon',
    'grace_locked',
  ];

  /// Create a rent-review / rent-change request. Returns the new doc id, or
  /// null on failure. createdAt/updatedAt are set server-side here, overriding
  /// the model's client clock.
  Future<String?> createRentReviewRequest(RentReviewRequest request) async {
    try {
      final data = request.toFirestore();
      data['createdAt'] = FieldValue.serverTimestamp();
      data['updatedAt'] = FieldValue.serverTimestamp();
      final ref = await _firestore.collection('rent_review_requests').add(data);
      developer.log(
        '✅ Rent review request created: ${ref.id}',
        name: 'RentReviewService',
      );
      return ref.id;
    } catch (e) {
      developer.log(
        '❌ Error creating rent review request: $e',
        name: 'RentReviewService',
      );
      return null;
    }
  }

  /// The current landlord's occupying active_rentals on one property.
  /// Used to pick the specific tenancy a scheduled review targets, and as
  /// the occupancy signal for the scheduled-vs-immediate branch.
  Stream<List<ActiveRental>> streamLandlordRentalsForProperty(
    String propertyId,
  ) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(const []);

    final rentalsStream = _firestore
        .collection('active_rentals')
        .where('landlordId', isEqualTo: uid)
        .where('propertyId', isEqualTo: propertyId)
        .where('status', whereIn: _occupyingRentalStatuses)
        .snapshots();

    // Confirmed tenancy_links are sitting tenants too — a scheduled review can
    // target them, and the increase carries through completeLinkedPromotion
    // when they promote to an active rental. Scoped by landlordId to satisfy
    // the tenancy_links list rule (F1.13).
    final linksStream = _firestore
        .collection('tenancy_links')
        .where('landlordId', isEqualTo: uid)
        .where('propertyId', isEqualTo: propertyId)
        .where('status', isEqualTo: 'confirmed')
        .snapshots();

    // Manual combineLatest — hold the latest of each source, emit once both
    // have reported and on every subsequent change.
    final controller = StreamController<List<ActiveRental>>();
    QuerySnapshot<Map<String, dynamic>>? latestRentals;
    QuerySnapshot<Map<String, dynamic>>? latestLinks;
    var rentalsReady = false;
    var linksReady = false;

    void emit() {
      if (!rentalsReady || !linksReady) return;
      final out = <ActiveRental>[];
      if (latestRentals != null) {
        for (final d in latestRentals!.docs) {
          out.add(ActiveRental.fromFirestore(d.data(), d.id));
        }
      }
      if (latestLinks != null) {
        for (final d in latestLinks!.docs) {
          final link = TenancyLinkModel.fromFirestore(d.data(), d.id);
          // Present the link as an ActiveRental for the picker, using its REAL
          // lease end (fromLink synthesises one). Legacy links with no term get
          // a far-future date so the notice window doesn't wrongly block them.
          out.add(ActiveRental.fromLink(link).copyWith(
            leaseEndDate: link.leaseEndDate ??
                DateTime.now().add(const Duration(days: 3650)),
          ));
        }
      }
      controller.add(out);
    }

    final rentalsSub = rentalsStream.listen(
      (s) {
        latestRentals = s;
        rentalsReady = true;
        emit();
      },
      onError: controller.addError,
    );
    final linksSub = linksStream.listen(
      (s) {
        latestLinks = s;
        linksReady = true;
        emit();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await rentalsSub.cancel();
      await linksSub.cancel();
    };

    return controller.stream;
  }

  /// True if the property has any sitting tenant — an occupying active_rental
  /// OR a confirmed tenancy_link. Drives the form's scheduled (true) vs
  /// immediate (false) branch. The CF re-checks this on approval.
  Future<bool> propertyHasSittingTenant(String propertyId) async {
    // The caller is the property owner; scope both queries by landlordId so
    // they satisfy the ownership-constrained list rules (active_rentals, and
    // tenancy_links F1.13). The owner's uid is on every rental/link for their
    // property, so this returns the same set as a propertyId-only query.
    final uid = _auth.currentUser?.uid;
    if (uid == null) return false;
    final rentals = await _firestore
        .collection('active_rentals')
        .where('landlordId', isEqualTo: uid)
        .where('propertyId', isEqualTo: propertyId)
        .where('status', whereIn: _occupyingRentalStatuses)
        .limit(1)
        .get();
    if (rentals.docs.isNotEmpty) return true;

    final links = await _firestore
        .collection('tenancy_links')
        .where('propertyId', isEqualTo: propertyId)
        .where('landlordId', isEqualTo: uid)
        .where('status', isEqualTo: 'confirmed')
        .limit(1)
        .get();
    return links.docs.isNotEmpty;
  }
}