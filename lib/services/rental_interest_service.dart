import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:developer' as developer;
import '../shared/models/rental_interest_model.dart';
import '../shared/models/inspection_request_model.dart';
import 'auth_service.dart';

class RentalInterestService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final AuthService _authService = AuthService();

  // ============ CREATE ============

  /// Create a rental interest when tenant says "I want to rent".
  ///
  /// Amounts are deliberately NOT passed from here. The createRentalInterest
  /// Cloud Function derives every figure from the property and config/pricing,
  /// because the client-supplied paymentAmount written here used to decide what
  /// the tenant was later charged for rent - a modified client could mint an
  /// interest claiming ₦100 against a ₦1.2m tenancy (HANDOVER H2). Direct
  /// `create` on rental_interests is now denied by rule, so this MUST go
  /// through the callable. Eligibility (caller is the tenant, inspection
  /// completed + rated) is re-checked server-side.
  /// Creates the interest, or explains why it could not be created.
  ///
  /// The server refuses for reasons the tenant can act on: the viewing has not
  /// been rated, the place has been taken, the rent is below the floor. Those
  /// messages used to be logged and thrown away, and every one of them reached
  /// the tenant as "Failed to express interest. Please try again." - advice
  /// that is wrong in every case, and unreadable from the outside: a release
  /// build logs nothing, so the same sentence covered a data problem, a
  /// precondition and a real fault alike.
  Future<({RentalInterest? interest, String? error})> createRentalInterest({
    required InspectionRequest inspectionRequest,
  }) async {
    try {
      final callable = _functions.httpsCallable('createRentalInterest');
      final result = await callable.call<Map<String, dynamic>>({
        'inspectionRequestId': inspectionRequest.id,
      });

      final interestId = result.data['interestId'] as String?;
      if (interestId == null) {
        return (interest: null, error: 'We could not start this rental.');
      }

      final doc = await _firestore
          .collection('rental_interests')
          .doc(interestId)
          .get();
      if (doc.exists) {
        developer.log('✅ Rental interest ready: $interestId',
            name: 'RentalInterestService');
        return (
          interest: RentalInterest.fromFirestore(doc.data()!, doc.id),
          error: null,
        );
      }
      return (interest: null, error: 'We could not start this rental.');
    } on FirebaseFunctionsException catch (e) {
      developer.log('❌ createRentalInterest rejected: ${e.code} ${e.message}',
          name: 'RentalInterestService');
      // The server writes these for the tenant to read. Anything else is ours
      // to explain, not theirs to decipher.
      final refusal = e.code == 'failed-precondition' ||
          e.code == 'permission-denied' ||
          e.code == 'not-found';
      final message = e.message;
      return (
        interest: null,
        error: refusal && message != null && message.isNotEmpty ?
            message :
            'We could not start this rental. Please try again.',
      );
    } catch (e) {
      developer.log('❌ Error creating rental interest: $e',
          name: 'RentalInterestService');
      return (
        interest: null,
        error: 'We could not reach ClearRent. Check your connection and '
            'try again.',
      );
    }
  }

  // ============ PAYMENT FLOW ============

  // ============ ADMIN VERIFICATION ============

  /// Record a successful rent payment (pay-after-accept).
  ///
  /// Replaces the old client-side `markPaymentVerified` write: the money-status
  /// fields are now written server-side by the recordRentPayment callable, which
  /// verifies the caller is the accepted tenant and the agreement is finalized
  /// before flipping the interest to `rent_paid` and stamping the active_rental
  /// as paid. Mirrors how createRentalInterest took interest creation off the
  /// client (HANDOVER H2). Returns false if the server rejects it.
  Future<bool> recordRentPayment(
    String interestId, {
    String? paymentReference,
  }) async {
    try {
      final callable = _functions.httpsCallable('recordRentPayment');
      await callable.call<Map<String, dynamic>>({
        'rentalInterestId': interestId,
        'paymentReference': paymentReference,
      });
      developer.log('✅ Rent payment recorded: $interestId',
          name: 'RentalInterestService');
      return true;
    } on FirebaseFunctionsException catch (e) {
      developer.log('❌ recordRentPayment rejected: ${e.code} ${e.message}',
          name: 'RentalInterestService');
      return false;
    } catch (e) {
      developer.log('❌ recordRentPayment error: $e',
          name: 'RentalInterestService');
      return false;
    }
  }

  /// Stream of pending rental payment verifications (admin screen)
  Stream<List<RentalInterest>> getPendingRentalVerifications() {
    return _firestore
        .collection('rental_interests')
        .where('status', isEqualTo: 'payment_uploaded')
        .orderBy('paymentUploadedAt', descending: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => RentalInterest.fromFirestore(doc.data(), doc.id))
          .toList();
    });
  }

  // ============ LANDLORD ACCEPTANCE ============

  /// Landlord accepts the rental (called from landlord_inspections_screen)
  /// Screens call: acceptRentalInterest(interestId)
  Future<bool> acceptRentalInterest(String interestId) async {
    try {
      await _firestore
          .collection('rental_interests')
          .doc(interestId)
          .update({
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Rental interest accepted: $interestId',
          name: 'RentalInterestService');
      return true;
    } catch (e) {
      developer.log('❌ Error accepting interest: $e',
          name: 'RentalInterestService');
      return false;
    }
  }

  // ============ QUERIES ============

  /// Get rental interest for a specific inspection
  Future<RentalInterest?> getInterestForInspection(
      String inspectionRequestId) async {
    try {
      final querySnapshot = await _firestore
          .collection('rental_interests')
          .where('inspectionRequestId', isEqualTo: inspectionRequestId)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) return null;

      final doc = querySnapshot.docs.first;
      return RentalInterest.fromFirestore(doc.data(), doc.id);
    } catch (e) {
      developer.log('❌ Error getting interest for inspection: $e',
          name: 'RentalInterestService');
      return null;
    }
  }

  /// Live stream of the rental interest for one inspection (or null if none
  /// yet). Lets the inspection card update itself the moment the interest state
  /// changes - e.g. the landlord accepting flips it to `accepted`, so "Review
  /// Agreement" appears without the tenant having to leave and come back.
  Stream<RentalInterest?> streamInterestForInspection(
      String inspectionRequestId) {
    return _firestore
        .collection('rental_interests')
        .where('inspectionRequestId', isEqualTo: inspectionRequestId)
        .limit(1)
        .snapshots()
        .map((snap) => snap.docs.isEmpty
            ? null
            : RentalInterest.fromFirestore(
                snap.docs.first.data(), snap.docs.first.id));
  }

  /// Get rental interest by ID
  Future<RentalInterest?> getInterestById(String interestId) async {
    try {
      final doc = await _firestore
          .collection('rental_interests')
          .doc(interestId)
          .get();

      if (!doc.exists) return null;

      return RentalInterest.fromFirestore(doc.data()!, doc.id);
    } catch (e) {
      developer.log('❌ Error getting interest by ID: $e',
          name: 'RentalInterestService');
      return null;
    }
  }

  // ============ TENANT QUERIES ============

  /// Get all rental interests for the current tenant (Future-based)
  /// Used by: payment_history_screen.dart, documents_screen.dart
  Future<List<RentalInterest>> getTenantInterests() async {
    try {
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) return [];

      final snapshot = await _firestore
          .collection('rental_interests')
          .where('tenantId', isEqualTo: currentUserId)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => RentalInterest.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting tenant interests: $e',
          name: 'RentalInterestService');
      return [];
    }
  }

  /// Stream interests for a tenant (real-time updates)
  Stream<List<RentalInterest>> streamTenantInterests() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('rental_interests')
        .where('tenantId', isEqualTo: currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => RentalInterest.fromFirestore(doc.data(), doc.id))
          .toList();
    });
  }

  // ============ LANDLORD QUERIES ============

  /// Get all rental interests for the current landlord (Future-based)
  Future<List<RentalInterest>> getLandlordInterests() async {
    try {
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) return [];

      final snapshot = await _firestore
          .collection('rental_interests')
          .where('landlordId', isEqualTo: currentUserId)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => RentalInterest.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting landlord interests: $e',
          name: 'RentalInterestService');
      return [];
    }
  }

  /// Stream interests for a landlord (real-time updates)
  Stream<List<RentalInterest>> streamLandlordInterests() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('rental_interests')
        .where('landlordId', isEqualTo: currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => RentalInterest.fromFirestore(doc.data(), doc.id))
          .toList();
    });
  }

  /// Get verified interests for a landlord (ready to accept)
  Future<List<RentalInterest>> getVerifiedInterestsForLandlord() async {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return [];

    try {
      final querySnapshot = await _firestore
          .collection('rental_interests')
          .where('landlordId', isEqualTo: currentUserId)
          .where('status', isEqualTo: 'payment_verified')
          .orderBy('paymentVerifiedAt', descending: true)
          .get();

      return querySnapshot.docs
          .map((doc) => RentalInterest.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting verified interests: $e',
          name: 'RentalInterestService');
      return [];
    }
  }
  
}