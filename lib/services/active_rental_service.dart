import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import '../shared/models/active_rental_model.dart';
import '../shared/models/rental_interest_model.dart';
import '../shared/models/inspection_request_model.dart';
import 'auth_service.dart';

class ActiveRentalService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AuthService _authService = AuthService();

  // ============ CREATE ============

  /// Create active rental after landlord accepts verified interest.
  /// This is the method the landlord inspections screen calls:
  ///   _activeRentalService.createActiveRental(
  ///       rentalInterest: interest, inspectionRequest: widget.request);
  Future<ActiveRental?> createActiveRental({
    required RentalInterest rentalInterest,
    required InspectionRequest inspectionRequest,
  }) async {
    try {
      // Verify payment is verified or accepted
      if (!rentalInterest.isPaymentVerified &&
          rentalInterest.status != RentalInterestStatus.accepted) {
        throw Exception('Payment must be verified before creating rental');
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
        'rentAmount': rentalInterest.paymentAmount,
        'agentFee': 0.0,
        'totalPaid': rentalInterest.paymentAmount,
        'inspectionFeeCredit': 5000,
        'rentFrequency': 'yearly',
        'leaseStartDate': Timestamp.fromDate(leaseStart),
        'leaseEndDate': Timestamp.fromDate(leaseEnd),
        'nextPaymentDue': Timestamp.fromDate(nextPayment),
        'status': 'active',
        'hasPaymentReminder': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef =
          await _firestore.collection('active_rentals').add(rentalData);

      // Update property status — mark as rented
      await _updatePropertyStatus(
          rentalInterest.propertyId, rentalInterest.tenantId, true);

      // Update tenant status — mark as having active rental
      await _updateTenantStatus(
          rentalInterest.tenantId,
          rentalInterest.propertyId,
          docRef.id,
          true);

      // Fetch created document
      final doc = await docRef.get();
      if (doc.exists) {
        developer.log('✅ Active rental created: ${docRef.id}',
            name: 'ActiveRentalService');
        return ActiveRental.fromFirestore(doc.data()!, doc.id);
      }

      return null;
    } catch (e) {
      developer.log('❌ Error creating rental: $e',
          name: 'ActiveRentalService');
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
      final leaseEnd = rentFrequency == 'yearly'
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

      final docRef =
          await _firestore.collection('active_rentals').add(rentalData);

      await _updatePropertyStatus(
          interest.propertyId, interest.tenantId, true);
      await _updateTenantStatus(
          interest.tenantId, interest.propertyId, docRef.id, true);

      final doc = await docRef.get();
      if (doc.exists) {
        developer.log('✅ Active rental created: ${docRef.id}',
            name: 'ActiveRentalService');
        return ActiveRental.fromFirestore(doc.data()!, doc.id);
      }
      return null;
    } catch (e) {
      developer.log('❌ Error creating rental: $e',
          name: 'ActiveRentalService');
      return null;
    }
  }

  // ============ HELPERS ============

  /// Update property status (mark as rented/available)
  Future<void> _updatePropertyStatus(
      String propertyId, String tenantId, bool isRented) async {
    try {
      await _firestore.collection('properties').doc(propertyId).update({
        'isAvailable': !isRented,
        'rentedToTenantId': isRented ? tenantId : null,
        'rentalStartDate': isRented ? FieldValue.serverTimestamp() : null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Property status updated: $propertyId',
          name: 'ActiveRentalService');
    } catch (e) {
      developer.log('❌ Error updating property status: $e',
          name: 'ActiveRentalService');
    }
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
      developer.log('✅ Tenant status updated: $tenantId',
          name: 'ActiveRentalService');
    } catch (e) {
      developer.log('❌ Error updating tenant status: $e',
          name: 'ActiveRentalService');
    }
  }

  // ============ READ ============

  /// Get active rental for current tenant
  Future<ActiveRental?> getTenantActiveRental() async {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return null;

    try {
      final querySnapshot = await _firestore
          .collection('active_rentals')
          .where('tenantId', isEqualTo: currentUserId)
          .where('status', isEqualTo: 'active')
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) return null;

      final doc = querySnapshot.docs.first;
      return ActiveRental.fromFirestore(doc.data(), doc.id);
    } catch (e) {
      developer.log('❌ Error getting tenant active rental: $e',
          name: 'ActiveRentalService');
      return null;
    }
  }

  /// Get ALL rentals for the current tenant (active + past)
  /// Used by: my_rentals_screen.dart, documents_screen.dart
  Future<List<ActiveRental>> getTenantRentals() async {
    try {
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) return [];

      final snapshot = await _firestore
          .collection('active_rentals')
          .where('tenantId', isEqualTo: currentUserId)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting tenant rentals: $e',
          name: 'ActiveRentalService');
      return [];
    }
  }

  /// Get active rental by ID
  Future<ActiveRental?> getRentalById(String rentalId) async {
    try {
      final doc = await _firestore
          .collection('active_rentals')
          .doc(rentalId)
          .get();

      if (!doc.exists) return null;

      return ActiveRental.fromFirestore(doc.data()!, doc.id);
    } catch (e) {
      developer.log('❌ Error getting rental by ID: $e',
          name: 'ActiveRentalService');
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

  /// Get all rentals for a landlord
  Future<List<ActiveRental>> getLandlordRentals() async {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) return [];

    try {
      final querySnapshot = await _firestore
          .collection('active_rentals')
          .where('landlordId', isEqualTo: currentUserId)
          .orderBy('createdAt', descending: true)
          .get();

      return querySnapshot.docs
          .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting landlord rentals: $e',
          name: 'ActiveRentalService');
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
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify tenant via activities collection
      final doc = await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_uploaded',
          'title': 'Tenancy Agreement Ready',
          'message': 'Your landlord has uploaded the tenancy agreement for ${data['propertyTitle']}.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Agreement uploaded for rental: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error uploading agreement: $e',
          name: 'ActiveRentalService');
      return false;
    }
  }

   Future<bool> sendAgreementToTenant(String rentalId, String agreementUrl) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementUrl': agreementUrl,
        'agreementUploadedAt': FieldValue.serverTimestamp(),
        'agreementStatus': 'pending_review',
        'tenantDisputeReason': null, // Clear any previous dispute
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify tenant
      final doc = await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_uploaded',
          'title': 'Tenancy Agreement Ready for Review',
          'message': 'Your landlord has sent the tenancy agreement for ${data['propertyTitle']}. Please review and accept or raise any concerns.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Agreement sent to tenant for rental: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error sending agreement: $e',
          name: 'ActiveRentalService');
      return false;
    }
  }

  /// Tenant accepts the agreement
  Future<bool> tenantAcceptAgreement(String rentalId) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementStatus': 'accepted',
        'tenantAcceptedAt': FieldValue.serverTimestamp(),
        'tenantDisputeReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify landlord
      final doc = await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['landlordId'],
          'type': 'agreement_accepted',
          'title': 'Tenant Accepted Agreement',
          'message': '${data['tenantName']} has accepted the tenancy agreement for ${data['propertyTitle']}. You can now finalize it.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Tenant accepted agreement: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error accepting agreement: $e',
          name: 'ActiveRentalService');
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

      // Notify landlord
      final doc = await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['landlordId'],
          'type': 'agreement_disputed',
          'title': 'Tenant Has Concerns About Agreement',
          'message': '${data['tenantName']} has raised concerns about the agreement for ${data['propertyTitle']}: "$reason"',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Tenant disputed agreement: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error disputing agreement: $e',
          name: 'ActiveRentalService');
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

      // Notify tenant
      final doc = await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_finalized',
          'title': 'Tenancy Agreement Finalized',
          'message': 'Your tenancy agreement for ${data['propertyTitle']} has been finalized by your landlord. For full legal protection, consider getting it stamped at your local tax office (LIRS/SIRS).',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Agreement finalized: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error finalizing agreement: $e',
          name: 'ActiveRentalService');
      return false;
    }
  }

  /// Landlord re-uploads a revised agreement (after dispute)
  /// Resets status back to pending_review
  Future<bool> reuploadAgreement(String rentalId, String newAgreementUrl) async {
    try {
      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agreementUrl': newAgreementUrl,
        'agreementUploadedAt': FieldValue.serverTimestamp(),
        'agreementStatus': 'pending_review',
        'tenantDisputeReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final doc = await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_updated',
          'title': 'Updated Agreement Available',
          'message': 'Your landlord has uploaded a revised agreement for ${data['propertyTitle']}. Please review.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Agreement re-uploaded: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error re-uploading agreement: $e',
          name: 'ActiveRentalService');
      return false;
    }
  }


  // ============ UPDATE ============

  /// Toggle payment reminder
  Future<bool> togglePaymentReminder(String rentalId, bool enabled) async {
    try {
      await _firestore
          .collection('active_rentals')
          .doc(rentalId)
          .update({
        'hasPaymentReminder': enabled,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Payment reminder toggled: $rentalId -> $enabled',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error toggling payment reminder: $e',
          name: 'ActiveRentalService');
      return false;
    }
  }

  /// Terminate rental (early termination)
  Future<bool> terminateRental(String rentalId) async {
    try {
      final rental = await getRentalById(rentalId);
      if (rental == null) return false;

      await _firestore
          .collection('active_rentals')
          .doc(rentalId)
          .update({
        'status': 'terminated',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Update property and tenant status
      await _updatePropertyStatus(
          rental.propertyId, rental.tenantId, false);
      await _updateTenantStatus(
          rental.tenantId, rental.propertyId, rentalId, false);

      developer.log('✅ Rental terminated: $rentalId',
          name: 'ActiveRentalService');
      return true;
    } catch (e) {
      developer.log('❌ Error terminating rental: $e',
          name: 'ActiveRentalService');
      return false;
    }
  }

  /// Check and update rental statuses based on dates
  Future<void> updateRentalStatuses() async {
    try {
      final now = DateTime.now();
      final querySnapshot = await _firestore
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
          developer.log('✅ Rental expired: ${doc.id}',
              name: 'ActiveRentalService');
        } else if (rental.daysUntilLeaseEnd <= 30 &&
            rental.daysUntilLeaseEnd > 0) {
          await doc.reference.update({
            'status': 'expiring_soon',
            'updatedAt': FieldValue.serverTimestamp(),
          });
          developer.log('✅ Rental expiring soon: ${doc.id}',
              name: 'ActiveRentalService');
        }
      }
    } catch (e) {
      developer.log('❌ Error updating rental statuses: $e',
          name: 'ActiveRentalService');
    }
  }
}