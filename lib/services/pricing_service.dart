import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';

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
class PlatformPricing {
  final double tenantVerification;
  final double landlordVerification;
  final double agentVerification;
  final double listing;
  final double inspectionTotal;
  final double inspectionHandler;
  final double inspectionPlatform;

  const PlatformPricing({
    required this.tenantVerification,
    required this.landlordVerification,
    required this.agentVerification,
    required this.listing,
    required this.inspectionTotal,
    required this.inspectionHandler,
    required this.inspectionPlatform,
  });

  /// Mirrors DEFAULT_PRICING in functions/src/pricing.ts.
  static const PlatformPricing fallback = PlatformPricing(
    tenantVerification: 3000,
    landlordVerification: 12000,
    agentVerification: 7000,
    listing: 10000,
    inspectionTotal: 10000,
    inspectionHandler: 7000,
    inspectionPlatform: 3000,
  );

  double verificationFee(String accountType) {
    switch (accountType) {
      case 'landlord':
        return landlordVerification;
      case 'tenant':
        return tenantVerification;
      case 'agent':
        return agentVerification;
      default:
        return 0;
    }
  }

  static double _asDouble(dynamic value, double fallbackValue) =>
      value is num ? value.toDouble() : fallbackValue;

  factory PlatformPricing.fromMap(Map<String, dynamic>? map) {
    if (map == null) return fallback;
    final v = (map['verification'] as Map<String, dynamic>?) ?? const {};
    final i = (map['inspection'] as Map<String, dynamic>?) ?? const {};
    return PlatformPricing(
      tenantVerification: _asDouble(v['tenant'], fallback.tenantVerification),
      landlordVerification:
          _asDouble(v['landlord'], fallback.landlordVerification),
      agentVerification: _asDouble(v['agent'], fallback.agentVerification),
      listing: _asDouble(map['listing'], fallback.listing),
      inspectionTotal: _asDouble(i['total'], fallback.inspectionTotal),
      inspectionHandler: _asDouble(i['handler'], fallback.inspectionHandler),
      inspectionPlatform:
          _asDouble(i['platform'], fallback.inspectionPlatform),
    );
  }

  /// '₦3,000' — thousands-separated, no decimals.
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
      developer.log('Pricing unreadable — using fallback: $e',
          name: 'PricingService');
    }
    return _cached;
  }
}
