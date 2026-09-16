import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../shared/models/landlord_residence.dart';

/// Reads and writes the landlord's single residence record, and keeps every
/// listing they own in step with it.
///
/// The mutating methods return `null` on success and the message to show on
/// failure, like [CaretakerService].
class ResidenceService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> _doc(String uid) => _firestore
      .collection('users')
      .doc(uid)
      .collection('private')
      .doc('residence');

  Stream<LandlordResidence?> watch() {
    final uid = _uid;
    if (uid == null) return Stream.value(null);
    return _doc(uid).snapshots().map((s) => LandlordResidence.fromMap(s.data()));
  }

  Future<LandlordResidence?> get() async {
    final uid = _uid;
    if (uid == null) return null;
    final snap = await _doc(uid).get();
    return LandlordResidence.fromMap(snap.data());
  }

  /// Saves [residence] and rewrites the residence fields on every listing.
  ///
  /// A home building only survives while the landlord still says they live in
  /// a property they own; switching to renting or abroad clears it.
  Future<String?> save(LandlordResidence residence) async {
    final uid = _uid;
    if (uid == null) return 'You must be signed in.';
    if (!residence.isComplete) return 'Please finish telling us where you live.';
    final r = residence.canMarkHome
        ? residence
        : LandlordResidence(
            kind: residence.kind,
            state: residence.state,
            area: residence.area,
            country: residence.country,
          );
    try {
      await _doc(uid).set({
        ...r.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _syncListings(uid, r);
      return null;
    } catch (e) {
      developer.log('❌ Residence save failed: $e', name: 'ResidenceService');
      return 'Could not save where you live. Please try again.';
    }
  }

  /// "I live here": makes [buildingId] the one home, moving it off any other.
  Future<String?> markHome(String buildingId, String buildingName) async {
    final current = await get();
    if (current == null || !current.canMarkHome) {
      return 'First tell us in your profile that you live in a property you own.';
    }
    return save(LandlordResidence(
      kind: current.kind,
      state: current.state,
      area: current.area,
      homeBuildingId: buildingId,
      homeBuildingName: buildingName,
    ));
  }

  /// "I don't live here any more": clears the home building.
  Future<String?> clearHome() async {
    final current = await get();
    if (current == null) return null;
    return save(LandlordResidence(
      kind: current.kind,
      state: current.state,
      area: current.area,
      country: current.country,
    ));
  }

  /// Rewrites the tenant-facing residence fields on every listing, and takes
  /// self-handled listings out of "ready" for a landlord abroad: nobody would
  /// be there to open the door, and firestore.rules refuses to mark them ready
  /// again until an agent or caretaker handles them.
  Future<void> _syncListings(String uid, LandlordResidence r) async {
    final snap = await _firestore
        .collection('properties')
        .where('landlordId', isEqualTo: uid)
        .get();
    for (var i = 0; i < snap.docs.length; i += 400) {
      final batch = _firestore.batch();
      for (final d in snap.docs.skip(i).take(400)) {
        final data = d.data();
        final selfHandled = (data['inspectionHandler'] ?? 'self') == 'self';
        batch.update(d.reference, {
          ...r.listingFields(data['buildingId'] as String?),
          if (r.isAbroad && selfHandled && data['readyForInspections'] == true)
            'readyForInspections': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }
  }
}
