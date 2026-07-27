import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:developer' as developer;
import '../shared/models/active_rental_model.dart';
import '../shared/models/rental_interest_model.dart';
import '../shared/models/inspection_request_model.dart';
import '../shared/models/tenancy_link_model.dart';
import '../shared/models/tenant_rental.dart';
import 'auth_service.dart';

class ActiveRentalService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AuthService _authService = AuthService();
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  // ============ RENEWAL / PROMOTION (System D) ============

  /// Complete a renewal (active rental) or promotion (linked tenant) after
  /// a successful Paystack payment. Branches on origin to call the matching
  /// Cloud Function; the CF re-verifies the payment server-side, extends or
  /// creates the rental, and fires payout/receipt side-effects. Returns true
  /// on success.
  Future<bool> completeRenewal(
    TenantRental rental,
    String paymentReference,
  ) async {
    final fn = rental.isLinked
        ? 'completeLinkedPromotion'
        : 'completeActiveRenewal';
    try {
      final callable = _functions.httpsCallable(fn);
      final result = await callable.call<Map<String, dynamic>>({
        'sourceId': rental.sourceId,
        'paymentReference': paymentReference,
      });
      final success = result.data['success'] == true;
      if (!success) {
        developer.log('❌ $fn returned success=false',
            name: 'ActiveRentalService');
      }
      return success;
    } on FirebaseFunctionsException catch (e) {
      developer.log('❌ $fn failed: ${e.code} — ${e.message}',
          name: 'ActiveRentalService');
      return false;
    } catch (e) {
      developer.log('❌ $fn error: $e', name: 'ActiveRentalService');
      return false;
    }
  }

  // ============ CREATE ============

  /// Create active rental after landlord accepts verified interest.
  /// This is the method the landlord inspections screen calls:
  ///   _activeRentalService.createActiveRental(
  ///       rentalInterest: interest, inspectionRequest: widget.request);
  /// True if an active_rental already exists for this rental interest.
  ///
  /// Used to detect — and recover from — a PARTIAL accept: the interest was
  /// flipped to `accepted` but createActiveRental then failed, leaving the
  /// tenant with an accepted application and no rental record (no agreement,
  /// no dashboard). The landlord screen offers a "finish setup" action when
  /// this returns false for an accepted interest.
  Future<bool> hasRentalForInterest(String rentalInterestId) async {
    try {
      final snap = await _firestore
          .collection('active_rentals')
          .where('rentalInterestId', isEqualTo: rentalInterestId)
          .limit(1)
          .get();
      return snap.docs.isNotEmpty;
    } catch (e) {
      developer.log('❌ hasRentalForInterest failed: $e',
          name: 'ActiveRentalService');
      // Fail "it exists" — on a transient read error we'd rather hide the
      // recovery action than risk creating a duplicate rental.
      return true;
    }
  }

  /// Whether [propertyId] still has an open tenancy slot for [tenantId].
  ///
  /// One slot = one tenant: a property slot is held from the moment a tenant is
  /// accepted (rental created as pending_payment) through payment and tenancy.
  /// This lets the accept flow refuse a SECOND applicant on a full property,
  /// which otherwise produced two rentals for one slot. The tenant's own
  /// existing rental doesn't count against them (multi-slot re-entry).
  ///
  /// Best-effort client guard (rules can't cross-query the collection); the
  /// occupancy CFs remain the source of truth for currentTenantsCount.
  Future<bool> propertyHasOpenSlot(String propertyId, String tenantId) async {
    try {
      final propSnap =
          await _firestore.collection('properties').doc(propertyId).get();
      final maxTenants = (propSnap.data()?['maxTenants'] as num?)?.toInt() ?? 1;

      // Statuses that hold a slot — mirror the server's OCCUPYING set, plus
      // pending_payment (accepted, awaiting rent).
      const holding = [
        'active',
        'expiring_soon',
        'grace_locked',
        'pending_payment',
      ];
      final snap = await _firestore
          .collection('active_rentals')
          .where('propertyId', isEqualTo: propertyId)
          .get();
      final takenByOthers = snap.docs.where((d) {
        final data = d.data();
        return data['tenantId'] != tenantId &&
            holding.contains(data['status']);
      }).length;

      return takenByOthers < maxTenants;
    } catch (e) {
      developer.log('❌ propertyHasOpenSlot failed: $e',
          name: 'ActiveRentalService');
      // Fail "no open slot" — don't risk double-accepting on a read error.
      return false;
    }
  }

  Future<ActiveRental?> createActiveRental({
    required RentalInterest rentalInterest,
    required InspectionRequest inspectionRequest,
  }) async {
    try {
      // Pay-after-accept: the rental record is created when the landlord
      // ACCEPTS (still unpaid) — the tenant pays only after the agreement is
      // finalized. Legacy pay-first interests (payment_verified) still qualify.
      if (!rentalInterest.isPaymentVerified &&
          rentalInterest.status != RentalInterestStatus.accepted) {
        throw Exception(
          'Rental interest must be accepted before creating the rental',
        );
      }

      // Calculate dates
      final now = DateTime.now();
      final leaseStart = now;
      // Default to yearly — you can fetch property rentFrequency if needed
      final leaseEnd = DateTime(now.year + 1, now.month, now.day);
      final nextPayment = leaseEnd;

      final rentalData = {
        'propertyId': rentalInterest.propertyId,
        'tenantId': rentalInterest.tenantId,
        'landlordId': rentalInterest.landlordId,
        'agentId': rentalInterest.agentId,
        'inspectionRequestId': rentalInterest.inspectionRequestId,
        'rentalInterestId': rentalInterest.id,
        'propertyTitle': rentalInterest.propertyTitle,
        'propertyImage': rentalInterest.propertyImage,
        'propertyAddress': rentalInterest.propertyAddress,
        'tenantName': rentalInterest.tenantName,
        'landlordName': rentalInterest.landlordName,
        'rentAmount':
            rentalInterest.rentAmount > 0
                ? rentalInterest.rentAmount
                : rentalInterest.paymentAmount,
        'agentFee': rentalInterest.agentFee,
        // Pay-after-accept: the rental is created UNPAID at acceptance. The
        // accepted tenant pays only after the agreement is finalized, and the
        // recordRentPayment callable then stamps rentPaymentStatus/totalPaid/
        // rentPaidAt server-side. Until then totalPaid is 0.
        'totalPaid': 0,
        'rentPaymentStatus': 'pending',
        'landlordPayout': rentalInterest.landlordPayout,
        'agentPayout': rentalInterest.agentPayout,
        'clearrentEarnings': rentalInterest.clearrentEarnings,
        'landlordPayoutStatus': 'pending',
        'agentPayoutStatus':
            rentalInterest.agentId != null ? 'pending' : 'not_applicable',
        'inspectionFeeCredit': 5000,
        'rentFrequency': 'yearly',
        'leaseStartDate': Timestamp.fromDate(leaseStart),
        'leaseEndDate': Timestamp.fromDate(leaseEnd),
        'nextPaymentDue': Timestamp.fromDate(nextPayment),
        // Pay-after-accept: the tenancy isn't real until the rent is paid, so
        // the rental starts as pending_payment. That status is NOT in the
        // server's OCCUPYING_RENTAL_STATUSES, so the unit stays on the market
        // and the tenant isn't counted as occupying it during the agreement
        // window. recordRentPayment flips this to 'active' when the money lands,
        // which fires the occupancy recompute.
        'status': 'pending_payment',
        'hasPaymentReminder': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore
          .collection('active_rentals')
          .add(rentalData);

      // Property occupancy is server-owned (occupancy-sync CFs) and keys off the
      // rental status, so nothing to do here while it's pending_payment.
      // The tenant is NOT marked as having an active rental yet either — that
      // now happens server-side in recordRentPayment, once they've actually
      // paid. Marking them active here would show an unpaid tenant as a real
      // tenant on their dashboard.

      // Fetch created document
      final doc = await docRef.get();
      if (doc.exists) {
        developer.log(
          '✅ Active rental created: ${docRef.id}',
          name: 'ActiveRentalService',
        );
        return ActiveRental.fromFirestore(doc.data()!, doc.id);
      }

      return null;
    } catch (e) {
      developer.log('❌ Error creating rental: $e', name: 'ActiveRentalService');
      return null;
    }
  }

  /// Legacy method signature — delegates to createActiveRental
  Future<ActiveRental?> createRental({
    required RentalInterest interest,
    required double rentAmount,
    required double agentFee,
    String rentFrequency = 'yearly',
  }) async {
    // Create a dummy inspection request since the legacy call doesn't have one
    // For new code, use createActiveRental() instead
    try {
      if (!interest.isPaymentVerified &&
          interest.status != RentalInterestStatus.accepted) {
        throw Exception('Payment must be verified before creating rental');
      }

      final now = DateTime.now();
      final leaseStart = now;
      final leaseEnd =
          rentFrequency == 'yearly'
              ? DateTime(now.year + 1, now.month, now.day)
              : DateTime(now.year, now.month + 1, now.day);
      final nextPayment = leaseEnd;

      final rentalData = {
        'propertyId': interest.propertyId,
        'tenantId': interest.tenantId,
        'landlordId': interest.landlordId,
        'agentId': interest.agentId,
        'inspectionRequestId': interest.inspectionRequestId,
        'rentalInterestId': interest.id,
        'propertyTitle': interest.propertyTitle,
        'propertyImage': interest.propertyImage,
        'propertyAddress': interest.propertyAddress,
        'tenantName': interest.tenantName,
        'landlordName': interest.landlordName,
        'rentAmount': rentAmount,
        'agentFee': agentFee,
        'totalPaid': interest.paymentAmount,
        'inspectionFeeCredit': 5000,
        'rentFrequency': rentFrequency,
        'leaseStartDate': Timestamp.fromDate(leaseStart),
        'leaseEndDate': Timestamp.fromDate(leaseEnd),
        'nextPaymentDue': Timestamp.fromDate(nextPayment),
        'status': 'active',
        'hasPaymentReminder': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore
          .collection('active_rentals')
          .add(rentalData);

      await _updatePropertyStatus(interest.propertyId, interest.tenantId, true);
      await _updateTenantStatus(
        interest.tenantId,
        interest.propertyId,
        docRef.id,
        true,
      );

      final doc = await docRef.get();
      if (doc.exists) {
        developer.log(
          '✅ Active rental created: ${docRef.id}',
          name: 'ActiveRentalService',
        );
        return ActiveRental.fromFirestore(doc.data()!, doc.id);
      }
      return null;
    } catch (e) {
      developer.log('❌ Error creating rental: $e', name: 'ActiveRentalService');
      return null;
    }
  }

  // ============ HELPERS ============

  /// Update property status — increments/decrements currentTenantsCount
  /// and only marks unavailable when all slots are filled (respects maxTenants).
  /// Property occupancy (currentTenantsCount + isAvailable) is now owned
  /// exclusively by the server-side occupancy-sync Cloud Functions, which
  /// recompute from confirmed tenancy_links + occupying active_rentals.
  /// Kept as a no-op so the create/terminate call sites stay intact; the
  /// CF fires on the active_rentals create/status-change those flows cause.
  Future<void> _updatePropertyStatus(
    String propertyId,
    String tenantId,
    bool isRented,
  ) async {
    // Intentionally empty — see doc comment above.
  }
  
  /// Update tenant status (mark as having active rental)
  Future<void> _updateTenantStatus(
    String tenantId,
    String propertyId,
    String rentalId,
    bool hasRental,
  ) async {
    try {
      await _firestore.collection('users').doc(tenantId).update({
        'hasActiveRental': hasRental,
        'currentPropertyId': hasRental ? propertyId : null,
        'currentRentalId': hasRental ? rentalId : null,
        'rentStartDate': hasRental ? FieldValue.serverTimestamp() : null,
        'rentEndDate': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log(
        '✅ Tenant status updated: $tenantId',
        name: 'ActiveRentalService',
      );
    } catch (e) {
      developer.log(
        '❌ Error updating tenant status: $e',
        name: 'ActiveRentalService',
      );
    }
  }

  // ============ READ ============

  /// Get active rental for current tenant
  Future<ActiveRental?> getTenantActiveRental() async {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return null;

    try {
      final querySnapshot =
          await _firestore
              .collection('active_rentals')
              .where('tenantId', isEqualTo: currentUserId)
              .where('status', isEqualTo: 'active')
              .limit(1)
              .get();

      if (querySnapshot.docs.isEmpty) return null;

      final doc = querySnapshot.docs.first;
      return ActiveRental.fromFirestore(doc.data(), doc.id);
    } catch (e) {
      developer.log(
        '❌ Error getting tenant active rental: $e',
        name: 'ActiveRentalService',
      );
      return null;
    }
  }

  /// Live stream of ALL rentals for the current tenant (every status, no
  /// filter). Lets My Rentals stay current on its own — e.g. when a payment
  /// flips a rental from pending_payment to active, the card updates itself
  /// instead of showing the stale "Review & Pay" state until a manual reload.
  Stream<List<ActiveRental>> streamAllTenantRentals() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return Stream.value(const []);
    return _firestore
        .collection('active_rentals')
        .where('tenantId', isEqualTo: currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
            .toList());
  }

  /// Get ALL rentals for the current tenant (active + past)
  /// Used by: my_rentals_screen.dart, documents_screen.dart
  Future<List<ActiveRental>> getTenantRentals() async {
    try {
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) return [];

      final snapshot =
          await _firestore
              .collection('active_rentals')
              .where('tenantId', isEqualTo: currentUserId)
              .orderBy('createdAt', descending: true)
              .get();

      return snapshot.docs
          .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log(
        '❌ Error getting tenant rentals: $e',
        name: 'ActiveRentalService',
      );
      return [];
    }
  }

  /// Get active rental by ID
  Future<ActiveRental?> getRentalById(String rentalId) async {
    try {
      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();

      if (!doc.exists) return null;

      return ActiveRental.fromFirestore(doc.data()!, doc.id);
    } catch (e) {
      developer.log(
        '❌ Error getting rental by ID: $e',
        name: 'ActiveRentalService',
      );
      return null;
    }
  }

  /// Stream active rental for tenant
  Stream<ActiveRental?> streamTenantActiveRental() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) {
      return Stream.value(null);
    }

    return _firestore
        .collection('active_rentals')
        .where('tenantId', isEqualTo: currentUserId)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .snapshots()
        .map((snapshot) {
          if (snapshot.docs.isEmpty) return null;
          final doc = snapshot.docs.first;
          return ActiveRental.fromFirestore(doc.data(), doc.id);
        });
  }

  /// Unified multi-rental stream: merges every active_rentals doc (active /
  /// expiring_soon / expired — i.e. not terminated) with every CONFIRMED
  /// tenancy_link for the current tenant, wrapped as [TenantRental] tagged by
  /// origin. Confirmed-only filtering also excludes future 'promoted' links
  /// (a promoted link becomes an active_rental, so it must not double-count).
  ///
  /// Emits a fresh merged list whenever EITHER source changes. Replaces the
  /// single-rental .limit(1) reads for the dashboard; the old getters stay for
  /// other callers.
  Stream<List<TenantRental>> streamTenantRentals() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return Stream.value(const []);

    final activeStream = _firestore
        .collection('active_rentals')
        .where('tenantId', isEqualTo: currentUserId)
        .where('status', whereIn: ['active', 'expiring_soon', 'grace_locked'])
        .snapshots();

    final linkStream = _firestore
        .collection('tenancy_links')
        .where('tenantId', isEqualTo: currentUserId)
        .where('status', whereIn: ['confirmed', 'expiring_soon', 'grace_locked'])
        .snapshots();

    // Manual combineLatest — hold the latest of each source, emit on either.
    final controller = StreamController<List<TenantRental>>();
    QuerySnapshot<Map<String, dynamic>>? latestActive;
    QuerySnapshot<Map<String, dynamic>>? latestLinks;
    var activeReady = false;
    var linksReady = false;

    void emit() {
      // Wait until both sources have delivered at least once, so the first
      // emission is complete rather than active-only then links-added.
      if (!activeReady || !linksReady) return;

      final merged = <TenantRental>[];

      for (final doc in latestActive?.docs ?? const []) {
        merged.add(
          TenantRental.fromActive(
            ActiveRental.fromFirestore(doc.data(), doc.id),
          ),
        );
      }
      for (final doc in latestLinks?.docs ?? const []) {
        merged.add(
          TenantRental.fromLink(
            TenancyLinkModel.fromFirestore(doc.data(), doc.id),
          ),
        );
      }

      controller.add(merged);
    }

    final activeSub = activeStream.listen(
      (snap) {
        latestActive = snap;
        activeReady = true;
        emit();
      },
      onError: (Object e) {
        developer.log('❌ streamTenantRentals active error: $e',
            name: 'ActiveRentalService');
        activeReady = true;
        emit();
      },
    );

    final linkSub = linkStream.listen(
      (snap) {
        latestLinks = snap;
        linksReady = true;
        emit();
      },
      onError: (Object e) {
        developer.log('❌ streamTenantRentals link error: $e',
            name: 'ActiveRentalService');
        linksReady = true;
        emit();
      },
    );

    controller.onCancel = () async {
      await activeSub.cancel();
      await linkSub.cancel();
    };

    return controller.stream;
  }

  /// Get all rentals for a landlord
  Future<List<ActiveRental>> getLandlordRentals() async {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return [];

    try {
      final querySnapshot =
          await _firestore
              .collection('active_rentals')
              .where('landlordId', isEqualTo: currentUserId)
              .orderBy('createdAt', descending: true)
              .get();

      return querySnapshot.docs
          .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log(
        '❌ Error getting landlord rentals: $e',
        name: 'ActiveRentalService',
      );
      return [];
    }
  }

  // ============ AGREEMENT ============

  /// Upload tenancy agreement (landlord action)
  /// Called when landlord uploads agreement PDF/image for a rental
  Future<bool> uploadAgreement(String rentalId, String agreementUrl) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementUrl': agreementUrl,
        'agreementUploadedAt': FieldValue.serverTimestamp(),
        // Set the review status so the tenant is actually PROMPTED to review +
        // accept (the onActiveRentalUpdated CF fires on agreementStatus →
        // pending_review). Was left unset here, so an agreement uploaded at
        // accept-time sat with a URL but no status — no prompt, and the flow
        // looked dead. Matches sendAgreementToTenant.
        'agreementStatus': 'pending_review',
        'tenantDisputeReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notification handled by the onActiveRentalUpdated Cloud Function
      // (agreementStatus → pending_review).

      developer.log(
        '✅ Agreement uploaded for rental: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error uploading agreement: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  Future<bool> sendAgreementToTenant(
    String rentalId,
    String agreementUrl,
  ) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementUrl': agreementUrl,
        'agreementUploadedAt': FieldValue.serverTimestamp(),
        'agreementStatus': 'pending_review',
        'tenantDisputeReason': null, // Clear any previous dispute
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notification handled by the onActiveRentalUpdated Cloud Function
      // (agreementStatus → pending_review).

      developer.log(
        '✅ Agreement sent to tenant for rental: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error sending agreement: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Tenant accepts the agreement — which FINALIZES it.
  ///
  /// The landlord authored and sent the agreement (their side of it) and the
  /// tenant accepting completes it, so the deal is "finalized between the
  /// parties" at this point — there's no separate landlord finalize tap. That
  /// matters twice over: it's what unlocks the tenant's rent payment (rent is
  /// only ever collected on a finalized agreement), and it removes the step
  /// where a quiet landlord could strand an accepted tenant indefinitely.
  /// Legacy rentals sitting at 'accepted' can still be finalized by the
  /// landlord via finalizeAgreement.
  Future<bool> tenantAcceptAgreement(String rentalId) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        // NOTE: only fields in the active_rentals update allowlist
        // (firestore.rules) may be written here — an extra field would get the
        // whole write rejected. landlordFinalizedAt doubles as the finalize
        // stamp since tenant acceptance is what finalizes.
        'agreementStatus': 'finalized',
        'tenantAcceptedAt': FieldValue.serverTimestamp(),
        'landlordFinalizedAt': FieldValue.serverTimestamp(),
        'tenantDisputeReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notification handled by the onActiveRentalUpdated Cloud Function
      // (agreementStatus → finalized: tenant is prompted to pay, landlord is
      // told it's done).

      developer.log(
        '✅ Tenant accepted agreement: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error accepting agreement: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Tenant disputes/raises concerns about the agreement
  Future<bool> tenantDisputeAgreement(String rentalId, String reason) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementStatus': 'disputed',
        'tenantDisputeReason': reason,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notification handled by the onActiveRentalUpdated Cloud Function
      // (agreementStatus → disputed; reason read from tenantDisputeReason).

      developer.log(
        '✅ Tenant disputed agreement: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error disputing agreement: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Landlord finalizes the agreement after tenant acceptance
  Future<bool> landlordFinalizeAgreement(String rentalId) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementStatus': 'finalized',
        'landlordFinalizedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notification handled by the onActiveRentalUpdated Cloud Function
      // (agreementStatus → finalized).

      developer.log(
        '✅ Agreement finalized: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error finalizing agreement: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Landlord re-uploads a revised agreement (after dispute)
  /// Resets status back to pending_review
  Future<bool> reuploadAgreement(
    String rentalId,
    String newAgreementUrl,
  ) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementUrl': newAgreementUrl,
        'agreementUploadedAt': FieldValue.serverTimestamp(),
        'agreementStatus': 'pending_review',
        'tenantDisputeReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notification handled by the onActiveRentalUpdated Cloud Function
      // (agreementStatus → pending_review on re-upload).

      developer.log(
        '✅ Agreement re-uploaded: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error re-uploading agreement: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  // ============ UPDATE ============

  /// Toggle payment reminder
  Future<bool> togglePaymentReminder(String rentalId, bool enabled) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'hasPaymentReminder': enabled,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log(
        '✅ Payment reminder toggled: $rentalId -> $enabled',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error toggling payment reminder: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Terminate rental (early termination)
  Future<bool> terminateRental(String rentalId) async {
    try {
      final rental = await getRentalById(rentalId);
      if (rental == null) return false;

      await _firestore.collection('active_rentals').doc(rentalId).update({
        'status': 'terminated',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Update property and tenant status
      await _updatePropertyStatus(rental.propertyId, rental.tenantId, false);
      await _updateTenantStatus(
        rental.tenantId,
        rental.propertyId,
        rentalId,
        false,
      );

      developer.log(
        '✅ Rental terminated: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error terminating rental: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  Future<bool> tenantMoveOut(String rentalId, String reason) async {
    try {
      final rental = await getRentalById(rentalId);
      if (rental == null) return false;

      await _firestore.collection('active_rentals').doc(rentalId).update({
        'status': 'ended_by_tenant',
        'endReason': reason,
        'endedBy': 'tenant',
        'endedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _updatePropertyStatus(rental.propertyId, rental.tenantId, false);
      await _updateTenantStatus(
        rental.tenantId,
        rental.propertyId,
        rentalId,
        false,
      );

      // Landlord notification handled by the onActiveRentalUpdated Cloud
      // Function (status → ended_by_tenant).

      developer.log(
        '✅ Tenant moved out: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error in tenant move-out: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Landlord ends a rental. ONLY permitted when the rental is grace_locked
  /// (lease lapsed + tenant hasn't renewed). Fails closed otherwise — a
  /// landlord cannot touch a mid-lease active rental. ClearRent records and
  /// notifies; this is not an eviction.
  Future<bool> landlordRemoveTenant(String rentalId, String reason) async {
    try {
      final rental = await getRentalById(rentalId);
      if (rental == null) return false;

      // Server-truth gate: only grace_locked rentals are removable.
      if (rental.status != ActiveRentalStatus.graceLocked) {
        developer.log(
          '⚠️ landlordRemoveTenant blocked — status is '
          '${rental.statusDisplay}, not grace_locked: $rentalId',
          name: 'ActiveRentalService',
        );
        return false;
      }

      await _firestore.collection('active_rentals').doc(rentalId).update({
        'status': 'ended_by_landlord',
        'endReason': reason,
        'endedBy': 'landlord',
        'endedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _updatePropertyStatus(rental.propertyId, rental.tenantId, false);
      await _updateTenantStatus(
        rental.tenantId,
        rental.propertyId,
        rentalId,
        false,
      );

      // Tenant notification handled by the onActiveRentalUpdated Cloud
      // Function (status → ended_by_landlord).

      developer.log(
        '✅ Landlord removed tenant: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error in landlord removal: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Tenant adds their side to a landlord-ended rental. Annotates the record
  /// only — does NOT change rental status. Notifies the landlord. No
  /// adjudication; the timeline is preserved for any offline/legal process.
  Future<bool> tenantContest(String rentalId, String statement) async {
    try {
      final rental = await getRentalById(rentalId);
      if (rental == null) return false;

      await _firestore.collection('active_rentals').doc(rentalId).update({
        'tenantContested': true,
        'tenantContestStatement': statement,
        'contestedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Landlord notification handled by the onActiveRentalUpdated Cloud
      // Function (tenantContested → true).

      developer.log(
        '✅ Tenant contested rental end: $rentalId',
        name: 'ActiveRentalService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error in tenant contest: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Check and update rental statuses based on dates
  Future<void> updateRentalStatuses() async {
    try {
      final now = DateTime.now();
      final querySnapshot =
          await _firestore
              .collection('active_rentals')
              .where('status', isEqualTo: 'active')
              .get();

      for (final doc in querySnapshot.docs) {
        final rental = ActiveRental.fromFirestore(doc.data(), doc.id);

        if (rental.leaseEndDate.isBefore(now)) {
          await doc.reference.update({
            'status': 'expired',
            'updatedAt': FieldValue.serverTimestamp(),
          });
          developer.log(
            '✅ Rental expired: ${doc.id}',
            name: 'ActiveRentalService',
          );
        } else if (rental.daysUntilLeaseEnd <= 30 &&
            rental.daysUntilLeaseEnd > 0) {
          await doc.reference.update({
            'status': 'expiring_soon',
            'updatedAt': FieldValue.serverTimestamp(),
          });
          developer.log(
            '✅ Rental expiring soon: ${doc.id}',
            name: 'ActiveRentalService',
          );
        }
      }
    } catch (e) {
      developer.log(
        '❌ Error updating rental statuses: $e',
        name: 'ActiveRentalService',
      );
    }
  }
}
