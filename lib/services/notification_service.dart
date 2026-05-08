import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/utils/app_logger.dart';

/// Handles FCM token lifecycle and foreground display of push notifications.
///
/// Wiring:
///   - Call [init] once from main.dart after Firebase init.
///   - Listens to FirebaseAuth state changes and manages tokens automatically.
///   - Renders foreground messages via flutter_local_notifications.
///
/// What this class does NOT do (intentionally, deferred to later steps):
///   - Handle notification taps (deep linking).
///   - Track which screen the user is on (route-aware suppression).
///   - Re-prompt the user if they deny permission.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const String _channelId = 'clearrent_default';
  static const String _channelName = 'ClearRent';
  static const String _channelDescription =
      'General notifications from ClearRent';

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifs =
      FlutterLocalNotificationsPlugin();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _initialized = false;

  /// Tracks the currently-registered (uid, token) pair so we can clean up
  /// on logout or token rotation.
  String? _trackedUid;
  String? _trackedToken;

  /// Call once from main.dart after Firebase has been initialized.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _setupLocalNotifications();
    _listenToAuthChanges();
    _listenToTokenRefresh();
    _listenToForegroundMessages();

    AppLogger.i('NotificationService initialized', name: 'NotificationService');
  }

  // ─── Setup ────────────────────────────────────────────────────────────────

  Future<void> _setupLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('ic_notification');
    const initSettings = InitializationSettings(android: androidInit);
    await _localNotifs.initialize(initSettings);

    // Create the notification channel referenced by AndroidManifest.xml.
    // Idempotent — safe to call on every app start.
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
    );
    await _localNotifs
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  // ─── Auth state lifecycle ─────────────────────────────────────────────────

  void _listenToAuthChanges() {
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user != null) {
        await _registerForUser(user.uid);
      } else {
        await _unregisterPreviousUser();
      }
    });
  }

  Future<void> _registerForUser(String uid) async {
    try {
      final settings = await _fcm.requestPermission();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        AppLogger.w(
          'Notification permission denied (status: '
          '${settings.authorizationStatus})',
          name: 'NotificationService',
        );
        return;
      }

      final token = await _fcm.getToken();
      if (token == null) {
        AppLogger.w('FCM returned null token', name: 'NotificationService');
        return;
      }

      await _firestore.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });

      _trackedUid = uid;
      _trackedToken = token;

      AppLogger.i('FCM token registered for $uid',
          name: 'NotificationService');
    } catch (e) {
      AppLogger.e('Failed to register FCM token',
          error: e, name: 'NotificationService');
    }
  }

  Future<void> _unregisterPreviousUser() async {
    final uid = _trackedUid;
    final token = _trackedToken;
    if (uid == null || token == null) return;

    try {
      await _firestore.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayRemove([token]),
      });
      AppLogger.i('FCM token removed for $uid', name: 'NotificationService');
    } catch (e) {
      AppLogger.e('Failed to remove FCM token on logout',
          error: e, name: 'NotificationService');
    } finally {
      _trackedUid = null;
      _trackedToken = null;
    }
  }

  // ─── Token rotation ───────────────────────────────────────────────────────

  void _listenToTokenRefresh() {
    _fcm.onTokenRefresh.listen((newToken) async {
      final uid = _trackedUid;
      if (uid == null) return;

      try {
        final docRef = _firestore.collection('users').doc(uid);
        // Remove the old token, add the new one.
        if (_trackedToken != null) {
          await docRef.update({
            'fcmTokens': FieldValue.arrayRemove([_trackedToken]),
          });
        }
        await docRef.update({
          'fcmTokens': FieldValue.arrayUnion([newToken]),
        });
        _trackedToken = newToken;
        AppLogger.i('FCM token refreshed for $uid',
            name: 'NotificationService');
      } catch (e) {
        AppLogger.e('Failed to update token on refresh',
            error: e, name: 'NotificationService');
      }
    });
  }

  // ─── Foreground display ───────────────────────────────────────────────────

  void _listenToForegroundMessages() {
    FirebaseMessaging.onMessage.listen((message) {
      final notif = message.notification;
      if (notif == null) return;

      _localNotifs.show(
        message.hashCode,
        notif.title,
        notif.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_notification',
          ),
        ),
      );
    });
  }
}