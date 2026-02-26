import 'package:cloud_firestore/cloud_firestore.dart';

enum InspectionStatus {
  pendingPayment,      // Awaiting payment
  pendingVerification, // Payment proof uploaded, awaiting admin verification
  pending,             // Payment verified, waiting for agent/landlord response
  approved,            // Approved, scheduled
  declinedByAgent,     // Agent declined, landlord has 12hr window
  declined,            // Finally declined (after landlord window)
  completed,           // Inspection done
  cancelled,           // Cancelled by tenant
  refunded,            // Refund processed
}

class InspectionRequest {
  final String id;
  
  // Property info
  final String propertyId;
  final String propertyTitle;
  final String propertyImage;
  final String propertyAddress;
  final double? propertyLatitude;
  final double? propertyLongitude;
  
  // Tenant info
  final String tenantId;
  final String tenantName;
  final String? tenantPhone;
  
  // Landlord info
  final String landlordId;
  final String landlordName;
  final String? landlordPhone;
  
  // Agent info (null if self-handled by landlord)
  final String? agentId;
  final String? agentName;
  final String? agentPhone;
  final double? agentLatitude;
  final double? agentLongitude;
  
  // Schedule
  final DateTime requestedDate;
  final String requestedTimeSlot;
  final String requestedTimeDisplay;
  final String? notes;
  
  // Pricing
  final double distanceKm;
  final double transportFee;
  final double agentServiceFee;
  final double clearrentFee;
  final double totalFee;
  final double agentEarnings;
  
  // Payment
  final String paymentStatus; // pending, pending_verification, paid, refunded, not_required
  final String? paymentReference;
  final String? paymentProofUrl; // Screenshot of payment proof
  final DateTime? paidAt;
  final DateTime? paymentVerifiedAt; // When admin verified the payment
  final String? paymentVerifiedBy; // Admin who verified
  final DateTime? refundedAt;
  final String? refundReason;
  
  // Status
  final InspectionStatus status;
  final String? declinedBy; // 'agent' or 'landlord'
  final String? declineReason;
  final DateTime? declinedAt;
  final DateTime? landlordOverrideDeadline; // 12 hours after agent decline
  
  // Override tracking
  final bool wasOverridden;
  final String? overriddenBy; // landlordId if overridden
  final String? originalDeclineBy;
  
  // Completion & Rating
  final DateTime? completedAt;
  final int? tenantRating;
  final bool tenantRated;
  final String? tenantReview;
  final DateTime? ratingSubmittedAt;
  // Who the rating was given to (agent or landlord)
  final String? ratedUserId;
  final String? ratedUserType; // 'agent' or 'landlord'
  final String? ratedUserName;

  // Agent payout
  final String agentPayoutStatus; // pending, paid
  final DateTime? agentPaidAt;
  final String? agentPaidBy;

  final bool agentConfirmedPayment;
  final DateTime? agentConfirmedAt;

  // Arrival tracking
  final bool tenantArrived;
  final DateTime? tenantArrivedAt;
  final bool handlerArrived;
  final DateTime? handlerArrivedAt;
  
  // Timestamps
  final DateTime createdAt;
  final DateTime? updatedAt;

  InspectionRequest({
    required this.id,
    required this.propertyId,
    required this.propertyTitle,
    required this.propertyImage,
    required this.propertyAddress,
    this.propertyLatitude,
    this.propertyLongitude,
    required this.tenantId,
    required this.tenantName,
    this.tenantPhone,
    required this.landlordId,
    required this.landlordName,
    this.landlordPhone,
    this.agentId,
    this.agentName,
    this.agentPhone,
    this.agentLatitude,
    this.agentLongitude,
    required this.requestedDate,
    required this.requestedTimeSlot,
    required this.requestedTimeDisplay,
    this.notes,
    this.distanceKm = 0,
    this.transportFee = 0,
    this.agentServiceFee = 5000,
    this.clearrentFee = 3000,
    this.totalFee = 0,
    this.agentEarnings = 0,
    this.paymentStatus = 'pending',
    this.paymentReference,
    this.paymentProofUrl,
    this.paidAt,
    this.paymentVerifiedAt,
    this.paymentVerifiedBy,
    this.refundedAt,
    this.refundReason,
    this.status = InspectionStatus.pendingPayment,
    this.declinedBy,
    this.declineReason,
    this.declinedAt,
    this.landlordOverrideDeadline,
    this.wasOverridden = false,
    this.overriddenBy,
    this.originalDeclineBy,
    this.completedAt,
    this.tenantRating,
    this.tenantRated = false,
    this.tenantReview,
    this.ratingSubmittedAt,
    this.ratedUserId,
    this.ratedUserType,
    this.ratedUserName,
    this.agentPayoutStatus = 'pending',
    this.agentPaidAt,
    this.agentPaidBy,
    this.agentConfirmedPayment = false,
    this.agentConfirmedAt,
    this.tenantArrived = false,
    this.tenantArrivedAt,
    this.handlerArrived = false,
    this.handlerArrivedAt,
    required this.createdAt,
    this.updatedAt,
  });

  // Status helpers
  bool get isPendingPayment => status == InspectionStatus.pendingPayment;
  bool get isPendingVerification => status == InspectionStatus.pendingVerification;
  bool get isPending => status == InspectionStatus.pending;
  bool get isApproved => status == InspectionStatus.approved;
  bool get isDeclinedByAgent => status == InspectionStatus.declinedByAgent;
  bool get isDeclined => status == InspectionStatus.declined;
  bool get isCompleted => status == InspectionStatus.completed;
  bool get isCancelled => status == InspectionStatus.cancelled;
  bool get isRefunded => status == InspectionStatus.refunded;
  
  bool get isPaid => paymentStatus == 'paid';
  bool get isPaymentPendingVerification => paymentStatus == 'pending_verification';
  bool get canBeOverridden => isDeclinedByAgent && 
      landlordOverrideDeadline != null && 
      DateTime.now().isBefore(landlordOverrideDeadline!);
  
  bool get isAgentHandled => agentId != null;
  bool get bothArrived => tenantArrived && handlerArrived;

  // Display status
  String get statusDisplay {
    switch (status) {
      case InspectionStatus.pendingPayment:
        return 'Awaiting Payment';
      case InspectionStatus.pendingVerification:
        return 'Verifying Payment';
      case InspectionStatus.pending:
        return 'Pending';
      case InspectionStatus.approved:
        return 'Approved';
      case InspectionStatus.declinedByAgent:
        return 'Agent Declined';
      case InspectionStatus.declined:
        return 'Declined';
      case InspectionStatus.completed:
        return 'Completed';
      case InspectionStatus.cancelled:
        return 'Cancelled';
      case InspectionStatus.refunded:
        return 'Refunded';
    }
  }

  // Format date for display
  String get formattedDate {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    
    return '${weekdays[requestedDate.weekday - 1]}, ${months[requestedDate.month - 1]} ${requestedDate.day}';
  }

  // Time remaining for landlord override
  Duration? get overrideTimeRemaining {
    if (landlordOverrideDeadline == null) return null;
    final remaining = landlordOverrideDeadline!.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  String? get overrideTimeRemainingDisplay {
    final remaining = overrideTimeRemaining;
    if (remaining == null) return null;
    
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h ${remaining.inMinutes % 60}m left';
    } else if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m left';
    } else {
      return 'Less than a minute';
    }
  }

  // Copy with
  InspectionRequest copyWith({
    String? id,
    String? propertyId,
    String? propertyTitle,
    String? propertyImage,
    String? propertyAddress,
    double? propertyLatitude,
    double? propertyLongitude,
    String? tenantId,
    String? tenantName,
    String? tenantPhone,
    String? landlordId,
    String? landlordName,
    String? landlordPhone,
    String? agentId,
    String? agentName,
    String? agentPhone,
    double? agentLatitude,
    double? agentLongitude,
    DateTime? requestedDate,
    String? requestedTimeSlot,
    String? requestedTimeDisplay,
    String? notes,
    double? distanceKm,
    double? transportFee,
    double? agentServiceFee,
    double? clearrentFee,
    double? totalFee,
    double? agentEarnings,
    String? paymentStatus,
    String? paymentReference,
    String? paymentProofUrl,
    DateTime? paidAt,
    DateTime? paymentVerifiedAt,
    String? paymentVerifiedBy,
    DateTime? refundedAt,
    String? refundReason,
    InspectionStatus? status,
    String? declinedBy,
    String? declineReason,
    DateTime? declinedAt,
    DateTime? landlordOverrideDeadline,
    bool? wasOverridden,
    String? overriddenBy,
    String? originalDeclineBy,
    DateTime? completedAt,
    int? tenantRating,
    bool? tenantRated,
    String? tenantReview,
    DateTime? ratingSubmittedAt,
    String? ratedUserId,
    String? ratedUserType,
    String? ratedUserName,
    String? agentPayoutStatus,
    DateTime? agentPaidAt,
    String? agentPaidBy,
    bool? agentConfirmedPayment,
    DateTime? agentConfirmedAt,
    bool? tenantArrived,
    DateTime? tenantArrivedAt,
    bool? handlerArrived,
    DateTime? handlerArrivedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return InspectionRequest(
      id: id ?? this.id,
      propertyId: propertyId ?? this.propertyId,
      propertyTitle: propertyTitle ?? this.propertyTitle,
      propertyImage: propertyImage ?? this.propertyImage,
      propertyAddress: propertyAddress ?? this.propertyAddress,
      propertyLatitude: propertyLatitude ?? this.propertyLatitude,
      propertyLongitude: propertyLongitude ?? this.propertyLongitude,
      tenantId: tenantId ?? this.tenantId,
      tenantName: tenantName ?? this.tenantName,
      tenantPhone: tenantPhone ?? this.tenantPhone,
      landlordId: landlordId ?? this.landlordId,
      landlordName: landlordName ?? this.landlordName,
      landlordPhone: landlordPhone ?? this.landlordPhone,
      agentId: agentId ?? this.agentId,
      agentName: agentName ?? this.agentName,
      agentPhone: agentPhone ?? this.agentPhone,
      agentLatitude: agentLatitude ?? this.agentLatitude,
      agentLongitude: agentLongitude ?? this.agentLongitude,
      requestedDate: requestedDate ?? this.requestedDate,
      requestedTimeSlot: requestedTimeSlot ?? this.requestedTimeSlot,
      requestedTimeDisplay: requestedTimeDisplay ?? this.requestedTimeDisplay,
      notes: notes ?? this.notes,
      distanceKm: distanceKm ?? this.distanceKm,
      transportFee: transportFee ?? this.transportFee,
      agentServiceFee: agentServiceFee ?? this.agentServiceFee,
      clearrentFee: clearrentFee ?? this.clearrentFee,
      totalFee: totalFee ?? this.totalFee,
      agentEarnings: agentEarnings ?? this.agentEarnings,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      paymentReference: paymentReference ?? this.paymentReference,
      paymentProofUrl: paymentProofUrl ?? this.paymentProofUrl,
      paidAt: paidAt ?? this.paidAt,
      paymentVerifiedAt: paymentVerifiedAt ?? this.paymentVerifiedAt,
      paymentVerifiedBy: paymentVerifiedBy ?? this.paymentVerifiedBy,
      refundedAt: refundedAt ?? this.refundedAt,
      refundReason: refundReason ?? this.refundReason,
      status: status ?? this.status,
      declinedBy: declinedBy ?? this.declinedBy,
      declineReason: declineReason ?? this.declineReason,
      declinedAt: declinedAt ?? this.declinedAt,
      landlordOverrideDeadline: landlordOverrideDeadline ?? this.landlordOverrideDeadline,
      wasOverridden: wasOverridden ?? this.wasOverridden,
      overriddenBy: overriddenBy ?? this.overriddenBy,
      originalDeclineBy: originalDeclineBy ?? this.originalDeclineBy,
      completedAt: completedAt ?? this.completedAt,
      tenantRating: tenantRating ?? this.tenantRating,
      tenantRated: tenantRated ?? this.tenantRated,
      tenantReview: tenantReview ?? this.tenantReview,
      ratingSubmittedAt: ratingSubmittedAt ?? this.ratingSubmittedAt,
      ratedUserId: ratedUserId ?? this.ratedUserId,
      ratedUserType: ratedUserType ?? this.ratedUserType,
      ratedUserName: ratedUserName ?? this.ratedUserName,
      agentPayoutStatus: agentPayoutStatus ?? this.agentPayoutStatus,
      agentPaidAt: agentPaidAt ?? this.agentPaidAt,
      agentPaidBy: agentPaidBy ?? this.agentPaidBy,
      agentConfirmedPayment: agentConfirmedPayment ?? this.agentConfirmedPayment,
      agentConfirmedAt: agentConfirmedAt ?? this.agentConfirmedAt,
      tenantArrived: tenantArrived ?? this.tenantArrived,
      tenantArrivedAt: tenantArrivedAt ?? this.tenantArrivedAt,
      handlerArrived: handlerArrived ?? this.handlerArrived,
      handlerArrivedAt: handlerArrivedAt ?? this.handlerArrivedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // From Firestore
  factory InspectionRequest.fromFirestore(Map<String, dynamic> data, String docId) {
    return InspectionRequest(
      id: docId,
      propertyId: data['propertyId'] ?? '',
      propertyTitle: data['propertyTitle'] ?? '',
      propertyImage: data['propertyImage'] ?? '',
      propertyAddress: data['propertyAddress'] ?? '',
      propertyLatitude: data['propertyLatitude']?.toDouble(),
      propertyLongitude: data['propertyLongitude']?.toDouble(),
      tenantId: data['tenantId'] ?? '',
      tenantName: data['tenantName'] ?? '',
      tenantPhone: data['tenantPhone'],
      landlordId: data['landlordId'] ?? '',
      landlordName: data['landlordName'] ?? '',
      landlordPhone: data['landlordPhone'],
      agentId: data['agentId'],
      agentName: data['agentName'],
      agentPhone: data['agentPhone'],
      agentLatitude: data['agentLatitude']?.toDouble(),
      agentLongitude: data['agentLongitude']?.toDouble(),
      requestedDate: (data['requestedDate'] as Timestamp).toDate(),
      requestedTimeSlot: data['requestedTimeSlot'] ?? '',
      requestedTimeDisplay: data['requestedTimeDisplay'] ?? '',
      notes: data['notes'],
      distanceKm: (data['distanceKm'] ?? 0).toDouble(),
      transportFee: (data['transportFee'] ?? 0).toDouble(),
      agentServiceFee: (data['agentServiceFee'] ?? 5000).toDouble(),
      clearrentFee: (data['clearrentFee'] ?? 3000).toDouble(),
      totalFee: (data['totalFee'] ?? 0).toDouble(),
      agentEarnings: (data['agentEarnings'] ?? 0).toDouble(),
      paymentStatus: data['paymentStatus'] ?? 'pending',
      paymentReference: data['paymentReference'],
      paymentProofUrl: data['paymentProofUrl'],
      paidAt: (data['paidAt'] as Timestamp?)?.toDate(),
      paymentVerifiedAt: (data['paymentVerifiedAt'] as Timestamp?)?.toDate(),
      paymentVerifiedBy: data['paymentVerifiedBy'],
      refundedAt: (data['refundedAt'] as Timestamp?)?.toDate(),
      refundReason: data['refundReason'],
      status: InspectionStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => InspectionStatus.pending,
      ),
      declinedBy: data['declinedBy'],
      declineReason: data['declineReason'],
      declinedAt: (data['declinedAt'] as Timestamp?)?.toDate(),
      landlordOverrideDeadline: (data['landlordOverrideDeadline'] as Timestamp?)?.toDate(),
      wasOverridden: data['wasOverridden'] ?? false,
      overriddenBy: data['overriddenBy'],
      originalDeclineBy: data['originalDeclineBy'],
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      // *** FIX: Parse tenantRating from Firestore ***
      tenantRating: data['tenantRating'],
      // *** FIX: Parse tenantRated â€” true if rating exists OR explicit field ***
      tenantRated: data['tenantRated'] ?? (data['tenantRating'] != null),
      tenantReview: data['tenantReview'],
      ratingSubmittedAt: (data['ratingSubmittedAt'] as Timestamp?)?.toDate(),
      ratedUserId: data['ratedUserId'],
      ratedUserType: data['ratedUserType'],
      ratedUserName: data['ratedUserName'],
      agentPayoutStatus: data['agentPayoutStatus'] ?? 'pending',
      agentPaidAt: (data['agentPaidAt'] as Timestamp?)?.toDate(),
      agentPaidBy: data['agentPaidBy'],
      agentConfirmedPayment: data['agentConfirmedPayment'] ?? false,
      agentConfirmedAt: (data['agentConfirmedAt'] as Timestamp?)?.toDate(),
      tenantArrived: data['tenantArrived'] ?? false,
      tenantArrivedAt: (data['tenantArrivedAt'] as Timestamp?)?.toDate(),
      handlerArrived: data['handlerArrived'] ?? false,
      handlerArrivedAt: (data['handlerArrivedAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  // To Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'propertyId': propertyId,
      'propertyTitle': propertyTitle,
      'propertyImage': propertyImage,
      'propertyAddress': propertyAddress,
      'propertyLatitude': propertyLatitude,
      'propertyLongitude': propertyLongitude,
      'tenantId': tenantId,
      'tenantName': tenantName,
      'tenantPhone': tenantPhone,
      'landlordId': landlordId,
      'landlordName': landlordName,
      'landlordPhone': landlordPhone,
      'agentId': agentId,
      'agentName': agentName,
      'agentPhone': agentPhone,
      'agentLatitude': agentLatitude,
      'agentLongitude': agentLongitude,
      'requestedDate': Timestamp.fromDate(requestedDate),
      'requestedTimeSlot': requestedTimeSlot,
      'requestedTimeDisplay': requestedTimeDisplay,
      'notes': notes,
      'distanceKm': distanceKm,
      'transportFee': transportFee,
      'agentServiceFee': agentServiceFee,
      'clearrentFee': clearrentFee,
      'totalFee': totalFee,
      'agentEarnings': agentEarnings,
      'paymentStatus': paymentStatus,
      'paymentReference': paymentReference,
      'paymentProofUrl': paymentProofUrl,
      'paidAt': paidAt != null ? Timestamp.fromDate(paidAt!) : null,
      'paymentVerifiedAt': paymentVerifiedAt != null ? Timestamp.fromDate(paymentVerifiedAt!) : null,
      'paymentVerifiedBy': paymentVerifiedBy,
      'refundedAt': refundedAt != null ? Timestamp.fromDate(refundedAt!) : null,
      'refundReason': refundReason,
      'status': status.name,
      'declinedBy': declinedBy,
      'declineReason': declineReason,
      'declinedAt': declinedAt != null ? Timestamp.fromDate(declinedAt!) : null,
      'landlordOverrideDeadline': landlordOverrideDeadline != null 
          ? Timestamp.fromDate(landlordOverrideDeadline!) 
          : null,
      'wasOverridden': wasOverridden,
      'overriddenBy': overriddenBy,
      'originalDeclineBy': originalDeclineBy,
      'completedAt': completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'tenantRating': tenantRating,
      'tenantRated': tenantRated,
      'tenantReview': tenantReview,
      'ratingSubmittedAt': ratingSubmittedAt != null ? Timestamp.fromDate(ratingSubmittedAt!) : null,
      'ratedUserId': ratedUserId,
      'ratedUserType': ratedUserType,
      'ratedUserName': ratedUserName,
      'agentPayoutStatus': agentPayoutStatus,
      'agentPaidAt': agentPaidAt != null ? Timestamp.fromDate(agentPaidAt!) : null,
      'agentPaidBy': agentPaidBy,
      'agentConfirmedPayment': agentConfirmedPayment,
      'agentConfirmedAt': agentConfirmedAt != null ? Timestamp.fromDate(agentConfirmedAt!) : null,
      'tenantArrived': tenantArrived,
      'tenantArrivedAt': tenantArrivedAt != null ? Timestamp.fromDate(tenantArrivedAt!) : null,
      'handlerArrived': handlerArrived,
      'handlerArrivedAt': handlerArrivedAt != null ? Timestamp.fromDate(handlerArrivedAt!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}