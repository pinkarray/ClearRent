import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../shared/models/inspection_request_model.dart';
import '../shared/models/property_model.dart';
import '../core/utils/inspection_pricing.dart';
import 'package:flutter/foundation.dart';

class InspectionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

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

  /// Start-of-window hour (24h, local) for each time slot. Used to
  /// fold the slot's actual start time into `requestedDate`.
  static const Map<String, int> timeSlotStartHour = {
    'morning': 9,
    'afternoon': 12,
    'late_afternoon': 15,
    'evening': 18,
  };

  /// How far ahead a slot must start to still be bookable.
  ///
  /// Was duplicated inline in `reschedule_propose_sheet.dart`; it lives here
  /// now because the request sheet, the reschedule sheet AND the
  /// CF-unavailable fallback all have to apply the same rule. Anywhere that
  /// misses it can offer a slot that has already begun.
  static const Duration bookingLeadTime = Duration(hours: 2);

  /// Whether [slot] on [date] is far enough ahead to be booked.
  ///
  /// Unknown slots are treated as bookable — an unrecognised slot name is a
  /// data problem, and silently hiding it would look like the handler has no
  /// availability at all.
  static bool isSlotBookable(DateTime date, String slot) {
    final hour = timeSlotStartHour[slot];
    if (hour == null) return true;
    final start = DateTime(date.year, date.month, date.day, hour);
    return start.isAfter(DateTime.now().add(bookingLeadTime));
  }

  /// Compose a scheduled DateTime by combining a calendar date with
  /// the slot's start hour. Returns midnight if the slot is unknown.
  static DateTime composeScheduledDateTime(DateTime date, String slot) {
    final hour = timeSlotStartHour[slot];
    if (hour == null) {
      return DateTime(date.year, date.month, date.day);
    }
    return DateTime(date.year, date.month, date.day, hour, 0);
  }

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
        // Prefer the cluster resolved at listing time — the exact street
        // address now lives in the gated subdoc and isn't on the property here.
        final propertyCluster = property.inspectionPropertyCluster ??
            (propertyArea != null
                ? InspectionPricing.getClusterForArea(propertyArea)
                : null);

        if (agentCluster == null) {
          if (kDebugMode) {
            developer.log(
              '\u26a0\ufe0f Agent baseLocation "$agentBaseLocation" not mapped to any cluster, using same-zone fallback.',
              name: 'InspectionService',
            );
          }
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

    // Self-handled — by the landlord, or by the caretaker they appointed.
    //
    // `!= 'agent'` rather than `== 'self'` deliberately. This method returns
    // null when no branch matches, and a null breakdown takes the inspection
    // booking sheet down with it, so a handler value that falls through here is
    // not a degraded experience but a dead flow. The fee is flat (₦10k / ₦7k /
    // ₦3k) and the ₦7k still settles to the landlord either way — no inspection
    // request carries an agentId when it isn't agent-handled — so the two cases
    // differ only in who is asked to show up.
    if (property.isSelfHandled) {
      final byCaretaker = property.inspectionHandler == 'caretaker' &&
          property.caretakerId != null;
      final propertyArea = _resolvePropertyArea(property);
      // Prefer the cluster resolved at listing time (see agent path above).
      final propertyCluster = property.inspectionPropertyCluster ??
          (propertyArea != null
              ? InspectionPricing.getClusterForArea(propertyArea)
              : null);

      // Whoever actually opens the door is the one who may not have to travel:
      // for a caretaker that is caretakerLivesOnPremises, which until now was
      // pure display metadata.
      final handlerOnSite = byCaretaker
          ? property.caretakerLivesOnPremises == true
          : property.landlordLivesInProperty == true;

      if (handlerOnSite) {
        return InspectionPricing.calculateSelfHandledFee(
          landlordLivesInProperty: true,
          propertyCluster: propertyCluster ?? 'maryland_ikeja',
          propertyArea: propertyArea,
        );
      }

      // Handler lives elsewhere — get their baseLocation
      try {
        final landlordDoc = await _firestore
            .collection('users')
            .doc(byCaretaker ? property.caretakerId! : property.landlordId)
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

  /// Pay-after-approve: creates the request UNPAID and awaiting the handler
  /// (status 'pending'). The tenant pays only after the handler approves — the
  /// fee breakdown is stored now so the amount is fixed, but nothing is charged
  /// here. (Was pay-before-handler: the old callers passed paymentStatus:'paid'
  /// after charging up front.)
  Future<String?> createInspectionRequest({
    required PropertyModel property,
    required DateTime requestedDate,
    required String requestedTimeSlot,
    String? notes,
    InspectionFeeBreakdown? feeBreakdown,
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

      // Readiness gate (Phase 2): a property is only bookable once its handler
      // has vetted it. Rules enforce this server-side too; this is the UX gate.
      if (!property.readyForInspections) {
        developer.log('❌ Property not vetted for inspections',
            name: 'InspectionService');
        return 'property_not_ready';
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
                whereIn: ['pending', 'approved', 'pendingPayment','pendingVerification','declinedByAgent'],
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
        // Reveal-on-approval: store only the area-level address at booking. The
        // exact street address + coordinates stay in the gated `private/location`
        // subdoc; the tenant is granted read access when the handler approves.
        'propertyAddress': property.approximateAddress,

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

        'requestedDate': Timestamp.fromDate(
          composeScheduledDateTime(requestedDate, requestedTimeSlot),
        ),
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

        // Snapshot of handler context — used by activity notifications
        // and (later) by the creditInspectionEarnings Cloud Function.
        'isSelfHandled': property.inspectionHandler != 'agent',
        'landlordLivesInProperty': property.landlordLivesInProperty == true,

        // Pay-after-approve: nothing is charged at creation. A fee-bearing
        // request is 'unpaid' (the tenant pays after the handler approves); a
        // free inspection is 'not_required'.
        'paymentStatus':
            (feeBreakdown != null && feeBreakdown.totalFee > 0)
                ? 'unpaid'
                : 'not_required',
        'paymentReference': null,
        'paymentProofUrl': null,
        'paidAt': null,
        'paymentVerifiedAt': null,
        'paymentVerifiedBy': null,
        'refundedAt': null,
        'refundReason': null,

        // Always awaiting the handler's decision — no money has moved yet.
        'status': 'pending',
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

  /// Pay-after-approve: confirm the inspection payment server-side after a
  /// successful Paystack charge. The confirmInspectionPayment callable verifies
  /// the caller is the tenant and the request is approved, flips it to paid, and
  /// reveals the exact address (the reveal is handler-only by rule, so it must
  /// run server-side). Returns false if the server rejects it.
  Future<bool> confirmInspectionPayment(
    String requestId, {
    String? paymentReference,
  }) async {
    try {
      final callable = _functions.httpsCallable('confirmInspectionPayment');
      await callable.call<Map<String, dynamic>>({
        'requestId': requestId,
        'paymentReference': paymentReference,
      });
      developer.log('✅ Inspection payment confirmed: $requestId',
          name: 'InspectionService');
      return true;
    } on FirebaseFunctionsException catch (e) {
      developer.log(
          '❌ confirmInspectionPayment rejected: ${e.code} ${e.message}',
          name: 'InspectionService');
      return false;
    } catch (e) {
      developer.log('❌ confirmInspectionPayment error: $e',
          name: 'InspectionService');
      return false;
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

  /// One-shot, server-source read of the landlord's requests. Used
  /// by the smart-initial-tab logic to avoid landing on the wrong
  /// tab due to cache staleness right after a new request arrives.
  Future<List<InspectionRequest>> getLandlordRequestsOnce() async {
    if (_currentUserId == null) return [];

    try {
      final snapshot = await _firestore
          .collection('inspection_requests')
          .where('landlordId', isEqualTo: _currentUserId)
          .orderBy('createdAt', descending: true)
          .get(const GetOptions(source: Source.server));

      return snapshot.docs
          .map((doc) => InspectionRequest.fromFirestore(doc.data(), doc.id))
          .toList();
    } catch (e) {
      developer.log(
        '❌ Error in getLandlordRequestsOnce: $e',
        name: 'InspectionService',
      );
      return [];
    }
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

  /// Returns inspection requests for this tenant that are in any
  /// "needs awareness" state (pending payment, awaiting verification,
  /// awaiting landlord/agent response, or declined by agent).
  Stream<List<InspectionRequest>> getTenantPendingRequests() {
    if (_currentUserId == null) return Stream.value([]);

    return _firestore
        .collection('inspection_requests')
        .where('tenantId', isEqualTo: _currentUserId)
        .where('status', whereIn: [
          'pendingPayment',
          'pendingVerification',
          'pending',
          'declinedByAgent',
        ])
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) =>
                  InspectionRequest.fromFirestore(doc.data(), doc.id))
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

  /// Tenant reschedules an inspection that expired unapproved — picks a new
  /// future date; the request re-enters the approval queue (payment is kept).
  Future<bool> rescheduleExpiredInspection(
    String requestId,
    DateTime newDate,
    String newTimeSlot,
  ) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'pending',
        'requestedDate': Timestamp.fromDate(newDate),
        'requestedTimeSlot': newTimeSlot,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      developer.log('âŒ rescheduleExpiredInspection failed: $e',
          name: 'InspectionService');
      return false;
    }
  }

  /// Tenant takes the refund instead of rescheduling an expired inspection.
  /// Setting paymentStatus='refunded' triggers the refund record for admin
  /// payout (onInspectionRefundTriggered).
  Future<bool> refundExpiredInspection(String requestId) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'status': 'refunded',
        'paymentStatus': 'refunded',
        'refundReason': 'Inspection was not approved in time',
        'refundedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      developer.log('âŒ refundExpiredInspection failed: $e',
          name: 'InspectionService');
      return false;
    }
  }

  Future<bool> approveRequest(
    String requestId, {
    bool isLandlordOverride = false,
  }) async {
    try {
      developer.log(
        'ðŸ”„ Approving request: $requestId (override: $isLandlordOverride)',
        name: 'InspectionService',
      );

      // Refuse to approve a request whose date has already passed — it can't be
      // a real future inspection. (Compare by day so a same-day slot still
      // works.) The lifecycle sweep reclassifies these stale requests.
      final existing = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final reqTs = existing.data()?['requestedDate'];
      if (reqTs is Timestamp) {
        final reqDate = reqTs.toDate();
        final now = DateTime.now();
        final reqDay = DateTime(reqDate.year, reqDate.month, reqDate.day);
        final today = DateTime(now.year, now.month, now.day);
        if (reqDay.isBefore(today)) {
          developer.log(
            'â›” Cannot approve a past-date request: $requestId',
            name: 'InspectionService',
          );
          return false;
        }
      }

      final updates = <String, dynamic>{
        'status': 'approved',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (isLandlordOverride) {
        updates['wasOverridden'] = true;
        updates['overriddenBy'] = _currentUserId;
      }

      // Pay-after-approve: the exact address is NOT revealed on approval any
      // more. Approval alone doesn't unlock the property location — otherwise
      // an approved-but-unpaid tenant would get the connection for free. The
      // reveal (exact address fill + reveals/{tenantId} grant) now happens
      // server-side when the tenant pays (confirmInspectionPayment callable).
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
        // (Reveal moved to payment — see confirmInspectionPayment. Approval no
        // longer writes the reveals grant or the exact address.)
        final approvedBy =
            isLandlordOverride
                ? 'Landlord'
                : (requestData['agentId'] != null ? 'Agent' : 'Landlord');

        // Pay-after-approve: prompt the tenant to pay to confirm. The fee is
        // charged only now, and the exact address unlocks once they pay.
        final feeRequired = (requestData['totalFee'] as num?) != null &&
            (requestData['totalFee'] as num) > 0 &&
            requestData['paymentStatus'] != 'paid';
        await _createActivity(
          userId: requestData['tenantId'],
          type: 'inspection_approved',
          title: 'Inspection Approved!',
          message: feeRequired
              ? 'Your inspection for ${requestData['propertyTitle']} was '
                  'approved by $approvedBy. Pay the inspection fee to confirm '
                  'and unlock the exact address.'
              : 'Your inspection for ${requestData['propertyTitle']} has been '
                  'approved by $approvedBy',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );

        // Transport advisory: remind the tenant that transport is
        // off-platform. Skip if the handler is a landlord living in
        // the property (nothing to coordinate — landlord is already
        // at the destination).
        final isSelfHandled = requestData['isSelfHandled'] == true;
        final landlordLivesInProperty =
            requestData['landlordLivesInProperty'] == true;
        if (!(isSelfHandled && landlordLivesInProperty)) {
          final handlerLabel = isSelfHandled
              ? (requestData['landlordName'] ?? 'the landlord')
              : (requestData['agentName'] ?? 'the agent');
          await _createActivity(
            userId: requestData['tenantId'],
            type: 'transport_reminder',
            title: 'Coordinate transport directly',
            message:
                'Transport for your inspection is arranged directly with $handlerLabel. ClearRent does not collect transport money - please discuss the amount with them in chat.',
            relatedId: requestId,
            propertyId: requestData['propertyId'],
          );
        }

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

  /// Mark that the tenant decided NOT to rent this property ("I'll Keep Looking").
  /// Persists so it survives restart, re-locks exact address to approximate.
  Future<bool> markTenantPassed(String requestId) async {
    try {
      await _firestore.collection('inspection_requests').doc(requestId).update({
        'tenantPassed': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('Tenant passed on property: $requestId',
          name: 'InspectionService');
      return true;
    } catch (e) {
      developer.log('❌ Error marking tenant passed: $e',
          name: 'InspectionService');
      return false;
    }
  }

  /// True if the current tenant has passed on (declined to rent) this property.
  /// Used to re-lock the exact address.
  Future<bool> hasPassed(String propertyId) async {
    if (_currentUserId == null) return false;
    try {
      final snapshot = await _firestore
          .collection('inspection_requests')
          .where('propertyId', isEqualTo: propertyId)
          .where('tenantId', isEqualTo: _currentUserId)
          .where('tenantPassed', isEqualTo: true)
          .get();
      return snapshot.docs.isNotEmpty;
    } catch (e) {
      developer.log('❌ Error checking tenant passed: $e',
          name: 'InspectionService');
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
      final userId = _currentUserId;
      if (userId == null) return false;

      final requestDoc =
          await _firestore
              .collection('inspection_requests')
              .doc(requestId)
              .get();
      final requestData = requestDoc.data();
      if (requestData == null) return false;

      // Eligibility gates: status must be approved, BOTH parties must have
      // confirmed they met (a single party's flag can't unlock completion),
      // and caller must be the handler. handlerArrived is implied by the
      // handler's own confirmation, but we assert it defensively.
      if (requestData['status'] != 'approved') return false;
      if (requestData['tenantConfirmedMet'] != true) return false;
      if (requestData['handlerConfirmedMet'] != true) return false;
      if (requestData['handlerArrived'] != true) return false;
      final role = _actorRole(requestData, userId);
      if (role != 'agent' && role != 'landlord') return false;

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
        // Agent did the inspection — landlord activity feed entry.
        // Earnings are credited server-side by the
        // creditInspectionEarnings Cloud Function (closes F1.4).
        await _createActivity(
          userId: requestData['landlordId'],
          type: 'inspection_completed',
          title: 'Inspection Completed',
          message:
              '${requestData['agentName']} completed inspection for ${requestData['propertyTitle']}',
          relatedId: requestId,
          propertyId: requestData['propertyId'],
        );
      }
      // Landlord-handled completions: no client-side credit either.
      // The Cloud Function detects status→completed and credits the
      // landlord ₦7,000 server-side.

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

      // Rating aggregation is server-side: the onInspectionRated CF recomputes
      // the ratee's Bayesian rating from the inspection_requests write above.
      // The client no longer writes rating/totalRatings (locked in rules).
      if (isAgentHandled) {
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

  // Rating recomputation moved server-side to the onInspectionRated Cloud
  // Function (functions/src/rating_ops.ts): it recomputes a Bayesian average
  // from all of a user's rated inspections whenever tenantRated flips true,
  // and is the sole writer of users.rating/totalRatings (locked in rules).

  // ============ REPORT A PROBLEM (DISPUTE) ============

  /// File a dispute on an inspection that went wrong. This is distinct from
  /// rating: it routes the case to the admin review queue (via the
  /// reportInspectionIssue Cloud Function) which raises an admin alert and
  /// lets an admin decide a refund — the tenant can't self-refund.
  ///
  /// [category] is one of: misrepresented, no_show, unprofessional, safety,
  /// refund_request. Returns true on success (including an idempotent no-op
  /// when a dispute is already open).
  Future<bool> reportInspectionIssue(
    String requestId,
    String category, {
    String details = '',
  }) async {
    try {
      final callable = _functions.httpsCallable('reportInspectionIssue');
      await callable.call<Map<String, dynamic>>({
        'requestId': requestId,
        'category': category,
        'details': details,
      });
      return true;
    } catch (e) {
      developer.log(
        '❌ reportInspectionIssue failed: $e',
        name: 'InspectionService',
      );
      return false;
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
      if (requestData['status'] != 'pendingPayment') return false;

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

  // ============ RESCHEDULE ============

  /// Server-side guard: reschedule must be initiated more than 2
  /// hours before the current scheduled slot.
  bool _isWithinRescheduleWindow(DateTime requestedDate) {
    final cutoff = requestedDate.subtract(const Duration(hours: 2));
    return DateTime.now().isBefore(cutoff);
  }

  /// Determine whether the acting user is the tenant or the handler
  /// (agent or landlord) on a given request. Returns null if neither.
  String? _actorRole(Map<String, dynamic> data, String userId) {
    if (data['tenantId'] == userId) return 'tenant';
    if (data['agentId'] == userId) return 'agent';
    if (data['landlordId'] == userId) return 'landlord';
    return null;
  }

  /// Initiate a fresh reschedule proposal. Either tenant or handler
  /// can call this. Fails if there's already a pending proposal, the
  /// cap is reached, or the cutoff has passed.
  Future<bool> proposeReschedule({
    required String requestId,
    required DateTime newDate,
    required String newTimeSlot,
    required String reason,
  }) async {
    final userId = _currentUserId;
    if (userId == null) return false;
    if (reason.trim().isEmpty) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role == null) return false;

      if (data['status'] != 'approved') return false;
      if (data['rescheduleProposal'] != null) return false;
      if ((data['rescheduleCount'] ?? 0) >= 2) return false;

      final currentDate = (data['requestedDate'] as Timestamp).toDate();
      if (!_isWithinRescheduleWindow(currentDate)) return false;

      final proposal = RescheduleProposal(
        proposedBy: role,
        proposedByUserId: userId,
        proposedDate: composeScheduledDateTime(newDate, newTimeSlot),
        proposedTimeSlot: newTimeSlot,
        proposedTimeDisplay:
            timeSlotDisplay[newTimeSlot] ?? newTimeSlot,
        reason: reason.trim(),
        proposedAt: DateTime.now(),
      );

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'rescheduleProposal': proposal.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log(
        '✅ Reschedule proposed by $role for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error proposing reschedule: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Counter-propose against the active proposal. The receiver of the
  /// current proposal becomes the new proposer. Fails if the receiver
  /// has already used their counter slot.
  Future<bool> counterProposeReschedule({
    required String requestId,
    required DateTime newDate,
    required String newTimeSlot,
    required String reason,
  }) async {
    final userId = _currentUserId;
    if (userId == null) return false;
    if (reason.trim().isEmpty) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role == null) return false;

      final proposalData = data['rescheduleProposal'];
      if (proposalData == null) return false;

      final current = RescheduleProposal.fromMap(
        Map<String, dynamic>.from(proposalData as Map),
      );

      // The actor must be the *receiver* of the current proposal.
      final actorIsReceiver = (current.proposedBy == 'tenant')
          ? (role == 'agent' || role == 'landlord')
          : (role == 'tenant');
      if (!actorIsReceiver) return false;

      // Receiver must not have already countered.
      if (current.receiverCannotCounter) return false;

      final currentDate = (data['requestedDate'] as Timestamp).toDate();
      if (!_isWithinRescheduleWindow(currentDate)) return false;

      final isTenantCountering = role == 'tenant';
      final newProposal = RescheduleProposal(
        proposedBy: role,
        proposedByUserId: userId,
        proposedDate: composeScheduledDateTime(newDate, newTimeSlot),
        proposedTimeSlot: newTimeSlot,
        proposedTimeDisplay:
            timeSlotDisplay[newTimeSlot] ?? newTimeSlot,
        reason: reason.trim(),
        proposedAt: DateTime.now(),
        tenantHasCountered:
            current.tenantHasCountered || isTenantCountering,
        handlerHasCountered:
            current.handlerHasCountered || !isTenantCountering,
      );

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'rescheduleProposal': newProposal.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log(
        '✅ Reschedule counter-proposed by $role for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error counter-proposing: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Approve the active proposal. The receiver of the current
  /// proposal calls this. Updates the request's date/time, clears
  /// the proposal, increments rescheduleCount.
  Future<bool> approveReschedule(String requestId) async {
    final userId = _currentUserId;
    if (userId == null) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role == null) return false;

      final proposalData = data['rescheduleProposal'];
      if (proposalData == null) return false;

      final proposal = RescheduleProposal.fromMap(
        Map<String, dynamic>.from(proposalData as Map),
      );

      final actorIsReceiver = (proposal.proposedBy == 'tenant')
          ? (role == 'agent' || role == 'landlord')
          : (role == 'tenant');
      if (!actorIsReceiver) return false;

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'requestedDate': Timestamp.fromDate(
          composeScheduledDateTime(
            proposal.proposedDate,
            proposal.proposedTimeSlot,
          ),
        ),
        'requestedTimeSlot': proposal.proposedTimeSlot,
        'requestedTimeDisplay': proposal.proposedTimeDisplay,
        'rescheduleProposal': null,
        'rescheduleCount': FieldValue.increment(1),
        'tenantArrived': false,
        'tenantArrivedAt': null,
        'handlerArrived': false,
        'handlerArrivedAt': null,
        'tenantOnWay': false,
        'tenantOnWayAt': null,
        'handlerOnWay': false,
        'handlerOnWayAt': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log(
        '✅ Reschedule approved for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error approving reschedule: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Decline the active proposal. The receiver calls this with a
  /// required reason. Triggers refund and flips status to declined.
  Future<bool> declineReschedule({
    required String requestId,
    required String reason,
  }) async {
    final userId = _currentUserId;
    if (userId == null) return false;
    if (reason.trim().isEmpty) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role == null) return false;

      final proposalData = data['rescheduleProposal'];
      if (proposalData == null) return false;

      final proposal = RescheduleProposal.fromMap(
        Map<String, dynamic>.from(proposalData as Map),
      );

      final actorIsReceiver = (proposal.proposedBy == 'tenant')
          ? (role == 'agent' || role == 'landlord')
          : (role == 'tenant');
      if (!actorIsReceiver) return false;

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'status': 'declined',
        'declinedBy': role,
        'declineReason': reason.trim(),
        'declinedAt': FieldValue.serverTimestamp(),
        'rescheduleProposal': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Refund only if payment was actually taken.
      if (data['paymentStatus'] == 'paid') {
        await _processRefund(requestId, data);
      }

      developer.log(
        '✅ Reschedule declined by $role for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error declining reschedule: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Abandon the active proposal without consequences. Either side
  /// can call this. Original date stands, no refund.
  Future<bool> abandonReschedule(String requestId) async {
    final userId = _currentUserId;
    if (userId == null) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role == null) return false;

      if (data['rescheduleProposal'] == null) return false;

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'rescheduleProposal': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log(
        '✅ Reschedule abandoned by $role for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error abandoning reschedule: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  // ============ ON THE WAY ============

  /// Tenant marks themselves as on the way to the property.
  /// Eligible only when status is 'approved' and we're within 2h of
  /// the scheduled slot. Idempotent — second call is a no-op.
  Future<bool> markTenantOnWay(String requestId) async {
    final userId = _currentUserId;
    if (userId == null) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      if (data['tenantId'] != userId) return false;
      if (data['status'] != 'approved') return false;
      if (data['tenantOnWay'] == true) return false;

      final scheduledDate = (data['requestedDate'] as Timestamp).toDate();
      final cutoff = scheduledDate.subtract(const Duration(hours: 2));
      if (DateTime.now().isBefore(cutoff)) return false;

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'tenantOnWay': true,
        'tenantOnWayAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Tell the handler the tenant is on the way (mirrors markTenantArrived).
      // Self-handled ⇒ agentId is null, so only the landlord is notified.
      final tenantName = data['tenantName'] ?? 'The tenant';
      final propertyTitle = data['propertyTitle'] ?? 'the property';
      if (data['agentId'] != null) {
        await _createActivity(
          userId: data['agentId'],
          type: 'tenant_on_way',
          title: 'Tenant On the Way',
          message: '$tenantName is on the way to $propertyTitle for the inspection',
          relatedId: requestId,
          propertyId: data['propertyId'],
        );
      }
      await _createActivity(
        userId: data['landlordId'],
        type: 'tenant_on_way',
        title: 'Tenant On the Way',
        message: '$tenantName is on the way to $propertyTitle for the inspection',
        relatedId: requestId,
        propertyId: data['propertyId'],
      );

      developer.log(
        '✅ Tenant on way for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking tenant on way: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  /// Handler (agent or landlord) marks themselves as on the way.
  /// Eligible only when status is 'approved' and we're within 2h of
  /// the scheduled slot. Idempotent — second call is a no-op.
  Future<bool> markHandlerOnWay(String requestId) async {
    final userId = _currentUserId;
    if (userId == null) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role != 'agent' && role != 'landlord') return false;
      if (data['status'] != 'approved') return false;
      if (data['handlerOnWay'] == true) return false;

      final scheduledDate = (data['requestedDate'] as Timestamp).toDate();
      final cutoff = scheduledDate.subtract(const Duration(hours: 2));
      if (DateTime.now().isBefore(cutoff)) return false;

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'handlerOnWay': true,
        'handlerOnWayAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Tell the tenant the handler is on the way (mirrors markHandlerArrived).
      final handlerName = data['agentId'] != null
          ? (data['agentName'] ?? 'The agent')
          : (data['landlordName'] ?? 'The landlord');
      await _createActivity(
        userId: data['tenantId'],
        type: 'handler_on_way',
        title: 'Handler On the Way',
        message:
            '$handlerName is on the way to ${data['propertyTitle'] ?? 'the property'} for your inspection',
        relatedId: requestId,
        propertyId: data['propertyId'],
      );

      developer.log(
        'Handler on way for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error marking handler on way: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  // ============ MET CONFIRMATION ============

  /// Records the CALLER's own half of the "we met" confirmation. A meeting is
  /// a two-person fact, so neither party can assert it alone — completion is
  /// gated on BOTH halves (see completeInspection). Either party may only
  /// confirm once both have physically arrived: the handler can't fake a
  /// meeting with a tenant who never showed, and a tenant's confirmation alone
  /// can no longer unlock the handler's payout.
  Future<bool> markMet(String requestId) async {
    final userId = _currentUserId;
    if (userId == null) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role == 'unknown') return false;
      if (data['status'] != 'approved') return false;

      // Both must be physically present before either can confirm the meeting.
      if (data['tenantArrived'] != true) return false;
      if (data['handlerArrived'] != true) return false;

      final Map<String, dynamic> update = {
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (role == 'tenant') {
        if (data['tenantConfirmedMet'] == true) return false;
        update['tenantConfirmedMet'] = true;
        update['tenantConfirmedMetAt'] = FieldValue.serverTimestamp();
      } else {
        // agent or landlord — records the handler's half only.
        if (data['handlerConfirmedMet'] == true) return false;
        update['handlerConfirmedMet'] = true;
        update['handlerConfirmedMetAt'] = FieldValue.serverTimestamp();
      }

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update(update);

      developer.log(
        '✅ Met half confirmed by $role for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error in markMet: $e',
        name: 'InspectionService',
      );
      return false;
    }
  }

  // ============ HANDLER CANCEL ============

  /// Handler (agent or landlord) cancels a paid inspection on the
  /// tenant's behalf. Triggers refund. Reason is required.
  ///
  /// Eligible while status is 'pending' or 'approved'. Clears any
  /// pending reschedule proposal. Tenant gets notified via the
  /// status diff in onInspectionRequestUpdated.
  Future<bool> handlerCancelRequest({
    required String requestId,
    required String reason,
  }) async {
    final userId = _currentUserId;
    if (userId == null) return false;
    if (reason.trim().isEmpty) return false;

    try {
      final doc = await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .get();
      final data = doc.data();
      if (data == null) return false;

      final role = _actorRole(data, userId);
      if (role != 'agent' && role != 'landlord') return false;

      final status = data['status'] as String?;
      if (status != 'pending' && status != 'approved') return false;

      await _firestore
          .collection('inspection_requests')
          .doc(requestId)
          .update({
        'status': 'cancelled',
        'cancelledBy': role,
        'cancellationReason': reason.trim(),
        'cancelledAt': FieldValue.serverTimestamp(),
        'rescheduleProposal': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (data['paymentStatus'] == 'paid') {
        await _processRefund(requestId, data);
      }

      developer.log(
        '✅ Inspection cancelled by $role for $requestId',
        name: 'InspectionService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error in handler cancel: $e',
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
                whereIn: ['pending','pendingPayment','pendingVerification','approved','declinedByAgent'],
              )
              .get();

      return snapshot.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Returns true if the current tenant has an inspection on this property
  /// at status 'approved' or 'completed'. Used to gate exact-address reveal
  /// on the property detail screen.
  Future<bool> hasApprovedInspection(String propertyId) async {
    if (_currentUserId == null) return false;
    try {
      final snapshot = await _firestore
          .collection('inspection_requests')
          .where('propertyId', isEqualTo: propertyId)
          .where('tenantId', isEqualTo: _currentUserId)
          .where('status', whereIn: ['approved', 'completed'])
          .get();
      return snapshot.docs.isNotEmpty;
    } catch (e) {
      developer.log('❌ Error checking approved inspection: $e',
          name: 'InspectionService');
      return false;
    }
  }

  // ============ AVAILABILITY ============

  /// Dates the handler offers, soonest first.
  ///
  /// [allowToday] opens up same-day booking. It is OFF by default because a
  /// brand-new request still has to be approved by the handler and paid for
  /// before the slot arrives — hours of notice makes that a wasted approval.
  /// A reschedule is already approved and paid, so moving it a few hours is
  /// just a time change, and that flow passes true.
  ///
  /// Today only survives if at least one of the property's slots is still
  /// beyond [bookingLeadTime]; otherwise the strip would offer a day whose
  /// every slot the picker then rejects.
  Future<List<DateTime>> getAvailableDates(
    PropertyModel property, {
    int daysAhead = 30,
    bool allowToday = false,
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
    final today = DateTime(now.year, now.month, now.day);
    final startDate =
        allowToday ? today : today.add(const Duration(days: 1));

    for (int i = 0; i < daysAhead; i++) {
      final date = startDate.add(Duration(days: i));
      final weekdayName = _getWeekdayName(date.weekday);

      if (!landlordDays.contains(weekdayName)) continue;
      if (agentDays.isNotEmpty && !agentDays.contains(weekdayName)) continue;

      // Today is the only day whose slots can already have started.
      if (date == today &&
          !property.inspectionTimeSlots.any((s) => isSlotBookable(date, s))) {
        continue;
      }

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

  /// Available inspection slots for [property] on [date].
  ///
  /// Delegates to the getAvailableInspectionSlots Cloud Function, which
  /// computes availability server-side (landlord ∩ agent slots minus the
  /// times the handler is already booked for). This MUST be server-side: a
  /// tenant isn't allowed to list another handler's inspections to find taken
  /// slots (that would leak other tenants' bookings), so the old client query
  /// was silently denied and every slot looked free — letting a tenant book
  /// a taken slot and pay before the server conflict-guard declined it.
  Future<List<String>> getAvailableTimeSlots(
    PropertyModel property,
    DateTime date,
  ) async {
    try {
      final callable = _functions.httpsCallable('getAvailableInspectionSlots');
      final result = await callable.call<Map<String, dynamic>>({
        'propertyId': property.id,
        'dateMillis': date.millisecondsSinceEpoch,
      });
      final slots = result.data['slots'];
      if (slots is List) {
        return slots
            .map((e) => e.toString())
            .where((s) => isSlotBookable(date, s))
            .toList();
      }
      return const [];
    } catch (e) {
      developer.log(
        'getAvailableInspectionSlots failed: $e',
        name: 'InspectionService',
      );
      // Fallback: the landlord's offered slots without booked-exclusion. The
      // server-side rejectIfSlotConflict guard still backstops a double-book.
      //
      // The lead-time filter is applied here too. This path bypasses the
      // callable entirely, so without it a failed call would re-offer slots
      // that have already started.
      return property.inspectionTimeSlots
          .where((s) => isSlotBookable(date, s))
          .toList();
    }
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
        'Payment verified for request: $requestId',
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
        'Agent confirmed payment: $requestId',
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
}
