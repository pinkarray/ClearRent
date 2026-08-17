import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../shared/models/property_model.dart';

/// The caretaker side of a property: who manages it, and the invitation that
/// put them there.
///
/// Every state change runs through a Cloud Function. `properties.caretakerId`
/// is admin-SDK-only by design — the owner-update rule in firestore.rules lets
/// the landlord CLEAR it (revoking is theirs) and never set it, so a client
/// cannot appoint a caretaker without the invitee agreeing.
///
/// The callables' error messages are written for the end user, so the mutating
/// methods return `null` on success and the message to show on failure —
/// mirroring [PropertyService.agentUnassignFromProperty].
class CaretakerService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'us-central1');

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// Properties this user manages as caretaker.
  ///
  /// `properties` is readable by any signed-in user, so this needs no rules
  /// change — but it must still be scoped by caretakerId, which is also the
  /// field the caller's rule branch reads elsewhere.
  Stream<List<PropertyModel>> managedProperties() {
    final uid = _uid;
    if (uid == null) return Stream.value(const []);
    return _firestore
        .collection('properties')
        .where('caretakerId', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs
            .map((d) => PropertyModel.fromFirestore(d.data(), d.id))
            .toList());
  }

  /// Every invitation naming this user, in any state.
  ///
  /// One stream rather than a pending-only one: the screen needs the PENDING
  /// ones to answer and the ACCEPTED ones to map a managed property back to the
  /// invite that granted it, which is what stepping back has to revoke.
  /// Filtering client-side keeps that to a single listener.
  Stream<List<CaretakerInvite>> myInvites() {
    final uid = _uid;
    if (uid == null) return Stream.value(const []);
    return _firestore
        .collection('caretaker_invites')
        .where('caretakerId', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs.map(CaretakerInvite.fromDoc).toList());
  }

  /// The caretaker arrangements a landlord has going, in any state. Drives the
  /// "Caretaker" section of edit-property and the revoke action.
  Stream<List<CaretakerInvite>> invitesForLandlord() {
    final uid = _uid;
    if (uid == null) return Stream.value(const []);
    return _firestore
        .collection('caretaker_invites')
        .where('landlordId', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs.map(CaretakerInvite.fromDoc).toList());
  }

  /// Who does this number belong to? Called before [invite] so the landlord
  /// confirms a name rather than trusting the digits they typed — a single
  /// wrong digit would otherwise invite a real stranger, who could accept.
  ///
  /// Returns the candidate's name, or throws with a message to show.
  Future<String> lookupCandidate({
    required String phone,
    required List<String> propertyIds,
  }) async {
    try {
      final result = await _functions
          .httpsCallable('lookupCaretakerCandidate')
          .call<Map<String, dynamic>>({
        'phone': phone,
        'propertyIds': propertyIds,
      });
      return result.data['caretakerName'] as String? ?? 'this person';
    } on FirebaseFunctionsException catch (e) {
      throw CaretakerLookupException(
        e.message ?? 'Could not find that number. Check it and try again.',
      );
    } catch (e) {
      developer.log('❌ lookupCaretakerCandidate failed: $e',
          name: 'CaretakerService');
      throw const CaretakerLookupException(
        'Could not check that number. Please try again.',
      );
    }
  }

  /// Invite an existing ClearRent user, by phone, to manage [propertyIds].
  ///
  /// One invite covers many units so a building assignment is a single act on
  /// both sides — and so revoking it later has one document to close rather
  /// than a unit's worth of orphans.
  Future<String?> invite({
    required String phone,
    required List<String> propertyIds,
    String? buildingId,
  }) async {
    try {
      await _functions.httpsCallable('inviteCaretaker').call<Map<String, dynamic>>({
        'phone': phone,
        'propertyIds': propertyIds,
        if (buildingId != null) 'buildingId': buildingId,
      });
      return null;
    } on FirebaseFunctionsException catch (e) {
      return e.message ?? 'Could not send that invite. Please try again.';
    } catch (e) {
      developer.log('❌ inviteCaretaker failed: $e', name: 'CaretakerService');
      return 'Could not send that invite. Please try again.';
    }
  }

  /// Accept or decline an invitation. [accept] false declines it.
  Future<String?> respond({required String inviteId, required bool accept}) async {
    try {
      await _functions
          .httpsCallable('respondToCaretakerInvite')
          .call<Map<String, dynamic>>({
        'inviteId': inviteId,
        'action': accept ? 'accept' : 'decline',
      });
      return null;
    } on FirebaseFunctionsException catch (e) {
      return e.message ?? 'Could not record your answer. Please try again.';
    } catch (e) {
      developer.log('❌ respondToCaretakerInvite failed: $e',
          name: 'CaretakerService');
      return 'Could not record your answer. Please try again.';
    }
  }

  /// End a caretaker arrangement. Either party may call it: the landlord
  /// removes the caretaker, or the caretaker steps back.
  Future<String?> revoke({required String inviteId, String? reason}) async {
    try {
      await _functions.httpsCallable('revokeCaretaker').call<Map<String, dynamic>>({
        'inviteId': inviteId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
      return null;
    } on FirebaseFunctionsException catch (e) {
      return e.message ?? 'Could not remove the caretaker. Please try again.';
    } catch (e) {
      developer.log('❌ revokeCaretaker failed: $e', name: 'CaretakerService');
      return 'Could not remove the caretaker. Please try again.';
    }
  }
}

/// Thrown by [CaretakerService.lookupCandidate] with a message written for the
/// landlord. An exception rather than a nullable return because the caller has
/// to distinguish "this is Musa Bello" from "no such number" — a null name
/// would be indistinguishable from a person with no name on file.
class CaretakerLookupException implements Exception {
  final String message;
  const CaretakerLookupException(this.message);

  @override
  String toString() => message;
}

/// A caretaker invitation. Clients only ever READ these — every transition is a
/// callable, because a client-written invite would be a client-chosen
/// caretakerId, which is the one thing the invite exists to prevent.
class CaretakerInvite {
  final String id;
  final String landlordId;
  final String landlordName;
  final String caretakerId;
  final String caretakerName;
  final List<String> propertyIds;
  final List<String> propertyTitles;
  final String? buildingId;
  final String status; // pending | accepted | declined | revoked
  final DateTime? createdAt;

  const CaretakerInvite({
    required this.id,
    required this.landlordId,
    required this.landlordName,
    required this.caretakerId,
    required this.caretakerName,
    required this.propertyIds,
    required this.propertyTitles,
    required this.buildingId,
    required this.status,
    required this.createdAt,
  });

  factory CaretakerInvite.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return CaretakerInvite(
      id: doc.id,
      landlordId: data['landlordId'] as String? ?? '',
      landlordName: data['landlordName'] as String? ?? 'Your landlord',
      caretakerId: data['caretakerId'] as String? ?? '',
      caretakerName: data['caretakerName'] as String? ?? 'Your caretaker',
      // `appliedPropertyIds` is what acceptance ACTUALLY wrote — a unit can
      // drop out between invite and accept (sold, deleted, re-caretakered), so
      // an accepted invite describes itself by what landed, not what was asked.
      propertyIds: List<String>.from(
        (data['appliedPropertyIds'] ?? data['propertyIds'] ?? const []) as List,
      ),
      propertyTitles:
          List<String>.from((data['propertyTitles'] ?? const []) as List),
      buildingId: data['buildingId'] as String?,
      status: data['status'] as String? ?? 'pending',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  bool get isPending => status == 'pending';
  bool get isActive => status == 'accepted';
}
