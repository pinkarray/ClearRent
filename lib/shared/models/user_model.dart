import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String fullName;
  final String email;
  final String accountType; // 'tenant', 'landlord', or 'agent'
  final String? bvn;
  final String? phoneNumber;
  final String? profileImageUrl;
  final bool profileCompleted;
  final bool emailVerified;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // ── Tenant profile fields ──
  final String? occupation;
  final String? employer;
  final String? workMode; // 'remote' | 'hybrid' | 'commute'
  final String? workplaceArea; // Lagos area they commute to
  final String? incomeRange; // e.g. '100000-200000', '200000-500000'
  final double? budgetMin; // min rent they can afford
  final double? budgetMax; // max rent they can afford
  final List<String> preferredAreas; // Lagos areas they want to live in
  final String? maritalStatus; // 'single' | 'married' | 'family'

  UserModel({
    required this.uid,
    required this.fullName,
    required this.email,
    required this.accountType,
    this.bvn,
    this.phoneNumber,
    this.profileImageUrl,
    this.profileCompleted = false,
    this.emailVerified = false,
    this.createdAt,
    this.updatedAt,
    // Tenant fields
    this.occupation,
    this.employer,
    this.workMode,
    this.workplaceArea,
    this.incomeRange,
    this.budgetMin,
    this.budgetMax,
    this.preferredAreas = const [],
    this.maritalStatus,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      uid: json['uid'] ?? '',
      fullName: json['fullName'] ?? '',
      email: json['email'] ?? '',
      accountType: json['accountType'] ?? 'tenant',
      bvn: json['bvn'],
      phoneNumber: json['phoneNumber'],
      profileImageUrl: json['profileImageUrl'],
      profileCompleted: json['profileCompleted'] ?? false,
      emailVerified: json['emailVerified'] ?? false,
      createdAt: json['createdAt'] != null
          ? (json['createdAt'] as Timestamp).toDate()
          : null,
      updatedAt: json['updatedAt'] != null
          ? (json['updatedAt'] as Timestamp).toDate()
          : null,
      // Tenant fields
      occupation: json['occupation'] as String?,
      employer: json['employer'] as String?,
      workMode: json['workMode'] as String?,
      workplaceArea: json['workplaceArea'] as String?,
      incomeRange: json['incomeRange'] as String?,
      budgetMin: (json['budgetMin'] as num?)?.toDouble(),
      budgetMax: (json['budgetMax'] as num?)?.toDouble(),
      preferredAreas: List<String>.from(json['preferredAreas'] ?? []),
      maritalStatus: json['maritalStatus'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'fullName': fullName,
      'email': email,
      'accountType': accountType,
      'bvn': bvn,
      'phoneNumber': phoneNumber,
      'profileImageUrl': profileImageUrl,
      'profileCompleted': profileCompleted,
      'emailVerified': emailVerified,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      // Tenant fields
      if (occupation != null) 'occupation': occupation,
      if (employer != null) 'employer': employer,
      if (workMode != null) 'workMode': workMode,
      if (workplaceArea != null) 'workplaceArea': workplaceArea,
      if (incomeRange != null) 'incomeRange': incomeRange,
      if (budgetMin != null) 'budgetMin': budgetMin,
      if (budgetMax != null) 'budgetMax': budgetMax,
      if (preferredAreas.isNotEmpty) 'preferredAreas': preferredAreas,
      if (maritalStatus != null) 'maritalStatus': maritalStatus,
    };
  }

  UserModel copyWith({
    String? uid,
    String? fullName,
    String? email,
    String? accountType,
    String? bvn,
    String? phoneNumber,
    String? profileImageUrl,
    bool? profileCompleted,
    bool? emailVerified,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? occupation,
    String? employer,
    String? workMode,
    String? workplaceArea,
    String? incomeRange,
    double? budgetMin,
    double? budgetMax,
    List<String>? preferredAreas,
    String? maritalStatus,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      accountType: accountType ?? this.accountType,
      bvn: bvn ?? this.bvn,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      profileCompleted: profileCompleted ?? this.profileCompleted,
      emailVerified: emailVerified ?? this.emailVerified,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      occupation: occupation ?? this.occupation,
      employer: employer ?? this.employer,
      workMode: workMode ?? this.workMode,
      workplaceArea: workplaceArea ?? this.workplaceArea,
      incomeRange: incomeRange ?? this.incomeRange,
      budgetMin: budgetMin ?? this.budgetMin,
      budgetMax: budgetMax ?? this.budgetMax,
      preferredAreas: preferredAreas ?? this.preferredAreas,
      maritalStatus: maritalStatus ?? this.maritalStatus,
    );
  }

  bool get isTenant => accountType == 'tenant';
  bool get isLandlord => accountType == 'landlord';
  bool get isAgent => accountType == 'agent';

  // ── Tenant display helpers ──

  /// Human-readable work mode
  String get workModeLabel {
    switch (workMode) {
      case 'remote':
        return 'Works from home';
      case 'hybrid':
        return 'Hybrid (home & office)';
      case 'commute':
        return 'Commutes to work';
      default:
        return 'Not specified';
    }
  }

  /// Human-readable income range
  String get incomeRangeLabel {
    switch (incomeRange) {
      case 'below_100k':
        return 'Below ₦100K';
      case '100k_200k':
        return '₦100K – ₦200K';
      case '200k_500k':
        return '₦200K – ₦500K';
      case '500k_1m':
        return '₦500K – ₦1M';
      case 'above_1m':
        return 'Above ₦1M';
      default:
        return 'Not specified';
    }
  }

  /// Human-readable marital status
  String get maritalStatusLabel {
    switch (maritalStatus) {
      case 'single':
        return 'Single';
      case 'married':
        return 'Married';
      case 'family':
        return 'Family with children';
      default:
        return 'Not specified';
    }
  }

  /// Formatted budget range
  String get budgetLabel {
    if (budgetMin == null && budgetMax == null) return 'Not specified';
    final min = budgetMin ?? 0;
    final max = budgetMax ?? 0;
    String fmt(double v) {
      if (v >= 1000000) return '₦${(v / 1000000).toStringAsFixed(1)}M';
      if (v >= 1000) return '₦${(v / 1000).toStringAsFixed(0)}K';
      return '₦${v.toStringAsFixed(0)}';
    }
    if (max <= 0) return 'From ${fmt(min)}';
    if (min <= 0) return 'Up to ${fmt(max)}';
    return '${fmt(min)} – ${fmt(max)}';
  }

  /// Whether this tenant has completed the enhanced profile
  bool get hasTenantProfile =>
      occupation != null && occupation!.isNotEmpty && workMode != null;
}