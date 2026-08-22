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
  /// Deduplicates: only one "propertyAdded" per propertyId per landlord.
  Future<void> trackPropertyAdded({
    String? landlordId,
    required String propertyId,
    required String propertyTitle,
  }) async {
    final uid = landlordId ?? _currentUserId;
    if (uid == null) return;
    try {
      // ── Dedup: skip if we already tracked this property listing ──
      final existing = await _activitiesRef
          .where('landlordId', isEqualTo: uid)
          .where('propertyId', isEqualTo: propertyId)
          .where('type', isEqualTo: 'propertyAdded')
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        AppLogger.i(
          'Skipping duplicate propertyAdded for $propertyId',
          name: _tag,
        );
        return;
      }

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
  ///
  /// Merged from BOTH logs. `activities` is written ad hoc by whichever client
  /// screen remembered to — nine types in all. `notifications` is written
  /// centrally by the Cloud Functions and carries nineteen landlord-facing
  /// types, sixteen of which never reached this feed: a tenant requesting an
  /// inspection, rent interest paid, an agreement finalising, a caretaker
  /// accepting, a listing suspended.
  ///
  /// That gap is structural. Every event added since this screen was built went
  /// through the functions and skipped it, and would keep doing so. Reading
  /// both is the only version that stays complete.
  ///
  /// `activities` still earns its place: property VIEWS belong in a feed and
  /// must never be a push.
  Future<List<ActivityModel>> getAllActivities() async {
    if (_currentUserId == null) return [];
    final results = await Future.wait([
      _ownActivities(),
      _activitiesFromNotifications(),
    ]);
    final merged = [...results[0], ...results[1]]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }

  /// The `activities` collection alone.
  Future<List<ActivityModel>> _ownActivities() async {
    try {
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

  /// Notification types that belong in the feed, mapped to the nearest
  /// [ActivityType] so the existing tap-routing and icons keep working.
  ///
  /// Anything absent from this map is deliberately NOT in the feed — chat
  /// messages and reminders addressed to the tenant would only be noise here.
  static const Map<String, ActivityType> _notificationFeedTypes = {
    'inspection_request': ActivityType.inspectionRequest,
    'inspection_arrival': ActivityType.inspectionRequest,
    'issue_reported': ActivityType.issueReported,
    'issue_updated': ActivityType.issueReported,
    'issue_pending_reminder': ActivityType.issueReported,
    'rental_interest_paid': ActivityType.payment,
    'rental_accept_reminder': ActivityType.inquiry,
    'rental_expired': ActivityType.inquiry,
    'agreement_finalized': ActivityType.payment,
    'caretaker_accepted': ActivityType.inquiry,
    'caretaker_declined': ActivityType.inquiry,
    'agent_declined': ActivityType.inquiry,
    'agent_removed': ActivityType.inquiry,
    'handover_closed': ActivityType.moveoutCompleted,
    'handover_resolved': ActivityType.moveoutCompleted,
    'handover_condition_reminder': ActivityType.moveoutRequested,
    'moveout_requested': ActivityType.moveoutRequested,
    'moveout_auto_confirmed': ActivityType.moveoutCompleted,
    'moveout_pending_reminder': ActivityType.moveoutRequested,
    'listing_suspension': ActivityType.propertyAdded,
  };

  /// This user's notifications, rendered as feed entries.
  ///
  /// Notifications are per-USER (`userId`), not per-landlord, so this returns
  /// only what was addressed to the signed-in account either way.
  Future<List<ActivityModel>> _activitiesFromNotifications() async {
    try {
      final snap = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: _currentUserId)
          .get();

      final out = <ActivityModel>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final mapped = _notificationFeedTypes[data['type'] as String? ?? ''];
        if (mapped == null) continue;

        final created = (data['createdAt'] as Timestamp?)?.toDate();
        if (created == null) continue;

        final payload =
            (data['payload'] as Map<String, dynamic>?) ?? const {};

        out.add(ActivityModel(
          id: doc.id,
          landlordId: _currentUserId!,
          type: mapped,
          title: (data['title'] as String?) ?? '',
          subtitle: (data['body'] as String?) ?? '',
          propertyId: payload['propertyId'] as String?,
          relatedId: payload['issueId'] as String?,
          isRead: data['read'] == true,
          createdAt: created,
        ));
      }
      return out;
    } catch (e) {
      // A feed missing half its entries is better than a feed that fails.
      AppLogger.e('notification-backed activities failed',
          error: e, name: _tag);
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

  /// Mark one feed entry read, in whichever collection it came from.
  ///
  /// The feed is merged, so an id here may name a `notifications` doc rather
  /// than an `activities` one. Updating the wrong collection silently failed
  /// and the entry stayed bold forever.
  ///
  /// The two use different field names on purpose: `activities` has `isRead`,
  /// `notifications` has `read` + `readAt`, and the notification update rule
  /// allowlists exactly those two — sending `isRead` there rejects the whole
  /// write.
  Future<void> markAsRead(String activityId) async {
    try {
      final ref = _activitiesRef.doc(activityId);
      if ((await ref.get()).exists) {
        await ref.update({'isRead': true});
        return;
      }
      await _firestore.collection('notifications').doc(activityId).update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
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