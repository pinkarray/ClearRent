import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/utils/app_logger.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Centralized Paystack payment service for all ClearRent payments.
///
/// Handles:
/// - Verification fees (landlord ₦15k, tenant ₦5k, agent ₦10k)
/// - Inspection fees (variable)
/// - Listing fees (₦10k per additional property)
///
/// Uses Paystack Popup via in-app WebView for payment collection.
///
/// The Paystack SECRET key never touches the client. `initializeTransaction`,
/// `verifyTransaction`, and `initiateRefund` call the `initializePayment`,
/// `verifyPayment`, and `refundPayment` Cloud Functions, which hold the secret
/// in Secret Manager. The public key remains client-side (it is public).
class PaystackService {
  static final PaystackService _instance = PaystackService._internal();
  factory PaystackService() => _instance;
  PaystackService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  // ── Keys ──────────────────────────────────────────────────────────
  // Only the PUBLIC key lives client-side. The secret key was removed and
  // now lives in Secret Manager, used exclusively by the Paystack Cloud
  // Functions. Set the live public key here once Paystack is activated.
  static const String _livePublicKey = '';

  static String get publicKey {
    if (_livePublicKey.isNotEmpty) return _livePublicKey;
    if (kDebugMode) {
      return const String.fromEnvironment('PAYSTACK_TEST_PK',
          defaultValue: 'pk_test_48c474c1121fb75f80baae6fde8a0dfa380716e6');
    }
    return '';
  }

  String? get _currentUserId => _auth.currentUser?.uid;
  String? get _currentUserEmail => _auth.currentUser?.email;

  // ── Payment Types ─────────────────────────────────────────────────
  static const String typeVerification = 'verification';
  static const String typeInspection = 'inspection';
  static const String typeListing = 'listing';
  static const String typeRent = 'rent';
  static const String typeRenewal = 'renewal';

  /// Redact a payment reference for release-build logs.
  /// Returns the full reference in debug builds, first 8 chars + ellipsis in release.
  /// Partial prefix is enough to trace via Firestore lookup without leaking the full token.
  String _redactRef(String ref) {
    if (kDebugMode) return ref;
    return ref.length > 8 ? '${ref.substring(0, 8)}…' : ref;
  }

  // ── Initialize Transaction ────────────────────────────────────────
  /// Initialize a Paystack transaction via the `initializePayment` Cloud
  /// Function and return the authorization URL + reference.
  ///
  /// Amount is in Naira (e.g. 15000) — the function converts to kobo. The
  /// reference is generated server-side. `metadata` is merged into the
  /// Paystack metadata exactly as before.
  Future<PaystackInitResult> initializeTransaction({
    required double amount,
    required String type,
    Map<String, dynamic>? metadata,
  }) async {
    AppLogger.i('initializeTransaction — amount: $amount, type: $type',
        name: 'PaystackService');
    try {
      // Email presence is enforced server-side too; this is a fast local
      // guard that preserves the previous user-facing message.
      final email = _currentUserEmail;
      if (email == null || email.isEmpty) {
        return PaystackInitResult(
          success: false,
          error: 'User email not found. Please update your profile.',
        );
      }

      final callable = _functions.httpsCallable('initializePayment');
      final result = await callable.call<Map<String, dynamic>>({
        'amount': amount,
        'type': type,
        if (metadata != null) 'metadata': metadata,
      });

      final authorizationUrl = result.data['authorizationUrl'] as String?;
      final reference = result.data['reference'] as String?;
      final accessCode = result.data['accessCode'] as String?;

      if (authorizationUrl == null || reference == null) {
        AppLogger.e('Init returned no authorization URL/reference',
            name: 'PaystackService');
        return PaystackInitResult(
          success: false,
          error: 'Failed to initialize payment. Please try again.',
        );
      }

      AppLogger.i('Transaction initialized: ${_redactRef(reference)}',
          name: 'PaystackService');

      return PaystackInitResult(
        success: true,
        authorizationUrl: authorizationUrl,
        accessCode: accessCode,
        reference: reference,
      );
    } on FirebaseFunctionsException catch (e) {
      AppLogger.e('Init failed: ${e.code} — ${e.message}',
          name: 'PaystackService');
      return PaystackInitResult(
        success: false,
        error: _callableErrorMessage(
          e,
          fallback: 'Failed to initialize payment. Please try again.',
        ),
      );
    } catch (e) {
      AppLogger.e('Init error: $e', name: 'PaystackService', error: e);
      return PaystackInitResult(
        success: false,
        error: 'Network error. Please check your connection.',
      );
    }
  }

  /// Resolve account name via the `resolveAccount` Cloud Function,
  /// which proxies Paystack server-side.
  ///
  /// Returns an [AccountResolution]: the account name on success, or a
  /// user-facing message whose wording matches the *actual* cause — an
  /// App Check / auth rejection reads differently from a genuine
  /// "account not found" or a connectivity failure, so the UI never
  /// mislabels one as the other.
  Future<AccountResolution> resolveAccount({
    required String accountNumber,
    required String bankCode,
  }) async {
    try {
      final callable = _functions.httpsCallable('resolveAccount');
      final result = await callable.call<Map<String, dynamic>>({
        'accountNumber': accountNumber,
        'bankCode': bankCode,
      });
      final name = result.data['accountName'];
      if (name is String && name.isNotEmpty) {
        return AccountResolution.success(name);
      }
      // The function returns not-found rather than an empty name, so this
      // is a defensive fallback only.
      return AccountResolution.error(
        'Account name could not be resolved. Check the details and try again.',
      );
    } on FirebaseFunctionsException catch (e) {
      AppLogger.w(
        'Resolve account failed: ${e.code} — ${e.message}',
        name: 'PaystackService',
      );
      return AccountResolution.error(_resolveErrorMessage(e));
    } catch (e) {
      AppLogger.e(
        'Unexpected error in resolveAccount',
        error: e,
        name: 'PaystackService',
      );
      return AccountResolution.error(
        'Network error. Check your connection and try again.',
      );
    }
  }

  /// Map a callable failure code to a message that reflects the real cause.
  ///
  /// `unauthenticated` covers both a missing sign-in and a rejected App
  /// Check token (e.g. an unregistered debug device, or a release build
  /// whose Play Integrity attestation failed) — both mean "we couldn't
  /// verify this request", which is distinct from the account not existing.
  String _resolveErrorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return "Couldn't verify this request. Please try again, or enter "
            'the account name manually.';
      case 'not-found':
        return 'Account not found. Check the account number and bank.';
      case 'invalid-argument':
        return 'Enter a valid 10-digit account number and select a bank.';
      case 'resource-exhausted':
        // Paystack rate-limited the lookup — not an outage, just throttled.
        return 'Too many lookups in a short time. '
            'Please wait a moment and try again.';
      case 'unavailable':
      case 'internal':
        return 'The bank service is unavailable right now. Please try again.';
      default:
        return "Couldn't resolve the account name. Please try again.";
    }
  }

  /// Shared mapping for the App-Check-enforced payment callables. Overrides
  /// the codes whose default/framework message would mislead — notably
  /// `unauthenticated`, which is what an App Check rejection surfaces as and
  /// must never read as a network error. For other codes it prefers the
  /// server-provided message (the CFs set useful ones, e.g. missing email),
  /// falling back to [fallback].
  String _callableErrorMessage(
    FirebaseFunctionsException e, {
    required String fallback,
  }) {
    switch (e.code) {
      case 'unauthenticated':
        return "Couldn't verify this request. Please try again.";
      case 'resource-exhausted':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'unavailable':
        return 'The payment service is temporarily unavailable. '
            'Please try again.';
      default:
        final msg = e.message;
        return (msg != null && msg.isNotEmpty) ? msg : fallback;
    }
  }

  // ── Verify Transaction ────────────────────────────────────────────
  /// Verify a Paystack transaction by reference via the `verifyPayment`
  /// Cloud Function.
  Future<PaystackVerifyResult> verifyTransaction(String reference) async {
    try {
      final callable = _functions.httpsCallable('verifyPayment');
      final result = await callable.call<Map<String, dynamic>>({
        'reference': reference,
      });

      final data = result.data;
      final success = data['success'] == true;
      final status = data['status'] as String? ?? 'failed';
      final amountPaid = (data['amountPaid'] as num?)?.toDouble();
      final paidAt = data['paidAt'] as String?;
      final gatewayResponse = data['gatewayResponse'] as String? ?? '';
      final error = data['error'] as String?;

      AppLogger.i(
        'Verify: ${_redactRef(reference)} → $status'
        '${amountPaid != null ? ' (₦$amountPaid)' : ''}',
        name: 'PaystackService',
      );

      return PaystackVerifyResult(
        success: success,
        status: status,
        reference: reference,
        amountPaid: amountPaid,
        paidAt: paidAt,
        gatewayResponse: gatewayResponse,
        error: error,
      );
    } on FirebaseFunctionsException catch (e) {
      AppLogger.e('Verify failed: ${e.code} — ${e.message}',
          name: 'PaystackService');
      return PaystackVerifyResult(
        success: false,
        status: 'error',
        reference: reference,
        error: _callableErrorMessage(
          e,
          fallback: 'Verification failed. Please try again.',
        ),
      );
    } catch (e) {
      AppLogger.e('Verify error: $e', name: 'PaystackService', error: e);
      return PaystackVerifyResult(
        success: false,
        status: 'error',
        reference: reference,
        error: 'Network error during verification',
      );
    }
  }

  // ── Record Payment in Firestore ───────────────────────────────────
  /// Save a payment record to Firestore for tracking and admin review.
  Future<void> recordPayment({
    required String reference,
    required String type,
    required double amount,
    required String status,
    String? relatedId,
    Map<String, dynamic>? extra,
  }) async {
    try {
      await _firestore.collection('payments').doc(reference).set({
        'reference': reference,
        'userId': _currentUserId,
        'userEmail': _currentUserEmail,
        'type': type,
        'amount': amount,
        'status': status,
        'relatedId': relatedId,
        'createdAt': FieldValue.serverTimestamp(),
        ...?extra,
      });

      AppLogger.i('Payment recorded: ${_redactRef(reference)} ($type, ₦$amount, $status)',
          name: 'PaystackService');
    } catch (e) {
      AppLogger.e('Failed to record payment: $e',
          name: 'PaystackService', error: e);
    }
  }

  // ── Refund ────────────────────────────────────────────────────────
  /// Initiate a refund for a transaction via the `refundPayment` Cloud
  /// Function.
  /// NOTE: Requires Paystack live mode and approval.
  Future<bool> initiateRefund({
    required String reference,
    String? reason,
  }) async {
    try {
      final callable = _functions.httpsCallable('refundPayment');
      final result = await callable.call<Map<String, dynamic>>({
        'reference': reference,
        if (reason != null) 'reason': reason,
      });

      if (result.data['success'] == true) {
        AppLogger.i('Refund initiated for ${_redactRef(reference)}',
            name: 'PaystackService');

        await _firestore.collection('payments').doc(reference).update({
          'status': 'refund_initiated',
          'refundReason': reason,
          'refundInitiatedAt': FieldValue.serverTimestamp(),
        });

        return true;
      } else {
        AppLogger.e('Refund failed: ${result.data['error']}',
            name: 'PaystackService');
        return false;
      }
    } on FirebaseFunctionsException catch (e) {
      AppLogger.e('Refund failed: ${e.code} — ${e.message}',
          name: 'PaystackService');
      return false;
    } catch (e) {
      AppLogger.e('Refund error: $e', name: 'PaystackService', error: e);
      return false;
    }
  }
}

// ── Result Models ─────────────────────────────────────────────────────

/// Outcome of a bank account-name lookup. Either [accountName] is set
/// (success) or [error] holds a user-facing message describing the actual
/// failure cause.
class AccountResolution {
  final String? accountName;
  final String? error;

  const AccountResolution._(this.accountName, this.error);

  factory AccountResolution.success(String name) =>
      AccountResolution._(name, null);
  factory AccountResolution.error(String message) =>
      AccountResolution._(null, message);

  bool get ok => accountName != null;
}

class PaystackInitResult {
  final bool success;
  final String? authorizationUrl;
  final String? accessCode;
  final String? reference;
  final String? error;

  PaystackInitResult({
    required this.success,
    this.authorizationUrl,
    this.accessCode,
    this.reference,
    this.error,
  });
}

class PaystackVerifyResult {
  final bool success;
  final String status;
  final String reference;
  final double? amountPaid;
  final String? paidAt;
  final String? gatewayResponse;
  final String? error;

  PaystackVerifyResult({
    required this.success,
    required this.status,
    required this.reference,
    this.amountPaid,
    this.paidAt,
    this.gatewayResponse,
    this.error,
  });
}