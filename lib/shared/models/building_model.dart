import 'package:cloud_firestore/cloud_firestore.dart';

/// A physical building / compound that groups multiple unit listings of the
/// same owner (e.g. a "face me I slap you" with rooms on each side, or a
/// compound with a 1-bed, 2-bed and self-contain).
///
/// Each unit is still its own [PropertyModel] listing with its own rent, tenant
/// and availability (Model A). The building only groups them so:
///   - the admin approves with context ("Room 3 of 6 · [Building]"), and
///   - one ownership document (C of O / deed) is verified ONCE and covers every
///     unit (units inherit [ownershipDocStatus] via their `buildingId`).
///
/// A standalone listing has no building and keeps its own per-property doc.
class BuildingModel {
  final String id;
  final String landlordId;
  final String name; // e.g. "Olu Compound, 12 Allen Ave"
  final String address;

  // Shared ownership document — verified once, covers all units in the building.
  final String? ownershipDocUrl; // Cloudinary URL of the C of O / deed
  final String? ownershipDocType; // 'c_of_o' | 'deed' | 'other'
  final String ownershipDocStatus; // 'none' | 'pending' | 'verified' | 'rejected'
  final String? ownershipDocRejectionReason;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  const BuildingModel({
    required this.id,
    required this.landlordId,
    required this.name,
    this.address = '',
    this.ownershipDocUrl,
    this.ownershipDocType,
    this.ownershipDocStatus = 'none',
    this.ownershipDocRejectionReason,
    this.createdAt,
    this.updatedAt,
  });

  bool get isDocVerified => ownershipDocStatus == 'verified';
  bool get isDocRejected => ownershipDocStatus == 'rejected';

  factory BuildingModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return BuildingModel(
      id: docId,
      landlordId: data['landlordId'] ?? '',
      name: data['name'] ?? '',
      address: data['address'] ?? '',
      ownershipDocUrl: data['ownershipDocUrl'] as String?,
      ownershipDocType: data['ownershipDocType'] as String?,
      ownershipDocStatus: data['ownershipDocStatus'] as String? ?? 'none',
      ownershipDocRejectionReason:
          data['ownershipDocRejectionReason'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'landlordId': landlordId,
      'name': name,
      'address': address,
      if (ownershipDocUrl != null) 'ownershipDocUrl': ownershipDocUrl,
      if (ownershipDocType != null) 'ownershipDocType': ownershipDocType,
      'ownershipDocStatus': ownershipDocStatus,
      if (ownershipDocRejectionReason != null)
        'ownershipDocRejectionReason': ownershipDocRejectionReason,
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  BuildingModel copyWith({
    String? id,
    String? landlordId,
    String? name,
    String? address,
    String? ownershipDocUrl,
    String? ownershipDocType,
    String? ownershipDocStatus,
    String? ownershipDocRejectionReason,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return BuildingModel(
      id: id ?? this.id,
      landlordId: landlordId ?? this.landlordId,
      name: name ?? this.name,
      address: address ?? this.address,
      ownershipDocUrl: ownershipDocUrl ?? this.ownershipDocUrl,
      ownershipDocType: ownershipDocType ?? this.ownershipDocType,
      ownershipDocStatus: ownershipDocStatus ?? this.ownershipDocStatus,
      ownershipDocRejectionReason:
          ownershipDocRejectionReason ?? this.ownershipDocRejectionReason,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
