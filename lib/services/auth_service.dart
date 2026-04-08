import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
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

  // ============ PHONE AUTH ============

  // Static — must persist across AuthService instances (LoginScreen vs OtpScreen)
  static String? _verificationId;
  static int? _resendToken;

  String? get verificationId => _verificationId;

  /// Send OTP to phone number
  /// Returns a map with 'success' and optionally 'error' or 'verificationId'
  Future<PhoneAuthResult> sendOtp({
    required String phoneNumber,
    int? forceResendingToken,
  }) async {
    try {
      developer.log('📱 Sending OTP to $phoneNumber');

      final completer = PhoneAuthCompleter();

      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResendingToken ?? _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Auto-verification (e.g., on Android with SMS retriever)
          developer.log('✅ Phone auto-verified');
          completer.complete(PhoneAuthResult(
            success: true,
            autoVerified: true,
            credential: credential,
          ));
        },
        verificationFailed: (FirebaseAuthException e) {
          developer.log('❌ Phone verification failed: ${e.code} - ${e.message}');
          completer.complete(PhoneAuthResult(
            success: false,
            error: _getPhoneErrorMessage(e.code),
          ));
        },
        codeSent: (String verificationId, int? resendToken) {
          developer.log('📨 OTP code sent. verificationId: $verificationId');
          _verificationId = verificationId;
          _resendToken = resendToken;
          completer.complete(PhoneAuthResult(
            success: true,
            verificationId: verificationId,
          ));
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          developer.log('⏱️ Auto-retrieval timeout. verificationId: $verificationId');
          _verificationId = verificationId;
          // Don't complete here — codeSent already did
        },
      );

      return await completer.future;
    } catch (e) {
      developer.log('❌ sendOtp error: $e');
      return PhoneAuthResult(
        success: false,
        error: 'Failed to send verification code. Please try again.',
      );
    }
  }

  /// Verify OTP code and in
  Future<AuthResult> verifyOtpAndSignIn(String smsCode) async {
    try {
      if (_verificationId == null) {
        return AuthResult(
          success: false,
          error: 'Verification session expired. Please request a new code.',
        );
      }

      developer.log('🔑 Verifying OTP code...');

      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode,
      );

      final userCredential = await _auth.signInWithCredential(credential);
      final user = userCredential.user;
      final isNew = userCredential.additionalUserInfo?.isNewUser ?? false;

      developer.log('✅ Phone sign-in successful. uid=${user?.uid}, isNew=$isNew');

      // Check if user has completed profile
      bool hasProfile = false;
      if (user != null && !isNew) {
        hasProfile = await _checkUserProfile(user.uid);
      }

      return AuthResult(
        success: true,
        user: user,
        isNewUser: isNew,
        hasCompletedProfile: hasProfile,
      );
    } on FirebaseAuthException catch (e) {
      developer.log('❌ OTP verification failed: ${e.code} - ${e.message}');
      return AuthResult(
        success: false,
        error: _getPhoneErrorMessage(e.code),
      );
    } catch (e) {
      developer.log('❌ OTP verification error: $e');
      return AuthResult(
        success: false,
        error: 'Verification failed. Please try again.',
      );
    }
  }

  /// Verify OTP and link phone to current (email/password) account
  Future<AuthResult> verifyOtpAndLinkPhone(String smsCode) async {
    try {
      if (_verificationId == null) {
        return AuthResult(
          success: false,
          error: 'Verification session expired. Please request a new code.',
        );
      }

      if (currentUser == null) {
        return AuthResult(
          success: false,
          error: 'No user signed in. Please sign in first.',
        );
      }

      developer.log('🔗 Linking phone to existing account...');

      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode,
      );

      await currentUser!.linkWithCredential(credential);

      // Update Firestore with phone number
      final phone = currentUser!.phoneNumber;
      if (phone != null) {
        await _firestore.collection('users').doc(currentUser!.uid).update({
          'phone': phone,
          'phoneVerified': true,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Phone linked successfully');

      return AuthResult(success: true, user: currentUser);
    } on FirebaseAuthException catch (e) {
      developer.log('❌ Phone link failed: ${e.code} - ${e.message}');
      
      // Handle "already linked" case
      if (e.code == 'credential-already-in-use') {
        return AuthResult(
          success: false,
          error: 'This phone number is already linked to another account.',
        );
      }
      
      return AuthResult(
        success: false,
        error: _getPhoneErrorMessage(e.code),
      );
    } catch (e) {
      developer.log('❌ Phone link error: $e');
      return AuthResult(
        success: false,
        error: 'Failed to link phone number. Please try again.',
      );
    }
  }

  /// Auto-sign-in with credential (for auto-verified phones)
  Future<AuthResult> signInWithCredential(PhoneAuthCredential credential) async {
    try {
      final userCredential = await _auth.signInWithCredential(credential);
      final user = userCredential.user;
      final isNew = userCredential.additionalUserInfo?.isNewUser ?? false;

      bool hasProfile = false;
      if (user != null && !isNew) {
        hasProfile = await _checkUserProfile(user.uid);
      }

      return AuthResult(
        success: true,
        user: user,
        isNewUser: isNew,
        hasCompletedProfile: hasProfile,
      );
    } catch (e) {
      developer.log('❌ Credential sign-in error: $e');
      return AuthResult(
        success: false,
        error: 'Sign in failed. Please try again.',
      );
    }
  }

  // ============ EMAIL LINKING (for phone-primary accounts) ============

  /// Link email + password to the current phone-auth account.
  /// This gives the user a second way to sign in and enables biometric login.
  /// Call this during profile setup after phone OTP sign-in.
  Future<AuthResult> linkEmailToPhoneAccount({
    required String email,
    required String password,
  }) async {
    try {
      if (currentUser == null) {
        return AuthResult(
          success: false,
          error: 'No user signed in. Please sign in first.',
        );
      }

      developer.log('🔗 Linking email $email to phone account (uid=${currentUser!.uid})...');

      final credential = EmailAuthProvider.credential(
        email: email,
        password: password,
      );

      await currentUser!.linkWithCredential(credential);

      // Send verification email in background
      try {
        await currentUser!.sendEmailVerification();
        developer.log('📧 Verification email sent to $email');
      } catch (e) {
        developer.log('⚠️ Failed to send verification email: $e');
      }

      developer.log('✅ Email linked successfully to uid=${currentUser!.uid}');

      return AuthResult(success: true, user: currentUser);
    } on FirebaseAuthException catch (e) {
      developer.log('❌ Email link failed: ${e.code} - ${e.message}');

      if (e.code == 'email-already-in-use') {
        return AuthResult(
          success: false,
          error: 'This email is already registered to another account. Please use a different email.',
        );
      }
      if (e.code == 'provider-already-linked') {
        // Already has email linked — that's fine, treat as success
        developer.log('ℹ️ Email provider already linked — continuing');
        return AuthResult(success: true, user: currentUser);
      }
      if (e.code == 'invalid-email') {
        return AuthResult(
          success: false,
          error: 'Please enter a valid email address.',
        );
      }
      if (e.code == 'weak-password') {
        return AuthResult(
          success: false,
          error: 'Password is too weak. Please use at least 6 characters.',
        );
      }
      if (e.code == 'requires-recent-login') {
        return AuthResult(
          success: false,
          error: 'Your session has expired. Please sign in again.',
        );
      }

      return AuthResult(
        success: false,
        error: _getErrorMessage(e.code),
      );
    } catch (e) {
      developer.log('❌ Email link error: $e');
      return AuthResult(
        success: false,
        error: 'Failed to link email. Please try again.',
      );
    }
  }

  String _getPhoneErrorMessage(String code) {
    switch (code) {
      case 'invalid-phone-number':
        return 'Invalid phone number. Please check and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'invalid-verification-code':
        return 'Invalid verification code. Please check and try again.';
      case 'session-expired':
        return 'Verification session expired. Please request a new code.';
      case 'quota-exceeded':
        return 'SMS quota exceeded. Please try again later.';
      case 'credential-already-in-use':
        return 'This phone number is already linked to another account.';
      case 'provider-already-linked':
        return 'A phone number is already linked to this account.';
      default:
        return 'Phone verification failed. Please try again.';
    }
  }

  // ============ EMAIL/PASSWORD AUTH ============

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
    // Tenant-specific fields
    String? occupation,
    String? employer,
    String? workMode,
    String? workplaceArea,
    String? incomeRange,
    double? budgetMin,
    double? budgetMax,
    List<String>? preferredAreas,
    String? maritalStatus,
  }) async {
    try {
      if (currentUser == null) {
        developer.log('❌ saveUserProfile: No current user', name: 'AuthService');
        return false;
      }

      final data = <String, dynamic>{
        'uid': currentUser!.uid,
        'fullName': fullName,
        'fullNameLower': fullName.toLowerCase(), // for tenant name search
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

      // If user signed in with phone, store the phone number
      if (currentUser!.phoneNumber != null && currentUser!.phoneNumber!.isNotEmpty) {
        data['phone'] = currentUser!.phoneNumber;
        data['phoneVerified'] = true;
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

      // Rating fields for landlords (agents have them above)
      if (accountType == 'landlord') {
        data.putIfAbsent('rating', () => 0.0);
        data.putIfAbsent('totalRatings', () => 0);
      }

      // Add tenant-specific fields
      if (accountType == 'tenant') {
        if (occupation != null && occupation.isNotEmpty) {
          data['occupation'] = occupation;
        }
        if (employer != null && employer.isNotEmpty) {
          data['employer'] = employer;
        }
        if (workMode != null && workMode.isNotEmpty) {
          data['workMode'] = workMode;
        }
        if (workplaceArea != null && workplaceArea.isNotEmpty) {
          data['workplaceArea'] = workplaceArea;
        }
        if (incomeRange != null && incomeRange.isNotEmpty) {
          data['incomeRange'] = incomeRange;
        }
        if (budgetMin != null && budgetMin > 0) {
          data['budgetMin'] = budgetMin;
        }
        if (budgetMax != null && budgetMax > 0) {
          data['budgetMax'] = budgetMax;
        }
        if (preferredAreas != null && preferredAreas.isNotEmpty) {
          data['preferredAreas'] = preferredAreas;
        }
        if (maritalStatus != null && maritalStatus.isNotEmpty) {
          data['maritalStatus'] = maritalStatus;
        }
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
      _verificationId = null;
      _resendToken = null;
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

  /// Sign in using phone number + password.
  /// Looks up the user's email from Firestore by phone, then signs in with email+password.
  Future<AuthResult> signInWithPhone({
    required String phoneNumber,
    required String password,
  }) async {
    try {
      developer.log('📱 Looking up email for phone: $phoneNumber', name: 'AuthService');

      // Query Firestore for user with this phone number
      final query = await _firestore
          .collection('users')
          .where('phone', isEqualTo: phoneNumber)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        return AuthResult(
          success: false,
          error: 'No account found with this phone number. Please sign up.',
        );
      }

      final email = query.docs.first.data()['email'] as String?;
      if (email == null || email.isEmpty) {
        return AuthResult(
          success: false,
          error: 'No email linked to this account. Please contact support.',
        );
      }

      developer.log('✅ Found email: $email, signing in...', name: 'AuthService');

      // Sign in with the looked-up email + provided password
      return await signIn(email: email, password: password);
    } catch (e) {
      developer.log(
        '❌ Phone sign-in error: $e',
        name: 'AuthService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return AuthResult(
        success: false,
        error: 'Sign in failed. Please try again.',
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

// Result class for phone auth operations
class PhoneAuthResult {
  final bool success;
  final String? error;
  final String? verificationId;
  final bool autoVerified;
  final PhoneAuthCredential? credential;

  PhoneAuthResult({
    required this.success,
    this.error,
    this.verificationId,
    this.autoVerified = false,
    this.credential,
  });
}

/// Helper to handle the async callback pattern of verifyPhoneNumber
class PhoneAuthCompleter {
  final _completer = Completer<PhoneAuthResult>();
  bool _completed = false;

  void complete(PhoneAuthResult result) {
    if (_completed) return; // Only complete once
    _completed = true;
    _completer.complete(result);
  }

  Future<PhoneAuthResult> get future => _completer.future;
}