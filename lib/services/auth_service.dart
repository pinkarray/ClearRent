import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import 'dart:io';
import 'property_service.dart';

class AuthService {
  // Use singleton instances directly - Firebase is already initialized in main.dart
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final PropertyService _propertyService = PropertyService();

  // Get current user - now always works since we use FirebaseAuth.instance directly
  User? get currentUser => _auth.currentUser;

  String? get currentUserId => _auth.currentUser?.uid;

  // Check if user is logged in
  bool get isLoggedIn => currentUser != null;

  // Check if email is verified
  bool get isEmailVerified => currentUser?.emailVerified ?? false;

  // Auth state changes stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Sign up with email and password
  Future<AuthResult> signUp({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Send verification email in background (don't wait)
      _sendVerificationEmail();

      return AuthResult(success: true, user: credential.user, isNewUser: true);
    } on FirebaseAuthException catch (e) {
      return AuthResult(success: false, error: _getErrorMessage(e.code));
    } catch (e) {
      developer.log(
        '❌ Sign up error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return AuthResult(
        success: false,
        error: 'An unexpected error occurred. Please try again.',
      );
    }
  }

  // Sign in with email and password
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Check if user has completed profile setup
      final hasProfile = await _checkUserProfile(credential.user!.uid);

      return AuthResult(
        success: true,
        user: credential.user,
        isNewUser: false,
        hasCompletedProfile: hasProfile,
      );
    } on FirebaseAuthException catch (e) {
      return AuthResult(success: false, error: _getErrorMessage(e.code));
    } catch (e) {
      developer.log(
        '❌ Sign in error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return AuthResult(
        success: false,
        error: 'An unexpected error occurred. Please try again.',
      );
    }
  }

  // Send verification email
  Future<void> _sendVerificationEmail() async {
    try {
      await currentUser?.sendEmailVerification();
      developer.log('✅ Verification email sent', name: 'AuthService');
    } catch (e) {
      developer.log(
        '⚠️ Failed to send verification email: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  // Resend verification email (for manual trigger)
  Future<bool> resendVerificationEmail() async {
    try {
      await currentUser?.sendEmailVerification();
      return true;
    } catch (e) {
      developer.log(
        '❌ Resend verification error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // Check if user has completed profile in Firestore
  Future<bool> _checkUserProfile(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      return doc.exists && doc.data()?['profileCompleted'] == true;
    } catch (e) {
      developer.log(
        '⚠️ Check profile error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // Get user profile from Firestore
  Future<Map<String, dynamic>?> getUserProfile() async {
    try {
      if (currentUser == null) {
        developer.log('⚠️ getUserProfile: No current user', name: 'AuthService');
        return null;
      }

      final doc = await _firestore.collection('users').doc(currentUser!.uid).get();
      return doc.data();
    } catch (e) {
      developer.log(
        '❌ Get profile error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return null;
    }
  }

  // Save user profile to Firestore
  Future<bool> saveUserProfile({
    required String fullName,
    required String email,
    required String accountType,
    String? bvn,
    String? phone,
    // Agent-specific fields
    String? baseLocation,
    List<String>? serviceAreas,
  }) async {
    try {
      if (currentUser == null) {
        developer.log('❌ saveUserProfile: No current user', name: 'AuthService');
        return false;
      }

      final data = <String, dynamic>{
        'uid': currentUser!.uid,
        'fullName': fullName,
        'email': email,
        'accountType': accountType,
        'bvn': bvn,
        'profileCompleted': true,
        'emailVerified': currentUser!.emailVerified,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Add phone for landlords and agents
      if (phone != null && phone.isNotEmpty) {
        data['phone'] = phone;
      }

      // Add agent-specific fields
      if (accountType == 'agent') {
        if (baseLocation != null && baseLocation.isNotEmpty) {
          data['baseLocation'] = baseLocation;
        }
        if (serviceAreas != null && serviceAreas.isNotEmpty) {
          data['serviceAreas'] = serviceAreas;
        }
        // Agent starts unverified - admin will verify later
        data['isVerified'] = false;
        data['rating'] = 0.0;
        data['totalInspections'] = 0;
        data['totalRatings'] = 0;
      }

      await _firestore
          .collection('users')
          .doc(currentUser!.uid)
          .set(data, SetOptions(merge: true));

      developer.log('✅ Profile saved successfully', name: 'AuthService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to save user profile: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // Update account type
  Future<bool> updateAccountType(String accountType) async {
    try {
      if (currentUser == null) {
        return false;
      }

      await _firestore.collection('users').doc(currentUser!.uid).set({
        'accountType': accountType,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      developer.log(
        '❌ Update account type error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // Update specific profile fields
  Future<bool> updateUserProfile(Map<String, dynamic> updates) async {
    try {
      if (currentUser == null) {
        return false;
      }

      updates['updatedAt'] = FieldValue.serverTimestamp();

      await _firestore
          .collection('users')
          .doc(currentUser!.uid)
          .update(updates);

      developer.log('✅ Profile updated successfully', name: 'AuthService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to update profile: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  Future<String?> uploadProfileImage(File imageFile) async {
    try {
      if (currentUser == null) {
        developer.log('❌ uploadProfileImage: No current user', name: 'AuthService');
        return null;
      }

      developer.log('📤 Uploading profile image...', name: 'AuthService');

      final imageUrl = await _propertyService.uploadImage(imageFile);

      if (imageUrl == null || imageUrl.isEmpty) {
        developer.log('❌ Profile image upload returned null', name: 'AuthService');
        return null;
      }

      await _firestore.collection('users').doc(currentUser!.uid).update({
        'profileImageUrl': imageUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Profile image uploaded: $imageUrl', name: 'AuthService');
      return imageUrl;
    } catch (e) {
      developer.log('❌ Profile image upload failed: $e', name: 'AuthService', error: e);
      return null;
    }
  }

  /// Get profile image URL for any user by their ID.
  Future<String?> getUserProfileImageUrl(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.data()?['profileImageUrl'];
    } catch (e) {
      developer.log('❌ Error getting user profile image: $e', name: 'AuthService');
      return null;
    }
  }

  /// Remove profile image
  Future<bool> removeProfileImage() async {
    try {
      if (currentUser == null) return false;

      await _firestore.collection('users').doc(currentUser!.uid).update({
        'profileImageUrl': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Profile image removed', name: 'AuthService');
      return true;
    } catch (e) {
      developer.log('❌ Error removing profile image: $e', name: 'AuthService', error: e);
      return false;
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      developer.log('✅ Signed out successfully', name: 'AuthService');
    } catch (e) {
      developer.log(
        '❌ Sign out error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  // Password reset
  Future<bool> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      developer.log('✅ Password reset email sent', name: 'AuthService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Password reset error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // Convert Firebase error codes to user-friendly messages
  String _getErrorMessage(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'This email is already registered. Please sign in instead.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled.';
      case 'weak-password':
        return 'Password is too weak. Please use at least 6 characters.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
        return 'No account found with this email. Please sign up.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-credential':
        return 'Invalid email or password. Please try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      default:
        return 'An error occurred. Please try again.';
    }
  }
}

// Result class for auth operations
class AuthResult {
  final bool success;
  final User? user;
  final String? error;
  final bool isNewUser;
  final bool hasCompletedProfile;

  AuthResult({
    required this.success,
    this.user,
    this.error,
    this.isNewUser = false,
    this.hasCompletedProfile = false,
  });
}