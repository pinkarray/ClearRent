import 'package:cloud_firestore/cloud_firestore.dart';

class PropertyModel {
  final String id;
  final String landlordId;
  final String? agentId;
  final String title;
  final String description;
  final String propertyType;
  final int bedrooms;
  final int bathrooms;
  final int toilets;
  final List<String> images;
  final String address;
  final String city;
  final String state;
  final String lga;
  final double rent;
  final String rentFrequency;
  final double agentFee;
  final String agentFeePaidBy;
  final bool isAvailable;
  final bool isVerified;
  final List<String> amenities;
  final List<String> rules;
  final DateTime? createdAt;
  final String? landlordName;
  final String? landlordPhone;
  final double? latitude;
  final double? longitude;

  // Stats fields
  final int viewCount;
  final int inquiryCount;
  final int savedCount;

  // Inspection handling
  final String inspectionHandler; // 'self' or 'agent'
  final String? assignedAgentId;
  final String? assignedAgentName;

  // Inspection availability
  final List<String> inspectionDays;
  final List<String> inspectionTimeSlots;

  PropertyModel({
    required this.id,
    required this.landlordId,
    this.agentId,
    required this.title,
    required this.description,
    required this.propertyType,
    required this.bedrooms,
    required this.bathrooms,
    required this.toilets,
    required this.images,
    required this.address,
    required this.city,
    required this.state,
    this.lga = '',
    required this.rent,
    required this.rentFrequency,
    this.agentFee = 0,
    this.agentFeePaidBy = 'tenant',
    this.isAvailable = true,
    this.isVerified = false,
    this.amenities = const [],
    this.rules = const [],
    this.createdAt,
    this.landlordName,
    this.landlordPhone,
    this.latitude,
    this.longitude,
    this.viewCount = 0,
    this.inquiryCount = 0,
    this.savedCount = 0,
    this.inspectionHandler = 'self',
    this.assignedAgentId,
    this.assignedAgentName,
    this.inspectionDays = const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ],
    this.inspectionTimeSlots = const ['morning', 'afternoon', 'late_afternoon'],
  });

  // Format rent display
  String get formattedRent {
    if (rent >= 1000000) {
      return 'NGN ${(rent / 1000000).toStringAsFixed(1)}M';
    } else if (rent >= 1000) {
      return 'NGN ${(rent / 1000).toStringAsFixed(0)}K';
    }
    return 'NGN ${rent.toStringAsFixed(0)}';
  }

  String get rentPeriod => rentFrequency == 'yearly' ? '/year' : '/month';

  // Check if has agent
  bool get hasAgent => agentId != null && agentId!.isNotEmpty;

  // Calculate total first payment for tenant
  double get totalFirstPayment {
    if (hasAgent && agentFeePaidBy == 'tenant') {
      return rent + (rent * agentFee / 100);
    }
    return rent;
  }

  // Format agent fee
  String get formattedAgentFee => '${agentFee.toStringAsFixed(0)}%';

  // Copy with
  PropertyModel copyWith({
    String? id,
    String? landlordId,
    String? agentId,
    String? title,
    String? description,
    String? propertyType,
    int? bedrooms,
    int? bathrooms,
    int? toilets,
    List<String>? images,
    String? address,
    String? city,
    String? state,
    String? lga,
    double? rent,
    String? rentFrequency,
    double? agentFee,
    String? agentFeePaidBy,
    bool? isAvailable,
    bool? isVerified,
    List<String>? amenities,
    List<String>? rules,
    DateTime? createdAt,
    String? landlordName,
    String? landlordPhone,
    double? latitude,
    double? longitude,
    int? viewCount,
    int? inquiryCount,
    int? savedCount,
    String? inspectionHandler,
    String? assignedAgentId,
    String? assignedAgentName,
    List<String>? inspectionDays,
    List<String>? inspectionTimeSlots,
  }) {
    return PropertyModel(
      id: id ?? this.id,
      landlordId: landlordId ?? this.landlordId,
      agentId: agentId ?? this.agentId,
      title: title ?? this.title,
      description: description ?? this.description,
      propertyType: propertyType ?? this.propertyType,
      bedrooms: bedrooms ?? this.bedrooms,
      bathrooms: bathrooms ?? this.bathrooms,
      toilets: toilets ?? this.toilets,
      images: images ?? this.images,
      address: address ?? this.address,
      city: city ?? this.city,
      state: state ?? this.state,
      lga: lga ?? this.lga,
      rent: rent ?? this.rent,
      rentFrequency: rentFrequency ?? this.rentFrequency,
      agentFee: agentFee ?? this.agentFee,
      agentFeePaidBy: agentFeePaidBy ?? this.agentFeePaidBy,
      isAvailable: isAvailable ?? this.isAvailable,
      isVerified: isVerified ?? this.isVerified,
      amenities: amenities ?? this.amenities,
      rules: rules ?? this.rules,
      createdAt: createdAt ?? this.createdAt,
      landlordName: landlordName ?? this.landlordName,
      landlordPhone: landlordPhone ?? this.landlordPhone,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      viewCount: viewCount ?? this.viewCount,
      inquiryCount: inquiryCount ?? this.inquiryCount,
      savedCount: savedCount ?? this.savedCount,
      inspectionHandler: inspectionHandler ?? this.inspectionHandler,
      assignedAgentId: assignedAgentId ?? this.assignedAgentId,
      assignedAgentName: assignedAgentName ?? this.assignedAgentName,
      inspectionDays: inspectionDays ?? this.inspectionDays,
      inspectionTimeSlots: inspectionTimeSlots ?? this.inspectionTimeSlots,
    );
  }

  // From JSON (for API/local storage)
  factory PropertyModel.fromJson(Map<String, dynamic> json) {
    return PropertyModel(
      id: json['id'] ?? '',
      landlordId: json['landlordId'] ?? '',
      agentId: json['agentId'],
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      propertyType: json['propertyType'] ?? 'flat',
      bedrooms: json['bedrooms'] ?? 0,
      bathrooms: json['bathrooms'] ?? 0,
      toilets: json['toilets'] ?? 0,
      images: List<String>.from(json['images'] ?? []),
      address: json['address'] ?? '',
      city: json['city'] ?? '',
      state: json['state'] ?? '',
      lga: json['lga'] ?? '',
      rent: (json['rent'] ?? 0).toDouble(),
      rentFrequency: json['rentFrequency'] ?? 'yearly',
      agentFee: (json['agentFee'] ?? 0).toDouble(),
      agentFeePaidBy: json['agentFeePaidBy'] ?? 'tenant',
      isAvailable: json['isAvailable'] ?? true,
      isVerified: json['isVerified'] ?? false,
      amenities: List<String>.from(json['amenities'] ?? []),
      rules: List<String>.from(json['rules'] ?? []),
      createdAt:
          json['createdAt'] != null ? DateTime.parse(json['createdAt']) : null,
      landlordName: json['landlordName'],
      landlordPhone: json['landlordPhone'],
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      viewCount: json['viewCount'] ?? 0,
      inquiryCount: json['inquiryCount'] ?? 0,
      savedCount: json['savedCount'] ?? 0,
      inspectionHandler: json['inspectionHandler'] ?? 'self',
      assignedAgentId: json['assignedAgentId'],
      assignedAgentName: json['assignedAgentName'],
      inspectionDays: List<String>.from(
        json['inspectionDays'] ??
            [
              'Monday',
              'Tuesday',
              'Wednesday',
              'Thursday',
              'Friday',
              'Saturday',
            ],
      ),
      inspectionTimeSlots: List<String>.from(
        json['inspectionTimeSlots'] ??
            ['morning', 'afternoon', 'late_afternoon'],
      ),
    );
  }

  // From Firestore document
  factory PropertyModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return PropertyModel(
      id: docId,
      landlordId: data['landlordId'] ?? '',
      agentId: data['agentId'],
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      propertyType: data['propertyType'] ?? 'flat',
      bedrooms: data['bedrooms'] ?? 0,
      bathrooms: data['bathrooms'] ?? 0,
      toilets: data['toilets'] ?? 0,
      images: List<String>.from(data['images'] ?? []),
      address: data['address'] ?? '',
      city: data['city'] ?? '',
      state: data['state'] ?? '',
      lga: data['lga'] ?? '',
      rent: (data['rent'] ?? 0).toDouble(),
      rentFrequency: data['rentFrequency'] ?? 'yearly',
      agentFee: (data['agentFee'] ?? 0).toDouble(),
      agentFeePaidBy: data['agentFeePaidBy'] ?? 'tenant',
      isAvailable: data['isAvailable'] ?? true,
      isVerified: data['isVerified'] ?? false,
      amenities: List<String>.from(data['amenities'] ?? []),
      rules: List<String>.from(data['rules'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      landlordName: data['landlordName'],
      landlordPhone: data['landlordPhone'],
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      viewCount: data['viewCount'] ?? 0,
      inquiryCount: data['inquiryCount'] ?? 0,
      savedCount: data['savedCount'] ?? 0,
      inspectionHandler: data['inspectionHandler'] ?? 'self',
      assignedAgentId: data['assignedAgentId'],
      assignedAgentName: data['assignedAgentName'],
      inspectionDays: List<String>.from(
        data['inspectionDays'] ??
            [
              'Monday',
              'Tuesday',
              'Wednesday',
              'Thursday',
              'Friday',
              'Saturday',
            ],
      ),
      inspectionTimeSlots: List<String>.from(
        data['inspectionTimeSlots'] ??
            ['morning', 'afternoon', 'late_afternoon'],
      ),
    );
  }

  // To JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'landlordId': landlordId,
      'agentId': agentId,
      'title': title,
      'description': description,
      'propertyType': propertyType,
      'bedrooms': bedrooms,
      'bathrooms': bathrooms,
      'toilets': toilets,
      'images': images,
      'address': address,
      'city': city,
      'state': state,
      'lga': lga,
      'rent': rent,
      'rentFrequency': rentFrequency,
      'agentFee': agentFee,
      'agentFeePaidBy': agentFeePaidBy,
      'isAvailable': isAvailable,
      'isVerified': isVerified,
      'amenities': amenities,
      'rules': rules,
      'createdAt': createdAt?.toIso8601String(),
      'landlordName': landlordName,
      'landlordPhone': landlordPhone,
      'latitude': latitude,
      'longitude': longitude,
      'viewCount': viewCount,
      'inquiryCount': inquiryCount,
      'savedCount': savedCount,
      'inspectionHandler': inspectionHandler,
      'assignedAgentId': assignedAgentId,
      'assignedAgentName': assignedAgentName,
      'inspectionDays': inspectionDays,
      'inspectionTimeSlots': inspectionTimeSlots,
    };
  }

  // To Firestore map
  Map<String, dynamic> toFirestore() {
    return {
      'landlordId': landlordId,
      'agentId': agentId,
      'title': title,
      'description': description,
      'propertyType': propertyType,
      'bedrooms': bedrooms,
      'bathrooms': bathrooms,
      'toilets': toilets,
      'images': images,
      'address': address,
      'city': city,
      'state': state,
      'lga': lga,
      'rent': rent,
      'rentFrequency': rentFrequency,
      'agentFee': agentFee,
      'agentFeePaidBy': agentFeePaidBy,
      'isAvailable': isAvailable,
      'isVerified': isVerified,
      'amenities': amenities,
      'rules': rules,
      'createdAt':
          createdAt != null
              ? Timestamp.fromDate(createdAt!)
              : FieldValue.serverTimestamp(),
      'landlordName': landlordName,
      'landlordPhone': landlordPhone,
      'latitude': latitude,
      'longitude': longitude,
      'viewCount': viewCount,
      'inquiryCount': inquiryCount,
      'savedCount': savedCount,
      'inspectionHandler': inspectionHandler,
      'assignedAgentId': assignedAgentId,
      'assignedAgentName': assignedAgentName,
      'inspectionDays': inspectionDays,
      'inspectionTimeSlots': inspectionTimeSlots,
    };
  }
}
