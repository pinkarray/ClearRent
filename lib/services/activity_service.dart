import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/utils/app_logger.dart';
import '../shared/models/activity_model.dart';

class ActivityService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const String _tag = 'ActivityService';

  CollectionReference get _activitiesRef => _firestore.collection('activities');

  String? get _currentUserId => _auth.currentUser?.uid;

  // ─────────────────────────────────────────────
  // CREATE
  // ─────────────────────────────────────────────

  /// Track when a landlord lists a property.
  /// [landlordId] is optional — falls back to the current user's uid.
  Future<void> trackPropertyAdded({
    String? landlordId,
    required String propertyId,
    required String propertyTitle,
  }) async {
    final uid = landlordId ?? _currentUserId;
    if (uid == null) return;
    try {
      await _activitiesRef.add({
        'landlordId': uid,
        'type': 'propertyAdded',
        'title': 'Property Listed',
        'subtitle': propertyTitle,
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'actorId': uid,
        'actorName': 'You',
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppLogger.i('Property added tracked ($propertyId)', name: _tag);
    } catch (e) {
      AppLogger.e('trackPropertyAdded failed', error: e, name: _tag);
    }
  }

  /// Track when a tenant or agent views a property.
  Future<void> trackPropertyViewed({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
    required String viewerId,
    required String viewerName,
  }) async {
    if (landlordId == viewerId) return;
    try {
      // Deduplicate: skip if same viewer viewed within the last hour
      final recent = await _activitiesRef
          .where('landlordId', isEqualTo: landlordId)
          .where('propertyId', isEqualTo: propertyId)
          .where('actorId', isEqualTo: viewerId)
          .where('type', isEqualTo: 'propertyViewed')
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();

      if (recent.docs.isNotEmpty) {
        final ts = (recent.docs.first.data()
            as Map<String, dynamic>)['createdAt'] as Timestamp?;
        if (ts != null &&
            DateTime.now().difference(ts.toDate()).inHours < 1) {
          AppLogger.i('Skipping duplicate view', name: _tag);
          return;
        }
      }

      await _activitiesRef.add({
        'landlordId': landlordId,
        'type': 'propertyViewed',
        'title': '$viewerName viewed your property',
        'subtitle': propertyTitle,
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'actorId': viewerId,
        'actorName': viewerName,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppLogger.i('Property viewed by $viewerName', name: _tag);
    } catch (e) {
      AppLogger.e('trackPropertyViewed failed', error: e, name: _tag);
    }
  }

  /// Track when a tenant starts a chat (first inquiry only).
  Future<void> trackInquiry({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
    required String tenantId,
    required String tenantName,
  }) async {
    try {
      final existing = await _activitiesRef
          .where('landlordId', isEqualTo: landlordId)
          .where('propertyId', isEqualTo: propertyId)
          .where('actorId', isEqualTo: tenantId)
          .where('type', isEqualTo: 'inquiry')
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        AppLogger.i('Inquiry already tracked for this property', name: _tag);
        return;
      }

      await _activitiesRef.add({
        'landlordId': landlordId,
        'type': 'inquiry',
        'title': 'New inquiry from $tenantName',
        'subtitle': propertyTitle,
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'actorId': tenantId,
        'actorName': tenantName,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppLogger.i('Inquiry tracked from $tenantName', name: _tag);
    } catch (e) {
      AppLogger.e('trackInquiry failed', error: e, name: _tag);
    }
  }

  /// Track a rent payment received by the landlord.
  Future<void> trackPayment({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
    required String tenantId,
    required String tenantName,
    required double amount,
  }) async {
    try {
      final formatted = amount >= 1000000
          ? '₦${(amount / 1000000).toStringAsFixed(1)}M'
          : '₦${(amount / 1000).toStringAsFixed(0)}K';

      await _activitiesRef.add({
        'landlordId': landlordId,
        'type': 'payment',
        'title': 'Rent payment received',
        'subtitle': '$formatted from $tenantName',
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'actorId': tenantId,
        'actorName': tenantName,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppLogger.i('Payment tracked ($formatted)', name: _tag);
    } catch (e) {
      AppLogger.e('trackPayment failed', error: e, name: _tag);
    }
  }

  // ─────────────────────────────────────────────
  // READ
  // ─────────────────────────────────────────────

  /// Recent activities for the current landlord (one-time fetch).
  Future<List<ActivityModel>> getRecentActivities({int limit = 5}) async {
    try {
      if (_currentUserId == null) return [];
      final snap = await _activitiesRef
          .where('landlordId', isEqualTo: _currentUserId)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return _mapDocs(snap.docs);
    } catch (e) {
      AppLogger.e('getRecentActivities failed', error: e, name: _tag);
      return [];
    }
  }

  /// All activities for the current landlord (one-time fetch).
  Future<List<ActivityModel>> getAllActivities() async {
    try {
      if (_currentUserId == null) return [];
      final snap = await _activitiesRef
          .where('landlordId', isEqualTo: _currentUserId)
          .orderBy('createdAt', descending: true)
          .get();
      return _mapDocs(snap.docs);
    } catch (e) {
      AppLogger.e('getAllActivities failed', error: e, name: _tag);
      return [];
    }
  }

  /// Real-time stream of activities for the current landlord.
  Stream<List<ActivityModel>> activitiesStream({int limit = 10}) {
    if (_currentUserId == null) return Stream.value([]);
    return _activitiesRef
        .where('landlordId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => _mapDocs(snap.docs));
  }

  // ─────────────────────────────────────────────
  // UNREAD
  // ─────────────────────────────────────────────

  Future<int> getUnreadCount() async {
    try {
      if (_currentUserId == null) return 0;
      final snap = await _activitiesRef
          .where('landlordId', isEqualTo: _currentUserId)
          .where('isRead', isEqualTo: false)
          .count()
          .get();
      return snap.count ?? 0;
    } catch (e) {
      AppLogger.e('getUnreadCount failed', error: e, name: _tag);
      return 0;
    }
  }

  Future<void> markAsRead(String activityId) async {
    try {
      await _activitiesRef.doc(activityId).update({'isRead': true});
    } catch (e) {
      AppLogger.e('markAsRead failed', error: e, name: _tag);
    }
  }

  Future<void> markAllAsRead() async {
    try {
      if (_currentUserId == null) return;
      final snap = await _activitiesRef
          .where('landlordId', isEqualTo: _currentUserId)
          .where('isRead', isEqualTo: false)
          .get();
      final batch = _firestore.batch();
      for (final doc in snap.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
      await batch.commit();
      AppLogger.i('All activities marked as read', name: _tag);
    } catch (e) {
      AppLogger.e('markAllAsRead failed', error: e, name: _tag);
    }
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────

  List<ActivityModel> _mapDocs(List<QueryDocumentSnapshot> docs) {
    return docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      data['id'] = doc.id;
      return ActivityModel.fromJson(data);
    }).toList();
  }
}