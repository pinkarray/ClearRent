import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents an active rental agreement between tenant and landlord.
/// Created after payment is verified and landlord accepts the rental interest.
class ActiveRental {
  final String id;
  final String propertyId;
  final String tenantId;
  final String landlordId;
  final String inspectionRequestId;
  final String rentalInterestId;
  
  // Property details (denormalized for display)
  final String propertyTitle;
  final String propertyImage;
  final String propertyAddress;
  
  // User details (denormalized for display)
  final String tenantName;
  final String landlordName;
  final String? landlordPhone;
  
  // Financial details
  final double rentAmount;
  final double agentFee;
  final double totalPaid;
  final double inspectionFeeCredit;
  final String rentFrequency;
  
  // Lease details
  final DateTime leaseStartDate;
  final DateTime leaseEndDate;
  final DateTime nextPaymentDue;
  
  // Agreement workflow
  final String? agreementUrl;
  final DateTime? agreementUploadedAt;
  final AgreementStatus agreementStatus;
  final DateTime? tenantAcceptedAt;
  final String? tenantDisputeReason;
  final DateTime? landlordFinalizedAt;
  
  // Status
  final ActiveRentalStatus status;
  final bool hasPaymentReminder;
  
  // Timestamps
  final DateTime createdAt;
  final DateTime updatedAt;
  
  ActiveRental({
    required this.id,
    required this.propertyId,
    required this.tenantId,
    required this.landlordId,
    required this.inspectionRequestId,
    required this.rentalInterestId,
    required this.propertyTitle,
    required this.propertyImage,
    required this.propertyAddress,
    required this.tenantName,
    required this.landlordName,
    this.landlordPhone,
    required this.rentAmount,
    required this.agentFee,
    required this.totalPaid,
    this.inspectionFeeCredit = 5000,
    this.rentFrequency = 'yearly',
    required this.leaseStartDate,
    required this.leaseEndDate,
    required this.nextPaymentDue,
    this.agreementUrl,
    this.agreementUploadedAt,
    this.agreementStatus = AgreementStatus.none,
    this.tenantAcceptedAt,
    this.tenantDisputeReason,
    this.landlordFinalizedAt,
    this.status = ActiveRentalStatus.active,
    this.hasPaymentReminder = false,
    required this.createdAt,
    required this.updatedAt,
  });
  
  // Status helpers
  bool get isActive => status == ActiveRentalStatus.active;
  bool get isExpiringSoon => status == ActiveRentalStatus.expiringSoon;
  bool get isExpired => status == ActiveRentalStatus.expired;
  bool get isTerminated => status == ActiveRentalStatus.terminated;
  
  // Agreement helpers
  bool get hasAgreement => agreementUrl != null && agreementUrl!.isNotEmpty;
  bool get isAgreementPendingReview => agreementStatus == AgreementStatus.pendingReview;
  bool get isAgreementAccepted => agreementStatus == AgreementStatus.accepted;
  bool get isAgreementDisputed => agreementStatus == AgreementStatus.disputed;
  bool get isAgreementFinalized => agreementStatus == AgreementStatus.finalized;
  
  String get agreementStatusDisplay {
    switch (agreementStatus) {
      case AgreementStatus.none: return 'No Agreement';
      case AgreementStatus.pendingReview: return 'Pending Tenant Review';
      case AgreementStatus.accepted: return 'Accepted by Tenant';
      case AgreementStatus.disputed: return 'Tenant Has Concerns';
      case AgreementStatus.finalized: return 'Finalized';
    }
  }
  
  // Date helpers
  int get daysUntilPaymentDue => nextPaymentDue.difference(DateTime.now()).inDays;
  int get daysUntilLeaseEnd => leaseEndDate.difference(DateTime.now()).inDays;
  bool get isPaymentDueSoon => daysUntilPaymentDue <= 30 && daysUntilPaymentDue > 0;
  bool get isPaymentOverdue => daysUntilPaymentDue < 0;
  
  String get statusDisplay {
    switch (status) {
      case ActiveRentalStatus.active: return 'Active';
      case ActiveRentalStatus.expiringSoon: return 'Expiring Soon';
      case ActiveRentalStatus.expired: return 'Expired';
      case ActiveRentalStatus.terminated: return 'Terminated';
    }
  }
  
  String formatAmount(double amount) {
    if (amount >= 1000000) return '${(amount / 1000000).toStringAsFixed(1)}M';
    if (amount >= 1000) return '${(amount / 1000).toStringAsFixed(0)}K';
    return amount.toStringAsFixed(0);
  }
  
  String get formattedRent => '₦${formatAmount(rentAmount)}';
  String get rentPeriod => rentFrequency == 'yearly' ? '/year' : '/month';
  
  factory ActiveRental.fromFirestore(Map<String, dynamic> data, String docId) {
    return ActiveRental(
      id: docId,
      propertyId: data['propertyId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      landlordId: data['landlordId'] ?? '',
      inspectionRequestId: data['inspectionRequestId'] ?? '',
      rentalInterestId: data['rentalInterestId'] ?? '',
      propertyTitle: data['propertyTitle'] ?? '',
      propertyImage: data['propertyImage'] ?? '',
      propertyAddress: data['propertyAddress'] ?? '',
      tenantName: data['tenantName'] ?? '',
      landlordName: data['landlordName'] ?? '',
      landlordPhone: data['landlordPhone'],
      rentAmount: (data['rentAmount'] ?? 0).toDouble(),
      agentFee: (data['agentFee'] ?? 0).toDouble(),
      totalPaid: (data['totalPaid'] ?? 0).toDouble(),
      inspectionFeeCredit: (data['inspectionFeeCredit'] ?? 5000).toDouble(),
      rentFrequency: data['rentFrequency'] ?? 'yearly',
      leaseStartDate: (data['leaseStartDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      leaseEndDate: (data['leaseEndDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      nextPaymentDue: (data['nextPaymentDue'] as Timestamp?)?.toDate() ?? DateTime.now(),
      agreementUrl: data['agreementUrl'] as String?,
      agreementUploadedAt: data['agreementUploadedAt'] != null
          ? (data['agreementUploadedAt'] as Timestamp).toDate() : null,
      agreementStatus: _agreementStatusFromString(data['agreementStatus'] ?? 'none'),
      tenantAcceptedAt: data['tenantAcceptedAt'] != null
          ? (data['tenantAcceptedAt'] as Timestamp).toDate() : null,
      tenantDisputeReason: data['tenantDisputeReason'] as String?,
      landlordFinalizedAt: data['landlordFinalizedAt'] != null
          ? (data['landlordFinalizedAt'] as Timestamp).toDate() : null,
      status: _statusFromString(data['status'] ?? 'active'),
      hasPaymentReminder: data['hasPaymentReminder'] ?? false,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
  
  Map<String, dynamic> toFirestore() {
    return {
      'propertyId': propertyId,
      'tenantId': tenantId,
      'landlordId': landlordId,
      'inspectionRequestId': inspectionRequestId,
      'rentalInterestId': rentalInterestId,
      'propertyTitle': propertyTitle,
      'propertyImage': propertyImage,
      'propertyAddress': propertyAddress,
      'tenantName': tenantName,
      'landlordName': landlordName,
      'landlordPhone': landlordPhone,
      'rentAmount': rentAmount,
      'agentFee': agentFee,
      'totalPaid': totalPaid,
      'inspectionFeeCredit': inspectionFeeCredit,
      'rentFrequency': rentFrequency,
      'leaseStartDate': Timestamp.fromDate(leaseStartDate),
      'leaseEndDate': Timestamp.fromDate(leaseEndDate),
      'nextPaymentDue': Timestamp.fromDate(nextPaymentDue),
      if (agreementUrl != null) 'agreementUrl': agreementUrl,
      if (agreementUploadedAt != null) 'agreementUploadedAt': Timestamp.fromDate(agreementUploadedAt!),
      'agreementStatus': _agreementStatusToString(agreementStatus),
      if (tenantAcceptedAt != null) 'tenantAcceptedAt': Timestamp.fromDate(tenantAcceptedAt!),
      if (tenantDisputeReason != null) 'tenantDisputeReason': tenantDisputeReason,
      if (landlordFinalizedAt != null) 'landlordFinalizedAt': Timestamp.fromDate(landlordFinalizedAt!),
      'status': _statusToString(status),
      'hasPaymentReminder': hasPaymentReminder,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
  
  ActiveRental copyWith({
    String? id, String? propertyId, String? tenantId, String? landlordId,
    String? inspectionRequestId, String? rentalInterestId,
    String? propertyTitle, String? propertyImage, String? propertyAddress,
    String? tenantName, String? landlordName, String? landlordPhone,
    double? rentAmount, double? agentFee, double? totalPaid,
    double? inspectionFeeCredit, String? rentFrequency,
    DateTime? leaseStartDate, DateTime? leaseEndDate, DateTime? nextPaymentDue,
    String? agreementUrl, DateTime? agreementUploadedAt,
    AgreementStatus? agreementStatus, DateTime? tenantAcceptedAt,
    String? tenantDisputeReason, DateTime? landlordFinalizedAt,
    ActiveRentalStatus? status, bool? hasPaymentReminder,
    DateTime? createdAt, DateTime? updatedAt,
  }) {
    return ActiveRental(
      id: id ?? this.id,
      propertyId: propertyId ?? this.propertyId,
      tenantId: tenantId ?? this.tenantId,
      landlordId: landlordId ?? this.landlordId,
      inspectionRequestId: inspectionRequestId ?? this.inspectionRequestId,
      rentalInterestId: rentalInterestId ?? this.rentalInterestId,
      propertyTitle: propertyTitle ?? this.propertyTitle,
      propertyImage: propertyImage ?? this.propertyImage,
      propertyAddress: propertyAddress ?? this.propertyAddress,
      tenantName: tenantName ?? this.tenantName,
      landlordName: landlordName ?? this.landlordName,
      landlordPhone: landlordPhone ?? this.landlordPhone,
      rentAmount: rentAmount ?? this.rentAmount,
      agentFee: agentFee ?? this.agentFee,
      totalPaid: totalPaid ?? this.totalPaid,
      inspectionFeeCredit: inspectionFeeCredit ?? this.inspectionFeeCredit,
      rentFrequency: rentFrequency ?? this.rentFrequency,
      leaseStartDate: leaseStartDate ?? this.leaseStartDate,
      leaseEndDate: leaseEndDate ?? this.leaseEndDate,
      nextPaymentDue: nextPaymentDue ?? this.nextPaymentDue,
      agreementUrl: agreementUrl ?? this.agreementUrl,
      agreementUploadedAt: agreementUploadedAt ?? this.agreementUploadedAt,
      agreementStatus: agreementStatus ?? this.agreementStatus,
      tenantAcceptedAt: tenantAcceptedAt ?? this.tenantAcceptedAt,
      tenantDisputeReason: tenantDisputeReason ?? this.tenantDisputeReason,
      landlordFinalizedAt: landlordFinalizedAt ?? this.landlordFinalizedAt,
      status: status ?? this.status,
      hasPaymentReminder: hasPaymentReminder ?? this.hasPaymentReminder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
  
  static ActiveRentalStatus _statusFromString(String s) {
    switch (s) {
      case 'active': return ActiveRentalStatus.active;
      case 'expiring_soon': return ActiveRentalStatus.expiringSoon;
      case 'expired': return ActiveRentalStatus.expired;
      case 'terminated': return ActiveRentalStatus.terminated;
      default: return ActiveRentalStatus.active;
    }
  }
  
  static String _statusToString(ActiveRentalStatus s) {
    switch (s) {
      case ActiveRentalStatus.active: return 'active';
      case ActiveRentalStatus.expiringSoon: return 'expiring_soon';
      case ActiveRentalStatus.expired: return 'expired';
      case ActiveRentalStatus.terminated: return 'terminated';
    }
  }
  
  static AgreementStatus _agreementStatusFromString(String s) {
    switch (s) {
      case 'pending_review': return AgreementStatus.pendingReview;
      case 'accepted': return AgreementStatus.accepted;
      case 'disputed': return AgreementStatus.disputed;
      case 'finalized': return AgreementStatus.finalized;
      default: return AgreementStatus.none;
    }
  }
  
  static String _agreementStatusToString(AgreementStatus s) {
    switch (s) {
      case AgreementStatus.none: return 'none';
      case AgreementStatus.pendingReview: return 'pending_review';
      case AgreementStatus.accepted: return 'accepted';
      case AgreementStatus.disputed: return 'disputed';
      case AgreementStatus.finalized: return 'finalized';
    }
  }
}

enum ActiveRentalStatus { active, expiringSoon, expired, terminated }

enum AgreementStatus {
  none,            // No agreement uploaded yet
  pendingReview,   // Landlord uploaded, waiting for tenant review
  accepted,        // Tenant accepted
  disputed,        // Tenant raised concerns
  finalized,       // Landlord confirmed — agreement is complete
}