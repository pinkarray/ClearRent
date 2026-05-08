import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'services/connectivity_service.dart';
import 'services/notification_service.dart';

import 'app/app.dart';

// Global flag to check if Firebase is initialized
bool firebaseInitialized = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase with error handling
  try {
    await Firebase.initializeApp();
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
    );
    firebaseInitialized = true;
    await NotificationService.instance.init();
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