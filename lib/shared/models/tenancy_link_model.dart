import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/utils/date_format_utils.dart';

/// Represents a link between a landlord and a tenant for a specific property.
/// Status flow: pending → confirmed (or rejected/removed)
class TenancyLinkModel {
  final String id;
  final String landlordId;
  final String landlordName;
  final String landlordPhone;
  final String tenantId;
  final String tenantName;
  final String propertyId;
  final String propertyTitle;
  final String propertyAddress;
  final String propertyCity;

  /// 'pending' | 'confirmed' | 'rejected' | 'removed'
  final String status;

  /// Day of month rent is due (1–31)
  final int rentDueDay;

  /// Rent amount in Naira — captured at link time as baseline
  final double rentAmount;

  /// Rent frequency — 'yearly' | 'monthly'
  final String rentFrequency;

  /// Month rent is due each year (1–12). Only relevant when rentFrequency == 'yearly'.
  final int rentDueMonth;

  /// Lease term start — landlord picks this explicitly at link time.
  /// Null on legacy links created before lease terms existed (treated as
  /// "no term / never expires" — they never enter grace_locked).
  final DateTime? leaseStartDate;

  /// Lease term end. For yearly tenancies this is leaseStartDate + 1 year
  /// (computed at link time, stored explicitly so the scheduled lifecycle CF
  /// can query it directly). Null = legacy link, never expires.
  /// NOTE: monthly tenancies (post-launch) will need a duration picker and a
  /// different advance-rent cap — not handled here.
  final DateTime? leaseEndDate;

  /// Optional lease-agreement document URL, uploaded by landlord at link time.
  final String? agreementUrl;

  final DateTime? createdAt;
  final DateTime? acceptedAt;

  const TenancyLinkModel({
    required this.id,
    required this.landlordId,
    required this.landlordName,
    required this.landlordPhone,
    required this.tenantId,
    required this.tenantName,
    required this.propertyId,
    required this.propertyTitle,
    required this.propertyAddress,
    required this.propertyCity,
    required this.status,
    this.rentDueDay = 1,
    this.rentAmount = 0,
    this.rentFrequency = 'yearly',
    this.rentDueMonth = 1,
    this.leaseStartDate,
    this.leaseEndDate,
    this.agreementUrl,
    this.createdAt,
    this.acceptedAt,
  });

  bool get isPending => status == 'pending';
  bool get isConfirmed => status == 'confirmed';

  /// True once the lease term has lapsed. Null leaseEndDate (legacy links)
  /// never lapse.
  bool get isLeaseEnded =>
      leaseEndDate != null && leaseEndDate!.isBefore(DateTime.now());

  /// Days until the lease term ends. Null leaseEndDate yields a large sentinel
  /// so "never expires" links never trip reminder/lock thresholds.
  int get daysUntilLeaseEnd => leaseEndDate == null
      ? 1 << 30
      : leaseEndDate!.difference(DateTime.now()).inDays;

  /// Next rent due date calculated from today
  DateTime get nextDueDate {
    final now = DateTime.now();
    if (rentFrequency == 'yearly') {
      // Due once a year in rentDueMonth, on rentDueDay (clamped to the month's
      // length so e.g. 31 in a 30-day month doesn't roll into the next month).
      final thisYear = DateTime(now.year, rentDueMonth, _dueDayFor(now.year));
      if (thisYear.isAfter(now)) return thisYear;
      return DateTime(now.year + 1, rentDueMonth, _dueDayFor(now.year + 1));
    }
    // Monthly: due on rentDueDay each month
    final thisMonth = DateTime(now.year, now.month, rentDueDay);
    if (thisMonth.isAfter(now)) return thisMonth;
    return DateTime(now.year, now.month + 1, rentDueDay);
  }

  /// rentDueDay clamped to the number of days in [rentDueMonth] of [year].
  int _dueDayFor(int year) {
    final lastDay = DateTime(year, rentDueMonth + 1, 0).day;
    if (rentDueDay < 1) return 1;
    return rentDueDay > lastDay ? lastDay : rentDueDay;
  }

  /// Human label for when rent is due, matching the frequency.
  /// Yearly → "29th January"; monthly → "29th of each month".
  String get rentDueLabel {
    if (rentFrequency == 'yearly') {
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      final m = (rentDueMonth >= 1 && rentDueMonth <= 12)
          ? months[rentDueMonth - 1]
          : '';
      return '${ordinal(rentDueDay)} $m'.trim();
    }
    return '${ordinal(rentDueDay)} of each month';
  }

  /// Days until next rent is due
  int get daysUntilDue {
    final diff = nextDueDate.difference(DateTime.now());
    return diff.inDays;
  }

  String get formattedRentAmount {
    if (rentAmount >= 1000000) {
      return '₦${(rentAmount / 1000000).toStringAsFixed(1)}M';
    } else if (rentAmount >= 1000) {
      return '₦${(rentAmount / 1000).toStringAsFixed(0)}K';
    }
    return '₦${rentAmount.toStringAsFixed(0)}';
  }

  String get rentPeriodLabel =>
      rentFrequency == 'yearly' ? 'per year' : 'per month';

  factory TenancyLinkModel.fromFirestore(
    Map<String, dynamic> data,
    String docId,
  ) {
    return TenancyLinkModel(
      id: docId,
      landlordId: data['landlordId'] ?? '',
      landlordName: data['landlordName'] ?? '',
      landlordPhone: data['landlordPhone'] ?? '',
      tenantId: data['tenantId'] ?? '',
      tenantName: data['tenantName'] ?? '',
      propertyId: data['propertyId'] ?? '',
      propertyTitle: data['propertyTitle'] ?? '',
      propertyAddress: data['propertyAddress'] ?? '',
      propertyCity: data['propertyCity'] ?? '',
      status: data['status'] ?? 'pending',
      rentDueDay: (data['rentDueDay'] as num?)?.toInt() ?? 1,
      rentAmount: (data['rentAmount'] as num?)?.toDouble() ?? 0,
      rentFrequency: data['rentFrequency'] ?? 'yearly',
      rentDueMonth: (data['rentDueMonth'] as num?)?.toInt() ?? 1,
      leaseStartDate: (data['leaseStartDate'] as Timestamp?)?.toDate(),
      leaseEndDate: (data['leaseEndDate'] as Timestamp?)?.toDate(),
      agreementUrl: data['agreementUrl'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      acceptedAt: (data['acceptedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'landlordId': landlordId,
      'landlordName': landlordName,
      'landlordPhone': landlordPhone,
      'tenantId': tenantId,
      'tenantName': tenantName,
      'propertyId': propertyId,
      'propertyTitle': propertyTitle,
      'propertyAddress': propertyAddress,
      'propertyCity': propertyCity,
      'status': status,
      'rentDueDay': rentDueDay,
      'rentAmount': rentAmount,
      'rentFrequency': rentFrequency,
      'rentDueMonth': rentDueMonth,
      if (leaseStartDate != null)
        'leaseStartDate': Timestamp.fromDate(leaseStartDate!),
      if (leaseEndDate != null)
        'leaseEndDate': Timestamp.fromDate(leaseEndDate!),
      if (agreementUrl != null) 'agreementUrl': agreementUrl,
      'createdAt': FieldValue.serverTimestamp(),
      'acceptedAt':
          acceptedAt != null ? Timestamp.fromDate(acceptedAt!) : null,
    };
  }

  TenancyLinkModel copyWith({
    String? id,
    String? landlordId,
    String? landlordName,
    String? landlordPhone,
    String? tenantId,
    String? tenantName,
    String? propertyId,
    String? propertyTitle,
    String? propertyAddress,
    String? propertyCity,
    String? status,
    int? rentDueDay,
    double? rentAmount,
    String? rentFrequency,
    int? rentDueMonth,
    DateTime? leaseStartDate,
    DateTime? leaseEndDate,
    String? agreementUrl,
    DateTime? createdAt,
    DateTime? acceptedAt,
  }) {
    return TenancyLinkModel(
      id: id ?? this.id,
      landlordId: landlordId ?? this.landlordId,
      landlordName: landlordName ?? this.landlordName,
      landlordPhone: landlordPhone ?? this.landlordPhone,
      tenantId: tenantId ?? this.tenantId,
      tenantName: tenantName ?? this.tenantName,
      propertyId: propertyId ?? this.propertyId,
      propertyTitle: propertyTitle ?? this.propertyTitle,
      propertyAddress: propertyAddress ?? this.propertyAddress,
      propertyCity: propertyCity ?? this.propertyCity,
      status: status ?? this.status,
      rentDueDay: rentDueDay ?? this.rentDueDay,
      rentAmount: rentAmount ?? this.rentAmount,
      rentFrequency: rentFrequency ?? this.rentFrequency,
      rentDueMonth: rentDueMonth ?? this.rentDueMonth,
      leaseStartDate: leaseStartDate ?? this.leaseStartDate,
      leaseEndDate: leaseEndDate ?? this.leaseEndDate,
      agreementUrl: agreementUrl ?? this.agreementUrl,
      createdAt: createdAt ?? this.createdAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
    );
  }
}

/// Lightweight result from a tenant search
class TenantSearchResult {
  final String userId;
  final String fullName;
  final bool isVerified;
  final String? profileImageUrl;

  const TenantSearchResult({
    required this.userId,
    required this.fullName,
    required this.isVerified,
    this.profileImageUrl,
  });
}