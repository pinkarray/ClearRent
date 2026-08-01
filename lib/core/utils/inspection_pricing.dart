/// ClearRent Inspection Pricing
///
/// FLAT-FEE MODEL (off-platform transport):
/// - Tenant pays a flat ₦10,000 inspection booking fee.
/// - Handler (agent OR landlord) earns ₦7,000.
/// - ClearRent earns ₦3,000.
/// - Transport is arranged DIRECTLY between tenant and handler.
///   ClearRent does not collect or remit transport money.
///
/// The LGA list and area-to-LGA helpers below remain in use for
/// area categorization (dropdowns, filtering, display labels), but
/// no longer drive any fee calculation.
library;

class InspectionPricing {
  // ══════════════════════════════════════════════
  //  FEE CONSTANTS (FLAT-FEE MODEL)
  // ══════════════════════════════════════════════

  // Remote-overridable from Firestore config/pricing via PricingService, so a
  // fee change does not need a Play Store release. The values below are the
  // offline fallback and MUST mirror DEFAULT_PRICING in functions/src/
  // pricing.ts — the server derives what it actually charges from that same
  // document, so a drift here shows the user one price and bills another.
  static double _bookingFee = 10000.0;
  static double _handlerEarnings = 7000.0;
  static double _clearrentTake = 3000.0;

  /// Total inspection booking fee the tenant pays.
  static double get inspectionBookingFee => _bookingFee;

  /// Handler's earnings per inspection (agent or landlord).
  static double get handlerEarnings => _handlerEarnings;

  /// ClearRent's take per inspection.
  static double get clearrentTake => _clearrentTake;

  /// Apply the remote schedule. Called once by PricingService after it loads
  /// config/pricing so every inspection fee display uses the live numbers.
  static void applyRemote({
    required double total,
    required double handler,
    required double platform,
  }) {
    _bookingFee = total;
    _handlerEarnings = handler;
    _clearrentTake = platform;
  }

  // ── Legacy constants (kept for back-compat) ──
  // These no longer drive new fee calculations. The
  // InspectionFeeBreakdown still surfaces them so existing UI and
  // model code keeps compiling; new code should reference the three
  // constants above. Existing inspection docs in Firestore that
  // were written under the transport-included model will still
  // deserialize correctly because the field names are unchanged.

  static const double lastMileBuffer = 500.0;
  static const double tenantServiceCharge = 3000.0;
  static const double agentServiceFee = 10000.0;
  static const double clearrentAgentCut = 3000.0;
  static const double minTenantFee = 13000.0;
  static const double selfHandledBookingFee = 10000.0;

  // ══════════════════════════════════════════════
  //  LGA DEFINITIONS
  // ══════════════════════════════════════════════

  /// All Lagos LGAs used in the system.
  static const List<String> lgas = [
    'ikorodu',
    'kosofe',
    'shomolu',
    'ikeja',
    'ojodu_lcda',
    'agege',
    'ifako_ijaiye',
    'alimosho',
    'oshodi_isolo',
    'mushin',
    'surulere',
    'yaba_mainland',
    'eti_osa',
    'lagos_island',
    'apapa',
    'amuwo_odofin',
    'ojo',
    'ajeromi_ifelodun',
    'obafemi_owode',
  ];

  /// Outer/long-distance LGA (Epe, Badagry, Sango, Ibeju-Lekki)
  static const String outerLGA = 'outer';

  // ══════════════════════════════════════════════
  //  AREA → LGA MAPPING
  // ══════════════════════════════════════════════

  /// Compiled-in area → LGA map (lowercase keys). The offline baseline.
  ///
  /// Adding an area here needs an app release, which is far too slow when a
  /// landlord is standing in an unmapped part of Lagos right now. Areas can
  /// therefore also be added at runtime from `config/areas` — see
  /// [applyRemoteAreas] — exactly as `config/pricing` overrides the fees.
  static const Map<String, String> _defaultAreaToLGA = {
    // ── Ikorodu LGA ──
    'ikorodu': 'ikorodu',
    'ikorodu town': 'ikorodu',
    'benson': 'ikorodu',
    'itamaga': 'ikorodu',
    'odogunyan': 'ikorodu',
    'agric': 'ikorodu',
    'owutu': 'ikorodu',
    'igbogbo': 'ikorodu',
    'ijede': 'ikorodu',
    'imota': 'ikorodu',
    'bayeku': 'ikorodu',
    'ibeshe': 'ikorodu',
    'erikorodo': 'ikorodu',
    'agura': 'ikorodu',
    'isiu': 'ikorodu',
    'ebute': 'ikorodu',
    'aga': 'ikorodu',
    'ishawo': 'ikorodu',
    'oke-eletu': 'ikorodu',
    'oreta': 'ikorodu',
    'ofin': 'ikorodu',

    // ── Kosofe LGA ──
    'ketu': 'kosofe',
    'ojota': 'kosofe',
    'mile 12': 'kosofe',
    'alapere': 'kosofe',
    'ogudu-orioke': 'kosofe',
    'kosofe': 'kosofe',
    'ogudu': 'kosofe',
    'anthony': 'kosofe',
    'anthony village': 'kosofe',
    'magodo': 'kosofe',
    'maryland': 'kosofe',
    'mende': 'kosofe',
    'shangisha': 'kosofe',
    'isheri-olowo-ira': 'kosofe',

    // ── Shomolu LGA ──
    'shomolu': 'shomolu',
    'somolu': 'shomolu',
    'bariga': 'shomolu',
    'gbagada': 'shomolu',
    'pedro': 'shomolu',
    'onipanu': 'shomolu',
    'fadeyi': 'shomolu',
    'palmgrove': 'shomolu',
    'akoka': 'shomolu',

    // ── Ikeja LGA ──
    'ikeja': 'ikeja',
    'ikeja gra': 'ikeja',
    'alausa': 'ikeja',
    'opebi': 'ikeja',
    'adeniyi jones': 'ikeja',
    'allen': 'ikeja',
    'toyin street': 'ikeja',
    'computer village': 'ikeja',
    'oregun': 'ikeja',
    'ogba': 'ikeja',

    // ── Ojodu LCDA ──
    'ojodu': 'ojodu_lcda',
    'ojodu berger': 'ojodu_lcda',
    'berger': 'ojodu_lcda',
    'omole': 'ojodu_lcda',
    'onigbongbo': 'ojodu_lcda',
    'agidingbi': 'ojodu_lcda',

    // ── Agege LGA ──
    'agege': 'agege',
    'dopemu': 'agege',

    // ── Ifako-Ijaiye LGA ──
    'ifako-ijaiye': 'ifako_ijaiye',
    'ifako': 'ifako_ijaiye',
    'ijaiye': 'ifako_ijaiye',
    'oko-oba': 'ifako_ijaiye',
    'pen cinema': 'ifako_ijaiye',
    'tabon-tabon': 'ifako_ijaiye',
    'iju': 'ifako_ijaiye',
    'markaz': 'ifako_ijaiye',

    // ── Alimosho LGA ──
    'alimosho': 'alimosho',
    'egbeda': 'alimosho',
    'ikotun': 'alimosho',
    'idimu': 'alimosho',
    'igando': 'alimosho',
    'akowonjo': 'alimosho',
    'shasha': 'alimosho',
    'alakuko': 'alimosho',
    'kollinton': 'alimosho',
    'ikola': 'alimosho',
    'ijegun': 'alimosho',
    'aboru': 'alimosho',
    'abesan': 'alimosho',

    // ── Oshodi-Isolo LGA ──
    'oshodi': 'oshodi_isolo',
    'isolo': 'oshodi_isolo',
    'ejigbo': 'oshodi_isolo',
    'cement': 'oshodi_isolo',
    'okota': 'oshodi_isolo',
    'ilasa': 'oshodi_isolo',
    'oke-afa': 'oshodi_isolo',

    // ── Mushin LGA ──
    'mushin': 'mushin',
    'papa-ajao': 'mushin',
    'idi-araba': 'mushin',

    // ── Surulere LGA ──
    'surulere': 'surulere',
    'lawanson': 'surulere',
    'itire': 'surulere',
    'ijeshatedo': 'surulere',
    'ojuelegba': 'surulere',
    'aguda': 'surulere',
    'shitta': 'surulere',

    // ── Yaba / Mainland LGA ──
    'yaba': 'yaba_mainland',
    'ebute metta': 'yaba_mainland',
    'jibowu': 'yaba_mainland',
    'alagomeji': 'yaba_mainland',
    'obalende': 'yaba_mainland',
    'oto': 'yaba_mainland',
    'iwaya': 'yaba_mainland',
    'abule-oja': 'yaba_mainland',
    'sabo': 'yaba_mainland',
    'makoko': 'yaba_mainland',

    // ── Eti-Osa LGA ──
    'victoria island': 'eti_osa',
    'vi': 'eti_osa',
    'ikoyi': 'eti_osa',
    'oniru': 'eti_osa',
    'eko atlantic': 'eti_osa',
    'banana island': 'eti_osa',
    'lekki': 'eti_osa',
    'lekki phase 1': 'eti_osa',
    'lekki phase 2': 'eti_osa',
    'ajah': 'eti_osa',
    'sangotedo': 'eti_osa',
    'chevron': 'eti_osa',
    'jakande': 'eti_osa',
    'ikota': 'eti_osa',
    'agungi': 'eti_osa',
    'osapa': 'eti_osa',
    'idado': 'eti_osa',
    'vgc': 'eti_osa',
    'abraham adesanya': 'eti_osa',
    'langbasa': 'eti_osa',
    'ogombo': 'eti_osa',
    'badore': 'eti_osa',

    // ── Lagos Island LGA ──
    'lagos island': 'lagos_island',
    'marina': 'lagos_island',
    'isale-eko': 'lagos_island',
    'ologbowo': 'lagos_island',
    'idumota': 'lagos_island',

    // ── Apapa LGA ──
    'apapa': 'apapa',
    'ajegunle': 'apapa',
    'marine beach': 'apapa',
    'tincan': 'apapa',

    // ── Amuwo-Odofin LGA ──
    'festac': 'amuwo_odofin',
    'amuwo odofin': 'amuwo_odofin',
    'mile 2': 'amuwo_odofin',
    'satellite town': 'amuwo_odofin',

    // ── Ojo LGA ──
    'ojo': 'ojo',
    'okokomaiko': 'ojo',
    'ajangbadi': 'ojo',
    'ijanikin': 'ojo',
    'lasu': 'ojo',

    // ── Ajeromi-Ifelodun LGA ──
    'orile': 'ajeromi_ifelodun',
    'mosafejo': 'ajeromi_ifelodun',
    'amukoko': 'ajeromi_ifelodun',

    // ── Obafemi-Owode LGA (Ogun) ──
    'mowe': 'obafemi_owode',
    'ibafo': 'obafemi_owode',
    'arepo': 'obafemi_owode',
    'magboro': 'obafemi_owode',
    'isheri': 'obafemi_owode',

    // ── Outer Lagos ──
    'epe': 'outer',
    'badagry': 'outer',
    'sango': 'outer',
    'sango ota': 'outer',
    'ibeju-lekki': 'outer',
    'ibeju lekki': 'outer',
  };

  /// The live map: compiled defaults plus anything added remotely.
  static Map<String, String> _areaToLGA =
      Map<String, String>.from(_defaultAreaToLGA);

  /// Merge areas published by an admin (Firestore `config/areas`) over the
  /// compiled defaults, so a missing Lagos area becomes selectable without a
  /// Play Store release.
  ///
  /// Entries are ignored unless the LGA is one we actually price — a typo must
  /// not silently create an unpriceable area, because `city` feeds
  /// [findMatchingArea] and therefore the inspection fee.
  static void applyRemoteAreas(Map<String, dynamic>? raw) {
    final merged = Map<String, String>.from(_defaultAreaToLGA);
    if (raw != null) {
      final valid = {...lgas, outerLGA};
      raw.forEach((area, lga) {
        if (lga is! String) return;
        final key = area.trim().toLowerCase();
        final value = lga.trim().toLowerCase();
        if (key.isEmpty || !valid.contains(value)) return;
        merged[key] = value;
      });
    }
    _areaToLGA = merged;
  }

  static const Map<String, String> _lgaLabels = {
    'ikorodu': 'Ikorodu LGA',
    'kosofe': 'Kosofe LGA',
    'shomolu': 'Shomolu LGA',
    'ikeja': 'Ikeja LGA',
    'ojodu_lcda': 'Ojodu LCDA',
    'agege': 'Agege LGA',
    'ifako_ijaiye': 'Ifako-Ijaiye LGA',
    'alimosho': 'Alimosho LGA',
    'oshodi_isolo': 'Oshodi-Isolo LGA',
    'mushin': 'Mushin LGA',
    'surulere': 'Surulere LGA',
    'yaba_mainland': 'Yaba / Mainland LGA',
    'eti_osa': 'Eti-Osa LGA',
    'lagos_island': 'Lagos Island LGA',
    'apapa': 'Apapa LGA',
    'amuwo_odofin': 'Amuwo-Odofin LGA',
    'ojo': 'Ojo LGA',
    'ajeromi_ifelodun': 'Ajeromi-Ifelodun LGA',
    'obafemi_owode': 'Obafemi-Owode LGA (Ogun)',
    'outer': 'Outer Lagos',
  };

  // ══════════════════════════════════════════════
  //  LOOKUP METHODS
  // ══════════════════════════════════════════════

  /// Resolve an area name to its LGA.
  /// Returns null if the area is not recognized.
  static String? getLGAForArea(String area) {
    if (area.isEmpty) return null;
    final normalized = area.trim().toLowerCase();

    // Direct match
    if (_areaToLGA.containsKey(normalized)) {
      return _areaToLGA[normalized];
    }

    // Partial match
    for (final entry in _areaToLGA.entries) {
      if (normalized.contains(entry.key) || entry.key.contains(normalized)) {
        return entry.value;
      }
    }

    return null;
  }

  /// Backward-compatible alias for [getLGAForArea].
  /// Used by existing code that calls getClusterForArea.
  static String? getClusterForArea(String area) => getLGAForArea(area);

  /// Get human-readable label for an LGA.
  static String getLGALabel(String lga) {
    return _lgaLabels[lga] ?? lga;
  }

  /// Backward-compatible alias for [getLGALabel].
  static String getClusterLabel(String lga) => getLGALabel(lga);

  /// Get all areas that belong to a given LGA.
  static List<String> getAreasForLGA(String lga) {
    return _areaToLGA.entries
        .where((e) => e.value == lga)
        .map((e) => e.key)
        .toList()
      ..sort();
  }

  /// Backward-compatible alias for [getAreasForLGA].
  static List<String> getAreasForCluster(String lga) => getAreasForLGA(lga);

  /// Get all LGA names (for dropdowns, etc.)
  static List<String> get allLGAs => [...lgas, outerLGA];

  /// Backward-compatible alias.
  static List<String> get allClusters => allLGAs;

  /// Get all recognized area names as Title Case, sorted alphabetically.
  static List<String> getAllAreas() {
    final areas = _areaToLGA.keys.toSet().toList();
    areas.sort();
    return areas.map((a) => _titleCase(a)).toList();
  }

  /// Get all areas grouped by LGA, with LGA labels as headers.
  static List<Map<String, dynamic>> getAreasGroupedByLGA() {
    final groups = <Map<String, dynamic>>[];
    for (final lga in allLGAs) {
      final areas = getAreasForLGA(lga);
      if (areas.isNotEmpty) {
        groups.add({
          'cluster': lga, // keep key name for backward compat with AreaDropdown
          'label': getLGALabel(lga),
          'areas': areas.map((a) => _titleCase(a)).toList()..sort(),
        });
      }
    }
    return groups;
  }

  /// Backward-compatible alias.
  static List<Map<String, dynamic>> getAreasGroupedByCluster() =>
      getAreasGroupedByLGA();

  /// Try to fuzzy-match a geocoded city name to a known area.
  /// Handles diacritics (Ìkòròdú → Ikorodu) and LGA suffixes.
  static String? findMatchingArea(String rawCityName) {
    if (rawCityName.isEmpty) return null;

    // Strip diacritics
    final stripped = _stripDiacritics(rawCityName.trim().toLowerCase());

    // Direct match
    if (_areaToLGA.containsKey(stripped)) {
      return _titleCase(stripped);
    }

    // Try removing common suffixes
    for (final suffix in [' lga', ' lcda', ' local government', ' area']) {
      final withoutSuffix = stripped.replaceAll(suffix, '').trim();
      if (_areaToLGA.containsKey(withoutSuffix)) {
        return _titleCase(withoutSuffix);
      }
    }

    // Partial match
    for (final key in _areaToLGA.keys) {
      if (stripped.contains(key) || key.contains(stripped)) {
        return _titleCase(key);
      }
    }

    return null;
  }

  // ══════════════════════════════════════════════
  //  FEE CALCULATION
  // ══════════════════════════════════════════════

  /// Calculate the inspection fee.
  ///
  /// FLAT-FEE MODEL: tenant always pays [inspectionBookingFee] (₦10,000).
  /// Handler always earns [handlerEarnings] (₦7,000). ClearRent always
  /// keeps [clearrentTake] (₦3,000). Transport is arranged off-platform.
  ///
  /// The [agentCluster] and [propertyCluster] inputs are still recorded
  /// on the resulting breakdown for context/display, but they no longer
  /// affect the amounts.
  static InspectionFeeBreakdown calculateFee({
    required String agentCluster, // recorded for context, not used in math
    required String propertyCluster,
    String? propertyArea,
  }) {
    return InspectionFeeBreakdown(
      agentCluster: agentCluster,
      propertyCluster: propertyCluster,
      propertyArea: propertyArea,
      oneWayFare: 0,
      transportFee: 0,
      agentServiceFee: handlerEarnings,
      tenantServiceCharge: clearrentTake,
      totalFee: inspectionBookingFee,
      agentEarnings: handlerEarnings,
      clearrentEarnings: clearrentTake,
    );
  }

  /// Calculate fee from area names (resolves LGAs automatically).
  static InspectionFeeBreakdown? calculateFeeFromAreas({
    required String agentArea,
    required String propertyArea,
  }) {
    final agentLGA = getLGAForArea(agentArea);
    final propertyLGA = getLGAForArea(propertyArea);

    if (agentLGA == null || propertyLGA == null) return null;

    return calculateFee(
      agentCluster: agentLGA,
      propertyCluster: propertyLGA,
      propertyArea: propertyArea,
    );
  }

  /// Calculate the fee for a self-handled inspection (landlord shows
  /// the property themselves).
  ///
  /// FLAT-FEE MODEL: identical to [calculateFee]. Tenant pays ₦10,000,
  /// landlord earns ₦7,000, ClearRent keeps ₦3,000. The
  /// [landlordLivesInProperty] flag no longer affects the fee — it is
  /// still accepted for API stability and used elsewhere (e.g. to
  /// decide whether to post the transport-coordination chat message
  /// when the landlord accepts).
  static InspectionFeeBreakdown calculateSelfHandledFee({
    required bool landlordLivesInProperty,
    required String propertyCluster,
    String? landlordCluster,
    String? propertyArea,
  }) {
    final effectiveLandlordLGA = landlordCluster ?? propertyCluster;
    return InspectionFeeBreakdown(
      agentCluster: effectiveLandlordLGA,
      propertyCluster: propertyCluster,
      propertyArea: propertyArea,
      oneWayFare: 0,
      transportFee: 0,
      agentServiceFee: handlerEarnings,
      tenantServiceCharge: clearrentTake,
      totalFee: inspectionBookingFee,
      agentEarnings: handlerEarnings,
      clearrentEarnings: clearrentTake,
    );
  }

  // ══════════════════════════════════════════════
  //  FORMATTING HELPERS
  // ══════════════════════════════════════════════

  static String formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  static String formatNaira(double amount) {
    return '₦${formatAmount(amount)}';
  }

  static String _titleCase(String input) {
    if (input.isEmpty) return input;
    return input.split(' ').map((word) {
      if (word.isEmpty) return word;
      if ({'vi', 'vgc', 'gra', 'bq', 'lasu', 'cms'}.contains(word.toLowerCase())) {
        return word.toUpperCase();
      }
      return '${word[0].toUpperCase()}${word.substring(1)}';
    }).join(' ');
  }

  static String normalizeAreaName(String displayName) {
    return displayName.trim().toLowerCase();
  }

  /// Strip common diacritics from Yoruba text for matching.
  static String _stripDiacritics(String input) {
    const diacriticMap = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a',
      'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
      'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
      'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
      'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
      'ṣ': 's', 'ẹ': 'e', 'ọ': 'o',
    };
    return input.split('').map((c) => diacriticMap[c] ?? c).join('');
  }
}

/// Fee breakdown result
class InspectionFeeBreakdown {
  /// The LGA the agent/landlord is in (named agentCluster for backward compat)
  final String agentCluster;

  /// The LGA the property is in (named propertyCluster for backward compat)
  final String propertyCluster;

  /// The specific area within the property's LGA (if known)
  final String? propertyArea;

  /// One-way fare between the two LGAs
  final double oneWayFare;

  /// Round-trip transport fee (fare × 2 + last-mile buffer × 2)
  final double transportFee;

  /// Agent's flat service fee
  final double agentServiceFee;

  /// ClearRent's service charge to tenant
  final double tenantServiceCharge;

  /// Total the tenant pays
  final double totalFee;

  /// What the agent takes home
  final double agentEarnings;

  /// What ClearRent earns
  final double clearrentEarnings;

  /// Alias for UI
  double get clearrentFee => clearrentEarnings;

  /// Convenient LGA label accessors
  String get agentLGALabel => InspectionPricing.getLGALabel(agentCluster);
  String get propertyLGALabel => InspectionPricing.getLGALabel(propertyCluster);

  const InspectionFeeBreakdown({
    required this.agentCluster,
    required this.propertyCluster,
    this.propertyArea,
    this.oneWayFare = 0,
    required this.transportFee,
    required this.agentServiceFee,
    required this.tenantServiceCharge,
    required this.totalFee,
    required this.agentEarnings,
    required this.clearrentEarnings,
  });

  Map<String, dynamic> toMap() {
    return {
      'agentCluster': agentCluster,
      'propertyCluster': propertyCluster,
      'propertyArea': propertyArea,
      'oneWayFare': oneWayFare,
      'transportFee': transportFee,
      'agentServiceFee': agentServiceFee,
      'tenantServiceCharge': tenantServiceCharge,
      'totalFee': totalFee,
      'agentEarnings': agentEarnings,
      'clearrentEarnings': clearrentEarnings,
    };
  }

  factory InspectionFeeBreakdown.fromMap(Map<String, dynamic> map) {
    return InspectionFeeBreakdown(
      agentCluster: map['agentCluster'] ?? '',
      propertyCluster: map['propertyCluster'] ?? '',
      propertyArea: map['propertyArea'],
      oneWayFare: (map['oneWayFare'] ?? 0).toDouble(),
      transportFee: (map['transportFee'] ?? 0).toDouble(),
      agentServiceFee:
          (map['agentServiceFee'] ?? InspectionPricing.handlerEarnings)
              .toDouble(),
      tenantServiceCharge:
          (map['tenantServiceCharge'] ?? InspectionPricing.clearrentTake)
              .toDouble(),
      totalFee: (map['totalFee'] ?? 0).toDouble(),
      agentEarnings: (map['agentEarnings'] ?? 0).toDouble(),
      clearrentEarnings:
          (map['clearrentEarnings'] ?? InspectionPricing.clearrentTake)
              .toDouble(),
    );
  }

  @override
  String toString() {
    return '''
Inspection Fee Breakdown:
  Route: ${InspectionPricing.getLGALabel(agentCluster)} → ${InspectionPricing.getLGALabel(propertyCluster)}${propertyArea != null ? ' ($propertyArea)' : ''}
  One-way fare: ${InspectionPricing.formatNaira(oneWayFare)}
  Transport (round trip + buffer): ${InspectionPricing.formatNaira(transportFee)}
  Agent Service Fee: ${InspectionPricing.formatNaira(agentServiceFee)}
  Tenant Service Charge: ${InspectionPricing.formatNaira(tenantServiceCharge)}
  ─────────────────
  Tenant Pays: ${InspectionPricing.formatNaira(totalFee)}
  Agent Earns: ${InspectionPricing.formatNaira(agentEarnings)}
  ClearRent Earns: ${InspectionPricing.formatNaira(clearrentEarnings)}
''';
  }
}