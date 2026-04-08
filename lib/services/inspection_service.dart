import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../shared/models/inspection_request_model.dart';
import '../shared/models/property_model.dart';
import '../core/utils/inspection_pricing.dart';

class InspectionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get _currentUserId => _auth.currentUser?.uid;

  // Time slot display mapping
  static const Map<String, String> timeSlotDisplay = {
    'morning': '9:00 AM - 12:00 PM',
    'afternoon': '12:00 PM - 3:00 PM',
    'late_afternoon': '3:00 PM - 6:00 PM',
    'evening': '6:00 PM - 8:00 PM',
  };

  static const Map<String, String> timeSlotLabels = {
    'morning': 'Morning',
    'afternoon': 'Afternoon',
    'late_afternoon': 'Late Afternoon',
    'evening': 'Evening',
  };

  // ============ PRICING CALCULATION ============

  /// Resolves the property's area/cluster from its address, LGA, or city fields.
  /// Tries address first (most specific), then LGA, then city.
  String? _resolvePropertyArea(PropertyModel property) {
    // Try address — extract the most likely area name
    final address = property.address.trim();
    if (address.isNotEmpty) {
      // Try each comma-separated segment (e.g. "12 Adeola Odeku, Victoria Island, Lagos")
      final segments = address.split(',').map((s) => s.trim()).toList();
      for (final segment in segments) {
        if (InspectionPricing.getClusterForArea(segment) != null) {
          return segment;
        }
      }
    }

    // Try LGA
    final lga = property.lga.trim();
    if (lga.isNotEmpty && InspectionPricing.getClusterForArea(lga) != null) {
      return lga;
    }

    // Try city
    final city = property.city.trim();
    if (city.isNotEmpty && InspectionPricing.getClusterForArea(city) != null) {
      return city;
    }

    return null;
  }

  Future<InspectionFeeBreakdown?> calculateInspectionFee({
    required PropertyModel property,
  }) async {
    // Agent-handled: calculate from agent's baseLocation to property area
    if (property.inspectionHandler == 'agent') {
      if (property.assignedAgentId == null) return null;

      try {
        final agentDoc = await _firestore
            .collection('users')
            .doc(property.assignedAgentId)
            .get();

        if (!agentDoc.exists) return null;

        final agentData = agentDoc.data()!;
        final agentBaseLocation = agentData['baseLocation'] as String? ?? '';

        final agentCluster = InspectionPricing.getClusterForArea(agentBaseLocation);
        final propertyArea = _resolvePropertyArea(property);
        final propertyCluster = propertyArea != null
            ? InspectionPricing.getClusterForArea(propertyArea)
            : null;

        if (agentCluster == null) {
          developer.log(
            '\u26a0\ufe0f Agent baseLocation "$agentBaseLocation" not mapped to any cluster, using same-zone fallback.',
            name: 'InspectionService',
          );
        }

        if (propertyCluster == null) {
          developer.log(
            '\u26a0\ufe0f Property area not resolved (address: "${property.address}", lga: "${property.lga}"), using same-zone fallback.',
            name: 'InspectionService',
          );
        }

        // If either cluster is unknown, assume same-zone (minimum transport)
        return InspectionPricing.calculateFee(
          agentCluster: agentCluster ?? propertyCluster ?? 'maryland_ikeja',
          propertyCluster: propertyCluster ?? agentCluster ?? 'maryland_ikeja',
          propertyArea: propertyArea,
        );
      } catch (e) {
        developer.log(
          '\u274c Error calculating agent fee: $e',
          name: 'InspectionService',
        );
        return null;
      }
    }

    // Self-handled by landlord
    if (property.inspectionHandler == 'self') {
      final propertyArea = _resolvePropertyArea(property);
      final propertyCluster = propertyArea != null
          ? InspectionPricing.getClusterForArea(propertyArea)
          : null;

      if (property.landlordLivesInProperty == true) {
        return InspectionPricing.calculateSelfHandledFee(
          landlordLivesInProperty: true,
          propertyCluster: propertyCluster ?? 'maryland_ikeja',
          propertyArea: propertyArea,
        );
      }

      // Landlord lives elsewhere — get their baseLocation
      try {
        final landlordDoc = await _firestore
            .collection('users')
            .doc(property.landlordId)
            .get();

        String? landlordCluster;
        if (landlordDoc.exists) {
          final landlordData = landlordDoc.data()!;
          final landlordBase = landlordData['baseLocation'] as String? ?? '';
          landlordCluster = InspectionPricing.getClusterForArea(landlordBase);
        }

        return InspectionPricing.calculateSelfHandledFee(
          landlordLivesInProperty: false,
          propertyCluster: propertyCluster ?? 'maryland_ikeja',
          landlordCluster: landlordCluster,
          propertyArea: propertyArea,
        );
      } catch (e) {
        developer.log(
          '\u274c Error calculating landlord fee: $e',
          name: 'InspectionService',
        );
        return InspectionPricing.calculateSelfHandledFee(
          landlordLivesInProperty: true,
          propertyCluster: propertyCluster ?? 'maryland_ikeja',
        );
      }
    }

    return null;
  }

  // ============ VERIFICATION CHECK ============

  Future<bool> _isUserVerified(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) return false;

      final userData = userDoc.data();
      final verificationStatus = userData?['verificationStatus'] ?? 'none';
      return verificationStatus == 'verified';
    } catch (e) {
      developer.log(
        'Error checking verification: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  // ============ CREATE INSPECTION REQUEST ============

  Future<String?> createInspectionRequest({
    required PropertyModel property,
    required DateTime requestedDate,
    required String requestedTimeSlot,
    String? notes,
    InspectionFeeBreakdown? feeBreakdown,
    String? paymentReference,
    String? paymentProofUrl,
    String? paymentStatus,
  }) async {
    try {
      if (_currentUserId == null) {
        developer.log('❌ User not authenticated', name: 'InspectionService');
        return null;
      }

      final tenantDoc =
          await _firestore.collection('users').doc(_currentUserId).get();
      final tenantData = tenantDoc.data();

      final tenantVerificationStatus =
          tenantData?['verificationStatus'] ?? 'none';
      if (tenantVerificationStatus != 'verified') {
        developer.log('❌ Tenant not verified', name: 'InspectionService');
        return 'not_verified';
      }

      final landlordVerified = await _isUserVerified(property.landlordId);
      if (!landlordVerified) {
        developer.log('❌ Landlord not verified', name: 'InspectionService');
        return 'landlord_not_verified';
      }

      final tenantName = tenantData?['fullName'] ?? 'Tenant';
      final tenantPhone = tenantData?['phone'];

      final existingRequest =
          await _firestore
              .collection('inspection_requests')
              .where('propertyId', isEqualTo: property.id)
              .where('tenantId', isEqualTo: _currentUserId)
              .where(
                'status',
                whereIn: ['pending', 'approved', 'declinedByAgent'],
              )
              .get();

      if (existingRequest.docs.isNotEmpty) {
        developer.log(
          '❌ Tenant already has active request',
          name: 'InspectionService',
        );
        return 'already_pending';
      }

      final isAgentHandled =
          property.inspectionHandler == 'agent' &&
          property.assignedAgentId != null;

      String? agentName;
      String? agentPhone;
      double? agentLat;
      double? agentLon;
      String? agentBaseLocation;

      if (isAgentHandled) {
        final agentVerified = await _isUserVerified(property.assignedAgentId!);
        if (!agentVerified) {
          developer.log('❌ Agent not verified', name: 'InspectionService');
          return 'agent_not_verified';
        }

        final agentDoc =
            await _firestore
                .collection('users')
                .doc(property.assignedAgentId)
                .get();

        if (agentDoc.exists) {
          final agentData = agentDoc.data()!;
          agentName = agentData['fullName'];
          agentPhone = agentData['phone'];
          agentLat = agentData['baseLatitude']?.toDouble();
          agentLon = agentData['baseLongitude']?.toDouble();
          agentBaseLocation = agentData['baseLocation'] as String?;
        }
      }

      final requestData = {
        'propertyId': property.id,
        'propertyTitle': property.title,
        'propertyImage':
            property.images.isNotEmpty ? property.images.first : '',
        'propertyAddress': '${property.address}, ${property.city}',
        'propertyLatitude': property.latitude,
        'propertyLongitude': property.longitude,

        'tenantId': _currentUserId,
        'tenantName': tenantName,
        'tenantPhone': tenantPhone,

        'landlordId': property.landlordId,
        'landlordName': property.landlordName ?? 'Landlord',
        'landlordPhone': property.landlordPhone,

        'agentId': isAgentHandled ? property.assignedAgentId : null,
        'agentName': agentName,
        'agentPhone': agentPhone,
        'agentLatitude': agentLat,
        'agentLongitude': agentLon,
        'agentBaseLocation': agentBaseLocation,

        'requestedDate': Timestamp.fromDate(requestedDate),
        'requestedTimeSlot': requestedTimeSlot,
        'requestedTimeDisplay':
            timeSlotDisplay[requestedTimeSlot] ?? requestedTimeSlot,
        'notes': notes,

        'agentCluster': feeBreakdown?.agentCluster,
        'propertyCluster': feeBreakdown?.propertyCluster,
        'propertyArea': feeBreakdown?.propertyArea,
        'transportFee': feeBreakdown?.transportFee ?? 0,
        'agentServiceFee': feeBreakdown?.agentServiceFee ?? 0,
        'clearrentFee': feeBreakdown?.clearrentEarnings ?? 0,
        'totalFee': feeBreakdown?.totalFee ?? 0,
        'agentEarnings': feeBreakdown?.agentEarnings ?? 0,

        'paymentStatus':
            paymentStatus ??
            (feeBreakdown != null && feeBreakdown.totalFee > 0
                ? 'pending_verification'
                : 'not_required'),
        'paymentReference': paymentReference,
        'paymentProofUrl': paymentProofUrl,
        'paidAt': null,
        'paymentVerifiedAt': null,
        'paymentVerifiedBy': null,
        'refundedAt': null,
        'refundReason': null,

        // If payment proof was uploaded, go to pendingVerification.
        // If fee is required but no proof yet, go to pendingPayment.
        // If no fee at all, go straight to pending.
        'status': paymentProofUrl != null
            ? 'pendingVerification'
            : (feeBreakdown != null && feeBreakdown.totalFee > 0
                ? 'pendingPayment'
                : 'pending'),
        'declinedBy': null,
        'declineReason': null,
        'declinedAt': null,
        'landlordOverrideDeadline': null,

        'wasOverridden': false,
        'overriddenBy': null,
        'originalDeclineBy': null,

        'completedAt': null,
        'tenantRating': null,
        'tenantReview': null,

        'tenantArrived': false,
        'tenantArrivedAt': null,
        'handlerArrived': false,
        'handlerArrivedAt': null,

        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore
          .collection('inspection_requests')
          .add(requestData);

      developer.log(
        'âœ… Inspection request created: ${docRef.id}',
        name: 'InspectionService',
      );

      await _firestore.collection('properties').doc(property.id).update({
        'inquiryCount': FieldValue.increment(1),
      });

      if (isAgentHandled) {
        await _createActivity(
          userId: property.assignedAgentId!,
          type: 'inspection_request',
          title: 'New Inspection Request',
          message: '$tenantName wants to inspect ${property.title}',
          relatedId: docRef.id,
          propertyId: property.id,
        );

        await _createActivity(
          userId: property.landlordId,
          type: 'inspection_request_agent',
          title: 'New Inspection Request',
          message:
              '$tenantName requested inspection for ${property.title}. $agentName will handle.',
          relatedId: docRef.id,
          propertyId: property.id,
        );
      } else {
        await _createActivity(
          userId: property.landlordId,
          type: 'inspection_request',
          title: 'New Inspection Request',
          message: '$tenantName wants to inspect ${property.title}',
          relatedId: docRef.id,
          propertyId: property.id,
        );
      }

      return docRef.id;
    } catch (e) {
      developer.log(
        '❌ Error creating inspection request: $e',
        name: 'InspectionService',
      );
      return null;
    }
  }

  // ============ GET REQUESTS ============

  Stream<List<InspectionRequest>> getTenantRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('tenantId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          developer.log(
            'ðŸ“‹ Tenant requests count: ${snapshot.docs.length}',
            name: 'InspectionService',
          );
          return snapshot.docs.map((doc) {
            final data = doc.data();
            developer.log(
              '  - Raw status: "${data['status']}"',
              name: 'InspectionService',
            );
            final request = InspectionRequest.fromFirestore(data, doc.id);
            developer.log(
              '  - ${request.propertyTitle}: parsed=${request.status.name}, isApproved=${request.isApproved}',
              name: 'InspectionService',
            );
            return request;
          }).toList();
        });
  }

  Stream<List<InspectionRequest>> getLandlordRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('landlordId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          developer.log(
            'ðŸ“‹ Landlord requests count: ${snapshot.docs.length}',
            name: 'InspectionService',
          );
          return snapshot.docs.map((doc) {
            final data = doc.data();
            developer.log(
              '  - Raw status: "${data['status']}"',
              name: 'InspectionService',
            );
            final request = InspectionRequest.fromFirestore(data, doc.id);
            developer.log(
              '  - ${request.propertyTitle}: parsed=${request.status.name}, isApproved=${request.isApproved}',
              name: 'InspectionService',
            );
            return request;
          }).toList();
        });
  }

  Stream<List<InspectionRequest>> getLandlordPendingRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('landlordId', isEqualTo: _currentUserId)
        .where('status', whereIn: ['pending', 'declinedByAgent'])
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        InspectionRequest.fromFirestore(doc.data(), doc.id),
                  )
                  .toList(),
        );
  }

  Stream<List<InspectionRequest>> getAgentRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('agentId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          developer.log(
            'ðŸ“‹ Agent requests count: ${snapshot.docs.length}',
            name: 'InspectionService',
          );
          return snapshot.docs.map((doc) {
            final data = doc.data();
            developer.log(
              '  - Raw Firestore status: "${data['status']}"',
              name: 'InspectionService',
            );
            final request = InspectionRequest.fromFirestore(data, doc.id);
            developer.log(
              '  - ${request.propertyTitle}: parsed=${request.status.name}, isApproved=${request.isApproved}',
              name: 'InspectionService',
            );
            return request;
          }).toList();
        });
  }

  Stream<List<InspectionRequest>> getAgentPendingRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('agentId', isEqualTo: _currentUserId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        InspectionRequest.fromFirestore(doc.data(), doc.id),
                  )
                  .toList(),
        );
  }

  Stream<List<InspectionRequest>> getPropertyRequests(String propertyId) {
    return _firestore
        .collection('inspection_requests')
        .where('propertyId', isEqualTo: propertyId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        InspectionRequest.fromFirestore(doc.data(), doc.id),
                  )
                  .toList(),
        );
  }

  // ============ APPROVE / DECLINE ============

  Future<bool> approveRequest(
    String requestId, {
    bool isLandlordOverride = false,
  }) async {
    try {
      developer.log(
        'ðŸ”„ Approving request: $requestId (override: $isLandlordOverride)',
        name: 'InspectionService',
      );

      final updates = <String, dynamic>{
        'status': 'approved',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (isLandlordOverride) {
        updates['wasOverridden'] = true;
        updates['overriddenBy'] = _currentUserId;
      }

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update(updates);

      developer.log(
        'âœ… Firestore updated with status: approved',
        name: 'InspectionService',
      );

      // Verify the update
      final verifyDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      developer.log(
        'ðŸ” Verification - status in Firestore: "${verifyDoc.data()?['status']}"',
        name: 'InspectionService',
      );

      final requestData = verifyDoc.data();

      if (requestData != null) {
        final approvedBy =
            isLandlordOverride
                ? 'Landlord'
                : (requestData['agentId'] != null ? 'Agent' : 'Landlord');

        await _createActivity(
          userId: requestData['tenantId'],
          type: 'inspection_approved',
          title: 'Inspection Approved!',
          message:
              'Your inspection for ${requestData['propertyTitle']} has been approved by $approvedBy',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );

        if (isLandlordOverride && requestData['agentId'] != null) {
          await _createActivity(
            userId: requestData['agentId'],
            type: 'landlord_override',
            title: 'Landlord Override',
            message:
                'Landlord approved the inspection you declined for ${requestData['propertyTitle']}',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );
        }

        if (!isLandlordOverride && requestData['agentId'] != null) {
          await _createActivity(
            userId: requestData['landlordId'],
            type: 'agent_approved',
            title: 'Inspection Approved',
            message:
                '${requestData['agentName']} approved inspection for ${requestData['propertyTitle']}',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );
        }

        // Notify agent when landlord approves
        if (requestData['agentId'] != null &&
            _currentUserId == requestData['landlordId']) {
          await _createActivity(
            userId: requestData['agentId'],
            type: 'inspection_approved',
            title: 'Inspection Scheduled',
            message:
                'You have an inspection to conduct for ${requestData['propertyTitle']} - ${requestData['requestedTimeDisplay']}',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );
        }
      }

      developer.log(
        'âœ… Request approved: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error approving request: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> agentDeclineRequest(String requestId, {String? reason}) async {
    try {
      final deadline = DateTime.now().add(const Duration(hours: 12));

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'declinedByAgent',
        'declinedBy': 'agent',
        'declineReason': reason,
        'declinedAt': FieldValue.serverTimestamp(),
        'landlordOverrideDeadline': Timestamp.fromDate(deadline),
        'originalDeclineBy': 'agent',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();

      if (requestData != null) {
        await _createActivity(
          userId: requestData['landlordId'],
          type: 'agent_declined',
          title: 'Agent Declined Inspection',
          message:
              '${requestData['agentName']} declined inspection for ${requestData['propertyTitle']}. You have 12 hours to approve if you want.',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      developer.log(
        'âœ… Agent declined request: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error declining request: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> finalDeclineRequest(String requestId, {String? reason}) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'declined',
        'declinedBy': _currentUserId != null ? 'landlord' : 'system',
        'declineReason':
            reason ?? 'Request was not approved within the time window',
        'declinedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();

      if (requestData != null) {
        await _createActivity(
          userId: requestData['tenantId'],
          type: 'inspection_declined',
          title: 'Inspection Request Declined',
          message:
              reason ??
              'Your inspection for ${requestData['propertyTitle']} was declined. A refund will be processed.',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );

        if (requestData['paymentStatus'] == 'paid') {
          await _processRefund(requestId, requestData);
        }
      }

      developer.log(
        'âœ… Request finally declined: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error declining request: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> landlordDeclineRequest(
    String requestId, {
    String? reason,
  }) async {
    try {
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();

      if (requestData == null) return false;

      final isOverride =
          requestData['status'] == 'approved' && requestData['agentId'] != null;

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'declined',
        'declinedBy': 'landlord',
        'declineReason': reason,
        'declinedAt': FieldValue.serverTimestamp(),
        'wasOverridden': isOverride,
        'overriddenBy': isOverride ? _currentUserId : null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _createActivity(
        userId: requestData['tenantId'],
        type: 'inspection_declined',
        title: 'Inspection Request Declined',
        message:
            reason ??
            'Your inspection for ${requestData['propertyTitle']} was declined by the landlord.',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      if (isOverride && requestData['agentId'] != null) {
        await _createActivity(
          userId: requestData['agentId'],
          type: 'landlord_override',
          title: 'Landlord Override',
          message:
              'Landlord declined the inspection you approved for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      if (requestData['paymentStatus'] == 'paid') {
        await _processRefund(requestId, requestData);
      }

      developer.log(
        'âœ… Landlord declined request: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error declining request: $e', name: 'InspectionService');
      return false;
    }
  }

  // ============ ARRIVAL CONFIRMATION ============

  /// Mark the tenant as arrived at the inspection location
  Future<bool> markTenantArrived(String requestId) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'tenantArrived': true,
        'tenantArrivedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify the handler
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final data = requestDoc.data();
      if (data != null) {
        if (data['agentId'] != null) {
          await _createActivity(
            userId: data['agentId'],
            type: 'tenant_arrived',
            title: 'Tenant Has Arrived',
            message:
                '${data['tenantName']} has arrived for the inspection at ${data['propertyTitle']}',
            relatedId: requestId,
            propertyId: data['propertyId'],
          );
        }

        await _createActivity(
          userId: data['landlordId'],
          type: 'tenant_arrived',
          title: 'Tenant Has Arrived',
          message:
              '${data['tenantName']} has arrived for the inspection at ${data['propertyTitle']}',
          relatedId: requestId,
          propertyId: data['propertyId'],
        );
      }

      developer.log(
        'âœ… Tenant marked arrived: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking tenant arrived: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Mark the handler (agent or landlord) as arrived at the inspection location
  Future<bool> markHandlerArrived(String requestId) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'handlerArrived': true,
        'handlerArrivedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify the tenant
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final data = requestDoc.data();
      if (data != null) {
        final handlerName =
            data['agentId'] != null
                ? (data['agentName'] ?? 'Agent')
                : (data['landlordName'] ?? 'Landlord');
        await _createActivity(
          userId: data['tenantId'],
          type: 'handler_arrived',
          title: 'Handler Has Arrived',
          message:
              '$handlerName has arrived at ${data['propertyTitle']} for your inspection',
          relatedId: requestId,
          propertyId: data['propertyId'],
        );
      }

      developer.log(
        'âœ… Handler marked arrived: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking handler arrived: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  // ============ COMPLETION & RATING ============

  Future<bool> completeInspection(String requestId) async {
    try {
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();
      if (requestData == null) return false;

      // Determine the actual handler — whoever is calling this method.
      // If the current user is the assigned agent, they handled it.
      // If the landlord called it (even on an agent-assigned property), landlord handled it.
      final String? assignedAgentId = requestData['agentId'] as String?;
      final bool agentHandled = assignedAgentId != null &&
          assignedAgentId.isNotEmpty &&
          _currentUserId == assignedAgentId;

      // Record who actually completed it
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
        'agentPayoutStatus': 'pending',
        'completedBy': _currentUserId,
        'completedByType': agentHandled ? 'agent' : 'landlord',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify tenant
      await _createActivity(
        userId: requestData['tenantId'],
        type: 'inspection_completed',
        title: 'Inspection Completed',
        message:
            'Your inspection for ${requestData['propertyTitle']} is complete. Please rate your experience!',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      if (agentHandled) {
        // Agent did the inspection — agent gets paid and notified
        await _createActivity(
          userId: requestData['landlordId'],
          type: 'inspection_completed',
          title: 'Inspection Completed',
          message:
              '${requestData['agentName']} completed inspection for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
        await _creditAgentEarnings(
          assignedAgentId,
          requestData['agentEarnings']?.toDouble() ?? 0,
        );
      } else {
        // Landlord did the inspection (either self-handled or overrode agent)
        final landlordEarnings = (requestData['agentEarnings'] ?? 0).toDouble();
        if (landlordEarnings > 0) {
          await _firestore
              .collection('users')
              .doc(requestData['landlordId'])
              .update({
                'totalEarnings': FieldValue.increment(landlordEarnings),
                'pendingEarnings': FieldValue.increment(landlordEarnings),
                'completedInspections': FieldValue.increment(1),
              });
        }
      }

      developer.log(
        '✅ Inspection completed: $requestId by ${agentHandled ? 'agent' : 'landlord'}',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error completing inspection: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> rateInspection(
    String requestId,
    int rating, {
    String? review,
  }) async {
    try {
      if (rating < 1 || rating > 5) return false;

      // Fetch request data FIRST so we know who to rate before writing
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();
      if (requestData == null) return false;

      // Guard: prevent double-rating which corrupts the running average
      if (requestData['tenantRated'] == true) {
        developer.log(
          '⚠️ rateInspection: already rated, ignoring duplicate call',
          name: 'InspectionService',
        );
        return false;
      }

      final rawAgentId = requestData['agentId'];
      final completedByType = requestData['completedByType'] as String?;

      // Rate whoever actually conducted the inspection.
      // If completedByType is recorded, use it. Otherwise fall back to agentId check.
      final isAgentHandled = completedByType == 'agent' ||
          (completedByType == null &&
              rawAgentId != null &&
              rawAgentId is String &&
              rawAgentId.isNotEmpty);
      final ratedUserId = isAgentHandled
          ? requestData['agentId'] as String
          : requestData['landlordId'] as String;
      final ratedUserType = isAgentHandled ? 'agent' : 'landlord';
      final ratedUserName = isAgentHandled
          ? (requestData['agentName'] ?? 'Agent')
          : (requestData['landlordName'] ?? 'Landlord');

      // Write rating fields including who received it (for history display)
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'tenantRating': rating,
        'tenantReview': review,
        'tenantRated': true,
        'ratingSubmittedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'ratedUserId': ratedUserId,
        'ratedUserType': ratedUserType,
        'ratedUserName': ratedUserName,
      });

      developer.log('🔵 RATING: about to call _updateAgentRating/Landlord. isAgentHandled=$isAgentHandled', name: 'InspectionService');

      if (isAgentHandled) {
        developer.log('🔵 RATING: calling _updateAgentRating for $ratedUserId', name: 'InspectionService');
        await _updateAgentRating(ratedUserId, rating);
        developer.log('🟢 RATING: _updateAgentRating returned', name: 'InspectionService' );
        await _createActivity(
          userId: ratedUserId,
          type: 'new_rating',
          title: 'New Rating Received',
          message:
              '${requestData['tenantName']} rated you $rating stars for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
        // Notify landlord so rating appears in their history with context
        await _createActivity(
          userId: requestData['landlordId'],
          type: 'inspection_rated',
          title: 'Inspection Rated',
          message:
              '${requestData['tenantName']} gave $rating stars to ${requestData['agentName'] ?? 'your agent'} for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      } else {
        await _updateLandlordRating(ratedUserId, rating);
        await _createActivity(
          userId: ratedUserId,
          type: 'new_rating',
          title: 'New Rating Received',
          message:
              '${requestData['tenantName']} rated you $rating stars for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      developer.log(
        '✅ Inspection rated: $requestId → $ratedUserType ($ratedUserId) = $rating stars',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error rating inspection: $e', name: 'InspectionService');
      return false;
    }
  }

  /// Recalculates and corrects a user's rating by scanning all completed
  /// inspections they handled. Use this to fix agents whose past ratings
  /// were incorrectly written to the landlord document.
  Future<void> recalculateUserRating(String userId, String userType) async {
    developer.log('🔵 RECALC START: userId=$userId userType=$userType', name: 'InspectionService');
    try {
      final field = userType == 'agent' ? 'agentId' : 'landlordId';
      final snapshot = await _firestore
          .collection('inspection_requests')
          .where(field, isEqualTo: userId)
          .where('tenantRated', isEqualTo: true)
          .get();

      developer.log('🔵 RECALC: query returned ${snapshot.docs.length} docs with tenantRated=true', name: 'InspectionService');
      for (final doc in snapshot.docs) {
        final d = doc.data();
        developer.log('  doc ${doc.id}: agentId=${d['agentId']} tenantRating=${d['tenantRating']}', name: 'InspectionService');
      }

      final relevantDocs = snapshot.docs.where((doc) {
        final data = doc.data();
        if (userType == 'agent') {
          return data['agentId'] == userId;
        } else {
          final rawAgentId = data['agentId'];
          return rawAgentId == null || (rawAgentId is String && rawAgentId.isEmpty);
        }
      }).toList();

      developer.log('🔵 RECALC: ${relevantDocs.length} docs after filtering for $userType');

      if (relevantDocs.isEmpty) {
        developer.log('🟡 RECALC: no relevant docs — writing rating=0', name: 'InspectionService');
        await _firestore.collection('users').doc(userId).update({
          'rating': 0.0,
          'totalRatings': 0,
        });
        return;
      }

      final ratings = relevantDocs
          .map((doc) => (doc.data()['tenantRating'] ?? 0) as int)
          .where((r) => r > 0)
          .toList();

      developer.log('🔵 RECALC: extracted ratings=$ratings', name: 'InspectionService');

      if (ratings.isEmpty) {
        developer.log('🟡 RECALC: all ratings were 0 — writing rating=0', name: 'InspectionService');
        await _firestore.collection('users').doc(userId).update({'rating': 0.0, 'totalRatings': 0});
        return;
      }

      final average = ratings.reduce((a, b) => a + b) / ratings.length;
      developer.log('🟢 RECALC: writing rating=${average.toStringAsFixed(2)} totalRatings=${ratings.length} to users/$userId', name: 'InspectionService');

      await _firestore.collection('users').doc(userId).update({
        'rating': average,
        'totalRatings': ratings.length,
      });

      developer.log('🟢 RECALC DONE: $userType $userId = ${average.toStringAsFixed(2)} stars', name: 'InspectionService');
    } catch (e) {
      developer.log('🔴 RECALC ERROR: $e', name: 'InspectionService');
    }
  }

  // ============ CANCEL ============

  Future<bool> cancelRequest(String requestId) async {
    try {
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();

      if (requestData == null) return false;
      if (requestData['tenantId'] != _currentUserId) return false;
      if (requestData['status'] != 'pending') return false;

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'cancelled',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (requestData['paymentStatus'] == 'paid') {
        await _processRefund(requestId, requestData);
      }

      developer.log(
        'âœ… Request cancelled: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error cancelling request: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  // ============ COUNTS ============

  Future<int> getLandlordPendingCount() async {
    if (_currentUserId == null) return 0;

    try {
      final snapshot =
          await _firestore
              .collection('inspection_requests')
              .where('landlordId', isEqualTo: _currentUserId)
              .where('status', whereIn: ['pending', 'declinedByAgent'])
              .count()
              .get();

      return snapshot.count ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<int> getAgentPendingCount() async {
    if (_currentUserId == null) return 0;

    try {
      final snapshot =
          await _firestore
              .collection('inspection_requests')
              .where('agentId', isEqualTo: _currentUserId)
              .where('status', isEqualTo: 'pending')
              .count()
              .get();

      return snapshot.count ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<bool> hasPendingRequest(String propertyId) async {
    if (_currentUserId == null) return false;

    try {
      final snapshot =
          await _firestore
              .collection('inspection_requests')
              .where('propertyId', isEqualTo: propertyId)
              .where('tenantId', isEqualTo: _currentUserId)
              .where(
                'status',
                whereIn: ['pending', 'approved', 'declinedByAgent'],
              )
              .get();

      return snapshot.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // ============ AVAILABILITY ============

  Future<List<DateTime>> getAvailableDates(
    PropertyModel property, {
    int daysAhead = 30,
  }) async {
    final landlordDays = property.inspectionDays;
    List<String> agentDays = [];
    List<Map<String, dynamic>> agentBlockedDates = [];

    if (property.inspectionHandler == 'agent' &&
        property.assignedAgentId != null) {
      try {
        final agentDoc =
            await _firestore
                .collection('users')
                .doc(property.assignedAgentId)
                .get();

        if (agentDoc.exists) {
          final agentData = agentDoc.data()!;
          agentDays = List<String>.from(agentData['availableDays'] ?? []);
          agentBlockedDates = List<Map<String, dynamic>>.from(
            agentData['blockedDates'] ?? [],
          );
        }
      } catch (e) {
        developer.log(
          'âš ï¸ Could not get agent availability: $e',
          name: 'InspectionService',
        );
      }
    }

    final List<DateTime> dates = [];
    final now = DateTime.now();
    final startDate = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));

    for (int i = 0; i < daysAhead; i++) {
      final date = startDate.add(Duration(days: i));
      final weekdayName = _getWeekdayName(date.weekday);

      if (!landlordDays.contains(weekdayName)) continue;
      if (agentDays.isNotEmpty && !agentDays.contains(weekdayName)) continue;

      bool isBlocked = false;
      for (final blocked in agentBlockedDates) {
        final start = DateTime.parse(blocked['start']);
        final end = DateTime.parse(blocked['end']);
        if (date.isAfter(start.subtract(const Duration(days: 1))) &&
            date.isBefore(end.add(const Duration(days: 1)))) {
          isBlocked = true;
          break;
        }
      }
      if (isBlocked) continue;

      dates.add(date);
    }

    return dates;
  }

  Future<List<String>> getAvailableTimeSlots(
    PropertyModel property,
    DateTime date,
  ) async {
    final landlordSlots = property.inspectionTimeSlots;
    List<String> agentSlots = [];

    if (property.inspectionHandler == 'agent' &&
        property.assignedAgentId != null) {
      try {
        final agentDoc =
            await _firestore
                .collection('users')
                .doc(property.assignedAgentId)
                .get();

        if (agentDoc.exists) {
          agentSlots = List<String>.from(
            agentDoc.data()!['availableTimeSlots'] ?? [],
          );
        }
      } catch (e) {
        developer.log(
          'âš ï¸ Could not get agent time slots: $e',
          name: 'InspectionService',
        );
      }
    }

    if (agentSlots.isEmpty) {
      return landlordSlots;
    }

    return landlordSlots.where((slot) => agentSlots.contains(slot)).toList();
  }

  String _getWeekdayName(int weekday) {
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[weekday - 1];
  }

  // ============ HELPER METHODS ============

  Future<void> _createActivity({
    required String userId,
    required String type,
    required String title,
    required String message,
    String? relatedId,
    String? propertyId,
  }) async {
    try {
      await _firestore.collection('activities').add({
        'userId': userId,
        'landlordId': userId, // Also write as landlordId for unified querying
        'type': type,
        'title': title,
        'message': message,
        'subtitle': message, // Also write as subtitle for ActivityModel compat
        'relatedId': relatedId,
        'propertyId': propertyId,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      developer.log(
        'âš ï¸ Failed to create activity: $e',
        name: 'InspectionService',
      );
    }
  }

  Future<void> _processRefund(
    String requestId,
    Map<String, dynamic> requestData,
  ) async {
    try {
      developer.log(
        'ðŸ’° Processing refund for request: $requestId',
        name: 'InspectionService',
      );

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'paymentStatus': 'refunded',
        'refundedAt': FieldValue.serverTimestamp(),
        'refundReason': 'Inspection request was declined',
      });

      await _createActivity(
        userId: requestData['tenantId'],
        type: 'refund_processed',
        title: 'Refund Processed',
        message:
            'Your payment of ₦${requestData['totalFee']?.toStringAsFixed(0) ?? '0'} for ${requestData['propertyTitle']} has been refunded.',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );
    } catch (e) {
      developer.log('❌ Error processing refund: $e', name: 'InspectionService');
    }
  }

  Future<void> _creditAgentEarnings(String agentId, double amount) async {
    try {
      await _firestore.collection('users').doc(agentId).update({
        'totalEarnings': FieldValue.increment(amount),
        'pendingEarnings': FieldValue.increment(amount),
        'totalInspections': FieldValue.increment(1),
        'completedInspections': FieldValue.increment(1),
      });

      developer.log(
        'ðŸ’° Credited ₦$amount to agent: $agentId',
        name: 'InspectionService',
      );
    } catch (e) {
      developer.log('❌ Error crediting agent: $e', name: 'InspectionService');
    }
  }

  Future<void> _updateAgentRating(String agentId, int newRating) async {
    // Use recalculateUserRating to recompute from all rated inspections.
    // This avoids Firestore transaction conflicts that silently fail.
    await recalculateUserRating(agentId, 'agent');
  }

  Future<void> _updateLandlordRating(String landlordId, int newRating) async {
    await recalculateUserRating(landlordId, 'landlord');
  }

  // ============ PAYMENT VERIFICATION (ADMIN) ============

  Future<bool> verifyPayment(String requestId) async {
    try {
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();

      if (requestData == null) return false;

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'paymentStatus': 'paid',
        'paymentVerifiedAt': FieldValue.serverTimestamp(),
        'paymentVerifiedBy': _currentUserId,
        'paidAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _createActivity(
        userId: requestData['tenantId'],
        type: 'payment_verified',
        title: 'Payment Verified!',
        message:
            'Your payment for ${requestData['propertyTitle']} inspection has been confirmed.',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      if (requestData['agentId'] != null) {
        await _createActivity(
          userId: requestData['agentId'],
          type: 'inspection_request',
          title: 'New Inspection Request',
          message:
              '${requestData['tenantName']} wants to inspect ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      await _createActivity(
        userId: requestData['landlordId'],
        type:
            requestData['agentId'] != null
                ? 'inspection_request_agent'
                : 'inspection_request',
        title: 'New Inspection Request',
        message:
            requestData['agentId'] != null
                ? '${requestData['tenantName']} requested inspection for ${requestData['propertyTitle']}. ${requestData['agentName']} will handle.'
                : '${requestData['tenantName']} wants to inspect ${requestData['propertyTitle']}',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      developer.log(
        'âœ… Payment verified for request: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error verifying payment: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> rejectPayment(String requestId, String reason) async {
    try {
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();

      if (requestData == null) return false;

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'paymentStatus': 'rejected',
        'status': 'cancelled',
        'declineReason': reason,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _createActivity(
        userId: requestData['tenantId'],
        type: 'payment_rejected',
        title: 'Payment Verification Failed',
        message:
            'Your payment for ${requestData['propertyTitle']} could not be verified. Reason: $reason',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      developer.log(
        '❌ Payment rejected for request: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log('❌ Error rejecting payment: $e', name: 'InspectionService');
      return false;
    }
  }

  Stream<List<InspectionRequest>> getPendingVerificationRequests() {
    return _firestore
        .collection('inspection_requests')
        .where('status', isEqualTo: 'pendingVerification')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        InspectionRequest.fromFirestore(doc.data(), doc.id),
                  )
                  .toList(),
        );
  }

  // ============ AGENT PAYOUT (ADMIN) ============

  /// Get all completed inspections where agent hasn't been paid yet
  /// Get all completed inspections with pending payouts (agent OR landlord)
  Stream<List<InspectionRequest>> getPendingAgentPayouts() {
    return _firestore
        .collection('inspection_requests')
        .where('status', isEqualTo: 'completed')
        .where('agentPayoutStatus', isEqualTo: 'pending')
        .orderBy('completedAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
            .toList());
  }

  /// Get all completed inspections where agent has been paid
  Stream<List<InspectionRequest>> getPaidAgentPayouts() {
    return _firestore
        .collection('inspection_requests')
        .where('status', isEqualTo: 'completed')
        .where('agentPayoutStatus', isEqualTo: 'paid')
        .orderBy('agentPaidAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        InspectionRequest.fromFirestore(doc.data(), doc.id),
                  )
                  .toList(),
        );
  }

  /// Get agent's bank details for payout
  Future<Map<String, dynamic>?> getAgentBankDetails(String agentId) async {
    try {
      final doc = await _firestore.collection('users').doc(agentId).get();
      if (!doc.exists) return null;
      final data = doc.data()!;

      // Bank details are stored in a nested 'bankDetails' map
      final bankDetails = data['bankDetails'] as Map<String, dynamic>? ?? {};

      // Fall back to root-level fields for older accounts
      final bankName = bankDetails['bankName'] as String? ?? 
                       data['bankName'] as String? ?? '';
      final accountNumber = bankDetails['accountNumber'] as String? ?? 
                            data['accountNumber'] as String? ?? '';
      final accountName = bankDetails['accountName'] as String? ?? 
                          data['accountName'] as String? ?? '';

      return {
        'agentName': data['fullName'] ?? data['name'] ?? '',
        'bankName': bankName,
        'accountNumber': accountNumber,
        'accountName': accountName,
        'agentPhone': data['phone'] ?? '',
        'pendingEarnings': (data['pendingEarnings'] ?? 0).toDouble(),
      };
    } catch (e) {
      developer.log(
        '❌ Error getting agent bank details: $e',
        name: 'InspectionService',
      );
      return null;
    }
  }

  /// Admin marks agent as paid for a specific inspection
  Future<bool> markAgentPaid(String requestId) async {
    try {
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final data = requestDoc.data();
      if (data == null) return false;

      final agentId = data['agentId'];
      final landlordId = data['landlordId'];
      final earnings = (data['agentEarnings'] ?? 0).toDouble();
      
      // Determine who the handler is (agent or landlord)
      final handlerId = agentId ?? landlordId;

      // Update inspection request
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'agentPayoutStatus': 'paid',
        'agentPaidAt': FieldValue.serverTimestamp(),
        'agentPaidBy': _currentUserId,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Move from pending to paid on handler's user doc
      if (handlerId != null) {
        await _firestore.collection('users').doc(handlerId).update({
          'pendingEarnings': FieldValue.increment(-earnings),
          'paidEarnings': FieldValue.increment(earnings),
        });

        await _createActivity(
          userId: handlerId,
          type: 'payout_received',
          title: 'Payment Received',
          message:
              'You\'ve been paid ₦${earnings.toStringAsFixed(0)} for inspection at ${data['propertyTitle']}',
          relatedId: requestId,
          propertyId: data['propertyId'],
        );
      }

      developer.log(
        'âœ… Agent marked as paid for: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking agent paid: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Agent confirms they received payment
  Future<bool> confirmPaymentReceived(String requestId) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'agentConfirmedPayment': true,
        'agentConfirmedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify admin/landlord
      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final data = requestDoc.data();
      if (data != null) {
        await _createActivity(
          userId: data['landlordId'],
          type: 'agent_confirmed_payment',
          title: 'Agent Confirmed Payment',
          message:
              '${data['agentName'] ?? "Agent"} confirmed receiving payment for ${data['propertyTitle']}',
          relatedId: requestId,
          propertyId: data['propertyId'],
        );
      }

      developer.log(
        'âœ… Agent confirmed payment: $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error confirming payment: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Get agent's inspections that are paid but not yet confirmed
  Stream<List<InspectionRequest>> getAgentPendingConfirmations() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('agentId', isEqualTo: _currentUserId)
        .where('agentPayoutStatus', isEqualTo: 'paid')
        .where('agentConfirmedPayment', isEqualTo: false)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        InspectionRequest.fromFirestore(doc.data(), doc.id),
                  )
                  .toList(),
        );
  }

  /// Get landlord's self-handled inspections that are paid but not yet confirmed
  Stream<List<InspectionRequest>> getLandlordPendingConfirmations() {
    if (_currentUserId == null) return Stream.value([]);
    
    return _firestore
        .collection('inspection_requests')
        .where('landlordId', isEqualTo: _currentUserId)
        .where('agentPayoutStatus', isEqualTo: 'paid')
        .where('agentConfirmedPayment', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .where((doc) => doc.data()['agentId'] == null) // Only self-handled
            .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
            .toList());
  }
}