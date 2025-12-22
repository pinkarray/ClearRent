import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String fullName;
  final String email;
  final String accountType; // 'tenant' or 'landlord'
  final String? bvn;
  final String? phoneNumber;
  final String? profileImageUrl;
  final bool profileCompleted;
  final bool emailVerified;
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
    );
  }

  bool get isTenant => accountType == 'tenant';
  bool get isLandlord => accountType == 'landlord';
}