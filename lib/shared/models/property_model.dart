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
  // Whether the deposit is returned at move-out when the tenant leaves the
  // unit in good condition. Defaults true: every listing before this field
  // existed was advertised as refundable in the add-property copy.
  final bool cautionDepositRefundable;
  final bool isAvailable;
  final bool isVerified;
  final List<String> amenities;
  final List<String> rules;
  final DateTime? createdAt;
  final double? scheduledRent;
  final DateTime? scheduledRentEffectiveDate;
  final String? scheduledRentReason;
  final int rentIncreaseCount;
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

  // Readiness gate (Phase 2): a property is only bookable for inspection once
  // its current handler (the assigned agent, or the landlord when self-handled)
  // has vetted it against a standard checklist. Reset to false whenever the
  // handler changes (agent assigned / agent steps back / switched to self), so
  // a new handler must re-vet. Absent field ⇒ not ready (legacy properties must
  // be vetted before they can take new inspections).
  final bool readyForInspections;
  final DateTime? readinessCheckedAt;
  final String? readinessCheckedBy;

  // Inspection availability
  final List<String> inspectionDays;
  final List<String> inspectionTimeSlots;

  // Pre-resolved inspection pricing cluster for this property (area-level, safe
  // to expose on the public doc). Computed from the address at creation and
  // used for fee calculation, since the exact street address now lives in the
  // gated `private/location` subdoc and isn't available for cluster resolution.
  final String? inspectionPropertyCluster;

  // Ownership verification document.
  // Null on a grouped unit (buildingId != null): the BUILDING holds the single
  // document an admin reviews, and the unit inherits that verdict.
  final String? ownershipDocUrl;    // private Storage PATH of the C of O / deed
  final String? ownershipDocType;   // 'c_of_o' | 'deed' | 'other'
  // Owner-settable: 'none' | 'not_uploaded' | 'pending' | 'inherited'.
  // Admin-only verdict: 'verified' | 'rejected'.
  // 'inherited' marks a grouped unit — resolve the real status from its building
  // (see effectiveDocStatus), never treat the marker itself as an approval.
  // Guards keyed on the literal 'verified' silently passed 'inherited' and
  // 'not_uploaded' straight through, so any new check must be an ALLOWLIST.
  final String ownershipDocStatus;
  final String? ownershipDocRejectionReason;  // admin's words; owner cannot write

  // Building group — non-null when this property is a unit in a multi-unit
  // building/compound. Units inherit the building's ownership-doc verification
  // (one C of O covers every unit of the same owner). Null = standalone listing.
  final String? buildingId;

  // Landlord residence (for inspection travel calculation)
  final bool landlordLivesInProperty;

  // Video tour
  final String? videoUrl; // Cloudinary video URL

  // Ceiling types — a flat can mix them (POP in the living room, slate in the
  // bedroom), so this is a list.
  // 'pop' | 'pvc' | 'concrete' | 'asbestos' | 'slate' | 'none'
  // Legacy docs carry a single `ceilingType` string ('false_ceiling' meaning
  // 'pop'); both are folded into this list on read.
  final List<String> ceilingTypes;
  
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
    this.cautionDepositRefundable = true,
    this.isAvailable = true,
    this.isVerified = false,
    this.amenities = const [],
    this.rules = const [],
    this.createdAt,
    this.scheduledRent,
    this.scheduledRentEffectiveDate,
    this.scheduledRentReason,
    this.rentIncreaseCount = 0, 
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
    this.readyForInspections = false,
    this.readinessCheckedAt,
    this.readinessCheckedBy,
    this.inspectionDays = const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ],
    this.inspectionTimeSlots = const ['morning', 'afternoon', 'late_afternoon'],
    this.inspectionPropertyCluster,
    this.landlordLivesInProperty = false,
    this.videoUrl,
    this.ceilingTypes = const [],
    this.recurringDues = const [],
    this.landlordLivesOnPremises,
    this.currentTenantsCount,
    this.hasCaretaker,
    this.caretakerLivesOnPremises,
    this.ownershipDocUrl,
    this.ownershipDocType,
    this.ownershipDocStatus = 'none',
    this.ownershipDocRejectionReason,
    this.buildingId,
  });

  /// Address shown to a viewer who is NOT yet entitled to the exact address.
  /// Area-level only: LGA, city, state — enough to judge location without
  /// revealing the street. Used before an inspection is approved (tenant) or
  /// before an agent is assigned.
  String get approximateAddress {
    final parts = <String>[];
    if (lga.isNotEmpty) parts.add(lga);
    if (city.isNotEmpty) parts.add(city);
    if (state.isNotEmpty) parts.add(state);
    return parts.isEmpty ? 'Location available after approval' : parts.join(', ');
  }

  /// Full street-level address. Only show when the viewer is entitled:
  /// tenant with an approved inspection, assigned agent, or the owner.
  String get exactAddress => '$address, $city, $state';

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

  /// True when a future rent increase is scheduled.
  bool get hasScheduledIncrease =>
      scheduledRent != null && scheduledRentEffectiveDate != null;

  /// The rent figure to charge/display *now*. Once the scheduled date has
  /// passed, this returns the scheduled rent; otherwise the current rent.
  /// Stored `rent` is never mutated — read sites opt in by calling this.
  double get effectiveRent {
    if (hasScheduledIncrease &&
        !DateTime.now().isBefore(scheduledRentEffectiveDate!)) {
      return scheduledRent!;
    }
    return rent;
  }

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
    bool? cautionDepositRefundable,
    bool? isAvailable,
    bool? isVerified,
    List<String>? amenities,
    List<String>? rules,
    DateTime? createdAt,
    double? scheduledRent,
    DateTime? scheduledRentEffectiveDate,
    String? scheduledRentReason,
    int? rentIncreaseCount,
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
    bool? readyForInspections,
    DateTime? readinessCheckedAt,
    String? readinessCheckedBy,
    List<String>? inspectionDays,
    List<String>? inspectionTimeSlots,
    String? inspectionPropertyCluster,
    bool? landlordLivesInProperty,
    bool? landlordLivesOnPremises,
    int? currentTenantsCount,
    bool? hasCaretaker,
    bool? caretakerLivesOnPremises,
    String? ownershipDocUrl,
    String? ownershipDocType,
    String? ownershipDocStatus,
    String? ownershipDocRejectionReason,
    String? buildingId,
    String? videoUrl,
    List<String>? ceilingTypes,
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
      cautionDepositRefundable:
          cautionDepositRefundable ?? this.cautionDepositRefundable,
      isAvailable: isAvailable ?? this.isAvailable,
      isVerified: isVerified ?? this.isVerified,
      amenities: amenities ?? this.amenities,
      rules: rules ?? this.rules,
      createdAt: createdAt ?? this.createdAt,
      scheduledRent: scheduledRent ?? this.scheduledRent,
      scheduledRentEffectiveDate:
          scheduledRentEffectiveDate ?? this.scheduledRentEffectiveDate,
      scheduledRentReason: scheduledRentReason ?? this.scheduledRentReason,
      rentIncreaseCount: rentIncreaseCount ?? this.rentIncreaseCount,
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
      readyForInspections: readyForInspections ?? this.readyForInspections,
      readinessCheckedAt: readinessCheckedAt ?? this.readinessCheckedAt,
      readinessCheckedBy: readinessCheckedBy ?? this.readinessCheckedBy,
      inspectionDays: inspectionDays ?? this.inspectionDays,
      inspectionTimeSlots: inspectionTimeSlots ?? this.inspectionTimeSlots,
      inspectionPropertyCluster:
          inspectionPropertyCluster ?? this.inspectionPropertyCluster,
      landlordLivesInProperty: landlordLivesInProperty ?? this.landlordLivesInProperty,
      videoUrl: videoUrl ?? this.videoUrl,
      ceilingTypes: ceilingTypes ?? this.ceilingTypes,
      recurringDues: recurringDues ?? this.recurringDues,
      landlordLivesOnPremises: landlordLivesOnPremises ?? this.landlordLivesOnPremises,
      currentTenantsCount: currentTenantsCount ?? this.currentTenantsCount,
      hasCaretaker: hasCaretaker ?? this.hasCaretaker,
      caretakerLivesOnPremises: caretakerLivesOnPremises ?? this.caretakerLivesOnPremises,
      ownershipDocUrl: ownershipDocUrl ?? this.ownershipDocUrl,
      ownershipDocType: ownershipDocType ?? this.ownershipDocType,
      ownershipDocStatus: ownershipDocStatus ?? this.ownershipDocStatus,
      ownershipDocRejectionReason: ownershipDocRejectionReason ?? this.ownershipDocRejectionReason,
      buildingId: buildingId ?? this.buildingId,
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

  /// True between publishing and the admin's verdict. Every new listing is
  /// written `isAvailable: false` so it can't be browsed before review, and
  /// `isVerified` flips to true only when an admin approves it.
  bool get isPendingReview =>
      !isVerified && ownershipDocStatus != 'rejected';

  /// Approved by admin and vacant, but the handler hasn't vetted it — so
  /// tenants are blocked from booking an inspection and the listing earns
  /// nothing. Silent unless something surfaces it, which is why the landlord
  /// home screen counts these.
  bool get isNotBookable {
    if (ownershipDocStatus == 'rejected') return false;
    if (isPendingReview) return false;
    if ((currentTenantsCount ?? 0) > 0) return false;
    if (!isAvailable) return false;
    return !readyForInspections;
  }

  /// One label for the state a landlord actually cares about. Availability
  /// alone can't express this: a listing awaiting review and a listing with a
  /// sitting tenant are both `isAvailable == false`, and calling the first one
  /// "Occupied" is simply wrong.
  String get statusLabel {
    if (ownershipDocStatus == 'rejected') return 'Rejected';
    if (isPendingReview) return 'Pending review';
    if ((currentTenantsCount ?? 0) > 0) return 'Occupied';
    if (!isAvailable) return 'Occupied'; // landlord's own "Mark Occupied"
    if (isNotBookable) return 'Not bookable';
    return 'Available';
  }

  /// Ceiling types, folding in the legacy single-value `ceilingType` field so
  /// documents written before the multi-select still read correctly.
  static List<String> _parseCeilingTypes(Map<String, dynamic> data) {
    final list = data['ceilingTypes'] as List<dynamic>?;
    if (list != null) return list.map((e) => e.toString()).toList();
    final legacy = data['ceilingType'] as String?;
    if (legacy == null || legacy.isEmpty) return const [];
    return [legacy == 'false_ceiling' ? 'pop' : legacy];
  }

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
      cautionDepositRefundable: json['cautionDepositRefundable'] ?? true,
      isAvailable: json['isAvailable'] ?? true,
      isVerified: json['isVerified'] ?? false,
      amenities: List<String>.from(json['amenities'] ?? []),
      rules: List<String>.from(json['rules'] ?? []),
      createdAt: _dateFromJson(json['createdAt']),
      scheduledRent: (json['scheduledRent'] as num?)?.toDouble(),
      scheduledRentEffectiveDate:
          _dateFromJson(json['scheduledRentEffectiveDate']),
      scheduledRentReason: json['scheduledRentReason'] as String?,
      rentIncreaseCount: (json['rentIncreaseCount'] as num?)?.toInt() ?? 0,
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
      readyForInspections: json['readyForInspections'] ?? false,
      readinessCheckedAt: _dateFromJson(json['readinessCheckedAt']),
      readinessCheckedBy: json['readinessCheckedBy'] as String?,
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
      ceilingTypes: _parseCeilingTypes(json),
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
      buildingId: json['buildingId'] as String?,
    );
  }

  /// Tolerant date parse for [fromJson]. Date fields can arrive as a Firestore
  /// Timestamp (raw Firestore stream data), an ISO-8601 String (already
  /// normalised JSON), or an existing DateTime. DateTime.parse only handles the
  /// String case — feeding it a Timestamp (e.g. scheduledRentEffectiveDate
  /// written by the approveRentReview CF) threw and broke property loading.
  static DateTime? _dateFromJson(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
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
      cautionDepositRefundable: data['cautionDepositRefundable'] ?? true,
      isAvailable: data['isAvailable'] ?? true,
      isVerified: data['isVerified'] ?? false,
      amenities: List<String>.from(data['amenities'] ?? []),
      rules: List<String>.from(data['rules'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      scheduledRent: (data['scheduledRent'] as num?)?.toDouble(),
      scheduledRentEffectiveDate:
          (data['scheduledRentEffectiveDate'] as Timestamp?)?.toDate(),
      scheduledRentReason: data['scheduledRentReason'] as String?,
      rentIncreaseCount: (data['rentIncreaseCount'] as num?)?.toInt() ?? 0,
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
      readyForInspections: data['readyForInspections'] ?? false,
      readinessCheckedAt: (data['readinessCheckedAt'] as Timestamp?)?.toDate(),
      readinessCheckedBy: data['readinessCheckedBy'] as String?,
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
      inspectionPropertyCluster: data['inspectionPropertyCluster'] as String?,
      landlordLivesInProperty: data['landlordLivesInProperty'] ?? false,
      videoUrl: data['videoUrl'] as String?,
      ceilingTypes: _parseCeilingTypes(data),
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
      buildingId: data['buildingId'] as String?,
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
      'cautionDepositRefundable': cautionDepositRefundable,
      'isAvailable': isAvailable,
      'isVerified': isVerified,
      'amenities': amenities,
      'rules': rules,
      'createdAt': createdAt?.toIso8601String(),
      if (scheduledRent != null) 'scheduledRent': scheduledRent,
      if (scheduledRentEffectiveDate != null)
        'scheduledRentEffectiveDate':
            scheduledRentEffectiveDate!.toIso8601String(),
      if (scheduledRentReason != null)
        'scheduledRentReason': scheduledRentReason,
      'rentIncreaseCount': rentIncreaseCount,
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
      if (ceilingTypes.isNotEmpty) 'ceilingTypes': ceilingTypes,
      if (recurringDues.isNotEmpty) 'recurringDues': recurringDues,
      'landlordLivesOnPremises': landlordLivesOnPremises,
      'currentTenantsCount': currentTenantsCount,
      'hasCaretaker': hasCaretaker,
      'caretakerLivesOnPremises': caretakerLivesOnPremises,
      'ownershipDocUrl': ownershipDocUrl,
      'ownershipDocType': ownershipDocType,
      'ownershipDocStatus': ownershipDocStatus,
      if (ownershipDocRejectionReason != null) 'ownershipDocRejectionReason': ownershipDocRejectionReason,
      if (buildingId != null) 'buildingId': buildingId,
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
      'cautionDepositRefundable': cautionDepositRefundable,
      'isAvailable': isAvailable,
      'isVerified': isVerified,
      'amenities': amenities,
      'rules': rules,
      'createdAt':
          createdAt != null
              ? Timestamp.fromDate(createdAt!)
              : FieldValue.serverTimestamp(),
      if (scheduledRent != null) 'scheduledRent': scheduledRent,
      if (scheduledRentEffectiveDate != null)
        'scheduledRentEffectiveDate':
            Timestamp.fromDate(scheduledRentEffectiveDate!),
      if (scheduledRentReason != null)
        'scheduledRentReason': scheduledRentReason,
      'rentIncreaseCount': rentIncreaseCount,
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
      'readyForInspections': readyForInspections,
      if (readinessCheckedAt != null)
        'readinessCheckedAt': Timestamp.fromDate(readinessCheckedAt!),
      if (readinessCheckedBy != null) 'readinessCheckedBy': readinessCheckedBy,
      'inspectionDays': inspectionDays,
      'inspectionTimeSlots': inspectionTimeSlots,
      'landlordLivesInProperty': landlordLivesInProperty,
      if (videoUrl != null) 'videoUrl': videoUrl,
      if (ceilingTypes.isNotEmpty) 'ceilingTypes': ceilingTypes,
      if (recurringDues.isNotEmpty) 'recurringDues': recurringDues,
      'landlordLivesOnPremises': landlordLivesOnPremises,
      'currentTenantsCount': currentTenantsCount,
      'hasCaretaker': hasCaretaker,
      'caretakerLivesOnPremises': caretakerLivesOnPremises,
      if (ownershipDocUrl != null) 'ownershipDocUrl': ownershipDocUrl,
      if (ownershipDocType != null) 'ownershipDocType': ownershipDocType,
      'ownershipDocStatus': ownershipDocStatus,
      if (ownershipDocRejectionReason != null) 'ownershipDocRejectionReason': ownershipDocRejectionReason,
      if (buildingId != null) 'buildingId': buildingId,
    };
  }
}