import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../app/routes.dart';
import '../core/utils/app_logger.dart';
import 'route_observer_service.dart';

/// Handles FCM token lifecycle, foreground display, and notification taps.
///
/// Wiring:
///   - Call [init] once from main.dart after Firebase init.
///   - Listens to FirebaseAuth state changes and manages tokens automatically.
///   - Renders foreground messages via flutter_local_notifications.
///   - Suppresses foreground display if the user is already on the
///     notification's target screen (per RouteObserverService).
///   - Handles taps in foreground / background / terminated states.
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
    _listenToBackgroundTaps();
    await _handleInitialMessage();

    AppLogger.i('NotificationService initialized', name: 'NotificationService');
  }

  // ─── Setup ────────────────────────────────────────────────────────────────

  Future<void> _setupLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('ic_notification');
    const initSettings = InitializationSettings(android: androidInit);
    await _localNotifs.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onLocalNotifTap,
    );

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

  // ─── Foreground display + suppression ─────────────────────────────────────

  void _listenToForegroundMessages() {
    FirebaseMessaging.onMessage.listen((message) {
      final notif = message.notification;
      if (notif == null) return;

      // Suppress if user is already on the target screen.
      if (_isOnTargetScreen(message.data)) {
        AppLogger.i(
          'Suppressing foreground notif: user already on target screen',
          name: 'NotificationService',
        );
        return;
      }

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
        payload: _encodePayload(message.data),
      );
    });
  }

  bool _isOnTargetScreen(Map<String, dynamic> data) {
    final route = data['route'] as String?;
    if (route == null) return false;

    // Build a match-params map from any data fields whose key starts
    // with 'param_'. Server-side: send `param_conversationId: 'abc'`.
    final matchParams = <String, String>{};
    for (final entry in data.entries) {
      if (entry.key.startsWith('param_')) {
        matchParams[entry.key.substring(6)] = entry.value.toString();
      }
    }

    return RouteObserverService.instance.isOnRoute(
      route,
      matchParams: matchParams.isEmpty ? null : matchParams,
    );
  }

  // ─── Tap handling (3 paths converge here) ─────────────────────────────────

  Future<void> _handleInitialMessage() async {
    final initial = await _fcm.getInitialMessage();
    if (initial != null) {
      AppLogger.i('Tap from terminated state', name: 'NotificationService');
      _handleNotificationTap(initial.data);
    }
  }

  void _listenToBackgroundTaps() {
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      AppLogger.i('Tap from background state', name: 'NotificationService');
      _handleNotificationTap(message.data);
    });
  }

  void _onLocalNotifTap(NotificationResponse response) {
    AppLogger.i('Tap from foreground state', name: 'NotificationService');
    final payload = response.payload;
    if (payload == null) return;
    _handleNotificationTap(_decodePayload(payload));
  }

  Future<void> _handleNotificationTap(Map<String, dynamic> data) async {
    // Mark the underlying notification doc read, if we have its id.
    final notifId = data['notificationId'] as String?;
    if (notifId != null) {
      try {
        await _firestore.collection('notifications').doc(notifId).update({
          'read': true,
          'readAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        AppLogger.e('Failed to mark notification read on tap',
            error: e, name: 'NotificationService');
      }
    }

    // Navigate to the deep-link target.
    final route = data['route'] as String?;
    if (route == null) return;

    try {
      // Pass the entire data map as `extra` so target screens can pluck
      // whatever fields they need.
      appRouter.push(route, extra: Map<String, dynamic>.from(data));
    } catch (e) {
      AppLogger.e('Failed to navigate to notification target',
          error: e, name: 'NotificationService');
    }
  }

  // ─── Payload encoding for local-notif (string-only constraint) ────────────

  String _encodePayload(Map<String, dynamic> data) {
    // FCM data values are already strings server-side. Encode as URL-style.
    return data.entries
        .map((e) => '${Uri.encodeComponent(e.key)}='
            '${Uri.encodeComponent(e.value.toString())}')
        .join('&');
  }

  Map<String, dynamic> _decodePayload(String payload) {
    final result = <String, dynamic>{};
    for (final part in payload.split('&')) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final k = Uri.decodeComponent(part.substring(0, eq));
      final v = Uri.decodeComponent(part.substring(eq + 1));
      result[k] = v;
    }
    return result;
  }
}