import 'package:cloud_firestore/cloud_firestore.dart';
import 'tenancy_link_model.dart';

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
  final double? pendingRentForRenewal;
  final DateTime? pendingRentEffectiveDate;
  final double agentFee;
  final double totalPaid;
  // Pay-after-accept: 'pending' until the accepted tenant pays rent (after the
  // agreement is finalized), then 'paid'. Legacy rentals created under the old
  // pay-before-accept flow have no field — treated as already paid.
  final String rentPaymentStatus;    // pending | paid
  final double inspectionFeeCredit;
  final String rentFrequency;
  
  // Payout details
  final double landlordPayout;
  final double agentPayout;
  final double clearrentEarnings;
  final String landlordPayoutStatus;  // pending | paid | not_applicable
  final String agentPayoutStatus;     // pending | paid | not_applicable
  final DateTime? landlordPaidAt;
  final DateTime? agentPaidAt;
  
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

  /// The copy the TENANT signed and uploaded. Their acceptance is this
  /// document, not a button press — a status and a timestamp in our own
  /// database is something a tenant can simply deny having agreed to.
  final String? tenantSignedUrl;
  final DateTime? tenantSignedAt;

  /// The counter-signed copy carrying BOTH signatures. Once present this is
  /// the agreement of record; the original and the tenant-signed copy are the
  /// trail behind it.
  final String? executedAgreementUrl;
  final DateTime? executedAt;

  /// Set when the landlord replaces the agreement on a LIVE tenancy.
  final DateTime? agreementRevisedAt;

  /// The landlord's declaration that a revision changes terms only, leaving
  /// the rent alone. Recorded rather than trusted: the tenant is shown it and
  /// can contradict it, and a false declaration is then provable.
  final bool agreementRevisionTermsOnly;

  /// The rent on record when that declaration was made, so the tenant can
  /// compare one number instead of auditing the document.
  final double? agreementRevisionDeclaredRent;

  /// The tenant says the revision DOES change the rent. Blocks signing and
  /// raises an admin alert carrying both sides.
  final bool tenantFlaggedRentChange;
  
  // End / move-out / contest (System G)
  final String? endReason;
  final String? endedBy;            // 'tenant' | 'landlord'
  final DateTime? endedAt;
  final bool tenantContested;
  final String? tenantContestStatement;
  final DateTime? contestedAt;

  // Move-out request (request + acknowledge flow). Set when the tenant asks to
  // move out; cleared into endedAt/endedBy when the landlord confirms handover
  // (or the auto-confirm sweep does). `endReason` carries the move-out reason.
  final DateTime? moveOutRequestedAt;
  final DateTime? moveOutIntendedDate;

  // Caution deposit, snapshotted from the property at rental creation so it
  // reflects what THIS tenant was promised, not the current listing. The
  // deduction fields are the landlord's declaration at handover: 0 (or
  // absent) means returned in full. ClearRent never holds this money — these
  // are a record, not a transfer.
  final double cautionDeposit;
  final bool cautionDepositRefundable;
  final double? cautionDeductionAmount;
  final String? cautionDeductionReason;
  final DateTime? cautionDeclaredAt;

  // Provenance (set on promoted rentals, null otherwise)
  final String? sourceLinkId;
  
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
    this.pendingRentForRenewal,
    this.pendingRentEffectiveDate,
    required this.agentFee,
    required this.totalPaid,
    this.rentPaymentStatus = 'paid',
    this.inspectionFeeCredit = 5000,
    this.rentFrequency = 'yearly',
    this.landlordPayout = 0,
    this.agentPayout = 0,
    this.clearrentEarnings = 0,
    this.landlordPayoutStatus = 'pending',
    this.agentPayoutStatus = 'not_applicable',
    this.landlordPaidAt,
    this.agentPaidAt,
    required this.leaseStartDate,
    required this.leaseEndDate,
    required this.nextPaymentDue,
    this.agreementUrl,
    this.agreementUploadedAt,
    this.agreementStatus = AgreementStatus.none,
    this.tenantAcceptedAt,
    this.tenantDisputeReason,
    this.landlordFinalizedAt,
    this.tenantSignedUrl,
    this.tenantSignedAt,
    this.executedAgreementUrl,
    this.executedAt,
    this.agreementRevisedAt,
    this.agreementRevisionTermsOnly = false,
    this.agreementRevisionDeclaredRent,
    this.tenantFlaggedRentChange = false,
    this.endReason,
    this.endedBy,
    this.endedAt,
    this.tenantContested = false,
    this.tenantContestStatement,
    this.contestedAt,
    this.moveOutRequestedAt,
    this.moveOutIntendedDate,
    this.cautionDeposit = 0,
    this.cautionDepositRefundable = true,
    this.cautionDeductionAmount,
    this.cautionDeductionReason,
    this.cautionDeclaredAt,
    this.sourceLinkId,
    this.status = ActiveRentalStatus.active,
    this.hasPaymentReminder = false,
    required this.createdAt,
    required this.updatedAt,
  });
  
  // Status helpers
  bool get isActive => status == ActiveRentalStatus.active;
  bool get isExpiringSoon => status == ActiveRentalStatus.expiringSoon;
  bool get isGraceLocked => status == ActiveRentalStatus.graceLocked;
  bool get isMoveoutPending => status == ActiveRentalStatus.moveoutPending;

  /// Whether the landlord may confirm handover yet.
  ///
  /// The tenant is still living there until the date they gave notice for, so
  /// confirming before it ends the tenancy over their head — frees the unit and
  /// clears their active-rental flag while they are mid-move. Allowed from the
  /// START of the intended day, since that is the day they said they'd be out.
  ///
  /// True when no intended date is recorded, which is every request written
  /// before the field was collected.
  bool get canConfirmHandover {
    final d = moveOutIntendedDate;
    if (d == null) return true;
    return !DateTime.now().isBefore(DateTime(d.year, d.month, d.day));
  }
  bool get isExpired => status == ActiveRentalStatus.expired;
  bool get isTerminated => status == ActiveRentalStatus.terminated;
  bool get isEndedByTenant => status == ActiveRentalStatus.endedByTenant;
  bool get isEndedByLandlord => status == ActiveRentalStatus.endedByLandlord;
  bool get isEnded => isEndedByTenant || isEndedByLandlord;
  /// Accepted, agreement in progress, rent not yet paid. A LIVE, current rental
  /// — must be shown as such, never bucketed with past/ended rentals.
  bool get isPendingPayment => status == ActiveRentalStatus.pendingPayment;
  /// A rental that belongs in the "current" section (in-progress or occupying).
  /// Move-out-pending is still current — the tenant occupies until handover.
  bool get isCurrent => isActive || isExpiringSoon || isPendingPayment || isMoveoutPending;

  // Agreement helpers
  bool get hasAgreement => agreementUrl != null && agreementUrl!.isNotEmpty;

  bool get hasTenantSignature =>
      tenantSignedUrl != null && tenantSignedUrl!.isNotEmpty;

  bool get hasExecutedAgreement =>
      executedAgreementUrl != null && executedAgreementUrl!.isNotEmpty;

  /// A tenancy finalized WITHOUT a counter-signed document on file — every
  /// rental that accepted by tap before signatures were required. Kept
  /// distinguishable so the gap is visible rather than silently blessed.
  bool get isFinalizedWithoutSignature =>
      agreementStatus == AgreementStatus.finalized && !hasExecutedAgreement;
  bool get isAgreementPendingReview => agreementStatus == AgreementStatus.pendingReview;
  bool get isAgreementAccepted => agreementStatus == AgreementStatus.accepted;
  bool get isAgreementDisputed => agreementStatus == AgreementStatus.disputed;
  bool get isAgreementFinalized => agreementStatus == AgreementStatus.finalized;
  
  String get agreementStatusDisplay {
    switch (agreementStatus) {
      case AgreementStatus.none: return 'No Agreement';
      case AgreementStatus.pendingReview: return 'Awaiting Tenant Signature';
      case AgreementStatus.accepted: return 'Signed by Tenant';
      case AgreementStatus.disputed: return 'Tenant Has Concerns';
      case AgreementStatus.finalized: return 'Fully Executed';
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
      case ActiveRentalStatus.graceLocked: return 'Renewal Due';
      case ActiveRentalStatus.moveoutPending: return 'Move-out Pending';
      case ActiveRentalStatus.expired: return 'Expired';
      case ActiveRentalStatus.terminated: return 'Terminated';
      case ActiveRentalStatus.endedByTenant: return 'Ended';
      case ActiveRentalStatus.endedByLandlord: return 'Ended';
      case ActiveRentalStatus.pendingPayment: return 'Awaiting Rent Payment';
    }
  }
  
  String formatAmount(double amount) {
    if (amount >= 1000000) return '${(amount / 1000000).toStringAsFixed(1)}M';
    if (amount >= 1000) return '${(amount / 1000).toStringAsFixed(0)}K';
    return amount.toStringAsFixed(0);
  }
  
  String get formattedRent => '₦${formatAmount(rentAmount)}';
  String get rentPeriod => rentFrequency == 'yearly' ? '/year' : '/month';
  
  /// Creates a lightweight ActiveRental from a TenancyLinkModel.
  /// Used so lease-details and report-issue screens work for linked tenants.
  factory ActiveRental.fromLink(TenancyLinkModel link) {
    final start = link.acceptedAt ?? link.createdAt ?? DateTime.now();
    final end = start.add(const Duration(days: 365));
    final nextDue = link.nextDueDate;
    return ActiveRental(
      id: link.id,
      propertyId: link.propertyId,
      tenantId: link.tenantId,
      landlordId: link.landlordId,
      inspectionRequestId: '',
      rentalInterestId: '',
      propertyTitle: link.propertyTitle,
      propertyImage: '',
      propertyAddress: link.propertyAddress,
      tenantName: link.tenantName,
      landlordName: link.landlordName,
      landlordPhone: link.landlordPhone.isNotEmpty ? link.landlordPhone : null,
      rentAmount: link.rentAmount,
      agentFee: 0,
      totalPaid: 0,
      rentFrequency: link.rentFrequency,
      leaseStartDate: start,
      leaseEndDate: end,
      nextPaymentDue: nextDue,
      createdAt: start,
      updatedAt: start,
    );
  }

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
      pendingRentForRenewal: (data['pendingRentForRenewal'] as num?)?.toDouble(),
      pendingRentEffectiveDate: data['pendingRentEffectiveDate'] != null
          ? (data['pendingRentEffectiveDate'] as Timestamp).toDate() : null,
      agentFee: (data['agentFee'] ?? 0).toDouble(),
      totalPaid: (data['totalPaid'] ?? 0).toDouble(),
      // Legacy rentals (pre pay-after-accept) have no field → treat as paid.
      rentPaymentStatus: data['rentPaymentStatus'] ?? 'paid',
      inspectionFeeCredit: (data['inspectionFeeCredit'] ?? 5000).toDouble(),
      rentFrequency: data['rentFrequency'] ?? 'yearly',
      landlordPayout: (data['landlordPayout'] ?? 0).toDouble(),
      agentPayout: (data['agentPayout'] ?? 0).toDouble(),
      clearrentEarnings: (data['clearrentEarnings'] ?? 0).toDouble(),
      landlordPayoutStatus: data['landlordPayoutStatus'] ?? 'pending',
      agentPayoutStatus: data['agentPayoutStatus'] ?? 'not_applicable',
      landlordPaidAt: data['landlordPaidAt'] != null
          ? (data['landlordPaidAt'] as Timestamp).toDate() : null,
      agentPaidAt: data['agentPaidAt'] != null
          ? (data['agentPaidAt'] as Timestamp).toDate() : null,
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
      tenantSignedUrl: data['tenantSignedUrl'] as String?,
      tenantSignedAt: data['tenantSignedAt'] != null
          ? (data['tenantSignedAt'] as Timestamp).toDate() : null,
      executedAgreementUrl: data['executedAgreementUrl'] as String?,
      executedAt: data['executedAt'] != null
          ? (data['executedAt'] as Timestamp).toDate() : null,
      agreementRevisedAt: data['agreementRevisedAt'] != null
          ? (data['agreementRevisedAt'] as Timestamp).toDate() : null,
      agreementRevisionTermsOnly:
          data['agreementRevisionTermsOnly'] == true,
      agreementRevisionDeclaredRent:
          (data['agreementRevisionDeclaredRent'] as num?)?.toDouble(),
      tenantFlaggedRentChange: data['tenantFlaggedRentChange'] == true,
      endReason: data['endReason'] as String?,
      endedBy: data['endedBy'] as String?,
      endedAt: data['endedAt'] != null
          ? (data['endedAt'] as Timestamp).toDate() : null,
      tenantContested: data['tenantContested'] ?? false,
      tenantContestStatement: data['tenantContestStatement'] as String?,
      contestedAt: data['contestedAt'] != null
          ? (data['contestedAt'] as Timestamp).toDate() : null,
      moveOutRequestedAt: data['moveOutRequestedAt'] != null
          ? (data['moveOutRequestedAt'] as Timestamp).toDate() : null,
      moveOutIntendedDate: data['moveOutIntendedDate'] != null
          ? (data['moveOutIntendedDate'] as Timestamp).toDate() : null,
      cautionDeposit: (data['cautionDeposit'] ?? 0).toDouble(),
      cautionDepositRefundable: data['cautionDepositRefundable'] ?? true,
      cautionDeductionAmount:
          (data['cautionDeductionAmount'] as num?)?.toDouble(),
      cautionDeductionReason: data['cautionDeductionReason'] as String?,
      cautionDeclaredAt: data['cautionDeclaredAt'] != null
          ? (data['cautionDeclaredAt'] as Timestamp).toDate() : null,
      sourceLinkId: data['sourceLinkId'] as String?,
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
      if (pendingRentForRenewal != null) 'pendingRentForRenewal': pendingRentForRenewal,
      if (pendingRentEffectiveDate != null)
        'pendingRentEffectiveDate': Timestamp.fromDate(pendingRentEffectiveDate!),
      'agentFee': agentFee,
      'totalPaid': totalPaid,
      'rentPaymentStatus': rentPaymentStatus,
      'inspectionFeeCredit': inspectionFeeCredit,
      'rentFrequency': rentFrequency,
      'landlordPayout': landlordPayout,
      'agentPayout': agentPayout,
      'clearrentEarnings': clearrentEarnings,
      'landlordPayoutStatus': landlordPayoutStatus,
      'agentPayoutStatus': agentPayoutStatus,
      if (landlordPaidAt != null) 'landlordPaidAt': Timestamp.fromDate(landlordPaidAt!),
      if (agentPaidAt != null) 'agentPaidAt': Timestamp.fromDate(agentPaidAt!),
      'leaseStartDate': Timestamp.fromDate(leaseStartDate),
      'leaseEndDate': Timestamp.fromDate(leaseEndDate),
      'nextPaymentDue': Timestamp.fromDate(nextPaymentDue),
      if (agreementUrl != null) 'agreementUrl': agreementUrl,
      if (agreementUploadedAt != null) 'agreementUploadedAt': Timestamp.fromDate(agreementUploadedAt!),
      'agreementStatus': _agreementStatusToString(agreementStatus),
      if (tenantAcceptedAt != null) 'tenantAcceptedAt': Timestamp.fromDate(tenantAcceptedAt!),
      if (tenantDisputeReason != null) 'tenantDisputeReason': tenantDisputeReason,
      if (landlordFinalizedAt != null) 'landlordFinalizedAt': Timestamp.fromDate(landlordFinalizedAt!),
      if (endReason != null) 'endReason': endReason,
      if (endedBy != null) 'endedBy': endedBy,
      if (endedAt != null) 'endedAt': Timestamp.fromDate(endedAt!),
      'tenantContested': tenantContested,
      if (tenantContestStatement != null) 'tenantContestStatement': tenantContestStatement,
      if (contestedAt != null) 'contestedAt': Timestamp.fromDate(contestedAt!),
      if (sourceLinkId != null) 'sourceLinkId': sourceLinkId,
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
    String? rentPaymentStatus,
    double? inspectionFeeCredit, String? rentFrequency,
    double? landlordPayout, double? agentPayout, double? clearrentEarnings,
    String? landlordPayoutStatus, String? agentPayoutStatus,
    DateTime? landlordPaidAt, DateTime? agentPaidAt,
    DateTime? leaseStartDate, DateTime? leaseEndDate, DateTime? nextPaymentDue,
    String? agreementUrl, DateTime? agreementUploadedAt,
    AgreementStatus? agreementStatus, DateTime? tenantAcceptedAt,
    String? tenantDisputeReason, DateTime? landlordFinalizedAt,
    String? endReason, String? endedBy, DateTime? endedAt,
    bool? tenantContested, String? tenantContestStatement, DateTime? contestedAt,
    DateTime? moveOutRequestedAt, DateTime? moveOutIntendedDate,
    double? cautionDeposit, bool? cautionDepositRefundable,
    double? cautionDeductionAmount, String? cautionDeductionReason,
    DateTime? cautionDeclaredAt,
    String? sourceLinkId,
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
      rentPaymentStatus: rentPaymentStatus ?? this.rentPaymentStatus,
      inspectionFeeCredit: inspectionFeeCredit ?? this.inspectionFeeCredit,
      rentFrequency: rentFrequency ?? this.rentFrequency,
      landlordPayout: landlordPayout ?? this.landlordPayout,
      agentPayout: agentPayout ?? this.agentPayout,
      clearrentEarnings: clearrentEarnings ?? this.clearrentEarnings,
      landlordPayoutStatus: landlordPayoutStatus ?? this.landlordPayoutStatus,
      agentPayoutStatus: agentPayoutStatus ?? this.agentPayoutStatus,
      landlordPaidAt: landlordPaidAt ?? this.landlordPaidAt,
      agentPaidAt: agentPaidAt ?? this.agentPaidAt,
      leaseStartDate: leaseStartDate ?? this.leaseStartDate,
      leaseEndDate: leaseEndDate ?? this.leaseEndDate,
      nextPaymentDue: nextPaymentDue ?? this.nextPaymentDue,
      agreementUrl: agreementUrl ?? this.agreementUrl,
      agreementUploadedAt: agreementUploadedAt ?? this.agreementUploadedAt,
      agreementStatus: agreementStatus ?? this.agreementStatus,
      tenantAcceptedAt: tenantAcceptedAt ?? this.tenantAcceptedAt,
      tenantDisputeReason: tenantDisputeReason ?? this.tenantDisputeReason,
      landlordFinalizedAt: landlordFinalizedAt ?? this.landlordFinalizedAt,
      endReason: endReason ?? this.endReason,
      endedBy: endedBy ?? this.endedBy,
      endedAt: endedAt ?? this.endedAt,
      moveOutRequestedAt: moveOutRequestedAt ?? this.moveOutRequestedAt,
      moveOutIntendedDate: moveOutIntendedDate ?? this.moveOutIntendedDate,
      cautionDeposit: cautionDeposit ?? this.cautionDeposit,
      cautionDepositRefundable:
          cautionDepositRefundable ?? this.cautionDepositRefundable,
      cautionDeductionAmount:
          cautionDeductionAmount ?? this.cautionDeductionAmount,
      cautionDeductionReason:
          cautionDeductionReason ?? this.cautionDeductionReason,
      cautionDeclaredAt: cautionDeclaredAt ?? this.cautionDeclaredAt,
      tenantContested: tenantContested ?? this.tenantContested,
      tenantContestStatement: tenantContestStatement ?? this.tenantContestStatement,
      contestedAt: contestedAt ?? this.contestedAt,
      sourceLinkId: sourceLinkId ?? this.sourceLinkId,
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
      case 'grace_locked': return ActiveRentalStatus.graceLocked;
      case 'moveout_pending': return ActiveRentalStatus.moveoutPending;
      case 'expired': return ActiveRentalStatus.expired;
      case 'terminated': return ActiveRentalStatus.terminated;
      case 'ended_by_tenant': return ActiveRentalStatus.endedByTenant;
      case 'ended_by_landlord': return ActiveRentalStatus.endedByLandlord;
      case 'pending_payment': return ActiveRentalStatus.pendingPayment;
      default: return ActiveRentalStatus.active;
    }
  }
  
  static String _statusToString(ActiveRentalStatus s) {
    switch (s) {
      case ActiveRentalStatus.active: return 'active';
      case ActiveRentalStatus.expiringSoon: return 'expiring_soon';
      case ActiveRentalStatus.graceLocked: return 'grace_locked';
      case ActiveRentalStatus.moveoutPending: return 'moveout_pending';
      case ActiveRentalStatus.expired: return 'expired';
      case ActiveRentalStatus.terminated: return 'terminated';
      case ActiveRentalStatus.endedByTenant: return 'ended_by_tenant';
      case ActiveRentalStatus.endedByLandlord: return 'ended_by_landlord';
      case ActiveRentalStatus.pendingPayment: return 'pending_payment';
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

enum ActiveRentalStatus {
  active,
  expiringSoon,
  graceLocked,
  /// The tenant has requested to move out and is awaiting the landlord's
  /// handover confirmation (or the auto-confirm sweep). The tenant is still
  /// occupying — kept in the server's OCCUPYING_RENTAL_STATUSES so the unit
  /// doesn't re-list until the move-out is confirmed.
  moveoutPending,
  expired,
  terminated,
  endedByTenant,
  endedByLandlord,
  /// Pay-after-accept: the landlord accepted and the agreement is being agreed,
  /// but the tenant hasn't paid rent yet. Deliberately NOT in the server's
  /// OCCUPYING_RENTAL_STATUSES, so the unit stays on the market and the tenant
  /// isn't counted as occupying until the money actually lands. recordRentPayment
  /// flips it to `active`.
  pendingPayment,
}

enum AgreementStatus {
  none,            // No agreement uploaded yet
  pendingReview,   // Landlord uploaded, waiting for tenant to sign
  /// Tenant has uploaded a SIGNED copy. Waiting on the landlord to
  /// counter-sign. Legacy rentals that accepted with a tap (before signatures
  /// were required) also land here, so they can still be finalized.
  accepted,
  disputed,        // Tenant raised concerns
  finalized,       // Counter-signed — the executed agreement is on record
}