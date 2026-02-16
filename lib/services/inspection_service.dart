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

  Future<InspectionFeeBreakdown?> calculateInspectionFee({
    required PropertyModel property,
  }) async {
    if (property.inspectionHandler == 'self') {
      return null;
    }

    if (property.assignedAgentId == null) {
      return null;
    }

    try {
      final agentDoc = await _firestore
          .collection('users')
          .doc(property.assignedAgentId)
          .get();

      if (!agentDoc.exists) return null;

      final agentData = agentDoc.data()!;
      final agentLat = agentData['baseLatitude']?.toDouble();
      final agentLon = agentData['baseLongitude']?.toDouble();

      if (agentLat == null || agentLon == null) {
        return InspectionPricing.calculateFee(distanceKm: 0);
      }

      // Use property coordinates if available
      final propertyLat = property.latitude;
      final propertyLon = property.longitude;

      if (propertyLat != null && propertyLon != null) {
        return InspectionPricing.calculateFeeFromCoordinates(
          agentLat: agentLat,
          agentLon: agentLon,
          propertyLat: propertyLat,
          propertyLon: propertyLon,
        );
      }

      return InspectionPricing.calculateFee(distanceKm: 0);
    } catch (e) {
      developer.log('❌ Error calculating fee: $e', name: 'InspectionService');
      return null;
    }
  }

  InspectionFeeBreakdown calculateFeeFromCoordinates({
    required double agentLat,
    required double agentLon,
    required double propertyLat,
    required double propertyLon,
  }) {
    return InspectionPricing.calculateFeeFromCoordinates(
      agentLat: agentLat,
      agentLon: agentLon,
      propertyLat: propertyLat,
      propertyLon: propertyLon,
    );
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
      developer.log('❌ Error checking verification: $e', name: 'InspectionService');
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

      final tenantDoc = await _firestore.collection('users').doc(_currentUserId).get();
      final tenantData = tenantDoc.data();
      
      final tenantVerificationStatus = tenantData?['verificationStatus'] ?? 'none';
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

      final existingRequest = await _firestore
          .collection('inspection_requests')
          .where('propertyId', isEqualTo: property.id)
          .where('tenantId', isEqualTo: _currentUserId)
          .where('status', whereIn: ['pending', 'approved', 'declinedByAgent'])
          .get();

      if (existingRequest.docs.isNotEmpty) {
        developer.log('❌ Tenant already has active request', name: 'InspectionService');
        return 'already_pending';
      }

      final isAgentHandled = property.inspectionHandler == 'agent' && property.assignedAgentId != null;

      String? agentName;
      String? agentPhone;
      double? agentLat;
      double? agentLon;

      if (isAgentHandled) {
        final agentVerified = await _isUserVerified(property.assignedAgentId!);
        if (!agentVerified) {
          developer.log('❌ Agent not verified', name: 'InspectionService');
          return 'agent_not_verified';
        }
        
        final agentDoc = await _firestore
            .collection('users')
            .doc(property.assignedAgentId)
            .get();

        if (agentDoc.exists) {
          final agentData = agentDoc.data()!;
          agentName = agentData['fullName'];
          agentPhone = agentData['phone'];
          agentLat = agentData['baseLatitude']?.toDouble();
          agentLon = agentData['baseLongitude']?.toDouble();
        }
      }

      final requestData = {
        'propertyId': property.id,
        'propertyTitle': property.title,
        'propertyImage': property.images.isNotEmpty ? property.images.first : '',
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

        'requestedDate': Timestamp.fromDate(requestedDate),
        'requestedTimeSlot': requestedTimeSlot,
        'requestedTimeDisplay': timeSlotDisplay[requestedTimeSlot] ?? requestedTimeSlot,
        'notes': notes,

        'distanceKm': feeBreakdown?.distanceKm ?? 0,
        'transportFee': feeBreakdown?.transportFee ?? 0,
        'agentServiceFee': feeBreakdown?.agentServiceFee ?? 0,
        'clearrentFee': feeBreakdown?.clearrentFee ?? 0,
        'totalFee': feeBreakdown?.totalFee ?? 0,
        'agentEarnings': feeBreakdown?.agentEarnings ?? 0,

        'paymentStatus': paymentStatus ?? (isAgentHandled ? 'pending_verification' : 'not_required'),
        'paymentReference': paymentReference,
        'paymentProofUrl': paymentProofUrl,
        'paidAt': null,
        'paymentVerifiedAt': null,
        'paymentVerifiedBy': null,
        'refundedAt': null,
        'refundReason': null,

        'status': isAgentHandled
            ? (paymentProofUrl != null ? 'pendingVerification' : 'pendingPayment')
            : 'pending',
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

        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore.collection('inspection_requests').add(requestData);

      developer.log('✅ Inspection request created: ${docRef.id}', name: 'InspectionService');

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
          message: '$tenantName requested inspection for ${property.title}. $agentName will handle.',
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
      developer.log('❌ Error creating inspection request: $e', name: 'InspectionService');
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
          developer.log('📋 Tenant requests count: ${snapshot.docs.length}', name: 'InspectionService');
          return snapshot.docs.map((doc) {
            final data = doc.data();
            developer.log('  - Raw status: "${data['status']}"', name: 'InspectionService');
            final request = InspectionRequest.fromFirestore(data, doc.id);
            developer.log('  - ${request.propertyTitle}: parsed=${request.status.name}, isApproved=${request.isApproved}', name: 'InspectionService');
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
          developer.log('📋 Landlord requests count: ${snapshot.docs.length}', name: 'InspectionService');
          return snapshot.docs.map((doc) {
            final data = doc.data();
            developer.log('  - Raw status: "${data['status']}"', name: 'InspectionService');
            final request = InspectionRequest.fromFirestore(data, doc.id);
            developer.log('  - ${request.propertyTitle}: parsed=${request.status.name}, isApproved=${request.isApproved}', name: 'InspectionService');
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
        .map((snapshot) => snapshot.docs
            .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
            .toList());
  }

  Stream<List<InspectionRequest>> getAgentRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('agentId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          developer.log('📋 Agent requests count: ${snapshot.docs.length}', name: 'InspectionService');
          return snapshot.docs.map((doc) {
            final data = doc.data();
            developer.log('  - Raw Firestore status: "${data['status']}"', name: 'InspectionService');
            final request = InspectionRequest.fromFirestore(data, doc.id);
            developer.log('  - ${request.propertyTitle}: parsed=${request.status.name}, isApproved=${request.isApproved}', name: 'InspectionService');
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
        .map((snapshot) => snapshot.docs
            .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
            .toList());
  }

  Stream<List<InspectionRequest>> getPropertyRequests(String propertyId) {
    return _firestore
        .collection('inspection_requests')
        .where('propertyId', isEqualTo: propertyId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
            .toList());
  }

  // ============ APPROVE / DECLINE ============

  Future<bool> approveRequest(String requestId, {bool isLandlordOverride = false}) async {
    try {
      developer.log('🔄 Approving request: $requestId (override: $isLandlordOverride)', name: 'InspectionService');

      final updates = <String, dynamic>{
        'status': 'approved',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (isLandlordOverride) {
        updates['wasOverridden'] = true;
        updates['overriddenBy'] = _currentUserId;
      }

      await _firestore.collection('inspection_requests').doc(requestId).update(updates);

      developer.log('✅ Firestore updated with status: approved', name: 'InspectionService');

      // Verify the update
      final verifyDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
      developer.log('🔍 Verification - status in Firestore: "${verifyDoc.data()?['status']}"', name: 'InspectionService');

      final requestData = verifyDoc.data();

      if (requestData != null) {
        final approvedBy = isLandlordOverride
            ? 'Landlord'
            : (requestData['agentId'] != null ? 'Agent' : 'Landlord');

        await _createActivity(
          userId: requestData['tenantId'],
          type: 'inspection_approved',
          title: 'Inspection Approved!',
          message: 'Your inspection for ${requestData['propertyTitle']} has been approved by $approvedBy',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );

        if (isLandlordOverride && requestData['agentId'] != null) {
          await _createActivity(
            userId: requestData['agentId'],
            type: 'landlord_override',
            title: 'Landlord Override',
            message: 'Landlord approved the inspection you declined for ${requestData['propertyTitle']}',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );
        }

        if (!isLandlordOverride && requestData['agentId'] != null) {
          await _createActivity(
            userId: requestData['landlordId'],
            type: 'agent_approved',
            title: 'Inspection Approved',
            message: '${requestData['agentName']} approved inspection for ${requestData['propertyTitle']}',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );
        }
      }

      developer.log('✅ Request approved: $requestId', name: 'InspectionService');
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

      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
      final requestData = requestDoc.data();

      if (requestData != null) {
        await _createActivity(
          userId: requestData['landlordId'],
          type: 'agent_declined',
          title: 'Agent Declined Inspection',
          message: '${requestData['agentName']} declined inspection for ${requestData['propertyTitle']}. You have 12 hours to approve if you want.',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      developer.log('✅ Agent declined request: $requestId', name: 'InspectionService');
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
        'declineReason': reason ?? 'Request was not approved within the time window',
        'declinedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
      final requestData = requestDoc.data();

      if (requestData != null) {
        await _createActivity(
          userId: requestData['tenantId'],
          type: 'inspection_declined',
          title: 'Inspection Request Declined',
          message: reason ?? 'Your inspection for ${requestData['propertyTitle']} was declined. A refund will be processed.',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );

        if (requestData['paymentStatus'] == 'paid') {
          await _processRefund(requestId, requestData);
        }
      }

      developer.log('✅ Request finally declined: $requestId', name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error declining request: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> landlordDeclineRequest(String requestId, {String? reason}) async {
    try {
      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
      final requestData = requestDoc.data();

      if (requestData == null) return false;

      final isOverride = requestData['status'] == 'approved' && requestData['agentId'] != null;

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
        message: reason ?? 'Your inspection for ${requestData['propertyTitle']} was declined by the landlord.',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      if (isOverride && requestData['agentId'] != null) {
        await _createActivity(
          userId: requestData['agentId'],
          type: 'landlord_override',
          title: 'Landlord Override',
          message: 'Landlord declined the inspection you approved for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      if (requestData['paymentStatus'] == 'paid') {
        await _processRefund(requestId, requestData);
      }

      developer.log('✅ Landlord declined request: $requestId', name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error declining request: $e', name: 'InspectionService');
      return false;
    }
  }

  // ============ COMPLETION & RATING ============

  Future<bool> completeInspection(String requestId) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
      final requestData = requestDoc.data();

      if (requestData != null) {
        await _createActivity(
          userId: requestData['tenantId'],
          type: 'inspection_completed',
          title: 'Inspection Completed',
          message: 'Your inspection for ${requestData['propertyTitle']} is complete. Please rate your experience!',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );

        if (requestData['agentId'] != null) {
          await _createActivity(
            userId: requestData['landlordId'],
            type: 'inspection_completed',
            title: 'Inspection Completed',
            message: '${requestData['agentName']} completed inspection for ${requestData['propertyTitle']}',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );

          await _creditAgentEarnings(requestData['agentId'], requestData['agentEarnings']?.toDouble() ?? 0);
        }
      }

      developer.log('✅ Inspection completed: $requestId', name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error completing inspection: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> rateInspection(String requestId, int rating, {String? review}) async {
    try {
      if (rating < 1 || rating > 5) return false;

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'tenantRating': rating,
        'tenantReview': review,
        'tenantRated': true,
        'ratingSubmittedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Update agent rating if agent-handled
      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
      final requestData = requestDoc.data();

      if (requestData != null && requestData['agentId'] != null) {
        await _updateAgentRating(requestData['agentId'], rating);

        await _createActivity(
          userId: requestData['agentId'],
          type: 'new_rating',
          title: 'New Rating Received',
          message: '${requestData['tenantName']} rated you $rating stars for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      developer.log('✅ Inspection rated: $requestId', name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error rating inspection: $e', name: 'InspectionService');
      return false;
    }
  }

  // ============ CANCEL ============

  Future<bool> cancelRequest(String requestId) async {
    try {
      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
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

      developer.log('✅ Request cancelled: $requestId', name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error cancelling request: $e', name: 'InspectionService');
      return false;
    }
  }

  // ============ COUNTS ============

  Future<int> getLandlordPendingCount() async {
    if (_currentUserId == null) return 0;

    try {
      final snapshot = await _firestore
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
      final snapshot = await _firestore
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
      final snapshot = await _firestore
          .collection('inspection_requests')
          .where('propertyId', isEqualTo: propertyId)
          .where('tenantId', isEqualTo: _currentUserId)
          .where('status', whereIn: ['pending', 'approved', 'declinedByAgent'])
          .get();

      return snapshot.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // ============ AVAILABILITY ============

  Future<List<DateTime>> getAvailableDates(PropertyModel property, {int daysAhead = 30}) async {
    final landlordDays = property.inspectionDays;
    List<String> agentDays = [];
    List<Map<String, dynamic>> agentBlockedDates = [];

    if (property.inspectionHandler == 'agent' && property.assignedAgentId != null) {
      try {
        final agentDoc = await _firestore.collection('users').doc(property.assignedAgentId).get();

        if (agentDoc.exists) {
          final agentData = agentDoc.data()!;
          agentDays = List<String>.from(agentData['availableDays'] ?? []);
          agentBlockedDates = List<Map<String, dynamic>>.from(agentData['blockedDates'] ?? []);
        }
      } catch (e) {
        developer.log('⚠️ Could not get agent availability: $e', name: 'InspectionService');
      }
    }

    final List<DateTime> dates = [];
    final now = DateTime.now();
    final startDate = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));

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

  Future<List<String>> getAvailableTimeSlots(PropertyModel property, DateTime date) async {
    final landlordSlots = property.inspectionTimeSlots;
    List<String> agentSlots = [];

    if (property.inspectionHandler == 'agent' && property.assignedAgentId != null) {
      try {
        final agentDoc = await _firestore.collection('users').doc(property.assignedAgentId).get();

        if (agentDoc.exists) {
          agentSlots = List<String>.from(agentDoc.data()!['availableTimeSlots'] ?? []);
        }
      } catch (e) {
        developer.log('⚠️ Could not get agent time slots: $e', name: 'InspectionService');
      }
    }

    if (agentSlots.isEmpty) {
      return landlordSlots;
    }

    return landlordSlots.where((slot) => agentSlots.contains(slot)).toList();
  }

  String _getWeekdayName(int weekday) {
    const names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
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
        'type': type,
        'title': title,
        'message': message,
        'relatedId': relatedId,
        'propertyId': propertyId,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      developer.log('⚠️ Failed to create activity: $e', name: 'InspectionService');
    }
  }

  Future<void> _processRefund(String requestId, Map<String, dynamic> requestData) async {
    try {
      developer.log('💰 Processing refund for request: $requestId', name: 'InspectionService');

      await _firestore.collection('inspection_requests').doc(requestId).update({
        'paymentStatus': 'refunded',
        'refundedAt': FieldValue.serverTimestamp(),
        'refundReason': 'Inspection request was declined',
      });

      await _createActivity(
        userId: requestData['tenantId'],
        type: 'refund_processed',
        title: 'Refund Processed',
        message: 'Your payment of ₦${requestData['totalFee']?.toStringAsFixed(0) ?? '0'} for ${requestData['propertyTitle']} has been refunded.',
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

      developer.log('💰 Credited ₦$amount to agent: $agentId', name: 'InspectionService');
    } catch (e) {
      developer.log('❌ Error crediting agent: $e', name: 'InspectionService');
    }
  }

  Future<void> _updateAgentRating(String agentId, int newRating) async {
    try {
      final agentDoc = await _firestore.collection('users').doc(agentId).get();
      if (!agentDoc.exists) return;

      final agentData = agentDoc.data()!;
      final currentRating = (agentData['rating'] ?? 0).toDouble();
      final totalRatings = (agentData['totalRatings'] ?? 0) + 1;

      final newAverage = totalRatings == 1
          ? newRating.toDouble()
          : ((currentRating * (totalRatings - 1)) + newRating) / totalRatings;

      await _firestore.collection('users').doc(agentId).update({
        'rating': newAverage,
        'totalRatings': totalRatings,
      });

      developer.log('⭐ Updated agent rating to ${newAverage.toStringAsFixed(2)}', name: 'InspectionService');
    } catch (e) {
      developer.log('❌ Error updating agent rating: $e', name: 'InspectionService');
    }
  }

  // ============ PAYMENT VERIFICATION (ADMIN) ============

  Future<bool> verifyPayment(String requestId) async {
    try {
      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
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
        message: 'Your payment for ${requestData['propertyTitle']} inspection has been confirmed.',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      if (requestData['agentId'] != null) {
        await _createActivity(
          userId: requestData['agentId'],
          type: 'inspection_request',
          title: 'New Inspection Request',
          message: '${requestData['tenantName']} wants to inspect ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }

      await _createActivity(
        userId: requestData['landlordId'],
        type: requestData['agentId'] != null ? 'inspection_request_agent' : 'inspection_request',
        title: 'New Inspection Request',
        message: requestData['agentId'] != null
            ? '${requestData['tenantName']} requested inspection for ${requestData['propertyTitle']}. ${requestData['agentName']} will handle.'
            : '${requestData['tenantName']} wants to inspect ${requestData['propertyTitle']}',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      developer.log('✅ Payment verified for request: $requestId', name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error verifying payment: $e', name: 'InspectionService');
      return false;
    }
  }

  Future<bool> rejectPayment(String requestId, String reason) async {
    try {
      final requestDoc = await _firestore.collection('inspection_requests').doc(requestId).get();
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
        message: 'Your payment for ${requestData['propertyTitle']} could not be verified. Reason: $reason',
        relatedId: requestId,
        propertyId: requestData['propertyId'],
      );

      developer.log('❌ Payment rejected for request: $requestId', name: 'InspectionService');
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
        .map((snapshot) => snapshot.docs
            .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
            .toList());
  }
}