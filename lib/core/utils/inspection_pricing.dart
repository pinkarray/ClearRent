/// ClearRent LGA-Based Inspection Pricing
///
/// Lagos Local Government Area (LGA) pricing with real transport fare data.
/// Each area maps to an LGA, and fares are defined between LGA hubs.
///
/// HOW TO UPDATE FARES:
/// 1. Find the route in [_lgaFares] (keys are alphabetically sorted pairs)
/// 2. Update the one-way fare value
/// 3. Done — calculateFee() picks it up automatically
///
/// HOW IT WORKS:
/// - Each Lagos area maps to an LGA via [_areaToLGA]
/// - Fee = round-trip LGA fare + ₦1,000 last-mile buffer
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
  //  SAME-LGA FARES
  // ══════════════════════════════════════════════

  /// Fares for travel within the same LGA.
  /// Compact LGAs = ₦600, spread-out LGAs = ₦1,000.
  static const Map<String, double> _sameLGAFares = {
    // Compact LGAs — ₦600
    'shomolu': 600,
    'mushin': 600,
    'agege': 600,
    'lagos_island': 600,
    'apapa': 600,
    'ajeromi_ifelodun': 600,
    'ikeja': 600,
    'surulere': 600,
    'yaba_mainland': 600,
    'kosofe': 600,
    'ojodu_lcda': 600,
    'ifako_ijaiye': 600,
    // Spread-out LGAs — ₦1,000
    'ikorodu': 1000,
    'alimosho': 1000,
    'eti_osa': 1000,
    'ojo': 1000,
    'obafemi_owode': 1000,
    'oshodi_isolo': 800,
    'amuwo_odofin': 800,
    'outer': 1500,
  };

  /// Default same-LGA fare when not specified
  static const double defaultSameLGAFare = 600.0;

  // ══════════════════════════════════════════════
  //  AREA → LGA MAPPING
  // ══════════════════════════════════════════════

  /// Maps a Lagos area name (lowercase) to its LGA.
  /// To add a new area: just add the mapping here.
  static const Map<String, String> _areaToLGA = {
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

  // ══════════════════════════════════════════════
  //  LGA-TO-LGA FARES (ONE-WAY, NAIRA)
  // ══════════════════════════════════════════════

  /// One-way transport fares between LGA hubs.
  /// Keys are sorted alphabetically: 'lgaA:lgaB' where A < B.
  ///
  /// To update a fare: find the pair and change the number.
  /// To add a new route: add a new entry with sorted key.
  static const Map<String, double> _lgaFares = {
    // ── From Ikorodu ──
    'ikorodu:kosofe': 1200, // Ikorodu garage → Ojota/Ketu
    'ikorodu:shomolu': 2200, // via Maryland (1500) + Maryland→Shomolu (700)
    'ikorodu:ikeja': 2000, // via Maryland (1500) + Maryland→Ikeja (500)
    'ikorodu:ojodu_lcda': 3000, // Ikorodu → Maryland (1500) + Maryland→Ikeja (500) + Ikeja→Ojodu (1500) — but direct is ~3000
    'ikorodu:yaba_mainland': 2500, // via Maryland (1500) + Maryland→Yaba (1000)
    'ikorodu:lagos_island': 2700, // via Maryland (1500) + Maryland→CMS (1200)
    'ikorodu:eti_osa': 3700, // via CMS chain
    'ikorodu:oshodi_isolo': 2500, // via Ikeja chain
    'ikorodu:agege': 2500, // via Ikeja chain
    'ikorodu:mushin': 2500, // via Oshodi chain
    'ikorodu:surulere': 3000, // long route
    'ikorodu:alimosho': 3300, // via Oshodi chain
    'ikorodu:apapa': 3500, // long route
    'ikorodu:amuwo_odofin': 4000, // long route
    'ikorodu:ifako_ijaiye': 2500, // via Ikeja chain
    'ikorodu:obafemi_owode': 3500, // Ikorodu → Berger corridor
    'ikorodu:outer': 3500, // Epe direct or long haul
    'ikorodu:ojo': 4500, // very long route
    'ikorodu:ajeromi_ifelodun': 3500, // via Apapa chain

    // ── From Kosofe (Maryland/Ojota hub) ──
    'ikeja:kosofe': 500, // Maryland → Ikeja under bridge
    'kosofe:shomolu': 700, // Maryland → Shomolu
    'kosofe:yaba_mainland': 1000, // Maryland → Tejuosho/Yaba
    'kosofe:lagos_island': 1200, // Maryland → CMS
    'kosofe:eti_osa': 2200, // Maryland → CMS (1200) + CMS → Lekki (1000)
    'kosofe:oshodi_isolo': 1000, // Maryland → Ikeja (500) + Ikeja → Oshodi (500)
    'kosofe:agege': 1000, // Maryland → Ikeja (500) + Ikeja → Agege (500)
    'kosofe:mushin': 1500, // via Oshodi
    'kosofe:surulere': 1500, // via Yaba or Oshodi
    'kosofe:alimosho': 1800, // via Oshodi chain
    'kosofe:apapa': 2000, // long route
    'kosofe:amuwo_odofin': 2500, // via Oshodi/Apapa
    'kosofe:ifako_ijaiye': 1000, // via Ikeja
    'kosofe:ojodu_lcda': 1500, // Maryland → Ikeja (500) + Ikeja → Berger
    'kosofe:obafemi_owode': 2200, // via Berger
    'kosofe:outer': 3000, // long haul
    'kosofe:ojo': 3000, // via Apapa/Mile 2
    'kosofe:ajeromi_ifelodun': 2000, // via Apapa

    // ── From Ikeja ──
    'ikeja:shomolu': 1200, // Ikeja → Maryland (500) + Maryland → Shomolu (700)
    'ikeja:yaba_mainland': 1500, // Ikeja → Yaba
    'ikeja:oshodi_isolo': 500, // Ikeja → Oshodi
    'ikeja:agege': 500, // Ikeja → Agege
    'ikeja:ifako_ijaiye': 500, // Ikeja → Pen Cinema/Iju
    'ikeja:ojodu_lcda': 1500, // Ikeja → Ojodu Berger
    'ikeja:mushin': 1000, // via Oshodi
    'ikeja:surulere': 1300, // via Oshodi → Ojuelegba
    'ikeja:lagos_island': 1700, // Ikeja → Maryland (500) + Maryland → CMS (1200)
    'ikeja:eti_osa': 2700, // via CMS chain
    'ikeja:alimosho': 1300, // via Oshodi → Egbeda
    'ikeja:apapa': 1700, // via Oshodi → Apapa
    'ikeja:amuwo_odofin': 2000, // via Oshodi chain
    'ikeja:obafemi_owode': 700, // Ikeja → Berger/Mowe
    'ikeja:outer': 3000, // long haul
    'ikeja:ojo': 2500, // via Mile 2
    'ikeja:ajeromi_ifelodun': 1700, // via Oshodi/Apapa

    // ── From Shomolu ──
    'shomolu:yaba_mainland': 500, // Bariga/Gbagada → Yaba (short)
    'shomolu:lagos_island': 1500, // via Yaba → CMS
    'shomolu:eti_osa': 2500, // via CMS chain
    'shomolu:oshodi_isolo': 1700, // via Ikeja
    'shomolu:surulere': 1200, // via Yaba
    'shomolu:mushin': 1500, // via Yaba/Oshodi

    // ── From Yaba/Mainland ──
    'lagos_island:yaba_mainland': 700, // Sabo/Yaba → CMS
    'eti_osa:yaba_mainland': 1700, // Yaba → CMS (700) + CMS → Lekki (1000)
    'oshodi_isolo:yaba_mainland': 1500, // Yaba → Oshodi
    'surulere:yaba_mainland': 600, // Yaba → Ojuelegba (short)
    'mushin:yaba_mainland': 1000, // Yaba → Mushin

    // ── From Lagos Island ──
    'eti_osa:lagos_island': 1000, // CMS → Lekki corridor
    'lagos_island:surulere': 800, // CMS → Ojuelegba
    'lagos_island:oshodi_isolo': 1500, // CMS → Oshodi

    // ── From Oshodi-Isolo ──
    'alimosho:oshodi_isolo': 800, // Oshodi → Ikotun/Egbeda
    'mushin:oshodi_isolo': 500, // Oshodi → Mushin (very short)
    'oshodi_isolo:surulere': 800, // Oshodi → Ojuelegba
    'apapa:oshodi_isolo': 1200, // Oshodi → Apapa
    'amuwo_odofin:oshodi_isolo': 1500, // via Mile 2
    'ojo:oshodi_isolo': 2000, // via Mile 2 chain
    'ajeromi_ifelodun:oshodi_isolo': 1200, // via Apapa/Orile
    'obafemi_owode:oshodi_isolo': 1700, // via Ikeja → Berger

    // ── From Agege ──
    'agege:ifako_ijaiye': 500, // adjacent LGAs
    'agege:ojodu_lcda': 1000, // via Ikeja corridor
    'agege:alimosho': 800, // Agege → Egbeda/Akowonjo
    'agege:mushin': 800, // via Oshodi
    'agege:oshodi_isolo': 1000, // Agege → Oshodi
    'agege:obafemi_owode': 1200, // Agege → Berger

    // ── From Ifako-Ijaiye ──
    'ifako_ijaiye:ojodu_lcda': 800, // adjacent
    'ifako_ijaiye:alimosho': 1000, // via Agege
    'ifako_ijaiye:obafemi_owode': 1000, // towards Berger

    // ── From Ojodu LCDA ──
    'obafemi_owode:ojodu_lcda': 500, // Ojodu Berger → Mowe (short)
    'ojodu_lcda:alimosho': 1500, // via Ikeja/Oshodi

    // ── From Surulere ──
    'mushin:surulere': 400, // very short trip
    'apapa:surulere': 1000, // Ojuelegba → Apapa
    'ajeromi_ifelodun:surulere': 800, // via Orile

    // ── From Mushin ──
    'apapa:mushin': 1200, // via Oshodi
    'alimosho:mushin': 1300, // via Oshodi

    // ── From Apapa ──
    'amuwo_odofin:apapa': 2000, // Apapa → Mile 2/Festac
    'apapa:ojo': 2750, // Apapa → Okokomaiko (avg of 2500-3000)
    'ajeromi_ifelodun:apapa': 1200, // Apapa → Orile

    // ── From Amuwo-Odofin ──
    'amuwo_odofin:ojo': 1000, // Mile 2 → Okokomaiko
    'ajeromi_ifelodun:amuwo_odofin': 1500, // Orile → Festac

    // ── From Ojo ──
    'ojo:outer': 2000, // Ojo → Badagry (avg of 1500-2500)
    'ajeromi_ifelodun:ojo': 2000, // Orile → Okokomaiko

    // ── From Alimosho ──
    'alimosho:apapa': 2000, // via Oshodi chain
    'alimosho:amuwo_odofin': 1800, // via Mile 2

    // ── Outer routes ──
    
    'eti_osa:outer': 2500, // Lekki → Ibeju-Lekki / Epe
   
    'obafemi_owode:outer': 2000, // Mowe → Sango
  };

  // ══════════════════════════════════════════════
  //  LGA LABELS (for display)
  // ══════════════════════════════════════════════

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

  /// Get the one-way fare between two LGAs.
  static double? getOneWayFare(String lgaA, String lgaB) {
    if (lgaA == lgaB) return _sameLGAFares[lgaA] ?? defaultSameLGAFare;

    final sorted = [lgaA, lgaB]..sort();
    final key = '${sorted[0]}:${sorted[1]}';

    return _lgaFares[key];
  }

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

  /// Calculate the full inspection fee from LGA names.
  static InspectionFeeBreakdown calculateFee({
    required String agentCluster, // actually LGA — kept for backward compat
    required String propertyCluster, // actually LGA
    String? propertyArea,
  }) {
    double? oneWayFare = getOneWayFare(agentCluster, propertyCluster);

    // Unknown route fallback
    oneWayFare ??= 3000.0;

    final transportFee = (oneWayFare * 2) + (lastMileBuffer * 2);
    final tenantTotal = transportFee + tenantServiceCharge + agentServiceFee;
    final adjustedTenantTotal =
        tenantTotal < minTenantFee ? minTenantFee : tenantTotal;
    final agentEarnings = transportFee + agentServiceFee - clearrentAgentCut;
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

  /// Calculate fee for self-handled inspections.
  static InspectionFeeBreakdown calculateSelfHandledFee({
    required bool landlordLivesInProperty,
    required String propertyCluster,
    String? landlordCluster,
    String? propertyArea,
  }) {
    double transportFee = 0;
    double oneWayFare = 0;
    final effectiveLandlordLGA = landlordCluster ?? propertyCluster;

    if (!landlordLivesInProperty && landlordCluster != null) {
      double? fare = getOneWayFare(landlordCluster, propertyCluster);
      fare ??= 3000.0;
      oneWayFare = fare;
      transportFee = (fare * 2) + (lastMileBuffer * 2);
    }

    final tenantTotal = transportFee + selfHandledBookingFee;
    final landlordEarnings = transportFee;
    final clearrentEarnings = selfHandledBookingFee;

    return InspectionFeeBreakdown(
      agentCluster: effectiveLandlordLGA,
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