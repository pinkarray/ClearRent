/// Where a landlord lives: ONE fact about the landlord, answered in their
/// profile, not a question on every listing.
///
/// Asked per listing, a landlord could say "I live here" on ten properties, or
/// Ikeja on one and Lekki on the next, and nothing tied the answers together.
/// It also fed two different flags: `landlordLivesInProperty` (inspection
/// behaviour) and `landlordLivesOnPremises` (what tenants are shown), and the
/// app only ever set the first, so tenants were told "No" on every listing it
/// created.
///
/// [own] landlords may then mark ONE building they list as home with
/// "I live here"; marking another moves it. Stored privately at
/// `users/{uid}/private/residence`, because user docs are readable by any
/// signed-in account. Listings carry only the coarse tenant line.
class LandlordResidence {
  /// [own], [rent] or [abroad].
  final String kind;

  /// Nigerian state, for [own] and [rent].
  final String? state;

  /// Area inside Lagos, when [state] is Lagos.
  final String? area;

  /// Country, for [abroad].
  final String? country;

  /// The listed building marked "I live here". Only ever set for [own].
  final String? homeBuildingId;
  final String? homeBuildingName;

  const LandlordResidence({
    required this.kind,
    this.state,
    this.area,
    this.country,
    this.homeBuildingId,
    this.homeBuildingName,
  });

  static const own = 'own';
  static const rent = 'rent';
  static const abroad = 'abroad';

  bool get isAbroad => kind == abroad;

  /// Only a landlord who lives in a property they own can live in one they list.
  bool get canMarkHome => kind == own;

  bool get isComplete => switch (kind) {
        own || rent => (state ?? '').isNotEmpty,
        abroad => (country ?? '').trim().isNotEmpty,
        _ => false,
      };

  /// Does the landlord live on the premises of a listing in [buildingId]?
  /// A whole property (no building) never counts: one tenant gets all of it.
  bool livesAt(String? buildingId) =>
      kind == own &&
      (buildingId ?? '').isNotEmpty &&
      buildingId == homeBuildingId;

  /// The landlord's own summary, e.g. "In a place I rent, Lagos (Allen)".
  String get summary {
    final place = (area ?? '').isNotEmpty ? '$state ($area)' : (state ?? '');
    return switch (kind) {
      own => 'In a property I own, $place',
      rent => 'In a place I rent, $place',
      abroad => 'Outside Nigeria (${country ?? ''})',
      _ => '',
    };
  }

  /// The fields a listing in [buildingId] carries. The two legacy flags are
  /// derived here so they can never disagree again.
  Map<String, dynamic> listingFields(String? buildingId) {
    final onPremises = livesAt(buildingId);
    return {
      'landlordResidence': onPremises
          ? ListingResidence.onPremises
          : (isAbroad ? ListingResidence.abroad : ListingResidence.elsewhere),
      // Coarse on purpose: a state, never an area or a building.
      'landlordResidenceRegion': isAbroad || onPremises ? null : state,
      'landlordLivesInProperty': onPremises,
      'landlordLivesOnPremises': onPremises,
    };
  }

  Map<String, dynamic> toMap() => {
        'kind': kind,
        'state': state,
        'area': area,
        'country': country,
        'homeBuildingId': homeBuildingId,
        'homeBuildingName': homeBuildingName,
      };

  static LandlordResidence? fromMap(Map<String, dynamic>? m) {
    if (m == null || m['kind'] == null) return null;
    return LandlordResidence(
      kind: m['kind'] as String,
      state: m['state'] as String?,
      area: m['area'] as String?,
      country: m['country'] as String?,
      homeBuildingId: m['homeBuildingId'] as String?,
      homeBuildingName: m['homeBuildingName'] as String?,
    );
  }
}

/// The tenant-facing value on a listing (`landlordResidence`).
class ListingResidence {
  static const onPremises = 'on_premises';
  static const elsewhere = 'elsewhere';
  static const abroad = 'abroad';

  /// The short form for a labelled row ("Landlord: Lives elsewhere (Lagos)").
  static String? shortLine(String? value, String? region) => switch (value) {
        onPremises => 'Lives on the premises',
        elsewhere => (region ?? '').isNotEmpty
            ? 'Lives elsewhere ($region)'
            : 'Lives elsewhere',
        abroad => 'Lives outside Nigeria',
        _ => null,
      };
}

/// Nigeria's 36 states and the FCT.
const nigerianStates = [
  'Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa', 'Benue',
  'Borno', 'Cross River', 'Delta', 'Ebonyi', 'Edo', 'Ekiti', 'Enugu',
  'FCT (Abuja)', 'Gombe', 'Imo', 'Jigawa', 'Kaduna', 'Kano', 'Katsina', 'Kebbi',
  'Kogi', 'Kwara', 'Lagos', 'Nasarawa', 'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo',
  'Plateau', 'Rivers', 'Sokoto', 'Taraba', 'Yobe', 'Zamfara',
];
