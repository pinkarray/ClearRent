/// ClearRent Zone-Based Inspection Pricing
///
/// Lagos transport clusters with real fare data.
/// Pricing uses cluster-to-cluster lookups instead of GPS distance.
///
/// HOW TO UPDATE FARES:
/// 1. Find the route in [_clusterFares] (keys are alphabetically sorted pairs)
/// 2. Update the one-way fare value
/// 3. For sub-area overrides, update [_subAreaFares]
/// 4. Fares marked with // TODO: verify fare need real data
///
/// HOW IT WORKS:
/// - Each Lagos area maps to a cluster via [_areaToCluster]
/// - Fee = round-trip cluster fare + ₦1,000 last-mile buffer
/// - Tenant pays: transport + ₦10,000 agent service fee + ₦3,000 service charge
/// - Agent gets: transport + ₦10,000 service fee − ₦3,000 ClearRent cut = transport + ₦7,000
/// - ClearRent earns: ₦6,000 (₦3K tenant charge + ₦3K agent deduction)
library;

class InspectionPricing {
  // ══════════════════════════════════════════════
  //  FEE CONSTANTS
  // ══════════════════════════════════════════════

  /// Last-mile buffer added to each leg (one-way), so ₦1,000 round trip
  static const double lastMileBuffer = 500.0;

  /// ClearRent's service charge added to tenant's bill
  static const double tenantServiceCharge = 3000.0;

  /// Agent's flat service fee per inspection
  static const double agentServiceFee = 10000.0;

  /// ClearRent's deduction from agent's service fee
  static const double clearrentAgentCut = 3000.0;

  /// Minimum total fee the tenant can pay
  static const double minTenantFee = 13000.0;

  /// Booking fee for self-handled inspections (prevents abuse)
  /// Tenant always pays this even when landlord lives in property
  static const double selfHandledBookingFee = 10000.0;

  /// Same-zone base fare (when agent and property are in the same cluster)
  static const double sameZoneFare = 500.0;

  // ══════════════════════════════════════════════
  //  CLUSTER DEFINITIONS
  // ══════════════════════════════════════════════

  /// The 11 Lagos transport clusters.
  /// Each cluster groups areas that share similar transport hub access.
  static const List<String> clusters = [
    'ikorodu_inner',    // Ikorodu town, Benson, Itamaga
    'ikorodu_outer',    // Igbogbo, Ijede, Imota, Bayeku
    'ketu_ojota',       // Ketu, Ojota, Mile 12, Alapere
    'mainland_east',    // Shomolu, Bariga, Gbagada, Ogudu
    'maryland_ikeja',   // Maryland, Ikeja, Ikeja GRA, Anthony, Magodo, Ogba, Ojodu, Omole, Oregun, Alausa
    'yaba_surulere',    // Yaba, Surulere, Ebute Metta, Obalende, Palmgrove
    'berger_north',     // Berger, Mowe, Ibafo, Arepo, Isheri
    'oshodi_central',   // Oshodi, Mushin, Isolo, Ikotun, Egbeda, Alimosho, Agege, Ifako-Ijaiye
    'island',           // Victoria Island, Ikoyi, Lagos Island
    'lekki',            // Lekki Phase 1 & 2, Ajah, Sangotedo, Chevron, Jakande
    'apapa_west',       // Apapa, Festac, Amuwo Odofin
  ];

  /// Outer/long-distance cluster (Epe, Badagry, Sango)
  /// Used for routes that go outside the core Lagos clusters.
  static const String outerCluster = 'outer';

  // ══════════════════════════════════════════════
  //  AREA → CLUSTER MAPPING
  // ══════════════════════════════════════════════

  /// Maps a Lagos area name (lowercase) to its cluster.
  /// Used to resolve both property and agent locations.
  ///
  /// To add a new area: just add the mapping here.
  static const Map<String, String> _areaToCluster = {
    // ── Ikorodu Inner ──
    'ikorodu': 'ikorodu_inner',
    'ikorodu town': 'ikorodu_inner',
    'benson': 'ikorodu_inner',
    'itamaga': 'ikorodu_inner',
    'odogunyan': 'ikorodu_inner',
    'agric': 'ikorodu_inner',
    'owutu': 'ikorodu_inner',

    // ── Ikorodu Outer ──
    'igbogbo': 'ikorodu_outer',
    'ijede': 'ikorodu_outer',
    'imota': 'ikorodu_outer',
    'bayeku': 'ikorodu_outer',
    'ibeshe': 'ikorodu_outer',
    'erikorodo': 'ikorodu_outer',

    // ── Ketu / Ojota ──
    'ketu': 'ketu_ojota',
    'ojota': 'ketu_ojota',
    'mile 12': 'ketu_ojota',
    'alapere': 'ketu_ojota',
    'ogudu-orioke': 'ketu_ojota',
    'kosofe': 'ketu_ojota',

    // ── Mainland East ──
    'shomolu': 'mainland_east',
    'somolu': 'mainland_east',
    'bariga': 'mainland_east',
    'gbagada': 'mainland_east',
    'ogudu': 'mainland_east',
    'pedro': 'mainland_east',
    'onipanu': 'mainland_east',
    'fadeyi': 'mainland_east',

    // ── Maryland / Ikeja ──
    'maryland': 'maryland_ikeja',
    'ikeja': 'maryland_ikeja',
    'ikeja gra': 'maryland_ikeja',
    'anthony': 'maryland_ikeja',
    'anthony village': 'maryland_ikeja',
    'magodo': 'maryland_ikeja',
    'ogba': 'maryland_ikeja',
    'ojodu': 'maryland_ikeja',
    'omole': 'maryland_ikeja',
    'oregun': 'maryland_ikeja',
    'alausa': 'maryland_ikeja',
    'opebi': 'maryland_ikeja',
    'adeniyi jones': 'maryland_ikeja',
    'allen': 'maryland_ikeja',
    'toyin street': 'maryland_ikeja',
    'computer village': 'maryland_ikeja',

    // ── Yaba / Surulere ──
    'yaba': 'yaba_surulere',
    'surulere': 'yaba_surulere',
    'ebute metta': 'yaba_surulere',
    'obalende': 'yaba_surulere',
    'palmgrove': 'yaba_surulere',
    'jibowu': 'yaba_surulere',
    'lawanson': 'yaba_surulere',
    'itire': 'yaba_surulere',
    'ijeshatedo': 'yaba_surulere',
    'ojuelegba': 'yaba_surulere',
    'alagomeji': 'yaba_surulere',

    // ── Berger / North ──
    'berger': 'berger_north',
    'mowe': 'berger_north',
    'ibafo': 'berger_north',
    'arepo': 'berger_north',
    'isheri': 'berger_north',
    'magboro': 'berger_north',
    'ojodu berger': 'berger_north',

    // ── Oshodi / Central ──
    'oshodi': 'oshodi_central',
    'mushin': 'oshodi_central',
    'isolo': 'oshodi_central',
    'ikotun': 'oshodi_central',
    'egbeda': 'oshodi_central',
    'alimosho': 'oshodi_central',
    'agege': 'oshodi_central',
    'ifako-ijaiye': 'oshodi_central',
    'ifako': 'oshodi_central',
    'ijaiye': 'oshodi_central',
    'idimu': 'oshodi_central',
    'ejigbo': 'oshodi_central',
    'igando': 'oshodi_central',
    'akowonjo': 'oshodi_central',
    'dopemu': 'oshodi_central',
    'cement': 'oshodi_central',

    // ── Island ──
    'victoria island': 'island',
    'vi': 'island',
    'ikoyi': 'island',
    'lagos island': 'island',
    'marina': 'island',
    'oniru': 'island',
    'eko atlantic': 'island',
    'banana island': 'island',

    // ── Lekki ──
    'lekki': 'lekki',
    'lekki phase 1': 'lekki',
    'lekki phase 2': 'lekki',
    'ajah': 'lekki',
    'sangotedo': 'lekki',
    'chevron': 'lekki',
    'jakande': 'lekki',
    'ikota': 'lekki',
    'agungi': 'lekki',
    'osapa': 'lekki',
    'idado': 'lekki',
    'vgc': 'lekki',
    'abraham adesanya': 'lekki',

    // ── Apapa / West ──
    'apapa': 'apapa_west',
    'festac': 'apapa_west',
    'amuwo odofin': 'apapa_west',
    'mile 2': 'apapa_west',
    'orile': 'apapa_west',
    'ajegunle': 'apapa_west',
    'satellite town': 'apapa_west',

    // ── Outer ──
    'epe': 'outer',
    'badagry': 'outer',
    'sango': 'outer',
    'sango ota': 'outer',
    'ibeju-lekki': 'outer',
    'ibeju lekki': 'outer',
    'ojo': 'outer',
    'lasu': 'outer',
  };

  // ══════════════════════════════════════════════
  //  CLUSTER-TO-CLUSTER FARES (ONE-WAY, NAIRA)
  // ══════════════════════════════════════════════

  /// One-way transport fares between clusters.
  /// Keys are sorted alphabetically: 'clusterA:clusterB' where A < B.
  ///
  /// For clusters with sub-area price variation, we use the HIGHEST
  /// known sub-area fare (safest for agents). See [_subAreaFares]
  /// for per-sub-area overrides.
  ///
  /// To update: change the value and remove the TODO comment.
  static const Map<String, double> _clusterFares = {
    // ── Ikorodu Inner routes ──
    'ikorodu_inner:ikorodu_outer': 700,
    'ikorodu_inner:ketu_ojota': 1900,
    'ikorodu_inner:mainland_east': 3500,        // highest: Gbagada 3500
    'ikorodu_inner:maryland_ikeja': 2200,
    'ikorodu_inner:yaba_surulere': 3200,        // highest: Obalende 3200
    'ikorodu_inner:berger_north': 4700,
    'ikorodu_inner:oshodi_central': 3200,       // highest: Mushin 3200 (Isolo pending)
    'ikorodu_inner:island': 4000,
    'ikorodu_inner:lekki': 4500,
    'ikorodu_inner:apapa_west': 3500,           // highest: Apapa 3500
    'ikorodu_inner:outer': 1200,

    // ── Ikorodu Outer routes ──
    'ikorodu_outer:ketu_ojota': 1200,
    'ikorodu_outer:mainland_east': 2800,        // highest: Gbagada 2800
    'ikorodu_outer:maryland_ikeja': 2500,       // highest: Ikeja 2500
    'ikorodu_outer:yaba_surulere': 2500,        // highest: Obalende 2500
    'ikorodu_outer:berger_north': 3500,
    'ikorodu_outer:oshodi_central': 3500,       // highest: Isolo/Ikotun axis 3500
    'ikorodu_outer:island': 3000,
    'ikorodu_outer:lekki': 3500,
    'ikorodu_outer:apapa_west': 2800,           // highest: Apapa 2800
    'ikorodu_outer:outer': 3500,                // TODO: verify fare (Epe, Badagry, Sango unknown)

    // ── Ketu / Ojota routes ──
    'ketu_ojota:mainland_east': 800,            // highest: Shomolu 800, Bariga 800 (Gbagada, Ogudu pending)
    'ketu_ojota:maryland_ikeja': 300,
    'ketu_ojota:yaba_surulere': 1000,
    'ketu_ojota:berger_north': 600,
    'ketu_ojota:oshodi_central': 600,
    'ketu_ojota:island': 1800,
    'ketu_ojota:lekki': 3800,
    'ketu_ojota:apapa_west': 1500,
    'ketu_ojota:outer': 3500,

    // ── Mainland East routes ──
    'mainland_east:maryland_ikeja': 600,
    'mainland_east:yaba_surulere': 500,
    'mainland_east:berger_north': 1200,
    'mainland_east:oshodi_central': 800,
    'mainland_east:island': 1500,
    'mainland_east:lekki': 4000,
    'mainland_east:apapa_west': 1500,
    'mainland_east:outer': 3500,

    // ── Maryland / Ikeja routes ──
    'maryland_ikeja:yaba_surulere': 1300,
    'maryland_ikeja:berger_north': 800,
    'maryland_ikeja:oshodi_central': 400,
    'maryland_ikeja:island': 1800,
    'maryland_ikeja:lekki': 3500,
    'maryland_ikeja:apapa_west': 1200,
    'maryland_ikeja:outer': 3000,

    // ── Yaba / Surulere routes ──
    'yaba_surulere:berger_north': 1800,
    'yaba_surulere:oshodi_central': 800,
    'yaba_surulere:island': 800,
    'yaba_surulere:lekki': 3000,
    'yaba_surulere:apapa_west': 1000,
    'yaba_surulere:outer': 3500,

    // ── Berger / North routes ──
    'berger_north:oshodi_central': 1500,
    'berger_north:island': 2500,
    'berger_north:lekki': 4500,
    'berger_north:apapa_west': 2000,
    'berger_north:outer': 3500,

    // ── Oshodi / Central routes ──
    'oshodi_central:island': 1500,
    'oshodi_central:lekki': 3000,
    'oshodi_central:apapa_west': 800,
    'oshodi_central:outer': 3000,

    // ── Island routes ──
    'island:lekki': 1500,
    'island:apapa_west': 1000,
    'island:outer': 4000,

    // ── Lekki routes ──
    'lekki:apapa_west': 4000,
    'lekki:outer': 3000,

    // ── Apapa / West routes ──
    'apapa_west:outer': 2500,
  };

  // ══════════════════════════════════════════════
  //  SUB-AREA FARE OVERRIDES
  // ══════════════════════════════════════════════

  /// Per-sub-area fare overrides for routes with known variation.
  /// Key format: 'fromCluster:toCluster:subArea' (subArea is lowercase).
  /// The sub-area refers to the destination within the target cluster.
  ///
  /// When a specific sub-area is known (from property address), this
  /// takes precedence over the cluster-level fare.
  static const Map<String, double> _subAreaFares = {
    // ── Ikorodu Inner → Mainland East (sub-areas) ──
    'ikorodu_inner:mainland_east:shomolu': 2800,
    'ikorodu_inner:mainland_east:bariga': 3000,
    'ikorodu_inner:mainland_east:gbagada': 3500,
    'ikorodu_inner:mainland_east:ogudu': 3400,

    // ── Ikorodu Inner → Yaba/Surulere (sub-areas) ──
    'ikorodu_inner:yaba_surulere:yaba': 2700,
    'ikorodu_inner:yaba_surulere:surulere': 2700,
    'ikorodu_inner:yaba_surulere:obalende': 3200,

    // ── Ikorodu Inner → Oshodi/Central (sub-areas) ──
    'ikorodu_inner:oshodi_central:oshodi': 2700,
    'ikorodu_inner:oshodi_central:mushin': 3200,
    // 'ikorodu_inner:oshodi_central:isolo': TODO,

    // ── Ikorodu Inner → Apapa/West (sub-areas) ──
    'ikorodu_inner:apapa_west:apapa': 3500,
    'ikorodu_inner:apapa_west:festac': 2800,

    // ── Ikorodu Outer → Mainland East (sub-areas) ──
    'ikorodu_outer:mainland_east:shomolu': 2100,
    'ikorodu_outer:mainland_east:bariga': 2300,
    'ikorodu_outer:mainland_east:gbagada': 2800,
    'ikorodu_outer:mainland_east:ogudu': 2700,

    // ── Ikorodu Outer → Maryland/Ikeja (sub-areas) ──
    'ikorodu_outer:maryland_ikeja:maryland': 1500,
    'ikorodu_outer:maryland_ikeja:ikeja': 2500,
    'ikorodu_outer:maryland_ikeja:ikeja gra': 2000,

    // ── Ikorodu Outer → Yaba/Surulere (sub-areas) ──
    'ikorodu_outer:yaba_surulere:yaba': 2000,
    'ikorodu_outer:yaba_surulere:surulere': 2000,
    'ikorodu_outer:yaba_surulere:obalende': 2500,

    // ── Ikorodu Outer → Oshodi/Central (sub-areas) ──
    'ikorodu_outer:oshodi_central:oshodi': 2000,
    'ikorodu_outer:oshodi_central:mushin': 2500,
    'ikorodu_outer:oshodi_central:isolo': 3500,  // Ikotun axis
    // 'ikorodu_outer:oshodi_central:egbeda': TODO,

    // ── Ikorodu Outer → Apapa/West (sub-areas) ──
    'ikorodu_outer:apapa_west:apapa': 2800,
    'ikorodu_outer:apapa_west:festac': 2100,

    // ── Ketu/Ojota → Mainland East (sub-areas) ──
    'ketu_ojota:mainland_east:shomolu': 800,
    'ketu_ojota:mainland_east:bariga': 800,
    // 'ketu_ojota:mainland_east:gbagada': TODO,
    // 'ketu_ojota:mainland_east:ogudu': TODO,
  };

  // ══════════════════════════════════════════════
  //  PUBLIC API
  // ══════════════════════════════════════════════

  /// Resolve an area name (e.g. "Gbagada", "Lekki Phase 1") to its cluster.
  /// Returns null if the area is not recognized.
  static String? getClusterForArea(String area) {
    if (area.isEmpty) return null;
    final normalized = area.trim().toLowerCase();

    // Direct match
    if (_areaToCluster.containsKey(normalized)) {
      return _areaToCluster[normalized];
    }

    // Partial match — check if input contains a known area name
    for (final entry in _areaToCluster.entries) {
      if (normalized.contains(entry.key) || entry.key.contains(normalized)) {
        return entry.value;
      }
    }

    return null;
  }

  /// Get the one-way fare between two clusters.
  /// Returns [sameZoneFare] if both are in the same cluster.
  /// Returns null if either cluster is invalid or no route exists.
  static double? getOneWayFare(String clusterA, String clusterB) {
    if (clusterA == clusterB) return sameZoneFare;

    // Keys are alphabetically sorted
    final sorted = [clusterA, clusterB]..sort();
    final key = '${sorted[0]}:${sorted[1]}';

    return _clusterFares[key];
  }

  /// Get a sub-area-specific fare if available.
  /// [fromCluster] is where the agent/landlord is.
  /// [toCluster] is where the property is.
  /// [subArea] is the specific area within the destination cluster.
  static double? getSubAreaFare(
    String fromCluster,
    String toCluster,
    String subArea,
  ) {
    if (fromCluster == toCluster) return sameZoneFare;

    final normalizedSubArea = subArea.trim().toLowerCase();

    // Try both orderings since the sub-area could be in either cluster
    final key1 = '$fromCluster:$toCluster:$normalizedSubArea';
    final key2 = '$toCluster:$fromCluster:$normalizedSubArea';

    return _subAreaFares[key1] ?? _subAreaFares[key2];
  }

  /// Calculate the full inspection fee from cluster names.
  ///
  /// [agentCluster] — the cluster where the agent/landlord is based.
  /// [propertyCluster] — the cluster where the property is.
  /// [propertyArea] — optional specific area for sub-area pricing.
  static InspectionFeeBreakdown calculateFee({
    required String agentCluster,
    required String propertyCluster,
    String? propertyArea,
  }) {
    // Try sub-area fare first, fall back to cluster fare
    double? oneWayFare;

    if (propertyArea != null && propertyArea.isNotEmpty) {
      oneWayFare = getSubAreaFare(agentCluster, propertyCluster, propertyArea);
    }

    oneWayFare ??= getOneWayFare(agentCluster, propertyCluster);

    // If no fare found (unknown route), use a safe fallback
    oneWayFare ??= 3000.0; // Safe middle-ground for unknown routes

    // Round-trip transport + last-mile buffer
    final transportFee = (oneWayFare * 2) + (lastMileBuffer * 2);

    // What the tenant pays
    final tenantTotal = transportFee + tenantServiceCharge + agentServiceFee;

    // Enforce minimum
    final adjustedTenantTotal =
        tenantTotal < minTenantFee ? minTenantFee : tenantTotal;

    // Agent earnings = transport + service fee - ClearRent's cut
    final agentEarnings =
        transportFee + agentServiceFee - clearrentAgentCut;

    // ClearRent total = tenant service charge + agent deduction
    final clearrentEarnings = tenantServiceCharge + clearrentAgentCut;

    return InspectionFeeBreakdown(
      agentCluster: agentCluster,
      propertyCluster: propertyCluster,
      propertyArea: propertyArea,
      oneWayFare: oneWayFare,
      transportFee: transportFee,
      agentServiceFee: agentServiceFee,
      tenantServiceCharge: tenantServiceCharge,
      totalFee: adjustedTenantTotal,
      agentEarnings: agentEarnings,
      clearrentEarnings: clearrentEarnings,
    );
  }

  /// Calculate fee from area names (resolves clusters automatically).
  /// Returns null if either area cannot be resolved to a cluster.
  static InspectionFeeBreakdown? calculateFeeFromAreas({
    required String agentArea,
    required String propertyArea,
  }) {
    final agentCluster = getClusterForArea(agentArea);
    final propertyCluster = getClusterForArea(propertyArea);

    if (agentCluster == null || propertyCluster == null) return null;

    return calculateFee(
      agentCluster: agentCluster,
      propertyCluster: propertyCluster,
      propertyArea: propertyArea,
    );
  }

  /// Calculate fee for self-handled inspections (landlord conducts it).
  ///
  /// [landlordLivesInProperty] — if true, no transport cost.
  /// [landlordCluster] — where the landlord lives (if not in property).
  /// [propertyCluster] — where the property is.
  /// [propertyArea] — optional specific area for sub-area pricing.
  static InspectionFeeBreakdown calculateSelfHandledFee({
    required bool landlordLivesInProperty,
    required String propertyCluster,
    String? landlordCluster,
    String? propertyArea,
  }) {
    double transportFee = 0;
    double oneWayFare = 0;
    final effectiveLandlordCluster = landlordCluster ?? propertyCluster;

    if (!landlordLivesInProperty && landlordCluster != null) {
      // Landlord travels — calculate transport
      double? fare;
      if (propertyArea != null && propertyArea.isNotEmpty) {
        fare = getSubAreaFare(landlordCluster, propertyCluster, propertyArea);
      }
      fare ??= getOneWayFare(landlordCluster, propertyCluster);
      fare ??= 3000.0;
      oneWayFare = fare;
      transportFee = (fare * 2) + (lastMileBuffer * 2);
    }

    // Tenant pays: transport (if any) + booking fee
    final tenantTotal = transportFee + selfHandledBookingFee;

    // Landlord gets the transport money
    final landlordEarnings = transportFee;

    // ClearRent keeps the booking fee
    final clearrentEarnings = selfHandledBookingFee;

    return InspectionFeeBreakdown(
      agentCluster: effectiveLandlordCluster,
      propertyCluster: propertyCluster,
      propertyArea: propertyArea,
      oneWayFare: oneWayFare,
      transportFee: transportFee,
      agentServiceFee: 0,
      tenantServiceCharge: selfHandledBookingFee,
      totalFee: tenantTotal,
      agentEarnings: landlordEarnings,
      clearrentEarnings: clearrentEarnings,
    );
  }

  /// Get all available cluster names (for dropdowns, etc.)
  static List<String> get allClusters => [...clusters, outerCluster];

  /// Get human-readable label for a cluster.
  static String getClusterLabel(String cluster) {
    return _clusterLabels[cluster] ?? cluster;
  }

  /// Get all areas that belong to a given cluster.
  static List<String> getAreasForCluster(String cluster) {
    return _areaToCluster.entries
        .where((e) => e.value == cluster)
        .map((e) => e.key)
        .toList()
      ..sort();
  }

  static const Map<String, String> _clusterLabels = {
    'ikorodu_inner': 'Ikorodu (Inner)',
    'ikorodu_outer': 'Ikorodu (Outer)',
    'ketu_ojota': 'Ketu / Ojota',
    'mainland_east': 'Mainland East',
    'maryland_ikeja': 'Maryland / Ikeja',
    'yaba_surulere': 'Yaba / Surulere',
    'berger_north': 'Berger / North',
    'oshodi_central': 'Oshodi / Central',
    'island': 'Island (VI / Ikoyi)',
    'lekki': 'Lekki / Ajah',
    'apapa_west': 'Apapa / Festac',
    'outer': 'Outer Lagos',
  };

  // ══════════════════════════════════════════════
  //  FORMATTING HELPERS
  // ══════════════════════════════════════════════

  /// Format amount with commas
  static String formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) {
        result.add(',');
      }
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  /// Format as Naira
  static String formatNaira(double amount) {
    return '₦${formatAmount(amount)}';
  }
}

/// Fee breakdown result
class InspectionFeeBreakdown {
  /// The cluster the agent/landlord is in
  final String agentCluster;

  /// The cluster the property is in
  final String propertyCluster;

  /// The specific area within the property's cluster (if known)
  final String? propertyArea;

  /// One-way fare between the two clusters
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

  /// Alias for UI — same as [clearrentEarnings]
  double get clearrentFee => clearrentEarnings;

  const InspectionFeeBreakdown({
    required this.agentCluster,
    required this.propertyCluster,
    this.propertyArea,
    required this.oneWayFare,
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
      agentServiceFee: (map['agentServiceFee'] ?? 5000).toDouble(),
      tenantServiceCharge: (map['tenantServiceCharge'] ?? 2000).toDouble(),
      totalFee: (map['totalFee'] ?? 0).toDouble(),
      agentEarnings: (map['agentEarnings'] ?? 0).toDouble(),
      clearrentEarnings: (map['clearrentEarnings'] ?? 4000).toDouble(),
    );
  }

  @override
  String toString() {
    return '''
Inspection Fee Breakdown:
  Route: ${InspectionPricing.getClusterLabel(agentCluster)} → ${InspectionPricing.getClusterLabel(propertyCluster)}${propertyArea != null ? ' ($propertyArea)' : ''}
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