import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../shared/models/tenancy_link_model.dart';

class TenancyLinkService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  CollectionReference get _links =>
      _firestore.collection('tenancy_links');

  String? get _currentUserId => _auth.currentUser?.uid;

  // ─────────────────────────────────────────────
  // LANDLORD SIDE
  // ─────────────────────────────────────────────

  /// Search tenants by name (for landlord to find and link)
  /// Only returns users with accountType == 'tenant'
  Future<List<TenantSearchResult>> searchTenantsByName(String query) async {
    if (query.trim().length < 2) return [];
    try {
      final q = query.trim().toLowerCase();

      // First try the indexed prefix search (works for users registered after fullNameLower was added)
      final indexedSnap = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'tenant')
          .where('fullNameLower', isGreaterThanOrEqualTo: q)
          .where('fullNameLower', isLessThan: '${q}z')
          .limit(20)
          .get();

      // Also do a client-side filtered fetch for users who don't have fullNameLower yet
      final allTenantsSnap = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'tenant')
          .get();

      // Merge results, deduplicate by doc id
      final seen = <String>{};
      final merged = <QueryDocumentSnapshot>[];

      for (final doc in [...indexedSnap.docs, ...allTenantsSnap.docs]) {
        if (seen.add(doc.id)) merged.add(doc);
      }

      // Client-side filter on the merged set
      final results = merged.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        final name = (data['fullName'] ?? '').toString().toLowerCase();
        return name.contains(q);
      }).map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        // Backfill fullNameLower if missing (fire-and-forget)
        if (data['fullNameLower'] == null) {
          doc.reference.update({'fullNameLower': (data['fullName'] ?? '').toString().toLowerCase()});
        }
        return TenantSearchResult(
          userId: doc.id,
          fullName: data['fullName'] ?? '',
          isVerified: data['verificationStatus'] == 'verified',
          profileImageUrl: data['profileImageUrl'],
        );
      }).toList();

      developer.log('✅ searchTenantsByName: found ${results.length} for "$query"',
          name: 'TenancyLinkService');
      return results;
    } catch (e) {
      developer.log('❌ searchTenantsByName error: $e', name: 'TenancyLinkService');
      return [];
    }
  }

  /// Landlord sends a link request to a tenant for a specific property.
  /// rentDueDay and rentAmount are set here — captured as baseline.
  Future<bool> sendLinkRequest({
    required String propertyId,
    required String propertyTitle,
    required String propertyAddress,
    required String propertyCity,
    required String tenantId,
    required String tenantName,
    required int rentDueDay,
    int rentDueMonth = 1,
    required double rentAmount,
    required String rentFrequency,
  }) async {
    try {
      final landlordId = _currentUserId;
      if (landlordId == null) return false;

      // Prevent duplicate — check if a non-removed link already exists
      final existing = await _links
          .where('landlordId', isEqualTo: landlordId)
          .where('tenantId', isEqualTo: tenantId)
          .where('propertyId', isEqualTo: propertyId)
          .where('status', whereIn: ['pending', 'confirmed']).get();

      if (existing.docs.isNotEmpty) {
        developer.log('⚠️ Link already exists', name: 'TenancyLinkService');
        return false;
      }

      // Get landlord info
      final landlordDoc =
          await _firestore.collection('users').doc(landlordId).get();
      final landlordData = landlordDoc.data();
      final landlordName = landlordData?['fullName'] ?? 'Landlord';
      final landlordPhone = landlordData?['phone'] ?? '';

      final link = TenancyLinkModel(
        id: '',
        landlordId: landlordId,
        landlordName: landlordName,
        landlordPhone: landlordPhone,
        tenantId: tenantId,
        tenantName: tenantName,
        propertyId: propertyId,
        propertyTitle: propertyTitle,
        propertyAddress: propertyAddress,
        propertyCity: propertyCity,
        status: 'pending',
        rentDueDay: rentDueDay,
        rentDueMonth: rentDueMonth,
        rentAmount: rentAmount,
        rentFrequency: rentFrequency,
      );

      await _links.add(link.toFirestore());
      developer.log('✅ Link request sent to $tenantName',
          name: 'TenancyLinkService');
      return true;
    } catch (e) {
      developer.log('❌ sendLinkRequest error: $e',
          name: 'TenancyLinkService');
      return false;
    }
  }

  /// One-time fetch of all confirmed links where this user is landlord.
  /// Used by the landlord home screen to show linked tenants section.
  Future<List<TenancyLinkModel>> landlordConfirmedLinksOnce(String landlordId) async {
    try {
      final snap = await _links
          .where('landlordId', isEqualTo: landlordId)
          .where('status', isEqualTo: 'confirmed')
          .get();
      return snap.docs.map((doc) {
        return TenancyLinkModel.fromFirestore(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
      }).toList();
    } catch (e) {
      developer.log('❌ landlordConfirmedLinksOnce error: $e', name: 'TenancyLinkService');
      return [];
    }
  }

  /// Stream of all tenants (pending + confirmed) for a property — for landlord view
  Stream<List<TenancyLinkModel>> propertyTenantsStream(String propertyId) {
    return _links
        .where('propertyId', isEqualTo: propertyId)
        .where('status', whereIn: ['pending', 'confirmed'])
        .snapshots()
        .map((snap) => snap.docs.map((doc) {
              return TenancyLinkModel.fromFirestore(
                doc.data() as Map<String, dynamic>,
                doc.id,
              );
            }).toList());
  }

  /// Remove a tenant link (landlord action).
  /// Also decrements currentTenantsCount and re-marks the property as available
  /// if no confirmed links remain.
  Future<bool> removeTenant(String linkId) async {
    try {
      // Fetch the link first so we have propertyId
      final linkDoc = await _links.doc(linkId).get();
      if (!linkDoc.exists) return false;
      final data = linkDoc.data() as Map<String, dynamic>;
      final propertyId = data['propertyId'] as String? ?? '';

      await _links.doc(linkId).update({
        'status': 'removed',
        'removedAt': FieldValue.serverTimestamp(),
      });

      // Check if any other confirmed links remain for this property
      if (propertyId.isNotEmpty) {
        final remaining = await _links
            .where('propertyId', isEqualTo: propertyId)
            .where('status', isEqualTo: 'confirmed')
            .get();

        await _firestore.collection('properties').doc(propertyId).update({
          'currentTenantsCount': FieldValue.increment(-1),
          // Re-mark available only if no confirmed tenants left
          if (remaining.docs.isEmpty) 'isAvailable': true,
        });
      }

      developer.log('✅ Tenant removed from link $linkId — property $propertyId updated',
          name: 'TenancyLinkService');
      return true;
    } catch (e) {
      developer.log('❌ removeTenant error: $e', name: 'TenancyLinkService');
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // TENANT SIDE
  // ─────────────────────────────────────────────

  /// Stream of pending link requests for the current tenant
  Stream<List<TenancyLinkModel>> tenantPendingLinksStream() {
    final uid = _currentUserId;
    if (uid == null) return Stream.value([]);
    return _links
        .where('tenantId', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snap) => snap.docs.map((doc) {
              return TenancyLinkModel.fromFirestore(
                doc.data() as Map<String, dynamic>,
                doc.id,
              );
            }).toList());
  }

  /// Stream of the tenant's active (confirmed) link — there should only be one at a time
  Stream<TenancyLinkModel?> tenantActiveLinkStream() {
    final uid = _currentUserId;
    if (uid == null) return Stream.value(null);
    return _links
        .where('tenantId', isEqualTo: uid)
        .where('status', isEqualTo: 'confirmed')
        .limit(1)
        .snapshots()
        .map((snap) {
          if (snap.docs.isEmpty) return null;
          return TenancyLinkModel.fromFirestore(
            snap.docs.first.data() as Map<String, dynamic>,
            snap.docs.first.id,
          );
        });
  }

  /// One-time fetch of tenant's active link (for non-stream use)
  Future<TenancyLinkModel?> getTenantActiveLink() async {
    final uid = _currentUserId;
    if (uid == null) return null;
    try {
      final snap = await _links
          .where('tenantId', isEqualTo: uid)
          .where('status', isEqualTo: 'confirmed')
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return null;
      return TenancyLinkModel.fromFirestore(
        snap.docs.first.data() as Map<String, dynamic>,
        snap.docs.first.id,
      );
    } catch (e) {
      developer.log('❌ getTenantActiveLink error: $e',
          name: 'TenancyLinkService');
      return null;
    }
  }

  /// Tenant accepts a link request.
  /// Also marks the property as occupied and increments currentTenantsCount.
  Future<bool> acceptLink(String linkId) async {
    try {
      // Fetch the link first so we have propertyId
      final linkDoc = await _links.doc(linkId).get();
      if (!linkDoc.exists) return false;
      final data = linkDoc.data() as Map<String, dynamic>;
      final propertyId = data['propertyId'] as String? ?? '';

      // Update link status
      await _links.doc(linkId).update({
        'status': 'confirmed',
        'acceptedAt': FieldValue.serverTimestamp(),
      });

      // Update property: mark occupied + increment tenant count
      if (propertyId.isNotEmpty) {
        await _firestore.collection('properties').doc(propertyId).update({
          'isAvailable': false,
          'currentTenantsCount': FieldValue.increment(1),
        });
      }

      developer.log('✅ Tenant accepted link $linkId — property $propertyId marked occupied',
          name: 'TenancyLinkService');
      return true;
    } catch (e) {
      developer.log('❌ acceptLink error: $e', name: 'TenancyLinkService');
      return false;
    }
  }

  /// Tenant rejects a link request (no property change needed — was never confirmed).
  Future<bool> rejectLink(String linkId) async {
    try {
      await _links.doc(linkId).update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Tenant rejected link $linkId',
          name: 'TenancyLinkService');
      return true;
    } catch (e) {
      developer.log('❌ rejectLink error: $e', name: 'TenancyLinkService');
      return false;
    }
  }

  /// Check if tenant is currently linked (has a confirmed link)
  Future<bool> isLinked() async {
    final link = await getTenantActiveLink();
    return link != null;
  }
}