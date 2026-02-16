import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;

/// ============================================================
/// TEMPORARY FIX: Update ₦0 rental interests & active rentals
/// ============================================================
///
/// HOW TO USE:
///   Call fixZeroRentAmounts() once from any screen (e.g. admin screen,
///   or a temporary button on your profile). After running, remove it.
///
///   Example: Add a temporary button somewhere:
///     ElevatedButton(
///       onPressed: () async {
///         await fixZeroRentAmounts();
///         ScaffoldMessenger.of(context).showSnackBar(
///           SnackBar(content: Text('Fix complete! Check logs.')),
///         );
///       },
///       child: Text('Fix ₦0 Amounts'),
///     )
///
/// WHAT IT DOES:
///   1. Finds all rental_interests with paymentAmount == 0
///   2. Looks up the actual property rent + agentFee
///   3. Updates the rental interest with correct amount
///   4. Finds all active_rentals with rentAmount == 0
///   5. Updates those too with correct rent from the property
///
/// SAFE: Only updates documents where amount is 0. Doesn't touch
/// records that already have correct amounts.

Future<void> fixZeroRentAmounts() async {
  final firestore = FirebaseFirestore.instance;
  int fixedInterests = 0;
  int fixedRentals = 0;

  developer.log('🔧 Starting ₦0 rent amount fix...', name: 'FixZeroRent');

  // ── Fix rental_interests with paymentAmount == 0 ──
  try {
    final interestsSnapshot = await firestore
        .collection('rental_interests')
        .where('paymentAmount', isEqualTo: 0)
        .get();

    developer.log(
        '📋 Found ${interestsSnapshot.docs.length} rental interests with ₦0',
        name: 'FixZeroRent');

    for (final doc in interestsSnapshot.docs) {
      final data = doc.data();
      final propertyId = data['propertyId'] as String?;
      if (propertyId == null || propertyId.isEmpty) continue;

      // Look up the property's actual rent
      final propertyDoc =
          await firestore.collection('properties').doc(propertyId).get();
      if (!propertyDoc.exists) {
        developer.log('⚠️ Property $propertyId not found, skipping interest ${doc.id}',
            name: 'FixZeroRent');
        continue;
      }

      final propertyData = propertyDoc.data()!;
      final rent = (propertyData['rent'] ?? 0).toDouble();
      final agentFee = (propertyData['agentFee'] ?? 0).toDouble();
      final totalAmount = rent + agentFee;

      if (totalAmount <= 0) {
        developer.log(
            '⚠️ Property $propertyId also has ₦0 rent, skipping',
            name: 'FixZeroRent');
        continue;
      }

      await doc.reference.update({
        'paymentAmount': totalAmount,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      fixedInterests++;
      developer.log(
          '✅ Fixed interest ${doc.id}: ₦0 → ₦${totalAmount.toStringAsFixed(0)} '
          '(rent: ₦${rent.toStringAsFixed(0)}, agentFee: ₦${agentFee.toStringAsFixed(0)})',
          name: 'FixZeroRent');
    }
  } catch (e) {
    developer.log('❌ Error fixing rental interests: $e', name: 'FixZeroRent');
  }

  // ── Fix active_rentals with rentAmount == 0 ──
  try {
    final rentalsSnapshot = await firestore
        .collection('active_rentals')
        .where('rentAmount', isEqualTo: 0)
        .get();

    developer.log(
        '📋 Found ${rentalsSnapshot.docs.length} active rentals with ₦0',
        name: 'FixZeroRent');

    for (final doc in rentalsSnapshot.docs) {
      final data = doc.data();
      final propertyId = data['propertyId'] as String?;
      if (propertyId == null || propertyId.isEmpty) continue;

      final propertyDoc =
          await firestore.collection('properties').doc(propertyId).get();
      if (!propertyDoc.exists) {
        developer.log('⚠️ Property $propertyId not found, skipping rental ${doc.id}',
            name: 'FixZeroRent');
        continue;
      }

      final propertyData = propertyDoc.data()!;
      final rent = (propertyData['rent'] ?? 0).toDouble();
      final agentFee = (propertyData['agentFee'] ?? 0).toDouble();
      final totalPaid = rent + agentFee;
      final rentFrequency = propertyData['rentFrequency'] ?? 'yearly';

      await doc.reference.update({
        'rentAmount': rent,
        'agentFee': agentFee,
        'totalPaid': totalPaid,
        'rentFrequency': rentFrequency,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      fixedRentals++;
      developer.log(
          '✅ Fixed rental ${doc.id}: ₦0 → ₦${rent.toStringAsFixed(0)}/$rentFrequency',
          name: 'FixZeroRent');
    }
  } catch (e) {
    developer.log('❌ Error fixing active rentals: $e', name: 'FixZeroRent');
  }

  developer.log(
      '🔧 Fix complete! Fixed $fixedInterests interests + $fixedRentals rentals',
      name: 'FixZeroRent');
}