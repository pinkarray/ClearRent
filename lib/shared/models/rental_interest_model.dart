import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a tenant's interest in renting a property after inspection.
/// Tracks the payment process from interest declaration to rental confirmation.
class RentalInterest {
  final String id;
  final String inspectionRequestId;
  final String propertyId;
  final String tenantId;
  final String landlordId;
  final String? agentId;
  
  // Property details (denormalized for display)
  final String propertyTitle;
  final String propertyImage;
  final String propertyAddress;
  
  // User details (denormalized for display)
  final String tenantName;
  final String landlordName;
  final String? agentName;
  
  // Status tracking
  final RentalInterestStatus status;
  
  // Payment details
  final double paymentAmount;
  final double rentAmount;
  final double agentFee;
  final double tenantDealFee;
  final double landlordDealFee;
  final double agentDealFee;
  final double landlordPayout;   // rent - landlordDealFee
  final double agentPayout;      // agentFee - agentDealFee
  final double clearrentEarnings; // sum of all deal fees
  final String? paymentReceiptUrl;
  final DateTime? paymentUploadedAt;
  final DateTime? paymentVerifiedAt;
  final String? paymentVerifiedBy; // Admin UID
  final String? paymentRejectionReason;
  
  // Timestamps
  final DateTime createdAt;
  final DateTime updatedAt;
  
  RentalInterest({
    required this.id,
    required this.inspectionRequestId,
    required this.propertyId,
    required this.tenantId,
    required this.landlordId,
    this.agentId,
    required this.propertyTitle,
    required this.propertyImage,
    required this.propertyAddress,
    required this.tenantName,
    required this.landlordName,
    this.agentName,
    required this.status,
    required this.paymentAmount,
    this.rentAmount = 0,
    this.agentFee = 0,
    this.tenantDealFee = 5000,
    this.landlordDealFee = 5000,
    this.agentDealFee = 5000,
    this.landlordPayout = 0,
    this.agentPayout = 0,
    this.clearrentEarnings = 0,
    this.paymentReceiptUrl,
    this.paymentUploadedAt,
    this.paymentVerifiedAt,
    this.paymentVerifiedBy,
    this.paymentRejectionReason,
    required this.createdAt,
    required this.updatedAt,
  });
  
  // Status helpers
  bool get isPendingAcceptance =>
      status == RentalInterestStatus.pendingAcceptance;
  bool get isPendingPayment => status == RentalInterestStatus.pendingPayment;
  bool get isPaymentUploaded => status == RentalInterestStatus.paymentUploaded;
  bool get isPaymentVerified => status == RentalInterestStatus.paymentVerified;
  bool get isRejected => status == RentalInterestStatus.rejected;
  bool get isAccepted => status == RentalInterestStatus.accepted;
  bool get isRentPaid => status == RentalInterestStatus.rentPaid;
  bool get isNotSelected => status == RentalInterestStatus.notSelected;
  bool get isExpired => status == RentalInterestStatus.expired;
  bool get isLostToOther => status == RentalInterestStatus.lostToOther;
  
  String get statusDisplay {
    switch (status) {
      case RentalInterestStatus.pendingAcceptance:
        return 'Awaiting Landlord';
      case RentalInterestStatus.pendingPayment:
        return 'Awaiting Payment';
      case RentalInterestStatus.paymentUploaded:
        return 'Verifying Payment';
      case RentalInterestStatus.paymentVerified:
        return 'Payment Confirmed';
      case RentalInterestStatus.rejected:
        return 'Payment Rejected';
      case RentalInterestStatus.accepted:
        return 'Accepted - Finalize Agreement';
      case RentalInterestStatus.rentPaid:
        return 'Rent Paid';
      case RentalInterestStatus.notSelected:
        return 'Not Selected';
      case RentalInterestStatus.expired:
        return 'Reservation Expired';
      case RentalInterestStatus.lostToOther:
        return 'Refund Processing';
    }
  }
  
  // From Firestore
  factory RentalInterest.fromFirestore(Map<String, dynamic> data, String docId) {
    return RentalInterest(
      id: docId,
      inspectionRequestId: data['inspectionRequestId'] ?? '',
      propertyId: data['propertyId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      landlordId: data['landlordId'] ?? '',
      agentId: data['agentId'],
      propertyTitle: data['propertyTitle'] ?? '',
      propertyImage: data['propertyImage'] ?? '',
      propertyAddress: data['propertyAddress'] ?? '',
      tenantName: data['tenantName'] ?? '',
      landlordName: data['landlordName'] ?? '',
      agentName: data['agentName'],
      status: _statusFromString(data['status'] ?? 'pending_payment'),
      paymentAmount: (data['paymentAmount'] ?? 0).toDouble(),
      rentAmount: (data['rentAmount'] ?? 0).toDouble(),
      agentFee: (data['agentFee'] ?? 0).toDouble(),
      tenantDealFee: (data['tenantDealFee'] ?? 5000).toDouble(),
      landlordDealFee: (data['landlordDealFee'] ?? 5000).toDouble(),
      agentDealFee: (data['agentDealFee'] ?? 5000).toDouble(),
      landlordPayout: (data['landlordPayout'] ?? 0).toDouble(),
      agentPayout: (data['agentPayout'] ?? 0).toDouble(),
      clearrentEarnings: (data['clearrentEarnings'] ?? 0).toDouble(),
      paymentReceiptUrl: data['paymentReceiptUrl'],
      paymentUploadedAt: (data['paymentUploadedAt'] as Timestamp?)?.toDate(),
      paymentVerifiedAt: (data['paymentVerifiedAt'] as Timestamp?)?.toDate(),
      paymentVerifiedBy: data['paymentVerifiedBy'],
      paymentRejectionReason: data['paymentRejectionReason'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
  
  // To Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'inspectionRequestId': inspectionRequestId,
      'propertyId': propertyId,
      'tenantId': tenantId,
      'landlordId': landlordId,
      'agentId': agentId,
      'propertyTitle': propertyTitle,
      'propertyImage': propertyImage,
      'propertyAddress': propertyAddress,
      'tenantName': tenantName,
      'landlordName': landlordName,
      'agentName': agentName,
      'status': _statusToString(status),
      'paymentAmount': paymentAmount,
      'rentAmount': rentAmount,
      'agentFee': agentFee,
      'tenantDealFee': tenantDealFee,
      'landlordDealFee': landlordDealFee,
      'agentDealFee': agentDealFee,
      'landlordPayout': landlordPayout,
      'agentPayout': agentPayout,
      'clearrentEarnings': clearrentEarnings,
      'paymentReceiptUrl': paymentReceiptUrl,
      'paymentUploadedAt': paymentUploadedAt != null 
          ? Timestamp.fromDate(paymentUploadedAt!) 
          : null,
      'paymentVerifiedAt': paymentVerifiedAt != null 
          ? Timestamp.fromDate(paymentVerifiedAt!) 
          : null,
      'paymentVerifiedBy': paymentVerifiedBy,
      'paymentRejectionReason': paymentRejectionReason,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
  
  // Copy with
  RentalInterest copyWith({
    String? id,
    String? inspectionRequestId,
    String? propertyId,
    String? tenantId,
    String? landlordId,
    String? agentId,
    String? propertyTitle,
    String? propertyImage,
    String? propertyAddress,
    String? tenantName,
    String? landlordName,
    String? agentName,
    RentalInterestStatus? status,
    double? paymentAmount,
    double? rentAmount,
    double? agentFee,
    double? tenantDealFee,
    double? landlordDealFee,
    double? agentDealFee,
    double? landlordPayout,
    double? agentPayout,
    double? clearrentEarnings,
    String? paymentReceiptUrl,
    DateTime? paymentUploadedAt,
    DateTime? paymentVerifiedAt,
    String? paymentVerifiedBy,
    String? paymentRejectionReason,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return RentalInterest(
      id: id ?? this.id,
      inspectionRequestId: inspectionRequestId ?? this.inspectionRequestId,
      propertyId: propertyId ?? this.propertyId,
      tenantId: tenantId ?? this.tenantId,
      landlordId: landlordId ?? this.landlordId,
      agentId: agentId ?? this.agentId,
      propertyTitle: propertyTitle ?? this.propertyTitle,
      propertyImage: propertyImage ?? this.propertyImage,
      propertyAddress: propertyAddress ?? this.propertyAddress,
      tenantName: tenantName ?? this.tenantName,
      landlordName: landlordName ?? this.landlordName,
      agentName: agentName ?? this.agentName,
      status: status ?? this.status,
      paymentAmount: paymentAmount ?? this.paymentAmount,
      rentAmount: rentAmount ?? this.rentAmount,
      agentFee: agentFee ?? this.agentFee,
      tenantDealFee: tenantDealFee ?? this.tenantDealFee,
      landlordDealFee: landlordDealFee ?? this.landlordDealFee,
      agentDealFee: agentDealFee ?? this.agentDealFee,
      landlordPayout: landlordPayout ?? this.landlordPayout,
      agentPayout: agentPayout ?? this.agentPayout,
      clearrentEarnings: clearrentEarnings ?? this.clearrentEarnings,
      paymentReceiptUrl: paymentReceiptUrl ?? this.paymentReceiptUrl,
      paymentUploadedAt: paymentUploadedAt ?? this.paymentUploadedAt,
      paymentVerifiedAt: paymentVerifiedAt ?? this.paymentVerifiedAt,
      paymentVerifiedBy: paymentVerifiedBy ?? this.paymentVerifiedBy,
      paymentRejectionReason: paymentRejectionReason ?? this.paymentRejectionReason,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
  
  // Helper methods
  static RentalInterestStatus _statusFromString(String status) {
    switch (status) {
      case 'pending_acceptance':
        return RentalInterestStatus.pendingAcceptance;
      case 'pending_payment':
        return RentalInterestStatus.pendingPayment;
      case 'payment_uploaded':
        return RentalInterestStatus.paymentUploaded;
      case 'payment_verified':
        return RentalInterestStatus.paymentVerified;
      case 'rejected':
        return RentalInterestStatus.rejected;
      case 'accepted':
        return RentalInterestStatus.accepted;
      case 'rent_paid':
        return RentalInterestStatus.rentPaid;
      case 'not_selected':
        return RentalInterestStatus.notSelected;
      case 'expired':
        return RentalInterestStatus.expired;
      case 'lost_to_other':
        return RentalInterestStatus.lostToOther;
      default:
        return RentalInterestStatus.pendingAcceptance;
    }
  }

  static String _statusToString(RentalInterestStatus status) {
    switch (status) {
      case RentalInterestStatus.pendingAcceptance:
        return 'pending_acceptance';
      case RentalInterestStatus.pendingPayment:
        return 'pending_payment';
      case RentalInterestStatus.paymentUploaded:
        return 'payment_uploaded';
      case RentalInterestStatus.paymentVerified:
        return 'payment_verified';
      case RentalInterestStatus.rejected:
        return 'rejected';
      case RentalInterestStatus.accepted:
        return 'accepted';
      case RentalInterestStatus.rentPaid:
        return 'rent_paid';
      case RentalInterestStatus.notSelected:
        return 'not_selected';
      case RentalInterestStatus.expired:
        return 'expired';
      case RentalInterestStatus.lostToOther:
        return 'lost_to_other';
    }
  }
}

/// Status of rental interest payment flow.
///
/// New pay-after-accept order (only the accepted tenant ever pays):
///   pendingAcceptance → accepted → rentPaid
/// The pre-accept states below (pendingPayment/paymentUploaded/paymentVerified)
/// are retained for legacy in-flight interests created under the old
/// pay-before-accept flow; new interests never enter them.
enum RentalInterestStatus {
  pendingAcceptance, // Tenant expressed interest, UNPAID, awaiting landlord pick
  pendingPayment,   // LEGACY: tenant declared interest, hasn't paid yet
  paymentUploaded,  // LEGACY: tenant uploaded payment receipt
  paymentVerified,  // LEGACY: admin verified payment (landlord locked in)
  rejected,         // Payment rejected by admin
  accepted,         // Landlord accepted; active rental created; UNPAID until rentPaid
  rentPaid,         // Accepted tenant paid rent after agreement finalized (terminal)
  notSelected,      // Unpaid applicant closed out because landlord picked another
  expired,          // Accepted but never paid in time; reservation released, slot freed
  lostToOther,      // LEGACY paid loser: property rented to another; full refund due
}