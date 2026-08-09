import 'dart:developer' as developer;
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../shared/models/condition_record.dart';

/// Reads and writes the condition of a property at each end of a tenancy.
///
/// This is the evidence layer under the caution deposit. ClearRent never holds
/// that money — it moves landlord-to-tenant off-platform — so the platform
/// cannot return it or compel it. What it can do is make sure the argument is
/// settled on a record neither side can edit after the fact.
class ConditionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> _parties(
    String rentalId,
    ConditionStage stage,
  ) =>
      _firestore
          .collection('active_rentals')
          .doc(rentalId)
          .collection('condition')
          .doc(stage.key)
          .collection('parties');

  /// Both parties' records for one end of a tenancy.
  Stream<List<ConditionRecord>> streamRecords(
    String rentalId,
    ConditionStage stage,
  ) {
    return _parties(rentalId, stage).snapshots().map((snap) => snap.docs
        .map((d) => ConditionRecord.fromFirestore(d.data(), d.id))
        .toList());
  }

  /// This user's own record, if they have made one.
  Future<ConditionRecord?> myRecord(
    String rentalId,
    ConditionStage stage,
  ) async {
    final uid = _uid;
    if (uid == null) return null;
    final snap = await _parties(rentalId, stage).doc(uid).get();
    if (!snap.exists) return null;
    return ConditionRecord.fromFirestore(snap.data()!, snap.id);
  }

  /// Uploads captured media and records it against the tenancy.
  ///
  /// Writes the document FIRST, marked pending, then uploads. That ordering is
  /// deliberate: a walkthrough video over a Nigerian mobile connection is the
  /// most likely thing here to fail, and if it does the record still exists
  /// saying an attempt was made and what it was for. Uploading first would
  /// leave a failed capture completely invisible.
  ///
  /// Returns true once the media is stored and the record sealed.
  Future<bool> submit({
    required String rentalId,
    required ConditionStage stage,
    required String partyRole,
    required List<File> videos,
    required List<File> images,
    String notes = '',
  }) async {
    final uid = _uid;
    if (uid == null) return false;
    if (videos.isEmpty && images.isEmpty) return false;

    final ref = _parties(rentalId, stage).doc(uid);
    try {
      await ref.set({
        'partyRole': partyRole,
        'notes': notes,
        'pending': true,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      developer.log('❌ Could not open condition record: $e',
          name: 'ConditionService');
      return false;
    }

    final videoPaths = <String>[];
    final imagePaths = <String>[];
    try {
      // Storage path must match the rule and what getConditionMediaUrl
      // validates: condition/{uid}/{rentalId}/{mediaId}.
      for (var i = 0; i < videos.length; i++) {
        final path = 'condition/$uid/$rentalId/'
            '${stage.key}_video_${DateTime.now().millisecondsSinceEpoch}_$i.mp4';
        await _storage.ref(path).putFile(videos[i]);
        videoPaths.add(path);
      }
      for (var i = 0; i < images.length; i++) {
        final path = 'condition/$uid/$rentalId/'
            '${stage.key}_image_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        await _storage.ref(path).putFile(images[i]);
        imagePaths.add(path);
      }
    } catch (e) {
      developer.log('❌ Condition media upload failed: $e',
          name: 'ConditionService');
      // Leaves the record pending and unsealed, so rules still allow a retry.
      return false;
    }

    try {
      // capturedAt seals the record — rules refuse further edits once it is
      // set, which is what stops evidence being swapped mid-argument.
      await ref.set({
        'videoPaths': videoPaths,
        'imagePaths': imagePaths,
        'pending': false,
        'capturedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      developer.log('❌ Could not seal condition record: $e',
          name: 'ConditionService');
      return false;
    }
  }

  /// A short-lived link to one stored recording.
  ///
  /// Storage rules only ever admit the uploader, because they cannot read
  /// Firestore to check who is party to a tenancy. The callable does that
  /// check server-side, which is the only way the counterparty sees anything.
  Future<String?> mediaUrl(String rentalId, String path) async {
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getConditionMediaUrl')
          .call<Map<String, dynamic>>({'rentalId': rentalId, 'path': path});
      return res.data['url'] as String?;
    } catch (e) {
      developer.log('❌ Could not sign condition media: $e',
          name: 'ConditionService');
      return null;
    }
  }
}
