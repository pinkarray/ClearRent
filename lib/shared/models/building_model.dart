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

  // What the whole structure is, physically. This is the axis `propertyType`
  // used to swallow: a listing's type says what is being LET (a room, a flat),
  // and this says what it sits in. Without it, propertyType 'room' loses the
  // fact it is a room in a duplex, and 'duplex' implies the whole duplex.
  // 'duplex' | 'bungalow' | 'storeyBuilding' | 'blockOfFlats' | 'compound' |
  // 'faceMeIFaceYou' | 'detachedHouse' | 'other'. Empty on buildings created
  // before this field existed.
  final String structure;
  final int? totalFloors;

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
    this.structure = '',
    this.totalFloors,
    this.ownershipDocUrl,
    this.ownershipDocType,
    this.ownershipDocStatus = 'none',
    this.ownershipDocRejectionReason,
    this.createdAt,
    this.updatedAt,
  });

  bool get isDocVerified => ownershipDocStatus == 'verified';
  bool get isDocRejected => ownershipDocStatus == 'rejected';

  /// Human label for [structure]. Empty for buildings created before the field
  /// existed — callers should omit the line rather than print a placeholder.
  String get structureLabel => structureLabelFor(structure);

  /// The structures a Lagos landlord actually names. Order is the chip order.
  static const List<Map<String, String>> structures = [
    {'value': 'duplex', 'label': 'Duplex'},
    {'value': 'bungalow', 'label': 'Bungalow'},
    {'value': 'storeyBuilding', 'label': 'Storey building'},
    {'value': 'blockOfFlats', 'label': 'Block of flats'},
    {'value': 'compound', 'label': 'Compound'},
    {'value': 'faceMeIFaceYou', 'label': 'Face me I face you'},
    {'value': 'detachedHouse', 'label': 'Detached house'},
    {'value': 'other', 'label': 'Other'},
  ];

  static String structureLabelFor(String value) {
    for (final s in structures) {
      if (s['value'] == value) return s['label']!;
    }
    return '';
  }

  factory BuildingModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return BuildingModel(
      id: docId,
      landlordId: data['landlordId'] ?? '',
      name: data['name'] ?? '',
      address: data['address'] ?? '',
      structure: data['structure'] as String? ?? '',
      totalFloors: (data['totalFloors'] as num?)?.toInt(),
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
      if (structure.isNotEmpty) 'structure': structure,
      if (totalFloors != null) 'totalFloors': totalFloors,
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
    String? structure,
    int? totalFloors,
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
      structure: structure ?? this.structure,
      totalFloors: totalFloors ?? this.totalFloors,
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
