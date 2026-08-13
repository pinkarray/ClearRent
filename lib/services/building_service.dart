import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../shared/models/building_model.dart';

/// Building / compound groups. A building groups multiple unit listings of the
/// same landlord so one ownership document is verified once for all of them and
/// the admin reviews units with building context. See [BuildingModel].
///
/// Verification of the building's ownership doc is admin-only (the CF / admin
/// dashboard sets ownershipDocStatus); clients here only create buildings and
/// read them back. Mirrors the property ownership-doc lifecycle.
class BuildingService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const _collection = 'buildings';

  /// Create a building for the current landlord. Returns the new id, or null on
  /// failure. The ownership doc starts 'pending' when a doc URL is supplied,
  /// else 'none'. createdAt/updatedAt are set server-side.
  Future<String?> createBuilding({
    required String name,
    String address = '',
    String structure = '',
    int? totalFloors,
    String? ownershipDocUrl,
    String? ownershipDocType,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    try {
      final data = BuildingModel(
        id: '',
        landlordId: uid,
        name: name.trim(),
        address: address.trim(),
        structure: structure,
        totalFloors: totalFloors,
        ownershipDocUrl: ownershipDocUrl,
        ownershipDocType: ownershipDocType,
        ownershipDocStatus:
            (ownershipDocUrl != null && ownershipDocUrl.isNotEmpty)
                ? 'pending'
                : 'none',
      ).toFirestore();
      data['createdAt'] = FieldValue.serverTimestamp();
      final ref = await _firestore.collection(_collection).add(data);
      developer.log('✅ Building created: ${ref.id}', name: 'BuildingService');
      return ref.id;
    } catch (e) {
      developer.log('❌ Error creating building: $e', name: 'BuildingService');
      return null;
    }
  }

  /// The current landlord's buildings, newest first — feeds the add-property
  /// "join an existing building" picker. Scoped to landlordId so it satisfies
  /// the ownership-constrained list rule.
  Stream<List<BuildingModel>> streamLandlordBuildings() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _firestore
        .collection(_collection)
        .where('landlordId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
          final list = snap.docs
              .map((d) => BuildingModel.fromFirestore(d.data(), d.id))
              .toList();
          // Sort client-side (newest first) to avoid a composite index on
          // landlordId + createdAt.
          list.sort((a, b) {
            final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bt.compareTo(at);
          });
          return list;
        });
  }

  /// One-shot fetch of a single building (e.g. to resolve a unit's inherited
  /// ownership-doc status). Returns null if missing or on error.
  Future<BuildingModel?> getBuilding(String buildingId) async {
    if (buildingId.isEmpty) return null;
    try {
      final doc =
          await _firestore.collection(_collection).doc(buildingId).get();
      if (!doc.exists) return null;
      return BuildingModel.fromFirestore(doc.data()!, doc.id);
    } catch (e) {
      developer.log('❌ Error fetching building: $e', name: 'BuildingService');
      return null;
    }
  }

  /// Live stream of a single building — for screens that should react to the
  /// admin verifying the shared ownership doc.
  Stream<BuildingModel?> streamBuilding(String buildingId) {
    if (buildingId.isEmpty) return Stream.value(null);
    return _firestore
        .collection(_collection)
        .doc(buildingId)
        .snapshots()
        .map((doc) => doc.exists
            ? BuildingModel.fromFirestore(doc.data()!, doc.id)
            : null);
  }
}
