import 'package:cloud_firestore/cloud_firestore.dart';

/// A landlord's request to change rent on a property they own.
///
/// Two paths, discriminated by [changeType]:
///   - 'scheduled': property is OCCUPIED. Increase is staged with ≥6-month
///     notice and applied at the sitting tenant's renewal. Requires
///     [effectiveDate]. Approved by the approveRentReview CF.
///   - 'immediate': property has NO sitting tenant (error correction / vacant
///     re-pricing). Applies to property.rent immediately on admin approval.
///     No [effectiveDate]. Approved by the approveImmediateRentChange CF.
///
/// Field keys here are the contract the CFs read — do not rename without
/// updating rent_review_ops.ts.
class RentReviewRequest {
  final String id;
  final String landlordId;
  final String tenantId; // empty string for 'immediate' (no sitting tenant)
  final String rentalId; // empty string for 'immediate'
  final String propertyId;
  final String propertyTitle;
  final double currentRent;
  final double proposedRent;
  final DateTime? effectiveDate; // null for 'immediate'
  final String reasonType; // 'improvements' | 'market' | 'both'
  final String justification;
  // Revised tenancy agreement attached at filing (scheduled only, mandatory).
  // On approval the CF pushes this onto the active_rental's agreementUrl so the
  // sitting tenant reviews the new terms alongside the increase. Empty for
  // 'immediate' (vacant — no tenant).
  final String revisedAgreementUrl;
  final String changeType; // 'scheduled' | 'immediate'
  final String status; // 'pending' | 'approved' | 'rejected'
  final String? decisionReason;
  final String? decidedBy;
  final DateTime? decidedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  RentReviewRequest({
    required this.id,
    required this.landlordId,
    this.tenantId = '',
    this.rentalId = '',
    required this.propertyId,
    required this.propertyTitle,
    required this.currentRent,
    required this.proposedRent,
    this.effectiveDate,
    required this.reasonType,
    required this.justification,
    this.revisedAgreementUrl = '',
    this.changeType = 'scheduled',
    this.status = 'pending',
    this.decisionReason,
    this.decidedBy,
    this.decidedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isScheduled => changeType == 'scheduled';
  bool get isImmediate => changeType == 'immediate';
  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  factory RentReviewRequest.fromFirestore(
    Map<String, dynamic> data,
    String docId,
  ) {
    return RentReviewRequest(
      id: docId,
      landlordId: data['landlordId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      rentalId: data['rentalId'] ?? '',
      propertyId: data['propertyId'] ?? '',
      propertyTitle: data['propertyTitle'] ?? '',
      currentRent: (data['currentRent'] ?? 0).toDouble(),
      proposedRent: (data['proposedRent'] ?? 0).toDouble(),
      effectiveDate: (data['effectiveDate'] as Timestamp?)?.toDate(),
      reasonType: data['reasonType'] ?? 'market',
      justification: data['justification'] ?? '',
      revisedAgreementUrl: data['revisedAgreementUrl'] ?? '',
      changeType: data['changeType'] ?? 'scheduled',
      status: data['status'] ?? 'pending',
      decisionReason: data['decisionReason'] as String?,
      decidedBy: data['decidedBy'] as String?,
      decidedAt: (data['decidedAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'landlordId': landlordId,
      'tenantId': tenantId,
      'rentalId': rentalId,
      'propertyId': propertyId,
      'propertyTitle': propertyTitle,
      'currentRent': currentRent,
      'proposedRent': proposedRent,
      if (effectiveDate != null)
        'effectiveDate': Timestamp.fromDate(effectiveDate!),
      'reasonType': reasonType,
      'justification': justification,
      if (revisedAgreementUrl.isNotEmpty)
        'revisedAgreementUrl': revisedAgreementUrl,
      'changeType': changeType,
      'status': status,
      if (decisionReason != null) 'decisionReason': decisionReason,
      if (decidedBy != null) 'decidedBy': decidedBy,
      if (decidedAt != null) 'decidedAt': Timestamp.fromDate(decidedAt!),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}