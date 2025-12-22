import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../shared/models/activity_model.dart';

class ActivityService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  CollectionReference get _activitiesRef => _firestore.collection('activities');

  String? get _currentUserId => _auth.currentUser?.uid;

  // ============ CREATE ACTIVITIES ============

  /// Track when a property is added
  Future<void> trackPropertyAdded({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
  }) async {
    try {
      await _activitiesRef.add({
        'landlordId': landlordId,
        'type': 'propertyAdded',
        'title': 'Property Listed',
        'subtitle': propertyTitle,
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'actorId': landlordId,
        'actorName': 'You',
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      developer.log(
        '✅ Activity tracked: Property added',
        name: 'ActivityService',
      );
    } catch (e) {
      developer.log(
        '❌ Failed to track property added: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  /// Track when someone views a property
  Future<void> trackPropertyViewed({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
    required String viewerId,
    required String viewerName,
  }) async {
    try {
      // Don't track if landlord views their own property
      if (landlordId == viewerId) return;

      // Check if this viewer already viewed this property recently (within 1 hour)
      final recentView =
          await _activitiesRef
              .where('landlordId', isEqualTo: landlordId)
              .where('propertyId', isEqualTo: propertyId)
              .where('actorId', isEqualTo: viewerId)
              .where('type', isEqualTo: 'propertyViewed')
              .orderBy('createdAt', descending: true)
              .limit(1)
              .get();

      if (recentView.docs.isNotEmpty) {
        final lastView =
            (recentView.docs.first.data() as Map<String, dynamic>)['createdAt'];
        if (lastView != null) {
          final lastViewTime = (lastView as Timestamp).toDate();
          if (DateTime.now().difference(lastViewTime).inHours < 1) {
            developer.log(
              '⏭️ Skipping duplicate view tracking',
              name: 'ActivityService',
            );
            return;
          }
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
      developer.log(
        '✅ Activity tracked: Property viewed by $viewerName',
        name: 'ActivityService',
      );
    } catch (e) {
      developer.log(
        '❌ Failed to track property view: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  /// Track when someone sends an inquiry (starts a chat)
  Future<void> trackInquiry({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
    required String tenantId,
    required String tenantName,
  }) async {
    try {
      // Check if inquiry already exists for this property from this tenant
      final existingInquiry =
          await _activitiesRef
              .where('landlordId', isEqualTo: landlordId)
              .where('propertyId', isEqualTo: propertyId)
              .where('actorId', isEqualTo: tenantId)
              .where('type', isEqualTo: 'inquiry')
              .limit(1)
              .get();

      if (existingInquiry.docs.isNotEmpty) {
        developer.log(
          '⏭️ Inquiry already tracked for this property',
          name: 'ActivityService',
        );
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
      developer.log(
        '✅ Activity tracked: Inquiry from $tenantName',
        name: 'ActivityService',
      );
    } catch (e) {
      developer.log(
        '❌ Failed to track inquiry: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  /// Track when rent is paid
  Future<void> trackPayment({
    required String landlordId,
    required String propertyId,
    required String propertyTitle,
    required String tenantId,
    required String tenantName,
    required double amount,
  }) async {
    try {
      final formattedAmount =
          amount >= 1000000
              ? 'NGN ${(amount / 1000000).toStringAsFixed(1)}M'
              : 'NGN ${(amount / 1000).toStringAsFixed(0)}K';

      await _activitiesRef.add({
        'landlordId': landlordId,
        'type': 'payment',
        'title': 'Rent payment received',
        'subtitle': '$formattedAmount from $tenantName',
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'actorId': tenantId,
        'actorName': tenantName,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      developer.log(
        '✅ Activity tracked: Payment received',
        name: 'ActivityService',
      );
    } catch (e) {
      developer.log(
        '❌ Failed to track payment: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  // ============ FETCH ACTIVITIES ============

  /// Get recent activities for landlord (limited)
  Future<List<ActivityModel>> getRecentActivities({int limit = 5}) async {
    try {
      if (_currentUserId == null) return [];

      final snapshot =
          await _activitiesRef
              .where('landlordId', isEqualTo: _currentUserId)
              .orderBy('createdAt', descending: true)
              .limit(limit)
              .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return ActivityModel.fromJson(data);
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get recent activities: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return [];
    }
  }

  /// Get all activities for landlord (for full list screen)
  Future<List<ActivityModel>> getAllActivities() async {
    try {
      if (_currentUserId == null) return [];

      final snapshot =
          await _activitiesRef
              .where('landlordId', isEqualTo: _currentUserId)
              .orderBy('createdAt', descending: true)
              .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return ActivityModel.fromJson(data);
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get all activities: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return [];
    }
  }

  /// Get unread activity count
  Future<int> getUnreadCount() async {
    try {
      if (_currentUserId == null) return 0;

      final snapshot =
          await _activitiesRef
              .where('landlordId', isEqualTo: _currentUserId)
              .where('isRead', isEqualTo: false)
              .count()
              .get();

      return snapshot.count ?? 0;
    } catch (e) {
      developer.log(
        '❌ Failed to get unread count: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return 0;
    }
  }

  /// Mark activity as read
  Future<void> markAsRead(String activityId) async {
    try {
      await _activitiesRef.doc(activityId).update({'isRead': true});
    } catch (e) {
      developer.log(
        '❌ Failed to mark as read: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  /// Mark all activities as read
  Future<void> markAllAsRead() async {
    try {
      if (_currentUserId == null) return;

      final snapshot =
          await _activitiesRef
              .where('landlordId', isEqualTo: _currentUserId)
              .where('isRead', isEqualTo: false)
              .get();

      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
      await batch.commit();
      developer.log('✅ All activities marked as read', name: 'ActivityService');
    } catch (e) {
      developer.log(
        '❌ Failed to mark all as read: $e',
        name: 'ActivityService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  /// Stream of activities (for real-time updates)
  Stream<List<ActivityModel>> activitiesStream({int limit = 10}) {
    if (_currentUserId == null) {
      return Stream.value([]);
    }

    return _activitiesRef
        .where('landlordId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return ActivityModel.fromJson(data);
          }).toList();
        });
  }
}
