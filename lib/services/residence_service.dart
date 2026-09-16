import 'dart:developer' as developer;
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

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
  /// The home building and its proof only survive while the landlord still
  /// lives in a property they own AND the home is unchanged; anything else
  /// clears them, so an accepted bill can never follow the claim to another
  /// building (firestore.rules refuses that too).
  Future<String?> save(LandlordResidence residence) async {
    final uid = _uid;
    if (uid == null) return 'You must be signed in.';
    if (!residence.isComplete) return 'Please finish telling us where you live.';
    try {
      final current = LandlordResidence.fromMap((await _doc(uid).get()).data());
      final keepHome = residence.canMarkHome &&
          residence.homeBuildingId != null &&
          residence.homeBuildingId == current?.homeBuildingId;
      final r = LandlordResidence(
        kind: residence.kind,
        state: residence.state,
        area: residence.area,
        country: residence.country,
        homeBuildingId: keepHome ? residence.homeBuildingId : null,
        homeBuildingName: keepHome ? residence.homeBuildingName : null,
        homeProofPath: keepHome ? current?.homeProofPath : null,
        homeProofStatus: keepHome ? current?.homeProofStatus : null,
        homeProofRejectionReason:
            keepHome ? current?.homeProofRejectionReason : null,
      );
      return _write(uid, r);
    } catch (e) {
      developer.log('❌ Residence save failed: $e', name: 'ResidenceService');
      return 'Could not save where you live. Please try again.';
    }
  }

  /// Uploads a utility bill for the home building. Returns its Storage path,
  /// under the verification folder admins already read documents from.
  Future<String?> uploadHomeProof(File file) async {
    final uid = _uid;
    if (uid == null) return null;
    final name = file.path.split(Platform.pathSeparator).last;
    // Extension off the file NAME only, letters and digits, so no slash can
    // reach the object name (see storage-403 notes).
    final ext = name.contains('.')
        ? name.split('.').last.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        : 'jpg';
    final path = 'verification/$uid/home_proof/'
        '${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
    await FirebaseStorage.instance.ref(path).putFile(file);
    return path;
  }

  /// "I live here": makes [buildingId] the one home, moving it off any other,
  /// with [proofPath] waiting for an admin. Tenants keep seeing "elsewhere"
  /// until it is accepted.
  Future<String?> markHome(
    String buildingId,
    String buildingName,
    String proofPath,
  ) async {
    final uid = _uid;
    if (uid == null) return 'You must be signed in.';
    final current = await get();
    if (current == null || !current.canMarkHome) {
      return 'First tell us in your profile that you live in a property you own.';
    }
    try {
      return _write(
        uid,
        LandlordResidence(
          kind: current.kind,
          state: current.state,
          area: current.area,
          homeBuildingId: buildingId,
          homeBuildingName: buildingName,
          homeProofPath: proofPath,
          homeProofStatus: LandlordResidence.proofPending,
        ),
      );
    } catch (e) {
      developer.log('❌ Mark home failed: $e', name: 'ResidenceService');
      return 'Could not save that. Please try again.';
    }
  }

  /// "I don't live here any more": clears the home building and its proof.
  Future<String?> clearHome() async {
    final uid = _uid;
    if (uid == null) return 'You must be signed in.';
    final current = await get();
    if (current == null) return null;
    try {
      return _write(
        uid,
        LandlordResidence(
          kind: current.kind,
          state: current.state,
          area: current.area,
          country: current.country,
        ),
      );
    } catch (e) {
      developer.log('❌ Clear home failed: $e', name: 'ResidenceService');
      return 'Could not save that. Please try again.';
    }
  }

  Future<String?> _write(String uid, LandlordResidence r) async {
    await _doc(uid).set({
      ...r.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await _syncListings(uid, r);
    return null;
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
