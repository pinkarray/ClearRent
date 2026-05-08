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
  final int livingRooms;
  final int guestRooms;
  final int kitchens;
  final List<String> images;
  final String address;
  final String city;
  final String state;
  final String lga;
  final double rent;
  final String rentFrequency;
  final double agentFee; // Now flat Naira amount (e.g. 200000), NOT percentage
  final double cautionDeposit; // Caution / damages deposit in Naira
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
  final int maxTenants;

  // Inspection availability
  final List<String> inspectionDays;
  final List<String> inspectionTimeSlots;

  // Ownership verification document
  final String? ownershipDocUrl;    // Cloudinary URL of uploaded C of O / deed
  final String? ownershipDocType;   // 'c_of_o' | 'deed' | 'other'
  final String ownershipDocStatus;  // 'none' | 'pending' | 'verified' | 'rejected'
  final String? ownershipDocRejectionReason;

  // Landlord residence (for inspection travel calculation)
  final bool landlordLivesInProperty;

  // Video tour
  final String? videoUrl; // Cloudinary video URL

  // Ceiling type
  final String? ceilingType; // 'false_ceiling' | 'pvc' | 'concrete' | 'asbestos' | 'none'
  
  // Recurring dues (security, PSB, waste, etc.)
  final List<Map<String, dynamic>> recurringDues;

  // Occupancy info (shown to tenants on property detail)
  final bool? landlordLivesOnPremises;
  final int? currentTenantsCount;
  final bool? hasCaretaker;
  final bool? caretakerLivesOnPremises;

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
    this.livingRooms = 1,
    this.guestRooms = 0,
    this.kitchens = 1,
    required this.images,
    required this.address,
    required this.city,
    required this.state,
    this.lga = '',
    required this.rent,
    required this.rentFrequency,
    this.agentFee = 0,
    this.cautionDeposit = 0,
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
    this.maxTenants = 1,
    this.inspectionDays = const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ],
    this.inspectionTimeSlots = const ['morning', 'afternoon', 'late_afternoon'],
    this.landlordLivesInProperty = false,
    this.videoUrl,
    this.ceilingType,
    this.recurringDues = const [],
    this.landlordLivesOnPremises,
    this.currentTenantsCount,
    this.hasCaretaker,
    this.caretakerLivesOnPremises,
    this.ownershipDocUrl,
    this.ownershipDocType,
    this.ownershipDocStatus = 'none',
    this.ownershipDocRejectionReason,
  });

  // ── Pricing helpers ──

  /// Format rent display (abbreviated)
  String get formattedRent {
    if (rent >= 1000000) {
      return '₦${(rent / 1000000).toStringAsFixed(1)}M';
    } else if (rent >= 1000) {
      return '₦${(rent / 1000).toStringAsFixed(0)}K';
    }
    return '₦${rent.toStringAsFixed(0)}';
  }

  String get rentPeriod => rentFrequency == 'yearly' ? '/year' : '/month';

  /// Format agent fee as Naira (flat amount)
  String get formattedAgentFee {
    if (agentFee >= 1000000) {
      return '₦${(agentFee / 1000000).toStringAsFixed(1)}M';
    } else if (agentFee >= 1000) {
      return '₦${(agentFee / 1000).toStringAsFixed(0)}K';
    }
    return '₦${agentFee.toStringAsFixed(0)}';
  }

  /// Format caution deposit as Naira
  String get formattedCautionDeposit {
    if (cautionDeposit >= 1000000) {
      return '₦${(cautionDeposit / 1000000).toStringAsFixed(1)}M';
    } else if (cautionDeposit >= 1000) {
      return '₦${(cautionDeposit / 1000).toStringAsFixed(0)}K';
    }
    return '₦${cautionDeposit.toStringAsFixed(0)}';
  }

  /// Total recurring dues per year
  double get totalRecurringDuesYearly {
    double total = 0;
    for (final due in recurringDues) {
      final amount = (due['amount'] as num?)?.toDouble() ?? 0;
      final freq = due['frequency'] as String? ?? 'yearly';
      total += freq == 'monthly' ? amount * 12 : amount;
    }
    return total;
  }

  /// Format recurring dues total
  String get formattedRecurringDues {
    final total = totalRecurringDuesYearly;
    if (total >= 1000000) {
      return '₦${(total / 1000000).toStringAsFixed(1)}M';
    } else if (total >= 1000) {
      return '₦${(total / 1000).toStringAsFixed(0)}K';
    }
    return '₦${total.toStringAsFixed(0)}';
  }

  /// Total Package = Rent + Agent Fee + Caution Deposit
  double get totalPackage => rent + agentFee + cautionDeposit;

  /// Format total package as Naira
  String get formattedTotalPackage {
    if (totalPackage >= 1000000) {
      return '₦${(totalPackage / 1000000).toStringAsFixed(1)}M';
    } else if (totalPackage >= 1000) {
      return '₦${(totalPackage / 1000).toStringAsFixed(0)}K';
    }
    return '₦${totalPackage.toStringAsFixed(0)}';
  }

  /// Renewal rent (just the base rent after the first year)
  double get renewalAmount => rent;

  // Check if has agent
  bool get hasAgent => agentId != null && agentId!.isNotEmpty;

  // ── Location helpers ──

  /// Public location shown to tenants browsing and unassigned agents.
  /// Hides the exact street address until an inspection is approved
  /// or the agent is assigned.
  String get publicLocation {
    final parts = <String>[];
    if (city.isNotEmpty) parts.add(city);
    if (state.isNotEmpty) parts.add(state);
    return parts.isEmpty ? 'Lagos' : parts.join(', ');
  }

  /// Full location including the street address. Shown only to the owner,
  /// the assigned agent, and tenants whose inspection on this property
  /// has reached `approved` status or beyond.
  String get fullLocation {
    final parts = <String>[];
    if (address.isNotEmpty) parts.add(address);
    if (city.isNotEmpty) parts.add(city);
    if (state.isNotEmpty) parts.add(state);
    return parts.isEmpty ? 'Lagos' : parts.join(', ');
  }

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
    int? livingRooms,
    int? guestRooms,
    int? kitchens,
    List<String>? images,
    String? address,
    String? city,
    String? state,
    String? lga,
    double? rent,
    String? rentFrequency,
    double? agentFee,
    double? cautionDeposit,
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
    int? maxTenants,
    List<String>? inspectionDays,
    List<String>? inspectionTimeSlots,
    bool? landlordLivesInProperty,
    bool? landlordLivesOnPremises,
    int? currentTenantsCount,
    bool? hasCaretaker,
    bool? caretakerLivesOnPremises,
    String? ownershipDocUrl,
    String? ownershipDocType,
    String? ownershipDocStatus,
    String? ownershipDocRejectionReason,
    String? videoUrl,
    String? ceilingType,
    List<Map<String, dynamic>>? recurringDues,
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
      livingRooms: livingRooms ?? this.livingRooms,
      guestRooms: guestRooms ?? this.guestRooms,
      kitchens: kitchens ?? this.kitchens,
      images: images ?? this.images,
      address: address ?? this.address,
      city: city ?? this.city,
      state: state ?? this.state,
      lga: lga ?? this.lga,
      rent: rent ?? this.rent,
      rentFrequency: rentFrequency ?? this.rentFrequency,
      agentFee: agentFee ?? this.agentFee,
      cautionDeposit: cautionDeposit ?? this.cautionDeposit,
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
      maxTenants: maxTenants ?? this.maxTenants,
      inspectionDays: inspectionDays ?? this.inspectionDays,
      inspectionTimeSlots: inspectionTimeSlots ?? this.inspectionTimeSlots,
      landlordLivesInProperty: landlordLivesInProperty ?? this.landlordLivesInProperty,
      videoUrl: videoUrl ?? this.videoUrl,
      ceilingType: ceilingType ?? this.ceilingType,
      recurringDues: recurringDues ?? this.recurringDues,
      landlordLivesOnPremises: landlordLivesOnPremises ?? this.landlordLivesOnPremises,
      currentTenantsCount: currentTenantsCount ?? this.currentTenantsCount,
      hasCaretaker: hasCaretaker ?? this.hasCaretaker,
      caretakerLivesOnPremises: caretakerLivesOnPremises ?? this.caretakerLivesOnPremises,
      ownershipDocUrl: ownershipDocUrl ?? this.ownershipDocUrl,
      ownershipDocType: ownershipDocType ?? this.ownershipDocType,
      ownershipDocStatus: ownershipDocStatus ?? this.ownershipDocStatus,
      ownershipDocRejectionReason: ownershipDocRejectionReason ?? this.ownershipDocRejectionReason,
    );
  }

  // From JSON (for API/local storage)
  /// True when property has open spots (even if marked unavailable by landlord toggle)
  bool get hasAvailableSpots {
    final count = currentTenantsCount ?? 0;
    return count < maxTenants;
  }

  /// True when property should appear in browse results
  bool get isListable => isAvailable && hasAvailableSpots;

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
      livingRooms: json['livingRooms'] ?? 1,
      guestRooms: json['guestRooms'] ?? 0,
      kitchens: json['kitchens'] ?? 1,
      images: List<String>.from(json['images'] ?? []),
      address: json['address'] ?? '',
      city: json['city'] ?? '',
      state: json['state'] ?? '',
      lga: json['lga'] ?? '',
      rent: (json['rent'] ?? 0).toDouble(),
      rentFrequency: json['rentFrequency'] ?? 'yearly',
      agentFee: (json['agentFee'] ?? 0).toDouble(),
      cautionDeposit: (json['cautionDeposit'] ?? 0).toDouble(),
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
      maxTenants: json['maxTenants'] ?? 1,
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
      landlordLivesInProperty: json['landlordLivesInProperty'] ?? false,
      videoUrl: json['videoUrl'] as String?,
      ceilingType: json['ceilingType'] as String?,
      recurringDues: (json['recurringDues'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      landlordLivesOnPremises: json['landlordLivesOnPremises'] as bool?,
      currentTenantsCount: (json['currentTenantsCount'] as num?)?.toInt(),
      hasCaretaker: json['hasCaretaker'] as bool?,
      caretakerLivesOnPremises: json['caretakerLivesOnPremises'] as bool?,
      ownershipDocUrl: json['ownershipDocUrl'] as String?,
      ownershipDocType: json['ownershipDocType'] as String?,
      ownershipDocStatus: json['ownershipDocStatus'] as String? ?? 'none',
      ownershipDocRejectionReason: json['ownershipDocRejectionReason'] as String?,
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
      livingRooms: data['livingRooms'] ?? 1,
      guestRooms: data['guestRooms'] ?? 0,
      kitchens: data['kitchens'] ?? 1,
      images: List<String>.from(data['images'] ?? []),
      address: data['address'] ?? '',
      city: data['city'] ?? '',
      state: data['state'] ?? '',
      lga: data['lga'] ?? '',
      rent: (data['rent'] ?? 0).toDouble(),
      rentFrequency: data['rentFrequency'] ?? 'yearly',
      agentFee: (data['agentFee'] ?? 0).toDouble(),
      cautionDeposit: (data['cautionDeposit'] ?? 0).toDouble(),
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
      maxTenants: data['maxTenants'] ?? 1,
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
      landlordLivesInProperty: data['landlordLivesInProperty'] ?? false,
      videoUrl: data['videoUrl'] as String?,
      ceilingType: data['ceilingType'] as String?,
      recurringDues: (data['recurringDues'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      landlordLivesOnPremises: data['landlordLivesOnPremises'] as bool?,
      currentTenantsCount: (data['currentTenantsCount'] as num?)?.toInt(),
      hasCaretaker: data['hasCaretaker'] as bool?,
      caretakerLivesOnPremises: data['caretakerLivesOnPremises'] as bool?,
      ownershipDocUrl: data['ownershipDocUrl'] as String?,
      ownershipDocType: data['ownershipDocType'] as String?,
      ownershipDocStatus: data['ownershipDocStatus'] as String? ?? 'none',
      ownershipDocRejectionReason: data['ownershipDocRejectionReason'] as String?,
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
      'livingRooms': livingRooms,
      'guestRooms': guestRooms,
      'kitchens': kitchens,
      'images': images,
      'address': address,
      'city': city,
      'state': state,
      'lga': lga,
      'rent': rent,
      'rentFrequency': rentFrequency,
      'agentFee': agentFee,
      'cautionDeposit': cautionDeposit,
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
      'maxTenants': maxTenants,
      'inspectionDays': inspectionDays,
      'inspectionTimeSlots': inspectionTimeSlots,
      'landlordLivesInProperty': landlordLivesInProperty,
      if (videoUrl != null) 'videoUrl': videoUrl,
      if (ceilingType != null) 'ceilingType': ceilingType,
      if (recurringDues.isNotEmpty) 'recurringDues': recurringDues,
      'landlordLivesOnPremises': landlordLivesOnPremises,
      'currentTenantsCount': currentTenantsCount,
      'hasCaretaker': hasCaretaker,
      'caretakerLivesOnPremises': caretakerLivesOnPremises,
      'ownershipDocUrl': ownershipDocUrl,
      'ownershipDocType': ownershipDocType,
      'ownershipDocStatus': ownershipDocStatus,
      if (ownershipDocRejectionReason != null) 'ownershipDocRejectionReason': ownershipDocRejectionReason,
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
      'livingRooms': livingRooms,
      'guestRooms': guestRooms,
      'kitchens': kitchens,
      'images': images,
      'address': address,
      'city': city,
      'state': state,
      'lga': lga,
      'rent': rent,
      'rentFrequency': rentFrequency,
      'agentFee': agentFee,
      'cautionDeposit': cautionDeposit,
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
      'maxTenants': maxTenants,
      'inspectionDays': inspectionDays,
      'inspectionTimeSlots': inspectionTimeSlots,
      'landlordLivesInProperty': landlordLivesInProperty,
      if (videoUrl != null) 'videoUrl': videoUrl,
      if (ceilingType != null) 'ceilingType': ceilingType,
      if (recurringDues.isNotEmpty) 'recurringDues': recurringDues,
      'landlordLivesOnPremises': landlordLivesOnPremises,
      'currentTenantsCount': currentTenantsCount,
      'hasCaretaker': hasCaretaker,
      'caretakerLivesOnPremises': caretakerLivesOnPremises,
      if (ownershipDocUrl != null) 'ownershipDocUrl': ownershipDocUrl,
      if (ownershipDocType != null) 'ownershipDocType': ownershipDocType,
      'ownershipDocStatus': ownershipDocStatus,
      if (ownershipDocRejectionReason != null) 'ownershipDocRejectionReason': ownershipDocRejectionReason,
    };
  }
}