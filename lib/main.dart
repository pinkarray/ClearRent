import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'services/connectivity_service.dart';
import 'services/notification_service.dart';
import 'services/presence_service.dart';

import 'app/app.dart';

// Global flag to check if Firebase is initialized
bool firebaseInitialized = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cap decoded-image memory. This was 200 MB to stop property images
  // re-decoding between list and detail, but a cache that large makes the app
  // the first thing Android's low-memory killer drops when something else
  // needs RAM (an incoming call) — the process dies and the app cold-restarts
  // to the splash screen, losing the user's place. 64 MB (under Flutter's
  // 100 MB default) keeps a useful working set on the low-RAM devices most of
  // our users are on.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64 MB

  // Initialize Firebase with error handling
  try {
    await Firebase.initializeApp();
    // M4: Play Integrity on release/Play builds (real attestation), debug
    // provider on `flutter run`/profile builds so local dev still works with
    // the App-Check-enforced callables. For local testing of those callables,
    // register the debug token the app prints on first run in the Firebase
    // console (App Check → Apps → Manage debug tokens). Release/Play builds use
    // Play Integrity and only attest on a Play-signed install.
    // (iOS App Check is a separate step for when iOS ships — not configured.)
    await FirebaseAppCheck.instance.activate(
      androidProvider:
          kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
    );
    firebaseInitialized = true;
    await NotificationService.instance.init();
    // Heartbeat for the admin dashboard's "active now" view. Follows auth
    // state, so it needs no hook in any individual sign-in path.
    PresenceService.instance.start();
    debugPrint('✅ Firebase initialized successfully');
  } catch (e) {
    firebaseInitialized = false;
    debugPrint('❌ Firebase initialization failed: $e');
  }

  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // NOTE: System UI overlay style is now set reactively inside ClearRentApp
  // based on the active theme, so we no longer hardcode it here.

  await ConnectivityService().initialize();

  runApp(const ProviderScope(child: ClearRentApp()));
}