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
  final DateTime createdAt;
  final String? landlordName;
  final String? landlordPhone;

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
    required this.lga,
    required this.rent,
    required this.rentFrequency,
    this.agentFee = 0,
    this.agentFeePaidBy = 'tenant',
    this.isAvailable = true,
    this.isVerified = false,
    this.amenities = const [],
    this.rules = const [],
    required this.createdAt,
    this.landlordName,
    this.landlordPhone,
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
    );
  }

  // From JSON
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
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
      landlordName: json['landlordName'],
      landlordPhone: json['landlordPhone'],
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
      'createdAt': createdAt.toIso8601String(),
      'landlordName': landlordName,
      'landlordPhone': landlordPhone,
    };
  }
}