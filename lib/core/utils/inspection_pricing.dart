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
  // pricing.ts - the server derives what it actually charges from that same
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
  //  LGA + AREA DEFINITIONS
  // ══════════════════════════════════════════════

  /// Long-distance bucket Badagry, Epe and Ibeju-Lekki used to share. They are
  /// real LGAs of their own now and nothing compiles into this any more, but it
  /// stays valid: inspection docs written before the split still carry it.
  static const String outerLGA = 'outer';

  /// Bucket for areas outside Lagos entirely. Nothing is compiled into it, and
  /// it deliberately has no state: an area whose LGA has no state does not get
  /// to claim Lagos. See [stateForArea].
  static const String otherLGA = 'other';

  // Everything between the markers below is GENERATED from
  // scripts/lagos_areas.json by scripts/gen_areas.js, which also rewrites the
  // web copy in clearrent_web/lib/lagos-areas.ts. Edit that JSON and re-run the
  // generator: hand-editing either list is how app and web drifted apart.
  //
  // Areas can also be published live from the admin dashboard (config/areas),
  // so a missing area never waits on a Play Store release.
  // GENERATED-AREAS-START
  /// Lagos LGAs in display order: what every area picker opens on.
  static const List<String> lgas = [
    'ikeja',
    'eti_osa',
    'lagos_island',
    'surulere',
    'yaba_mainland',
    'kosofe',
    'oshodi_isolo',
    'alimosho',
    'ojodu_lcda',
    'shomolu',
    'agege',
    'ifako_ijaiye',
    'mushin',
    'amuwo_odofin',
    'apapa',
    'ajeromi_ifelodun',
    'ojo',
    'ikorodu',
    'badagry',
    'epe',
    'ibeju_lekki',
    'obafemi_owode',
  ];

  /// The state each LGA is in. An area picked from the list decides the
  /// state, so this is what stops an Ogun area saving as Lagos.
  static const Map<String, String> _lgaState = {
    'ikeja': 'Lagos',
    'eti_osa': 'Lagos',
    'lagos_island': 'Lagos',
    'surulere': 'Lagos',
    'yaba_mainland': 'Lagos',
    'kosofe': 'Lagos',
    'oshodi_isolo': 'Lagos',
    'alimosho': 'Lagos',
    'ojodu_lcda': 'Lagos',
    'shomolu': 'Lagos',
    'agege': 'Lagos',
    'ifako_ijaiye': 'Lagos',
    'mushin': 'Lagos',
    'amuwo_odofin': 'Lagos',
    'apapa': 'Lagos',
    'ajeromi_ifelodun': 'Lagos',
    'ojo': 'Lagos',
    'ikorodu': 'Lagos',
    'badagry': 'Lagos',
    'epe': 'Lagos',
    'ibeju_lekki': 'Lagos',
    'obafemi_owode': 'Ogun',
    outerLGA: 'Lagos',
  };

  static const Map<String, String> _lgaLabels = {
    'ikeja': 'Ikeja LGA',
    'eti_osa': 'Eti-Osa LGA',
    'lagos_island': 'Lagos Island LGA',
    'surulere': 'Surulere LGA',
    'yaba_mainland': 'Lagos Mainland LGA (Yaba)',
    'kosofe': 'Kosofe LGA',
    'oshodi_isolo': 'Oshodi-Isolo LGA',
    'alimosho': 'Alimosho LGA',
    'ojodu_lcda': 'Ojodu LGA',
    'shomolu': 'Shomolu LGA',
    'agege': 'Agege LGA',
    'ifako_ijaiye': 'Ifako-Ijaiye LGA',
    'mushin': 'Mushin LGA',
    'amuwo_odofin': 'Amuwo-Odofin LGA',
    'apapa': 'Apapa LGA',
    'ajeromi_ifelodun': 'Ajeromi-Ifelodun LGA',
    'ojo': 'Ojo LGA',
    'ikorodu': 'Ikorodu LGA',
    'badagry': 'Badagry LGA',
    'epe': 'Epe LGA',
    'ibeju_lekki': 'Ibeju-Lekki LGA',
    'obafemi_owode': 'Lagos outskirts: Obafemi-Owode (Ogun)',
    outerLGA: 'Outer Lagos',
    otherLGA: 'Other areas',
  };

  /// Compiled-in area to LGA map (lowercase keys). The offline baseline.
  static const Map<String, String> _defaultAreaToLGA = {
    // Ikeja LGA
    'adekunle village': 'ikeja',
    'adeniyi jones': 'ikeja',
    'aguda ogba': 'ikeja',
    'airport road': 'ikeja',
    'alausa': 'ikeja',
    'allen': 'ikeja',
    'anifowoshe': 'ikeja',
    'computer village': 'ikeja',
    'ikeja': 'ikeja',
    'ikeja gra': 'ikeja',
    'inilekere': 'ikeja',
    'ipodo': 'ikeja',
    'oba akran': 'ikeja',
    'ogba': 'ikeja',
    'oke-ira': 'ikeja',
    'olusosun': 'ikeja',
    'onigbongbo': 'ikeja',
    'onipetesi': 'ikeja',
    'opebi': 'ikeja',
    'oregun': 'ikeja',
    'seriki aro': 'ikeja',
    'toyin street': 'ikeja',
    'wasimi': 'ikeja',

    // Eti-Osa LGA
    'abraham adesanya': 'eti_osa',
    'addo': 'eti_osa',
    'agungi': 'eti_osa',
    'ajah': 'eti_osa',
    'badore': 'eti_osa',
    'banana island': 'eti_osa',
    'chevron': 'eti_osa',
    'dolphin estate': 'eti_osa',
    'eko atlantic': 'eti_osa',
    'elegushi': 'eti_osa',
    'falomo': 'eti_osa',
    'idado': 'eti_osa',
    'igbo-efon': 'eti_osa',
    'ikate lekki': 'eti_osa',
    'ikota': 'eti_osa',
    'ikoyi': 'eti_osa',
    'ilado': 'eti_osa',
    'ilasan': 'eti_osa',
    'jakande': 'eti_osa',
    'kuramo': 'eti_osa',
    'langbasa': 'eti_osa',
    'lekki': 'eti_osa',
    'lekki phase 1': 'eti_osa',
    'lekki phase 2': 'eti_osa',
    'maroko': 'eti_osa',
    'obalende': 'eti_osa',
    'ogombo': 'eti_osa',
    'ologolo': 'eti_osa',
    'oniru': 'eti_osa',
    'osapa': 'eti_osa',
    'osborne': 'eti_osa',
    'parkview': 'eti_osa',
    'sangotedo': 'eti_osa',
    'thomas estate': 'eti_osa',
    'vgc': 'eti_osa',
    'victoria island': 'eti_osa',

    // Lagos Island LGA
    'adeniji adele': 'lagos_island',
    'agarawu': 'lagos_island',
    'anikantamo': 'lagos_island',
    'balogun': 'lagos_island',
    'broad street': 'lagos_island',
    'campos': 'lagos_island',
    'cms': 'lagos_island',
    'ebute ero': 'lagos_island',
    'eiyekole': 'lagos_island',
    'elegbata': 'lagos_island',
    'epetedo': 'lagos_island',
    'idumota': 'lagos_island',
    'iduntafa': 'lagos_island',
    'ilubirin': 'lagos_island',
    'ilupesi': 'lagos_island',
    'isale-agbede': 'lagos_island',
    'isale-eko': 'lagos_island',
    'kakawa': 'lagos_island',
    'lafiaji': 'lagos_island',
    'lagos island': 'lagos_island',
    'marina': 'lagos_island',
    'obadina': 'lagos_island',
    'oju-oto': 'lagos_island',
    'oke arin': 'lagos_island',
    'oko-awo': 'lagos_island',
    'oko-faji': 'lagos_island',
    'olosun': 'lagos_island',
    'olowogbowo': 'lagos_island',
    'olushi': 'lagos_island',
    'oluwole': 'lagos_island',
    'onikan': 'lagos_island',
    'popo aguda': 'lagos_island',
    'sandgrouse': 'lagos_island',

    // Surulere LGA
    'adeniran ogunsanya': 'surulere',
    'aguda': 'surulere',
    'akinhanmi': 'surulere',
    'alaka': 'surulere',
    'bode thomas': 'surulere',
    'coker': 'surulere',
    'cole': 'surulere',
    'eric moore': 'surulere',
    'iganmu': 'surulere',
    'igbaja': 'surulere',
    'ijeshatedo': 'surulere',
    'ikate surulere': 'surulere',
    'iponri': 'surulere',
    'itire': 'surulere',
    'lawanson': 'surulere',
    'masha': 'surulere',
    'ogunlana drive': 'surulere',
    'ojuelegba': 'surulere',
    'shitta': 'surulere',
    'small london': 'surulere',
    'stadium': 'surulere',
    'surulere': 'surulere',

    // Lagos Mainland LGA (Yaba)
    'abule nla': 'yaba_mainland',
    'abule-ijesha': 'yaba_mainland',
    'abule-oja': 'yaba_mainland',
    'adekunle': 'yaba_mainland',
    'alagomeji': 'yaba_mainland',
    'costain': 'yaba_mainland',
    'ebute metta': 'yaba_mainland',
    'glover': 'yaba_mainland',
    'iddo': 'yaba_mainland',
    'iwaya': 'yaba_mainland',
    'jibowu': 'yaba_mainland',
    'makoko': 'yaba_mainland',
    'oko-baba': 'yaba_mainland',
    'olaleye village': 'yaba_mainland',
    'onike': 'yaba_mainland',
    'oto': 'yaba_mainland',
    'oyadiran estate': 'yaba_mainland',
    'oyingbo': 'yaba_mainland',
    'sabo yaba': 'yaba_mainland',
    'yaba': 'yaba_mainland',
    'yaba tech': 'yaba_mainland',

    // Kosofe LGA
    'agboyi': 'kosofe',
    'agiliti': 'kosofe',
    'ajao estate anthony': 'kosofe',
    'ajelogo': 'kosofe',
    'akanimodo': 'kosofe',
    'alapere': 'kosofe',
    'anthony village': 'kosofe',
    'ifako-gbagada': 'kosofe',
    'ikosi': 'kosofe',
    'isheri-olowo-ira': 'kosofe',
    'ketu': 'kosofe',
    'kosofe': 'kosofe',
    'magodo': 'kosofe',
    'maryland': 'kosofe',
    'mende': 'kosofe',
    'mile 12': 'kosofe',
    'odo-ogun': 'kosofe',
    'ogudu': 'kosofe',
    'ogudu-orioke': 'kosofe',
    'ojota': 'kosofe',
    'orisigun': 'kosofe',
    'oruba': 'kosofe',
    'owode onirin': 'kosofe',
    'oworonshoki': 'kosofe',
    'shangisha': 'kosofe',
    'shonibare estate': 'kosofe',
    'soluyi': 'kosofe',

    // Oshodi-Isolo LGA
    'ago palace': 'oshodi_isolo',
    'ajao estate': 'oshodi_isolo',
    'alasia': 'oshodi_isolo',
    'bolade': 'oshodi_isolo',
    'bucknor': 'oshodi_isolo',
    'cement': 'oshodi_isolo',
    'ejigbo': 'oshodi_isolo',
    'ilasamaja': 'oshodi_isolo',
    'ire-akari': 'oshodi_isolo',
    'ishagatedo': 'oshodi_isolo',
    'isolo': 'oshodi_isolo',
    'mafoluku': 'oshodi_isolo',
    'oke-afa': 'oshodi_isolo',
    'okota': 'oshodi_isolo',
    'orile oshodi': 'oshodi_isolo',
    'oshodi': 'oshodi_isolo',
    'sogunle': 'oshodi_isolo',

    // Alimosho LGA
    'abesan': 'alimosho',
    'aboru': 'alimosho',
    'abule egba': 'alimosho',
    'agodo': 'alimosho',
    'akesan': 'alimosho',
    'akowonjo': 'alimosho',
    'alagbado': 'alimosho',
    'alimosho': 'alimosho',
    'ayobo': 'alimosho',
    'baruwa': 'alimosho',
    'command': 'alimosho',
    'egan': 'alimosho',
    'egbe': 'alimosho',
    'egbeda': 'alimosho',
    'gowon estate': 'alimosho',
    'idimu': 'alimosho',
    'igando': 'alimosho',
    'ijegun': 'alimosho',
    'ikola': 'alimosho',
    'ikotun': 'alimosho',
    'ipaja': 'alimosho',
    'isheri olofin': 'alimosho',
    'isheri oshun': 'alimosho',
    'iyana ipaja': 'alimosho',
    'meiran': 'alimosho',
    'mosan': 'alimosho',
    'oke odo': 'alimosho',
    'okunola': 'alimosho',
    'pleasure': 'alimosho',
    'shasha': 'alimosho',

    // Ojodu LGA
    'agidingbi': 'ojodu_lcda',
    'ojodu': 'ojodu_lcda',
    'ojodu berger': 'ojodu_lcda',
    'omole': 'ojodu_lcda',
    'omole phase 1': 'ojodu_lcda',
    'omole phase 2': 'ojodu_lcda',

    // Shomolu LGA
    'abule okuta': 'shomolu',
    'akoka': 'shomolu',
    'alade': 'shomolu',
    'apelehin': 'shomolu',
    'bajulaiye': 'shomolu',
    'bariga': 'shomolu',
    'fadeyi': 'shomolu',
    'fola agoro': 'shomolu',
    'gbagada': 'shomolu',
    'gbagada phase 1': 'shomolu',
    'gbagada phase 2': 'shomolu',
    'igbobi': 'shomolu',
    'ijebutedo': 'shomolu',
    'ilaje bariga': 'shomolu',
    'lad-lak': 'shomolu',
    'mafowoku': 'shomolu',
    'obanikoro': 'shomolu',
    'onipanu': 'shomolu',
    'palmgrove': 'shomolu',
    'pedro': 'shomolu',
    'shomolu': 'shomolu',

    // Agege LGA
    'agbotikuyo': 'agege',
    'agege': 'agege',
    'darocha': 'agege',
    'dopemu': 'agege',
    'idimangoro': 'agege',
    'iloro': 'agege',
    'isale odo': 'agege',
    'keke': 'agege',
    'mulero': 'agege',
    'okekoto': 'agege',
    'oko-oba': 'agege',
    'oniwaya': 'agege',
    'orile agege': 'agege',
    'oyewole': 'agege',
    'papa ashafa': 'agege',
    'papa-uku': 'agege',
    'pen cinema': 'agege',
    'tabon-tabon': 'agege',

    // Ifako-Ijaiye LGA
    'agbado': 'ifako_ijaiye',
    'ajegunle ifako': 'ifako_ijaiye',
    'akinde': 'ifako_ijaiye',
    'akute road': 'ifako_ijaiye',
    'alakuko': 'ifako_ijaiye',
    'animashaun': 'ifako_ijaiye',
    'fagba': 'ifako_ijaiye',
    'ifako-ijaiye': 'ifako_ijaiye',
    'ijaiye': 'ifako_ijaiye',
    'iju': 'ifako_ijaiye',
    'iju ishaga': 'ifako_ijaiye',
    'karaole': 'ifako_ijaiye',
    'kollington': 'ifako_ijaiye',
    'markaz': 'ifako_ijaiye',
    'obawole': 'ifako_ijaiye',
    'ojokoro': 'ifako_ijaiye',
    'oyemekun': 'ifako_ijaiye',
    'pamada': 'ifako_ijaiye',

    // Mushin LGA
    'alakara': 'mushin',
    'atewolara': 'mushin',
    'babalosa': 'mushin',
    'idi-araba': 'mushin',
    'idi-oro': 'mushin',
    'ilupeju': 'mushin',
    'ilupeju industrial estate': 'mushin',
    'kayode': 'mushin',
    'ladipo': 'mushin',
    'mushin': 'mushin',
    'odi-olowu': 'mushin',
    'ojuwoye': 'mushin',
    'olateju': 'mushin',
    'papa-ajao': 'mushin',

    // Amuwo-Odofin LGA
    'abule ado': 'amuwo_odofin',
    'abule osun': 'amuwo_odofin',
    'agboju': 'amuwo_odofin',
    'alakija': 'amuwo_odofin',
    'amuwo odofin': 'amuwo_odofin',
    'festac': 'amuwo_odofin',
    'ibeshe amuwo': 'amuwo_odofin',
    'igbologun': 'amuwo_odofin',
    'ijegun egba': 'amuwo_odofin',
    'ilashe': 'amuwo_odofin',
    'irede': 'amuwo_odofin',
    'kirikiri': 'amuwo_odofin',
    'mazamaza': 'amuwo_odofin',
    'mile 2': 'amuwo_odofin',
    'oloti': 'amuwo_odofin',
    'satellite town': 'amuwo_odofin',
    'tedimuwo': 'amuwo_odofin',
    'tomaro': 'amuwo_odofin',
    'trade fair': 'amuwo_odofin',

    // Apapa LGA
    'afolabi alasia': 'apapa',
    'apapa': 'apapa',
    'apapa gra': 'apapa',
    'badia': 'apapa',
    'creek road': 'apapa',
    'gaskiya': 'apapa',
    'ibafon': 'apapa',
    'ijora': 'apapa',
    'ijora olopa': 'apapa',
    'ijora oloye': 'apapa',
    'liverpool': 'apapa',
    'malu road': 'apapa',
    'marine beach': 'apapa',
    'orile iganmu': 'apapa',
    'pelewura crescent': 'apapa',
    'sari iganmu': 'apapa',
    'snake island': 'apapa',
    'tincan': 'apapa',
    'wharf': 'apapa',

    // Ajeromi-Ifelodun LGA
    'ago hausa': 'ajeromi_ifelodun',
    'aiyetoro ajeromi': 'ajeromi_ifelodun',
    'ajegunle': 'ajeromi_ifelodun',
    'alaba oro': 'ajeromi_ifelodun',
    'alakoto': 'ajeromi_ifelodun',
    'alayabiagba': 'ajeromi_ifelodun',
    'amukoko': 'ajeromi_ifelodun',
    'araromi ajeromi': 'ajeromi_ifelodun',
    'awodi-ora': 'ajeromi_ifelodun',
    'boundary': 'ajeromi_ifelodun',
    'layeni': 'ajeromi_ifelodun',
    'mosafejo': 'ajeromi_ifelodun',
    'ojo road': 'ajeromi_ifelodun',
    'olodi': 'ajeromi_ifelodun',
    'onibaba': 'ajeromi_ifelodun',
    'orile': 'ajeromi_ifelodun',
    'orodun': 'ajeromi_ifelodun',
    'temidire': 'ajeromi_ifelodun',
    'tolu': 'ajeromi_ifelodun',
    'wilmer': 'ajeromi_ifelodun',

    // Ojo LGA
    'ajangbadi': 'ojo',
    'alaba international': 'ojo',
    'alaba rago': 'ojo',
    'etegbin': 'ojo',
    'iba': 'ojo',
    'idoluwo': 'ojo',
    'igbo elerin': 'ojo',
    'ijanikin': 'ojo',
    'ilogbo': 'ojo',
    'ilopo': 'ojo',
    'irewe': 'ojo',
    'iyana iba': 'ojo',
    'lasu': 'ojo',
    'ojo': 'ojo',
    'ojo barracks': 'ojo',
    'ojo town': 'ojo',
    'okokomaiko': 'ojo',
    'sabo oniba': 'ojo',
    'shibiri': 'ojo',
    'tafi': 'ojo',

    // Ikorodu LGA
    'adamo': 'ikorodu',
    'adebo': 'ikorodu',
    'aga': 'ikorodu',
    'agbala': 'ikorodu',
    'agbede': 'ikorodu',
    'agric': 'ikorodu',
    'agura': 'ikorodu',
    'bayeku': 'ikorodu',
    'benson': 'ikorodu',
    'ebute ikorodu': 'ikorodu',
    'egbin': 'ikorodu',
    'elepe': 'ikorodu',
    'erikorodo': 'ikorodu',
    'gberigbe': 'ikorodu',
    'ibeshe': 'ikorodu',
    'igbaga': 'ikorodu',
    'igbogbo': 'ikorodu',
    'igbopa': 'ikorodu',
    'ijede': 'ikorodu',
    'ijimu': 'ikorodu',
    'ikorodu': 'ikorodu',
    'imota': 'ikorodu',
    'ipakodo': 'ikorodu',
    'iponmi': 'ikorodu',
    'isele': 'ikorodu',
    'ishawo': 'ikorodu',
    'isiu': 'ikorodu',
    'itamaga': 'ikorodu',
    'itu elepe': 'ikorodu',
    'itu ojoru': 'ikorodu',
    'itusopu': 'ikorodu',
    'ituwaye': 'ikorodu',
    'majidun': 'ikorodu',
    'maya': 'ikorodu',
    'odo iyewa': 'ikorodu',
    'odogunyan': 'ikorodu',
    'ofin': 'ikorodu',
    'ogolonto': 'ikorodu',
    'oke-eletu': 'ikorodu',
    'olorunda': 'ikorodu',
    'oreta': 'ikorodu',
    'owutu': 'ikorodu',
    'parafa': 'ikorodu',
    'sabo ikorodu': 'ikorodu',

    // Badagry LGA
    'age mowo': 'badagry',
    'ajara': 'badagry',
    'ajara agamaden': 'badagry',
    'ajido': 'badagry',
    'apa': 'badagry',
    'aradagun': 'badagry',
    'awhanjigoh': 'badagry',
    'badagry': 'badagry',
    'ibereko': 'badagry',
    'ikoga': 'badagry',
    'ilogbo-araromi': 'badagry',
    'iworo': 'badagry',
    'iworo gbanko': 'badagry',
    'iya-afin': 'badagry',
    'keta east': 'badagry',
    'kweme': 'badagry',
    'magbon': 'badagry',
    'morogbo': 'badagry',
    'mowo': 'badagry',
    'oko afo': 'badagry',
    'pasi': 'badagry',
    'posukoh': 'badagry',
    'ropoji': 'badagry',
    'seme border': 'badagry',
    'topo': 'badagry',
    'yewa': 'badagry',

    // Epe LGA
    'abomiti': 'epe',
    'agbowa': 'epe',
    'agbowa ikosi': 'epe',
    'ago owu': 'epe',
    'ajaganabe': 'epe',
    'ebode': 'epe',
    'ejirin': 'epe',
    'epe': 'epe',
    'eredo': 'epe',
    'etita': 'epe',
    'ibonwon': 'epe',
    'idasho': 'epe',
    'igbogun': 'epe',
    'ilara': 'epe',
    'ise': 'epe',
    'itoikin': 'epe',
    'ladaba': 'epe',
    'lagbade': 'epe',
    'mojoda': 'epe',
    'noforija': 'epe',
    'odo-nagun': 'epe',
    'odomola': 'epe',
    'odoragunsin': 'epe',
    'oke-balogun': 'epe',
    'omu': 'epe',
    'oriba': 'epe',
    'orugbo': 'epe',
    'poka': 'epe',
    'popo-oba': 'epe',

    // Ibeju-Lekki LGA
    'abegede': 'ibeju_lekki',
    'abijo': 'ibeju_lekki',
    'aiyeteju': 'ibeju_lekki',
    'akodo': 'ibeju_lekki',
    'awoyaya': 'ibeju_lekki',
    'bogije': 'ibeju_lekki',
    'dangote refinery': 'ibeju_lekki',
    'ebute lekki': 'ibeju_lekki',
    'efiran': 'ibeju_lekki',
    'eleko': 'ibeju_lekki',
    'eluju': 'ibeju_lekki',
    'eputu': 'ibeju_lekki',
    'ibeju': 'ibeju_lekki',
    'ibeju-lekki': 'ibeju_lekki',
    'igando oloja': 'ibeju_lekki',
    'igbekodo': 'ibeju_lekki',
    'ilagbo': 'ibeju_lekki',
    'ilege': 'ibeju_lekki',
    'ilumofin': 'ibeju_lekki',
    'itagbo': 'ibeju_lekki',
    'iwerekun': 'ibeju_lekki',
    'lakowe': 'ibeju_lekki',
    'lekki free zone': 'ibeju_lekki',
    'magbon-alade': 'ibeju_lekki',
    'mobido': 'ibeju_lekki',
    'mopo onijebu': 'ibeju_lekki',
    'mosere ikoga': 'ibeju_lekki',
    'ogogoro': 'ibeju_lekki',
    'oke egun': 'ibeju_lekki',
    'okoyogun': 'ibeju_lekki',
    'okunegun': 'ibeju_lekki',
    'ololu': 'ibeju_lekki',
    'orimedu': 'ibeju_lekki',
    'otolu': 'ibeju_lekki',
    'siriwon': 'ibeju_lekki',
    'tiye': 'ibeju_lekki',

    // Lagos outskirts: Obafemi-Owode (Ogun)
    'arepo': 'obafemi_owode',
    'asese': 'obafemi_owode',
    'ibafo': 'obafemi_owode',
    'isheri north': 'obafemi_owode',
    'magboro': 'obafemi_owode',
    'mowe': 'obafemi_owode',
    'redemption camp': 'obafemi_owode',
    'warewa': 'obafemi_owode',

  };

  /// Spellings and old names that must keep resolving, mapped onto the area
  /// they mean. They are deliberately NOT offered in the pickers, so one
  /// place is one row, but a listing or saved preference that used the old
  /// spelling still finds its LGA.
  static const Map<String, String> _areaAliases = {
    'amuwo': 'amuwo odofin',
    'anthony': 'anthony village',
    'berger': 'ojodu berger',
    'ebute': 'ebute ikorodu',
    'ebute-metta': 'ebute metta',
    'festac town': 'festac',
    'gbogije': 'bogije',
    'gra ikeja': 'ikeja gra',
    'iba town': 'iba',
    'ibeju lekki': 'ibeju-lekki',
    'iberekodo': 'igbekodo',
    'ifako': 'ifako-ijaiye',
    'ikorodu town': 'ikorodu',
    'ilasa': 'ilasamaja',
    'isheri': 'isheri north',
    'isheri olowora': 'isheri-olowo-ira',
    'itokin': 'itoikin',
    'kollinton': 'kollington',
    'olodi apapa': 'olodi',
    'ologbowo': 'olowogbowo',
    'osapa london': 'osapa',
    'otto': 'oto',
    'sabo': 'sabo yaba',
    'somolu': 'shomolu',
    'vi': 'victoria island',
    'victoria garden city': 'vgc',
  };
  // GENERATED-AREAS-END

  // ══════════════════════════════════════════════
  //  THE LIVE LISTS (compiled defaults + config/areas)
  // ══════════════════════════════════════════════

  /// The live map: compiled defaults plus anything published remotely.
  static Map<String, String> _areaToLGA =
      Map<String, String>.from(_defaultAreaToLGA);

  /// LGAs published remotely, with the label and state each one carries.
  ///
  /// Without this, opening a new state meant an app release, which is why 39
  /// out-of-state cities were once filed under [otherLGA] and every one of them
  /// saved as "Lagos".
  static final Map<String, String> _remoteLgaLabels = {};
  static final Map<String, String> _remoteLgaState = {};

  /// Compiled LGAs plus the remote ones, in display order.
  static List<String> _liveLgas = List<String>.from(lgas);

  /// Lower-cased, punctuation-flattened index of every name that resolves to an
  /// area: the areas themselves and [_areaAliases]. Rebuilt whenever the live
  /// map changes.
  static Map<String, String>? _searchIndex;

  /// Merge LGAs published by an admin (`config/areas` → `lgas`), shaped
  /// `{ "<key>": { "label": ..., "state": ... } }`.
  ///
  /// An entry with no state is dropped: the state is what the listing saves,
  /// and a stateless LGA is exactly how Ogun and Abuja areas came out as Lagos.
  static void applyRemoteLGAs(Map<String, dynamic>? raw) {
    _remoteLgaLabels.clear();
    _remoteLgaState.clear();
    raw?.forEach((key, value) {
      final lga = key.trim().toLowerCase();
      if (lga.isEmpty || lga == outerLGA || lga == otherLGA) return;
      if (lgas.contains(lga)) return; // compiled ones win
      if (value is! Map) return;
      final label = (value['label'] ?? '').toString().trim();
      final state = (value['state'] ?? '').toString().trim();
      if (label.isEmpty || state.isEmpty) return;
      _remoteLgaLabels[lga] = label;
      _remoteLgaState[lga] = state;
    });
    _liveLgas = [...lgas, ..._remoteLgaLabels.keys];
    _searchIndex = null;
  }

  /// Merge areas published by an admin (`config/areas` → `areas`) over the
  /// compiled defaults, so a missing area becomes selectable without a Play
  /// Store release.
  ///
  /// Entries are ignored unless the LGA is one we know, compiled or remote: an
  /// area whose LGA we cannot resolve has no state and no group to sit in.
  /// Call [applyRemoteLGAs] first when the same document carries both.
  static void applyRemoteAreas(Map<String, dynamic>? raw) {
    final merged = Map<String, String>.from(_defaultAreaToLGA);
    if (raw != null) {
      final valid = {..._liveLgas, outerLGA, otherLGA};
      raw.forEach((area, lga) {
        if (lga is! String) return;
        final key = area.trim().toLowerCase();
        final value = lga.trim().toLowerCase();
        if (key.isEmpty || !valid.contains(value)) return;
        merged[key] = value;
      });
    }
    _areaToLGA = merged;
    _searchIndex = null;
  }

  // ══════════════════════════════════════════════
  //  LOOKUP METHODS
  // ══════════════════════════════════════════════

  /// Resolve an area name to its LGA. Null when we do not recognise the area.
  static String? getLGAForArea(String area) {
    final key = canonicalArea(area);
    return key == null ? null : _areaToLGA[key];
  }

  /// The area an arbitrary name means: itself, the area an old spelling stands
  /// for, or the longest area name contained in it as whole words.
  ///
  /// It used to take the first key that appeared anywhere inside the name, in
  /// map order, which read "Gbagada Phase 2" as Aga in Ikorodu, "Ebute-Metta"
  /// as Ebute in Ikorodu, and any address segment containing "Lagos" as Lagos
  /// Island. Whole words only, and the longest match wins, so "Isheri Olowora"
  /// can no longer collapse to "Isheri".
  static String? canonicalArea(String area) {
    final form = _matchForm(area);
    if (form.isEmpty) return null;

    final direct = _index[form];
    if (direct != null) return direct;

    for (final suffix in const [
      ' lga',
      ' lcda',
      ' local government',
      ' local government area',
      ' area',
    ]) {
      if (!form.endsWith(suffix)) continue;
      final trimmed = form.substring(0, form.length - suffix.length).trim();
      final hit = _index[trimmed];
      if (hit != null) return hit;
    }

    String? best;
    for (final candidate in _index.keys) {
      if (!_containsWholeWords(form, candidate)) continue;
      if (best == null || candidate.length > best.length) best = candidate;
    }
    return best == null ? null : _index[best];
  }

  /// The state an area is in, taken from its LGA. Null when the area is unknown
  /// or its LGA has no state, because the caller must then keep whatever the
  /// map pin resolved instead of assuming Lagos.
  static String? stateForArea(String area) {
    final lga = getLGAForArea(area);
    return lga == null ? null : stateForLGA(lga);
  }

  /// The state an LGA sits in. Null for [otherLGA] and for a remote LGA that
  /// arrived without one.
  static String? stateForLGA(String lga) {
    final state = _lgaState[lga] ?? _remoteLgaState[lga];
    return (state == null || state.isEmpty) ? null : state;
  }

  /// Old spellings of an area, so a picker search for "Somolu" still finds
  /// Shomolu even though only one of them is a row.
  static List<String> alternativeNames(String area) {
    final canonical = canonicalArea(area);
    if (canonical == null) return const [];
    return _areaAliases.entries
        .where((e) => e.value == canonical)
        .map((e) => e.key)
        .toList();
  }

  /// Whether a picker search for [query] should show [area]. Matches the area's
  /// own name or any name it used to go by.
  static bool areaMatchesQuery(String area, String query) {
    final wanted = _matchForm(query);
    if (wanted.isEmpty) return true;
    if (_matchForm(area).contains(wanted)) return true;
    return alternativeNames(area)
        .any((alt) => _matchForm(alt).contains(wanted));
  }

  static Map<String, String> get _index {
    final cached = _searchIndex;
    if (cached != null) return cached;
    final index = <String, String>{};
    for (final area in _areaToLGA.keys) {
      final form = _matchForm(area);
      if (form.isNotEmpty) index[form] = area;
    }
    // Aliases never overwrite a real area of the same name.
    _areaAliases.forEach((alias, target) {
      if (!_areaToLGA.containsKey(target)) return;
      final form = _matchForm(alias);
      if (form.isNotEmpty) index.putIfAbsent(form, () => target);
    });
    return _searchIndex = index;
  }

  /// Comparison form: diacritics stripped, everything but letters and digits
  /// flattened to single spaces, so "Ebute-Metta", "ebute metta" and
  /// "Ẹbùtẹ́ Mettá" are one key and hyphens stop hiding a match.
  static String _matchForm(String input) {
    return _stripDiacritics(input.trim().toLowerCase())
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  /// True when [needle] appears in [haystack] on word boundaries. Both are
  /// already in [_matchForm], so a boundary is a space or an end.
  static bool _containsWholeWords(String haystack, String needle) {
    if (needle.isEmpty) return false;
    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) return false;
      final endsAt = at + needle.length;
      final startOk = at == 0 || haystack[at - 1] == ' ';
      final endOk = endsAt == haystack.length || haystack[endsAt] == ' ';
      if (startOk && endOk) return true;
      from = at + 1;
    }
  }

  /// Backward-compatible alias for [getLGAForArea].
  /// Used by existing code that calls getClusterForArea.
  static String? getClusterForArea(String area) => getLGAForArea(area);

  /// Get human-readable label for an LGA, including remotely added ones.
  static String getLGALabel(String lga) {
    return _lgaLabels[lga] ?? _remoteLgaLabels[lga] ?? lga;
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

  /// Get all LGA names (for dropdowns, etc.), remotely added ones included.
  static List<String> get allLGAs => [..._liveLgas, outerLGA, otherLGA];

  /// The LGAs of one state, in display order. Drives the area pickers once a
  /// state has been chosen, so a landlord living in Lagos is not offered an
  /// Ogun area, and vice versa.
  static List<String> lgasForState(String state) {
    final wanted = state.trim().toLowerCase();
    return allLGAs
        .where((lga) => (stateForLGA(lga) ?? '').toLowerCase() == wanted)
        .toList();
  }

  /// States we carry areas for, in display order (Lagos first).
  static List<String> get statesWithAreas {
    final states = <String>[];
    for (final lga in allLGAs) {
      final state = stateForLGA(lga);
      if (state != null && !states.contains(state)) states.add(state);
    }
    return states;
  }

  /// Backward-compatible alias.
  static List<String> get allClusters => allLGAs;

  /// Get all recognized area names as Title Case, sorted alphabetically.
  static List<String> getAllAreas() {
    final areas = _areaToLGA.keys.toSet().toList();
    areas.sort();
    return areas.map((a) => _titleCase(a)).toList();
  }

  /// Get all areas grouped by LGA, with LGA labels as headers.
  ///
  /// Pass [state] to show only that state's LGAs.
  static List<Map<String, dynamic>> getAreasGroupedByLGA({String? state}) {
    final groups = <Map<String, dynamic>>[];
    for (final lga in state == null ? allLGAs : lgasForState(state)) {
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
  static List<Map<String, dynamic>> getAreasGroupedByCluster({String? state}) =>
      getAreasGroupedByLGA(state: state);

  /// Try to match a geocoded city name to a known area, returning the display
  /// name the pickers show. Handles diacritics (Ìkòròdú → Ikorodu), LGA
  /// suffixes and old spellings (Somolu → Shomolu).
  static String? findMatchingArea(String rawCityName) {
    final key = canonicalArea(rawCityName);
    return key == null ? null : _titleCase(key);
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
  /// [landlordLivesInProperty] flag no longer affects the fee - it is
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

  /// Display form of an area key. Capitalises after a hyphen or slash too, or
  /// the picker reads "Isale-eko" and "Oke-afa".
  static String _titleCase(String input) {
    if (input.isEmpty) return input;
    return input.split(' ').map((word) {
      if (word.isEmpty) return word;
      if ({'vi', 'vgc', 'gra', 'bq', 'lasu', 'cms'}.contains(word.toLowerCase())) {
        return word.toUpperCase();
      }
      final buffer = StringBuffer();
      var capitalise = true;
      for (final char in word.split('')) {
        buffer.write(capitalise ? char.toUpperCase() : char);
        capitalise = char == '-' || char == '/';
      }
      return buffer.toString();
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