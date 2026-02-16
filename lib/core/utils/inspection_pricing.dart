import 'dart:math' as math;

/// ClearRent Inspection Pricing Constants and Calculations
class InspectionPricing {
  // Rate constants
  static const double ratePerKm = 200.0; // Naira per km (one way)
  static const double minTransportFee = 2000.0;
  static const double agentServiceFee = 5000.0;
  static const double clearrentFee = 3000.0;
  static const double minTotalFee = 10000.0;

  /// Calculate distance between two coordinates using Haversine formula
  static double calculateDistance({
    required double lat1,
    required double lon1,
    required double lat2,
    required double lon2,
  }) {
    const double earthRadius = 6371; // km

    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadius * c;
  }

  static double _toRadians(double degree) {
    return degree * math.pi / 180;
  }

  /// Calculate inspection fee breakdown
  static InspectionFeeBreakdown calculateFee({
    required double distanceKm,
  }) {
    // Round trip transport fee
    double transportFee = distanceKm * ratePerKm * 2;
    
    // Apply minimum transport fee
    if (transportFee < minTransportFee) {
      transportFee = minTransportFee;
    }

    // Calculate total
    double total = transportFee + agentServiceFee + clearrentFee;

    // Apply minimum total fee
    if (total < minTotalFee) {
      // Adjust transport fee to meet minimum
      transportFee = minTotalFee - agentServiceFee - clearrentFee;
      total = minTotalFee;
    }

    return InspectionFeeBreakdown(
      distanceKm: distanceKm,
      transportFee: transportFee,
      agentServiceFee: agentServiceFee,
      clearrentFee: clearrentFee,
      totalFee: total,
      agentEarnings: transportFee + agentServiceFee,
    );
  }

  /// Calculate fee from coordinates
  static InspectionFeeBreakdown calculateFeeFromCoordinates({
    required double agentLat,
    required double agentLon,
    required double propertyLat,
    required double propertyLon,
  }) {
    final distance = calculateDistance(
      lat1: agentLat,
      lon1: agentLon,
      lat2: propertyLat,
      lon2: propertyLon,
    );

    return calculateFee(distanceKm: distance);
  }

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
  final double distanceKm;
  final double transportFee;
  final double agentServiceFee;
  final double clearrentFee;
  final double totalFee;
  final double agentEarnings;

  const InspectionFeeBreakdown({
    required this.distanceKm,
    required this.transportFee,
    required this.agentServiceFee,
    required this.clearrentFee,
    required this.totalFee,
    required this.agentEarnings,
  });

  Map<String, dynamic> toMap() {
    return {
      'distanceKm': distanceKm,
      'transportFee': transportFee,
      'agentServiceFee': agentServiceFee,
      'clearrentFee': clearrentFee,
      'totalFee': totalFee,
      'agentEarnings': agentEarnings,
    };
  }

  factory InspectionFeeBreakdown.fromMap(Map<String, dynamic> map) {
    return InspectionFeeBreakdown(
      distanceKm: (map['distanceKm'] ?? 0).toDouble(),
      transportFee: (map['transportFee'] ?? 0).toDouble(),
      agentServiceFee: (map['agentServiceFee'] ?? 5000).toDouble(),
      clearrentFee: (map['clearrentFee'] ?? 3000).toDouble(),
      totalFee: (map['totalFee'] ?? 0).toDouble(),
      agentEarnings: (map['agentEarnings'] ?? 0).toDouble(),
    );
  }

  @override
  String toString() {
    return '''
Inspection Fee Breakdown:
  Distance: ${distanceKm.toStringAsFixed(1)} km
  Transport: ${InspectionPricing.formatNaira(transportFee)}
  Agent Service: ${InspectionPricing.formatNaira(agentServiceFee)}
  ClearRent Fee: ${InspectionPricing.formatNaira(clearrentFee)}
  ─────────────────
  Total: ${InspectionPricing.formatNaira(totalFee)}
  
  Agent Earns: ${InspectionPricing.formatNaira(agentEarnings)}
  ClearRent Earns: ${InspectionPricing.formatNaira(clearrentFee)}
''';
  }
}