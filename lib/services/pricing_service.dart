import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/utils/inspection_pricing.dart';

/// Platform fee schedule.
///
/// Read from Firestore `config/pricing` so prices can be changed from the
/// admin dashboard without a Play Store release, review, and user update.
///
/// The compiled-in values are a FALLBACK only, for first paint and for when
/// the document is unreachable. They must mirror DEFAULT_PRICING in
/// functions/src/pricing.ts.
///
/// Note this copy is DISPLAY-ONLY: the server derives the amount it actually
/// charges from the same document, so a tampered client cannot change a price.
/// What a role pays to verify, first time versus every year after.
///
/// Renewal is cheaper because it re-collects only the role proof, not identity
/// - the NIN is permanent and carried forward.
class RoleFee {
  final double initial;
  final double renewal;

  const RoleFee({required this.initial, required this.renewal});

  /// Accepts either shape from `config/pricing`.
  ///
  /// The document held a bare number per role before initial and renewal were
  /// distinguished. Reading that as BOTH prices keeps a stale document
  /// behaving exactly as it does today rather than silently repricing.
  factory RoleFee.fromValue(dynamic value, RoleFee fallback) {
    if (value is num) {
      return RoleFee(
          initial: value.toDouble(), renewal: value.toDouble());
    }
    if (value is Map) {
      return RoleFee(
        initial: PlatformPricing._asDouble(value['initial'], fallback.initial),
        renewal: PlatformPricing._asDouble(value['renewal'], fallback.renewal),
      );
    }
    return fallback;
  }
}

class PlatformPricing {
  final RoleFee tenantVerification;
  final RoleFee landlordVerification;
  final RoleFee agentVerification;
  final double listing;
  final double inspectionTotal;
  final double inspectionHandler;
  final double inspectionPlatform;

  /// Deal-completion fee charged per party on a completed rental. Also the
  /// tenant's share added on top of rent at payment time.
  final double dealFee;

  /// The landlord's (and agent's) service fee by rent band, lowest first; the
  /// last band has no ceiling. Mirrors serviceFeeBands in pricing.ts, which is
  /// what is actually charged.
  final List<FeeBand> serviceFeeBands;

  /// Charged to the tenant on each furnished-stay extension, on top of the
  /// rent for the added months (all of which goes to the landlord).
  final double extensionFee;

  /// Lowest rent a property may be listed at. Below it the deal fee consumes
  /// the whole rent and the landlord nets nothing, so the listing can never
  /// pay anyone. Enforced server-side in firestore.rules; mirrored here only
  /// so the add-property form can say so before the write is refused.
  final double minRent;

  const PlatformPricing({
    required this.tenantVerification,
    required this.landlordVerification,
    required this.agentVerification,
    required this.listing,
    required this.inspectionTotal,
    required this.inspectionHandler,
    required this.inspectionPlatform,
    required this.dealFee,
    this.serviceFeeBands = FeeBand.defaults,
    required this.extensionFee,
    required this.minRent,
  });

  /// Mirrors DEFAULT_PRICING in functions/src/pricing.ts.
  static const PlatformPricing fallback = PlatformPricing(
    tenantVerification: RoleFee(initial: 5000, renewal: 3000),
    landlordVerification: RoleFee(initial: 15000, renewal: 12000),
    agentVerification: RoleFee(initial: 10000, renewal: 7000),
    listing: 10000,
    inspectionTotal: 10000,
    inspectionHandler: 7000,
    inspectionPlatform: 3000,
    dealFee: 5000,
    extensionFee: 2500,
    minRent: 10000,
  );

  /// The landlord's service fee for a deal of this rent (a furnished stay's
  /// whole stay), taken out of the rent.
  double landlordServiceFee(double rent) {
    for (final b in serviceFeeBands) {
      if (b.upTo == null || rent <= b.upTo!) return b.landlord;
    }
    return serviceFeeBands.isEmpty ? 0 : serviceFeeBands.last.landlord;
  }

  /// The fee to show for [accountType].
  ///
  /// [isRenewal] must be derived the same way the server derives it - from
  /// whether the user has EVER been verified (`verifiedAt`) - or the price on
  /// screen will not be the price charged. The server is authoritative either
  /// way; this only decides what the user is told.
  double verificationFee(String accountType, {bool isRenewal = false}) {
    final fee = switch (accountType) {
      'landlord' => landlordVerification,
      'tenant' => tenantVerification,
      'agent' => agentVerification,
      _ => null,
    };
    if (fee == null) return 0;
    return isRenewal ? fee.renewal : fee.initial;
  }

  static double _asDouble(dynamic value, double fallbackValue) =>
      value is num ? value.toDouble() : fallbackValue;

  factory PlatformPricing.fromMap(Map<String, dynamic>? map) {
    if (map == null) return fallback;
    final v = (map['verification'] as Map<String, dynamic>?) ?? const {};
    final i = (map['inspection'] as Map<String, dynamic>?) ?? const {};
    return PlatformPricing(
      tenantVerification:
          RoleFee.fromValue(v['tenant'], fallback.tenantVerification),
      landlordVerification:
          RoleFee.fromValue(v['landlord'], fallback.landlordVerification),
      agentVerification:
          RoleFee.fromValue(v['agent'], fallback.agentVerification),
      listing: _asDouble(map['listing'], fallback.listing),
      inspectionTotal: _asDouble(i['total'], fallback.inspectionTotal),
      inspectionHandler: _asDouble(i['handler'], fallback.inspectionHandler),
      inspectionPlatform:
          _asDouble(i['platform'], fallback.inspectionPlatform),
      dealFee: _asDouble(map['dealFee'], fallback.dealFee),
      serviceFeeBands: FeeBand.listFrom(map['serviceFeeBands']),
      extensionFee: _asDouble(map['extensionFee'], fallback.extensionFee),
      minRent: _asDouble(map['minRent'], fallback.minRent),
    );
  }

  /// '₦3,000' - thousands-separated, no decimals.
  static String formatNaira(double amount) {
    final digits = amount.toStringAsFixed(0);
    final chars = digits.split('').reversed.toList();
    final out = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) out.add(',');
      out.add(chars[i]);
    }
    return '₦${out.reversed.join()}';
  }
}

/// Loads and caches the platform fee schedule. Singleton so a screen opening
/// twice doesn't re-hit Firestore for a value that changes a few times a year.
class PricingService {
  static final PricingService _instance = PricingService._();
  factory PricingService() => _instance;
  PricingService._();

  PlatformPricing _cached = PlatformPricing.fallback;

  /// Live `config/areas` subscription. Singleton service, so one listener for
  /// the life of the app - never cancelled, because the area list has to stay
  /// current wherever the landlord is in the flow.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _areasSub;

  /// Last loaded schedule; the fallback until [load] completes.
  PlatformPricing get current => _cached;

  Future<PlatformPricing> load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('config')
          .doc('pricing')
          .get();
      if (doc.exists) _cached = PlatformPricing.fromMap(doc.data());
    } catch (e) {
      // Never block a fee display on config being reachable.
      developer.log('Pricing unreadable - using fallback: $e',
          name: 'PricingService');
    }
    // Push the inspection numbers into InspectionPricing, whose static helpers
    // are called from several screens that have no access to this service.
    InspectionPricing.applyRemote(
      total: _cached.inspectionTotal,
      handler: _cached.inspectionHandler,
      platform: _cached.inspectionPlatform,
    );
    await _loadAreas();
    return _cached;
  }

  /// Areas an admin has added since the last release (`config/areas`). Merged
  /// over the compiled list, so an unmapped Lagos area becomes selectable
  /// without shipping a build. Failure is silent - the compiled list stands.
  ///
  /// Awaited once so the first paint has them, then [_watchAreas] keeps them
  /// current for the rest of the session.
  Future<void> _loadAreas() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('config')
          .doc('areas')
          .get();
      _apply(doc.data());
    } catch (e) {
      developer.log('Remote areas unreadable - using compiled list: $e',
          name: 'PricingService');
    }
    _watchAreas();
  }

  /// Live subscription, so an area published while a landlord is part-way
  /// through listing reaches them without restarting the app. They see it the
  /// next time the area picker is opened - the sheet reads the list on open.
  void _watchAreas() {
    _areasSub ??= FirebaseFirestore.instance
        .collection('config')
        .doc('areas')
        .snapshots()
        .listen(
      (doc) => _apply(doc.data()),
      onError: (Object e) => developer.log(
        'Remote areas stream failed - keeping last known list: $e',
        name: 'PricingService',
      ),
    );
  }

  void _apply(Map<String, dynamic>? data) {
    // LGAs first: a published area is dropped unless its LGA is already known,
    // and a new LGA is how a new state opens without a release.
    final lgas = data?['lgas'];
    InspectionPricing.applyRemoteLGAs(
      lgas is Map ? Map<String, dynamic>.from(lgas) : null,
    );
    final areas = data?['areas'];
    if (areas is! Map) return;
    InspectionPricing.applyRemoteAreas(Map<String, dynamic>.from(areas));
    developer.log(
      'Remote areas applied: ${areas.length} published'
      '${lgas is Map ? ', ${lgas.length} extra LGA(s)' : ''}',
      name: 'PricingService',
    );
  }
}

/// One rent band of the landlord's and agent's service fee.
class FeeBand {
  final double? upTo;
  final double landlord;
  final double agent;
  const FeeBand({required this.upTo, required this.landlord, required this.agent});

  /// Mirrors DEFAULT_PRICING.serviceFeeBands in functions/src/pricing.ts.
  static const defaults = [
    FeeBand(upTo: 300000, landlord: 7500, agent: 3750),
    FeeBand(upTo: 700000, landlord: 15000, agent: 7500),
    FeeBand(upTo: 1500000, landlord: 30000, agent: 15000),
    FeeBand(upTo: 3000000, landlord: 50000, agent: 25000),
    FeeBand(upTo: null, landlord: 75000, agent: 37500),
  ];

  /// The configured bands, or the defaults if any entry is malformed (the
  /// server falls back the same way).
  static List<FeeBand> listFrom(dynamic raw) {
    if (raw is! List || raw.isEmpty) return defaults;
    final out = <FeeBand>[];
    for (final b in raw) {
      if (b is! Map || b['landlord'] is! num || b['agent'] is! num) return defaults;
      final upTo = b['upTo'];
      if (upTo != null && upTo is! num) return defaults;
      out.add(FeeBand(
        upTo: (upTo as num?)?.toDouble(),
        landlord: (b['landlord'] as num).toDouble(),
        agent: (b['agent'] as num).toDouble(),
      ));
    }
    out.sort((x, y) => (x.upTo ?? double.infinity).compareTo(y.upTo ?? double.infinity));
    return out.last.upTo == null ? out : defaults;
  }
}
