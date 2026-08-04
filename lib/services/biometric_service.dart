import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:developer' as developer;

class BiometricService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  // No aOptions: flutter_secure_storage 10 dropped EncryptedSharedPreferences
  // (Jetpack Security is deprecated) and migrates existing data to its own
  // ciphers on first access.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  
  static const String _biometricEnabledKey = 'biometric_enabled';
  static const String _lastUserEmailKey = 'last_user_email';
  static const String _hasCompletedOnboardingKey = 'has_completed_onboarding';
  static const String _rememberMeKey = 'remember_me';
  
  // Secure storage keys
  static const String _storedEmailKey = 'secure_email';
  static const String _storedPasswordKey = 'secure_password';

  // ============ BIOMETRIC CHECKS ============

  /// Check if device supports biometrics
  Future<bool> isBiometricAvailable() async {
    try {
      final canAuthenticateWithBiometrics = await _localAuth.canCheckBiometrics;
      final canAuthenticate = canAuthenticateWithBiometrics || await _localAuth.isDeviceSupported();
      
      developer.log(
        '🔐 Biometric available: $canAuthenticate',
        name: 'BiometricService',
      );
      
      return canAuthenticate;
    } on PlatformException catch (e) {
      developer.log(
        '❌ Biometric check error: $e',
        name: 'BiometricService',
      );
      return false;
    }
  }

  /// Get available biometric types (fingerprint, face, etc.)
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      final biometrics = await _localAuth.getAvailableBiometrics();
      
      developer.log(
        '🔐 Available biometrics: $biometrics',
        name: 'BiometricService',
      );
      
      return biometrics;
    } on PlatformException catch (e) {
      developer.log(
        '❌ Get biometrics error: $e',
        name: 'BiometricService',
      );
      return [];
    }
  }

  /// Get a friendly name for the biometric type available
  Future<String> getBiometricTypeName() async {
    final biometrics = await getAvailableBiometrics();
    
    if (biometrics.contains(BiometricType.face)) {
      return 'Face ID';
    } else if (biometrics.contains(BiometricType.fingerprint)) {
      return 'Fingerprint';
    } else if (biometrics.contains(BiometricType.strong)) {
      return 'Biometric';
    } else if (biometrics.contains(BiometricType.weak)) {
      return 'Biometric';
    }
    
    return 'Biometric';
  }

  // ============ BIOMETRIC AUTHENTICATION ============

  /// Authenticate using biometrics (just the biometric check)
  Future<bool> authenticate({String? reason}) async {
    try {
      final biometricName = await getBiometricTypeName();
      
      developer.log(
        '🔐 Starting biometric authentication...',
        name: 'BiometricService',
      );
      
      final authenticated = await _localAuth.authenticate(
        localizedReason: reason ?? 'Use $biometricName to sign in to ClearRent',
        persistAcrossBackgrounding: true,
        biometricOnly: true,
      );

      developer.log(
        authenticated ? '✅ Biometric auth successful' : '❌ Biometric auth failed/cancelled',
        name: 'BiometricService',
      );

      return authenticated;
    } on PlatformException catch (e) {
      developer.log(
        '❌ Biometric auth error: ${e.code} - ${e.message}',
        name: 'BiometricService',
      );
      return false;
    } catch (e) {
      developer.log(
        '❌ Biometric auth unexpected error: $e',
        name: 'BiometricService',
      );
      return false;
    }
  }

  // ============ SECURE CREDENTIAL STORAGE ============

  /// Store credentials securely for biometric login
  Future<bool> storeCredentials(String email, String password) async {
    try {
      await _secureStorage.write(key: _storedEmailKey, value: email);
      await _secureStorage.write(key: _storedPasswordKey, value: password);
      developer.log('🔐 Credentials stored securely', name: 'BiometricService');
      return true;
    } catch (e) {
      developer.log('❌ Failed to store credentials: $e', name: 'BiometricService');
      return false;
    }
  }

  /// Get stored credentials (only call after biometric authentication!)
  Future<Map<String, String>?> getStoredCredentials() async {
    try {
      final email = await _secureStorage.read(key: _storedEmailKey);
      final password = await _secureStorage.read(key: _storedPasswordKey);
      
      developer.log(
        '🔐 Retrieved credentials: email=${email != null ? "exists" : "null"}, password=${password != null ? "exists" : "null"}',
        name: 'BiometricService',
      );
      
      if (email != null && password != null && email.isNotEmpty && password.isNotEmpty) {
        return {'email': email, 'password': password};
      }
      return null;
    } catch (e) {
      developer.log('❌ Failed to get credentials: $e', name: 'BiometricService');
      return null;
    }
  }

  /// Check if credentials are stored
  Future<bool> hasStoredCredentials() async {
    try {
      final email = await _secureStorage.read(key: _storedEmailKey);
      final password = await _secureStorage.read(key: _storedPasswordKey);
      final hasCredentials = email != null && password != null && email.isNotEmpty && password.isNotEmpty;
      
      developer.log(
        '🔐 Has stored credentials: $hasCredentials',
        name: 'BiometricService',
      );
      
      return hasCredentials;
    } catch (e) {
      developer.log('❌ Error checking credentials: $e', name: 'BiometricService');
      return false;
    }
  }

  /// Clear stored credentials
  Future<void> clearStoredCredentials() async {
    try {
      await _secureStorage.delete(key: _storedEmailKey);
      await _secureStorage.delete(key: _storedPasswordKey);
      developer.log('🗑️ Stored credentials cleared', name: 'BiometricService');
    } catch (e) {
      developer.log('❌ Failed to clear credentials: $e', name: 'BiometricService');
    }
  }

  // ============ PREFERENCES ============

  /// Check if user has enabled biometric login
  Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_biometricEnabledKey) ?? false;
    developer.log('🔐 Biometric enabled in prefs: $enabled', name: 'BiometricService');
    return enabled;
  }

  /// Enable or disable biometric login
  Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricEnabledKey, enabled);
    
    developer.log(
      '🔐 Biometric ${enabled ? 'enabled' : 'disabled'}',
      name: 'BiometricService',
    );
  }

  /// Get the last logged in user's email
  Future<String?> getLastUserEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastUserEmailKey);
  }

  /// Save the last logged in user's email
  Future<void> setLastUserEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUserEmailKey, email);
  }

  /// Clear the last user email (on logout)
  Future<void> clearLastUserEmail() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastUserEmailKey);
  }

  /// Check if user has completed onboarding
  Future<bool> hasCompletedOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hasCompletedOnboardingKey) ?? false;
  }

  /// Mark onboarding as completed
  Future<void> setOnboardingCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasCompletedOnboardingKey, true);
    
    developer.log(
      '✅ Onboarding marked as completed',
      name: 'BiometricService',
    );
  }

  /// Check if "Remember Me" is enabled
  Future<bool> isRememberMeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rememberMeKey) ?? false;
  }

  /// Enable or disable "Remember Me"
  Future<void> setRememberMe(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberMeKey, enabled);
  }

  /// Clear all auth preferences (for complete logout)
  /// Set clearCredentials to true to also remove stored login credentials
  Future<void> clearAllPreferences({bool clearCredentials = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_biometricEnabledKey);
    await prefs.remove(_lastUserEmailKey);
    await prefs.remove(_rememberMeKey);
    // Note: We don't clear onboarding - user shouldn't see it again
    
    // Optionally clear stored credentials too
    if (clearCredentials) {
      await clearStoredCredentials();
    }
    
    developer.log(
      '🗑️ Auth preferences cleared (credentials: ${clearCredentials ? "cleared" : "kept"})',
      name: 'BiometricService',
    );
  }
  
  /// Full biometric login check - returns true if biometric login should be shown
  Future<bool> canUseBiometricLogin() async {
    final available = await isBiometricAvailable();
    final enabled = await isBiometricEnabled();
    final hasCredentials = await hasStoredCredentials();
    
    developer.log(
      '🔐 Can use biometric login: available=$available, enabled=$enabled, hasCredentials=$hasCredentials',
      name: 'BiometricService',
    );
    
    return available && enabled && hasCredentials;
  }
}