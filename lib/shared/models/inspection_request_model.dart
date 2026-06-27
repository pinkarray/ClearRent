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
  expiredUnapproved,   // Paid but never approved before the date passed —
                       // tenant chooses reschedule or refund
  awaitingOutcome,     // Approved date passed without a clear completion —
                       // admin reviews (no-show / forgot to mark done)
}

/// Active reschedule proposal on an inspection request. Lives inside
/// the request doc as a nested map; null when no negotiation is in
/// progress. See RESCHEDULE_DESIGN.md.
class RescheduleProposal {
  final String proposedBy;          // 'tenant' | 'agent' | 'landlord'
  final String proposedByUserId;
  final DateTime proposedDate;
  final String proposedTimeSlot;
  final String proposedTimeDisplay;
  final String reason;
  final DateTime proposedAt;
  final bool tenantHasCountered;
  final bool handlerHasCountered;

  RescheduleProposal({
    required this.proposedBy,
    required this.proposedByUserId,
    required this.proposedDate,
    required this.proposedTimeSlot,
    required this.proposedTimeDisplay,
    required this.reason,
    required this.proposedAt,
    this.tenantHasCountered = false,
    this.handlerHasCountered = false,
  });

  factory RescheduleProposal.fromMap(Map<String, dynamic> data) {
    return RescheduleProposal(
      proposedBy: data['proposedBy'] ?? '',
      proposedByUserId: data['proposedByUserId'] ?? '',
      proposedDate: (data['proposedDate'] as Timestamp).toDate(),
      proposedTimeSlot: data['proposedTimeSlot'] ?? '',
      proposedTimeDisplay: data['proposedTimeDisplay'] ?? '',
      reason: data['reason'] ?? '',
      proposedAt: (data['proposedAt'] as Timestamp).toDate(),
      tenantHasCountered: data['tenantHasCountered'] ?? false,
      handlerHasCountered: data['handlerHasCountered'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'proposedBy': proposedBy,
      'proposedByUserId': proposedByUserId,
      'proposedDate': Timestamp.fromDate(proposedDate),
      'proposedTimeSlot': proposedTimeSlot,
      'proposedTimeDisplay': proposedTimeDisplay,
      'reason': reason,
      'proposedAt': Timestamp.fromDate(proposedAt),
      'tenantHasCountered': tenantHasCountered,
      'handlerHasCountered': handlerHasCountered,
    };
  }

  /// True when the receiving party can no longer counter-propose
  /// (their side already used its one counter slot).
  bool get receiverCannotCounter {
    final isTenantTurn = proposedBy != 'tenant';
    return isTenantTurn ? tenantHasCountered : handlerHasCountered;
  }
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
  final String? agentCluster;
  final String? propertyCluster;
  final String? propertyArea;
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
  /// True once the tenant decides not to rent this property ("I'll Keep Looking").
  /// Re-locks the exact address back to approximate. Persisted across restarts.
  final bool tenantPassed;
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

  // Who actually conducted the inspection (may differ from agentId if landlord overrode)
  final String? completedBy;       // UID of whoever pressed "Mark Complete"
  final String? completedByType;   // 'agent' or 'landlord'

  final bool agentConfirmedPayment;
  final DateTime? agentConfirmedAt;

  // Arrival tracking
  final bool tenantArrived;
  final DateTime? tenantArrivedAt;
  final bool handlerArrived;
  final DateTime? handlerArrivedAt;

  // On-the-way tracking
  final bool tenantOnWay;
  final DateTime? tenantOnWayAt;
  final bool handlerOnWay;
  final DateTime? handlerOnWayAt;

  // Met confirmation — gates the Mark as Completed button
  final bool met;
  final DateTime? metAt;
  final String? metBy; // 'tenant' | 'handler'

  // Reschedule
  final RescheduleProposal? rescheduleProposal;
  final int rescheduleCount;
  
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
    this.agentCluster,
    this.propertyCluster,
    this.propertyArea,
    this.transportFee = 0,
    this.agentServiceFee = 7000,
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
    this.tenantPassed = false,
    this.tenantReview,
    this.ratingSubmittedAt,
    this.ratedUserId,
    this.ratedUserType,
    this.ratedUserName,
    this.agentPayoutStatus = 'pending',
    this.agentPaidAt,
    this.agentPaidBy,
    this.completedBy,
    this.completedByType,
    this.agentConfirmedPayment = false,
    this.agentConfirmedAt,
    this.tenantArrived = false,
    this.tenantArrivedAt,
    this.handlerArrived = false,
    this.handlerArrivedAt,
    this.tenantOnWay = false,
    this.tenantOnWayAt,
    this.handlerOnWay = false,
    this.handlerOnWayAt,
    this.met = false,
    this.metAt,
    this.metBy,
    this.rescheduleProposal,
    this.rescheduleCount = 0,
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
  bool get isExpiredUnapproved =>
      status == InspectionStatus.expiredUnapproved;
  bool get isAwaitingOutcome => status == InspectionStatus.awaitingOutcome;
  
  bool get isPaid => paymentStatus == 'paid';
  bool get isPaymentPendingVerification => paymentStatus == 'pending_verification';
  bool get canBeOverridden => isDeclinedByAgent && 
      landlordOverrideDeadline != null && 
      DateTime.now().isBefore(landlordOverrideDeadline!);
  
  // If completedByType is recorded use it — it reflects who actually conducted the inspection.
  // Fall back to agentId check for older records that predate this field.
  bool get isAgentHandled => completedByType != null
      ? completedByType == 'agent'
      : agentId != null && agentId!.isNotEmpty;
  bool get bothArrived => tenantArrived && handlerArrived;

  // On-the-way helpers
  /// True if current time is within 2 hours of the scheduled slot.
  /// Mirror of isWithinRescheduleWindow — reschedule is allowed
  /// before the cutoff, on-way is allowed after.
  bool get isWithinOnWayWindow {
    final cutoff = requestedDate.subtract(const Duration(hours: 2));
    return DateTime.now().isAfter(cutoff);
  }

  bool get canTenantMarkOnWay =>
      isApproved && !tenantOnWay && isWithinOnWayWindow;

  bool get canHandlerMarkOnWay =>
      isApproved && !handlerOnWay && isWithinOnWayWindow;

  // Met confirmation helpers
  /// True when the tenant can tap "I've met the agent/landlord".
  bool get canTenantMarkMet =>
      tenantArrived && !met && isApproved;

  /// True when the handler can tap "I've met the tenant".
  /// Handler is a fallback path — they need tenant arrived (so
  /// they can't fake a meet on a tenant who never showed).
  bool get canHandlerMarkMet =>
      handlerArrived && tenantArrived && !met && isApproved;

  /// True when the handler may now tap Mark as Completed.
  bool get canMarkComplete => met && isApproved;

  // Reschedule helpers
  bool get hasPendingReschedule => rescheduleProposal != null;
  bool get hasReachedRescheduleCap => rescheduleCount >= 2;

  /// True if the current scheduled slot is more than 2 hours away.
  /// Reschedules are only allowed before this cutoff.
  bool get isWithinRescheduleWindow {
    final cutoff = requestedDate.subtract(const Duration(hours: 2));
    return DateTime.now().isBefore(cutoff);
  }

  /// True if a fresh reschedule can be initiated right now.
  bool get canInitiateReschedule =>
      isApproved &&
      !hasPendingReschedule &&
      !hasReachedRescheduleCap &&
      isWithinRescheduleWindow;

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
      case InspectionStatus.expiredUnapproved:
        return 'Expired — Action Needed';
      case InspectionStatus.awaitingOutcome:
        return 'Awaiting Review';
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
    String? agentCluster,
    String? propertyCluster,
    String? propertyArea,
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
    bool? tenantPassed,
    String? tenantReview,
    DateTime? ratingSubmittedAt,
    String? ratedUserId,
    String? ratedUserType,
    String? ratedUserName,
    String? agentPayoutStatus,
    DateTime? agentPaidAt,
    String? agentPaidBy,
    String? completedBy,
    String? completedByType,
    bool? agentConfirmedPayment,
    DateTime? agentConfirmedAt,
    bool? tenantArrived,
    DateTime? tenantArrivedAt,
    bool? handlerArrived,
    DateTime? handlerArrivedAt,
    bool? tenantOnWay,
    DateTime? tenantOnWayAt,
    bool? handlerOnWay,
    DateTime? handlerOnWayAt,
    bool? met,
    DateTime? metAt,
    String? metBy,
    RescheduleProposal? rescheduleProposal,
    bool clearRescheduleProposal = false,
    int? rescheduleCount,
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
      agentCluster: agentCluster ?? this.agentCluster,
      propertyCluster: propertyCluster ?? this.propertyCluster,
      propertyArea: propertyArea ?? this.propertyArea,
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
      tenantPassed: tenantPassed ?? this.tenantPassed,
      tenantReview: tenantReview ?? this.tenantReview,
      ratingSubmittedAt: ratingSubmittedAt ?? this.ratingSubmittedAt,
      ratedUserId: ratedUserId ?? this.ratedUserId,
      ratedUserType: ratedUserType ?? this.ratedUserType,
      ratedUserName: ratedUserName ?? this.ratedUserName,
      agentPayoutStatus: agentPayoutStatus ?? this.agentPayoutStatus,
      agentPaidAt: agentPaidAt ?? this.agentPaidAt,
      agentPaidBy: agentPaidBy ?? this.agentPaidBy,
      completedBy: completedBy ?? this.completedBy,
      completedByType: completedByType ?? this.completedByType,
      agentConfirmedPayment: agentConfirmedPayment ?? this.agentConfirmedPayment,
      agentConfirmedAt: agentConfirmedAt ?? this.agentConfirmedAt,
      tenantArrived: tenantArrived ?? this.tenantArrived,
      tenantArrivedAt: tenantArrivedAt ?? this.tenantArrivedAt,
      handlerArrived: handlerArrived ?? this.handlerArrived,
      handlerArrivedAt: handlerArrivedAt ?? this.handlerArrivedAt,
      tenantOnWay: tenantOnWay ?? this.tenantOnWay,
      tenantOnWayAt: tenantOnWayAt ?? this.tenantOnWayAt,
      handlerOnWay: handlerOnWay ?? this.handlerOnWay,
      handlerOnWayAt: handlerOnWayAt ?? this.handlerOnWayAt,
      met: met ?? this.met,
      metAt: metAt ?? this.metAt,
      metBy: metBy ?? this.metBy,
      rescheduleProposal: clearRescheduleProposal
          ? null
          : (rescheduleProposal ?? this.rescheduleProposal),
      rescheduleCount: rescheduleCount ?? this.rescheduleCount,
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
      agentCluster: data['agentCluster'],
      propertyCluster: data['propertyCluster'],
      propertyArea: data['propertyArea'],
      transportFee: (data['transportFee'] ?? 0).toDouble(),
      agentServiceFee: (data['agentServiceFee'] ?? 7000).toDouble(),
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
      // *** FIX: Parse tenantRated true if rating exists OR explicit field ***
      tenantRated: data['tenantRated'] ?? (data['tenantRating'] != null),
      tenantPassed: data['tenantPassed'] ?? false,
      tenantReview: data['tenantReview'],
      ratingSubmittedAt: (data['ratingSubmittedAt'] as Timestamp?)?.toDate(),
      ratedUserId: data['ratedUserId'],
      ratedUserType: data['ratedUserType'],
      ratedUserName: data['ratedUserName'],
      agentPayoutStatus: data['agentPayoutStatus'] ?? 'pending',
      agentPaidAt: (data['agentPaidAt'] as Timestamp?)?.toDate(),
      agentPaidBy: data['agentPaidBy'],
      completedBy: data['completedBy'],
      completedByType: data['completedByType'],
      agentConfirmedPayment: data['agentConfirmedPayment'] ?? false,
      agentConfirmedAt: (data['agentConfirmedAt'] as Timestamp?)?.toDate(),
      tenantArrived: data['tenantArrived'] ?? false,
      tenantArrivedAt: (data['tenantArrivedAt'] as Timestamp?)?.toDate(),
      handlerArrived: data['handlerArrived'] ?? false,
      handlerArrivedAt: (data['handlerArrivedAt'] as Timestamp?)?.toDate(),
      tenantOnWay: data['tenantOnWay'] ?? false,
      tenantOnWayAt: (data['tenantOnWayAt'] as Timestamp?)?.toDate(),
      handlerOnWay: data['handlerOnWay'] ?? false,
      handlerOnWayAt: (data['handlerOnWayAt'] as Timestamp?)?.toDate(),
      met: data['met'] ?? false,
      metAt: (data['metAt'] as Timestamp?)?.toDate(),
      metBy: data['metBy'] as String?,
      rescheduleProposal: data['rescheduleProposal'] == null
          ? null
          : RescheduleProposal.fromMap(
              Map<String, dynamic>.from(data['rescheduleProposal'] as Map),
            ),
      rescheduleCount: data['rescheduleCount'] ?? 0,
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
      'agentCluster': agentCluster,
      'propertyCluster': propertyCluster,
      'propertyArea': propertyArea,
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
      'tenantPassed': tenantPassed,
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
      'tenantOnWay': tenantOnWay,
      'tenantOnWayAt': tenantOnWayAt != null ? Timestamp.fromDate(tenantOnWayAt!) : null,
      'handlerOnWay': handlerOnWay,
      'handlerOnWayAt': handlerOnWayAt != null ? Timestamp.fromDate(handlerOnWayAt!) : null,
      'met': met,
      'metAt': metAt != null ? Timestamp.fromDate(metAt!) : null,
      'metBy': metBy,
      'rescheduleProposal': rescheduleProposal?.toMap(),
      'rescheduleCount': rescheduleCount,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}