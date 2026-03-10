import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

/// Lightweight logger for ClearRent.
/// Uses dart:developer log() in debug mode — no lint warnings, no extra packages.
/// Silenced automatically in release builds.
class AppLogger {
  AppLogger._();

  static void i(String message, {String name = 'ClearRent'}) {
    if (kDebugMode) dev.log(message, name: name);
  }

  static void e(String message, {Object? error, String name = 'ClearRent'}) {
    if (kDebugMode) {
      dev.log('❌ $message', name: name, error: error, level: 1000);
    }
  }

  static void w(String message, {String name = 'ClearRent'}) {
    if (kDebugMode) dev.log('⚠️  $message', name: name, level: 900);
  }
}