import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import '../shared/models/rental_interest_model.dart';
import '../shared/models/inspection_request_model.dart';
import 'auth_service.dart';

class RentalInterestService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AuthService _authService = AuthService();

  // ============ CREATE ============

  /// Create a rental interest when tenant says "I want to rent"
  Future<RentalInterest?> createRentalInterest({
    required InspectionRequest inspectionRequest,
    required double paymentAmount,
  }) async {
    try {
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) {
        throw Exception('User not authenticated');
      }

      // Verify this is the tenant who did the inspection
      if (inspectionRequest.tenantId != currentUserId) {
        throw Exception('Unauthorized: Only the tenant can express interest');
      }

      // Verify inspection is completed and rated
      if (!inspectionRequest.isCompleted || !inspectionRequest.tenantRated) {
        throw Exception('Inspection must be completed and rated first');
      }

      // Check if interest already exists
      final existing = await getInterestForInspection(inspectionRequest.id);
      if (existing != null) {
        return existing; // Already created
      }

      final interestData = {
        'inspectionRequestId': inspectionRequest.id,
        'propertyId': inspectionRequest.propertyId,
        'tenantId': inspectionRequest.tenantId,
        'landlordId': inspectionRequest.landlordId,
        'agentId': inspectionRequest.agentId,
        'propertyTitle': inspectionRequest.propertyTitle,
        'propertyImage': inspectionRequest.propertyImage,
        'propertyAddress': inspectionRequest.propertyAddress,
        'tenantName': inspectionRequest.tenantName,
        'landlordName': inspectionRequest.landlordName,
        'agentName': inspectionRequest.agentName,
        'status': 'pending_payment',
        'paymentAmount': paymentAmount,
        'paymentReceiptUrl': null,
        'paymentUploadedAt': null,
        'paymentVerifiedAt': null,
        'paymentVerifiedBy': null,
        'paymentRejectionReason': null,
        'acceptedAt': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef =
          await _firestore.collection('rental_interests').add(interestData);

      // Fetch the created document
      final doc = await docRef.get();
      if (doc.exists) {
        developer.log('✅ Rental interest created: ${docRef.id}',
            name: 'RentalInterestService');
        return RentalInterest.fromFirestore(doc.data()!, doc.id);
      }

      return null;
    } catch (e) {
      developer.log('❌ Error creating rental interest: $e',
          name: 'RentalInterestService');
      return null;
    }
  }

  // ============ PAYMENT FLOW ============

  /// Upload payment proof (called from rental_payment_screen)
  /// Screens call: uploadPaymentProof(interestId, imageUrl)
  Future<bool> uploadPaymentProof(String interestId, String receiptUrl) async {
    try {
      await _firestore
          .collection('rental_interests')
          .doc(interestId)
          .update({
        'paymentReceiptUrl': receiptUrl,
        'paymentUploadedAt': FieldValue.serverTimestamp(),
        'status': 'payment_uploaded',
        'paymentRejectionReason': null, // Clear any previous rejection
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Payment proof uploaded for interest: $interestId',
          name: 'RentalInterestService');
      return true;
    } catch (e) {
      developer.log('❌ Error uploading payment proof: $e',
          name: 'RentalInterestService');
      return false;
    }
  }

  // ============ ADMIN VERIFICATION ============

  /// Admin: Verify payment — LOCKS IN the landlord
  Future<bool> verifyRentalPayment(String interestId) async {
    try {
      final currentUserId = _authService.currentUserId;

      await _firestore
          .collection('rental_interests')
          .doc(interestId)
          .update({
        'status': 'payment_verified',
        'paymentVerifiedAt': FieldValue.serverTimestamp(),
        'paymentVerifiedBy': currentUserId,
        'paymentRejectionReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Payment verified (landlord locked in): $interestId',
          name: 'RentalInterestService');
      return true;
    } catch (e) {
      developer.log('❌ Error verifying payment: $e',
          name: 'RentalInterestService');
      return false;
    }
  }

  /// Admin: Reject payment — tenant must re-upload
  Future<bool> rejectRentalPayment(String interestId, String reason) async {
    try {
      await _firestore
          .collection('rental_interests')
          .doc(interestId)
          .update({
        'status': 'rejected',
        'paymentRejectionReason': reason,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Payment rejected: $interestId',
          name: 'RentalInterestService');
      return true;
    } catch (e) {
      developer.log('❌ Error rejecting payment: $e',
          name: 'RentalInterestService');
      return false;
    }
  }

  /// Mark rental interest as payment verified (called after Paystack success).
  /// Skips the 'paymentUploaded' state — goes directly to 'paymentVerified'.
  Future<bool> markPaymentVerified(
    String rentalInterestId, {
    String? paymentReference,
  }) async {
    try {
      await _firestore.collection('rental_interests').doc(rentalInterestId).update({
        'status': 'payment_verified',
        'isPaymentVerified': true,
        'paymentReference': paymentReference,
        'paymentVerifiedAt': FieldValue.serverTimestamp(),
        'paidAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Rental interest $rentalInterestId marked as paymentVerified',
          name: 'RentalInterestService');
      return true;
    } catch (e) {
      developer.log('❌ Error marking payment verified: $e',
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