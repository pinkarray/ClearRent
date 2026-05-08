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
        'rentAmount':
            rentalInterest.rentAmount > 0
                ? rentalInterest.rentAmount
                : rentalInterest.paymentAmount,
        'agentFee': rentalInterest.agentFee,
        'totalPaid': rentalInterest.paymentAmount,
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
        'status': 'active',
        'hasPaymentReminder': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore
          .collection('active_rentals')
          .add(rentalData);

      // Update property status — mark as rented
      await _updatePropertyStatus(
        rentalInterest.propertyId,
        rentalInterest.tenantId,
        true,
      );

      // Update tenant status — mark as having active rental
      await _updateTenantStatus(
        rentalInterest.tenantId,
        rentalInterest.propertyId,
        docRef.id,
        true,
      );

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
  Future<void> _updatePropertyStatus(
    String propertyId,
    String tenantId,
    bool isRented,
  ) async {
    try {
      final propertyDoc =
          await _firestore.collection('properties').doc(propertyId).get();
      final propertyData = propertyDoc.data();

      final maxTenants = (propertyData?['maxTenants'] as num?)?.toInt() ?? 1;
      final currentCount =
          (propertyData?['currentTenantsCount'] as num?)?.toInt() ?? 0;

      final newCount =
          isRented ? currentCount + 1 : (currentCount - 1).clamp(0, maxTenants);

      // Only mark unavailable when every slot is filled
      final nowFull = newCount >= maxTenants;
      // Only mark available again when count drops to 0
      final nowEmpty = newCount <= 0;

      final Map<String, dynamic> updates = {
        'currentTenantsCount': newCount,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (isRented) {
        updates['rentedToTenantId'] = tenantId;
        updates['rentalStartDate'] = FieldValue.serverTimestamp();
        if (nowFull) updates['isAvailable'] = false;
      } else {
        updates['rentedToTenantId'] = null;
        if (nowEmpty) updates['isAvailable'] = true;
      }

      await _firestore.collection('properties').doc(propertyId).update(updates);

      developer.log(
        '✅ Property $propertyId: tenants $currentCount → $newCount / $maxTenants',
        name: 'ActiveRentalService',
      );
    } catch (e) {
      developer.log(
        '❌ Error updating property status: $e',
        name: 'ActiveRentalService',
      );
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
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify tenant via activities collection
      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_uploaded',
          'title': 'Tenancy Agreement Ready',
          'message':
              'Your landlord has uploaded the tenancy agreement for ${data['propertyTitle']}.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

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

      // Notify tenant
      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_uploaded',
          'title': 'Tenancy Agreement Ready for Review',
          'message':
              'Your landlord has sent the tenancy agreement for ${data['propertyTitle']}. Please review and accept or raise any concerns.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

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
      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['landlordId'],
          'type': 'agreement_accepted',
          'title': 'Tenant Accepted Agreement',
          'message':
              '${data['tenantName']} has accepted the tenancy agreement for ${data['propertyTitle']}. You can now finalize it.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

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

      // Notify landlord
      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['landlordId'],
          'type': 'agreement_disputed',
          'title': 'Tenant Has Concerns About Agreement',
          'message':
              '${data['tenantName']} has raised concerns about the agreement for ${data['propertyTitle']}: "$reason"',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

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

      // Notify tenant
      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_finalized',
          'title': 'Tenancy Agreement Finalized',
          'message':
              'Your tenancy agreement for ${data['propertyTitle']} has been finalized by your landlord. For full legal protection, consider getting it stamped at your local tax office (LIRS/SIRS).',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

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

      final doc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = doc.data();
      if (data != null) {
        await _firestore.collection('activities').add({
          'userId': data['tenantId'],
          'type': 'agreement_updated',
          'title': 'Updated Agreement Available',
          'message':
              'Your landlord has uploaded a revised agreement for ${data['propertyTitle']}. Please review.',
          'propertyId': data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

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

  // ══════════════════════════════════════════════════════════════
  // RENT PAYOUT METHODS (admin)
  // ══════════════════════════════════════════════════════════════

  /// Get all active rentals where landlord payout is pending
  Stream<List<ActiveRental>> getPendingLandlordPayouts() {
    return _firestore
        .collection('active_rentals')
        .where('landlordPayoutStatus', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
                  .toList(),
        );
  }

  /// Get all active rentals where agent payout is pending
  Stream<List<ActiveRental>> getPendingAgentRentPayouts() {
    return _firestore
        .collection('active_rentals')
        .where('agentPayoutStatus', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
                  .toList(),
        );
  }

  /// Get all completed rent payouts (landlord or agent paid)
  Stream<List<ActiveRental>> getCompletedRentPayouts() {
    return _firestore
        .collection('active_rentals')
        .where('landlordPayoutStatus', isEqualTo: 'paid')
        .orderBy('landlordPaidAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
                  .toList(),
        );
  }

  /// Get bank details for a user (landlord or agent)
  Future<Map<String, dynamic>?> getUserBankDetails(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (!doc.exists) return null;
      final data = doc.data()!;
      final bankDetails = data['bankDetails'] as Map<String, dynamic>? ?? {};
      return {
        'fullName': data['fullName'] ?? data['name'] ?? '',
        'bankName': bankDetails['bankName'] ?? data['bankName'] ?? '',
        'accountNumber':
            bankDetails['accountNumber'] ?? data['accountNumber'] ?? '',
        'accountName': bankDetails['accountName'] ?? data['accountName'] ?? '',
        'phone': data['phone'] ?? '',
      };
    } catch (e) {
      developer.log(
        '❌ Error getting bank details: $e',
        name: 'ActiveRentalService',
      );
      return null;
    }
  }

  /// Admin marks landlord as paid for a rental
  Future<bool> markLandlordPaid(String rentalId) async {
    try {
      final rentalDoc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = rentalDoc.data();
      if (data == null) return false;

      await _firestore.collection('active_rentals').doc(rentalId).update({
        'landlordPayoutStatus': 'paid',
        'landlordPaidAt': FieldValue.serverTimestamp(),
        'landlordPaidBy': _authService.currentUserId,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Create activity for landlord
      final landlordId = data['landlordId'];
      if (landlordId != null) {
        final payout = (data['landlordPayout'] ?? 0).toDouble();
        await _firestore.collection('activities').add({
          'landlordId': landlordId,
          'type': 'rent_payout',
          'title': 'Rent Payout Sent',
          'message':
              'Your rent payout of ₦${payout.toStringAsFixed(0)} for ${data['propertyTitle']} has been sent to your bank account.',
          'propertyId': data['propertyId'],
          'rentalId': rentalId,
          'amount': payout,
          'actorId': _authService.currentUserId,
          'actorName': 'ClearRent Admin',
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Record in payments collection for documents screen
        await _firestore
            .collection('payments')
            .doc('PAYOUT_LANDLORD_$rentalId')
            .set({
              'reference': 'PAYOUT_LANDLORD_$rentalId',
              'userId': landlordId,
              'type': 'rent_payout',
              'amount': payout,
              'status': 'completed',
              'relatedId': rentalId,
              'propertyId': data['propertyId'],
              'propertyTitle': data['propertyTitle'],
              'description': 'Rent payout for ${data['propertyTitle']}',
              'createdAt': FieldValue.serverTimestamp(),
            });
      }

      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking landlord paid: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }

  /// Admin marks agent as paid for their rental cut
  Future<bool> markAgentRentPaid(String rentalId) async {
    try {
      final rentalDoc =
          await _firestore.collection('active_rentals').doc(rentalId).get();
      final data = rentalDoc.data();
      if (data == null) return false;

      await _firestore.collection('active_rentals').doc(rentalId).update({
        'agentPayoutStatus': 'paid',
        'agentPaidAt': FieldValue.serverTimestamp(),
        'agentPaidBy': _authService.currentUserId,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Create activity for agent
      final agentId = data['agentId'];
      if (agentId != null) {
        final payout = (data['agentPayout'] ?? 0).toDouble();
        await _firestore.collection('activities').add({
          'landlordId':
              agentId, // activity stream uses landlordId as the owner field
          'type': 'rent_payout',
          'title': 'Agent Fee Payout Sent',
          'message':
              'Your agent fee payout of ₦${payout.toStringAsFixed(0)} for ${data['propertyTitle']} has been sent to your bank account.',
          'propertyId': data['propertyId'],
          'rentalId': rentalId,
          'amount': payout,
          'actorId': _authService.currentUserId,
          'actorName': 'ClearRent Admin',
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Record in payments collection for documents screen
        await _firestore
            .collection('payments')
            .doc('PAYOUT_AGENT_$rentalId')
            .set({
              'reference': 'PAYOUT_AGENT_$rentalId',
              'userId': agentId,
              'type': 'rent_payout',
              'amount': payout,
              'status': 'completed',
              'relatedId': rentalId,
              'propertyId': data['propertyId'],
              'propertyTitle': data['propertyTitle'],
              'description': 'Agent fee payout for ${data['propertyTitle']}',
              'createdAt': FieldValue.serverTimestamp(),
            });
      }

      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking agent rent paid: $e',
        name: 'ActiveRentalService',
      );
      return false;
    }
  }
}
