import 'dart:async';
import 'dart:developer' as developer;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

/// Writes a "recently active" heartbeat to the signed-in user's doc so the
/// admin dashboard can show who is currently using the app.
///
/// Deliberately NOT true presence. There is no socket to watch, so a force-kill
/// or a dead network isn't detectable — `lastSeenAt` simply stops advancing and
/// the user ages out of the window. Read it as "active in the last few minutes",
/// never as a hard online/offline signal, and never gate anything on it.
///
/// Last *login* is not written here: Firebase Auth already records
/// `metadata.lastSignInTime` server-side, which the admin dashboard reads
/// through the Admin SDK. That can't be forged by a modified client, whereas
/// anything written from here can — `firestore.rules` lets a user write their
/// own doc apart from a denylist of sensitive fields.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  static const _heartbeatInterval = Duration(minutes: 5);

  Timer? _timer;
  StreamSubscription<User?>? _authSub;
  DateTime? _lastWrite;

  /// Call once at startup. Follows auth state, so it covers a fresh sign-in and
  /// a restored session alike.
  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        _stopHeartbeat();
      } else {
        _beat();
        _startHeartbeat();
      }
    });
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _authSub = null;
    _stopHeartbeat();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _beat();
      _startHeartbeat();
    } else {
      // Backgrounded: stop writing. The user ages out of the active window on
      // their own, which is the correct outcome.
      _stopHeartbeat();
    }
  }

  void _startHeartbeat() {
    _timer ??= Timer.periodic(_heartbeatInterval, (_) => _beat());
  }

  void _stopHeartbeat() {
    _timer?.cancel();
    _timer = null;
  }

  /// One heartbeat write, rate-limited so lifecycle churn can't turn into a
  /// write storm.
  Future<void> _beat() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final now = DateTime.now();
    final last = _lastWrite;
    if (last != null && now.difference(last) < _heartbeatInterval) return;
    _lastWrite = now;

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'lastSeenAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Best-effort telemetry — never surface or retry.
      developer.log('presence heartbeat failed: $e', name: 'PresenceService');
    }
  }
}
