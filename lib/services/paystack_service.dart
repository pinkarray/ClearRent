import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../core/utils/app_logger.dart';

/// Centralized Paystack payment service for all ClearRent payments.
///
/// Handles:
/// - Verification fees (landlord ₦15k, tenant ₦5k, agent ₦10k)
/// - Inspection fees (variable)
/// - Listing fees (₦10k per additional property)
///
/// Uses Paystack Popup via in-app WebView for payment collection.
class PaystackService {
  static final PaystackService _instance = PaystackService._internal();
  factory PaystackService() => _instance;
  PaystackService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ── Keys ──────────────────────────────────────────────────────────
  // Test keys are only available in debug builds.
  // Live keys should be set here once Paystack account is activated.
  static const String _liveSecretKey = '';
  static const String _livePublicKey = '';

  static String get secretKey {
    if (_liveSecretKey.isNotEmpty) return _liveSecretKey;
    if (kDebugMode) return const String.fromEnvironment('PAYSTACK_TEST_SK', defaultValue: 'sk_test_dba926781692c2cd5e56e84244262448d6d46d2d');
    // In release mode with no live key → error state
    return '';
  }

  static String get publicKey {
    if (_livePublicKey.isNotEmpty) return _livePublicKey;
    if (kDebugMode) return const String.fromEnvironment('PAYSTACK_TEST_PK', defaultValue: 'pk_test_48c474c1121fb75f80baae6fde8a0dfa380716e6');
    return '';
  }

  String? get _currentUserId => _auth.currentUser?.uid;
  String? get _currentUserEmail => _auth.currentUser?.email;

  // ── Payment Types ─────────────────────────────────────────────────
  static const String typeVerification = 'verification';
  static const String typeInspection = 'inspection';
  static const String typeListing = 'listing';
  static const String typeRent = 'rent';

  /// Generate a unique payment reference
  String _generateReference(String type) {
    final uuid = const Uuid().v4().substring(0, 8);
    return 'CR_${type.toUpperCase()}_${DateTime.now().millisecondsSinceEpoch}_$uuid';
  }

  // ── Initialize Transaction ────────────────────────────────────────
  /// Initialize a Paystack transaction and return the authorization URL + reference.
  ///
  /// Amount is in Naira (e.g. 15000) — this method converts to kobo internally.
  Future<PaystackInitResult> initializeTransaction({
    required double amount,
    required String type,
    Map<String, dynamic>? metadata,
  }) async {
    AppLogger.i('initializeTransaction — amount: $amount, type: $type',
        name: 'PaystackService');
    try {
      if (secretKey.isEmpty) {
        return PaystackInitResult(
          success: false,
          error: 'Payment service not configured. Please contact support.',
        );
      }

      final email = _currentUserEmail;
      if (email == null || email.isEmpty) {
        return PaystackInitResult(
          success: false,
          error: 'User email not found. Please update your profile.',
        );
      }

      final reference = _generateReference(type);
      final amountInKobo = (amount * 100).toInt();

      final fullMetadata = {
        'userId': _currentUserId,
        'paymentType': type,
        'custom_fields': [
          {
            'display_name': 'Payment Type',
            'variable_name': 'payment_type',
            'value': type,
          },
          {
            'display_name': 'User ID',
            'variable_name': 'user_id',
            'value': _currentUserId,
          },
        ],
        ...?metadata,
      };

      final response = await http.post(
        Uri.parse('https://api.paystack.co/transaction/initialize'),
        headers: {
          'Authorization': 'Bearer $secretKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': email,
          'amount': amountInKobo,
          'reference': reference,
          'currency': 'NGN',
          'metadata': fullMetadata,
          'callback_url': 'https://verealtytech.com/payment/callback',
        }),
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        throw TimeoutException('Paystack request timed out');
      });

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['status'] == true) {
        final authorizationUrl = data['data']['authorization_url'] as String;
        final accessCode = data['data']['access_code'] as String;

        AppLogger.i('Transaction initialized: $reference',
            name: 'PaystackService');

        return PaystackInitResult(
          success: true,
          authorizationUrl: authorizationUrl,
          accessCode: accessCode,
          reference: reference,
        );
      } else {
        final message = data['message'] ?? 'Failed to initialize payment';
        AppLogger.e('Init failed: $message', name: 'PaystackService');
        return PaystackInitResult(success: false, error: message);
      }
    } catch (e) {
      AppLogger.e('Init error: $e', name: 'PaystackService', error: e);
      return PaystackInitResult(
        success: false,
        error: 'Network error. Please check your connection.',
      );
    }
  }

  /// Resolve account name using Paystack's Resolve Account API.
  /// Returns the account name if successful, null otherwise.
  Future<String?> resolveAccount({
    required String accountNumber,
    required String bankCode,
  }) async {
    try {
      final uri = Uri.parse(
        'https://api.paystack.co/bank/resolve'
        '?account_number=$accountNumber'
        '&bank_code=$bankCode',
      );

      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $secretKey',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == true && data['data'] != null) {
          return data['data']['account_name'] as String?;
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ Resolve account error: $e');
      return null;
    }
  }

  // ── Verify Transaction ────────────────────────────────────────────
  /// Verify a Paystack transaction by reference.
  Future<PaystackVerifyResult> verifyTransaction(String reference) async {
    try {
      final response = await http.get(
        Uri.parse('https://api.paystack.co/transaction/verify/$reference'),
        headers: {
          'Authorization': 'Bearer $secretKey',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        throw TimeoutException('Verification request timed out');
      });

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['status'] == true) {
        final txData = data['data'];
        final status = txData['status'] as String;
        final amountInKobo = txData['amount'] as int;
        final paidAt = txData['paid_at'] as String?;

        AppLogger.i(
          'Verify: $reference → $status (₦${amountInKobo / 100})',
          name: 'PaystackService',
        );

        return PaystackVerifyResult(
          success: status == 'success',
          status: status,
          reference: reference,
          amountPaid: amountInKobo / 100,
          paidAt: paidAt,
          gatewayResponse: txData['gateway_response'] as String? ?? '',
        );
      } else {
        return PaystackVerifyResult(
          success: false,
          status: 'failed',
          reference: reference,
          error: data['message'] ?? 'Verification failed',
        );
      }
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

      AppLogger.i('Payment recorded: $reference ($type, ₦$amount, $status)',
          name: 'PaystackService');
    } catch (e) {
      AppLogger.e('Failed to record payment: $e',
          name: 'PaystackService', error: e);
    }
  }

  // ── Refund ────────────────────────────────────────────────────────
  /// Initiate a refund for a transaction.
  /// NOTE: Requires Paystack live mode and approval.
  Future<bool> initiateRefund({
    required String reference,
    String? reason,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.paystack.co/refund'),
        headers: {
          'Authorization': 'Bearer $secretKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'transaction': reference,
          'merchant_note': reason ?? 'ClearRent refund',
        }),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['status'] == true) {
        AppLogger.i('Refund initiated for $reference',
            name: 'PaystackService');

        await _firestore.collection('payments').doc(reference).update({
          'status': 'refund_initiated',
          'refundReason': reason,
          'refundInitiatedAt': FieldValue.serverTimestamp(),
        });

        return true;
      } else {
        AppLogger.e('Refund failed: ${data['message']}',
            name: 'PaystackService');
        return false;
      }
    } catch (e) {
      AppLogger.e('Refund error: $e', name: 'PaystackService', error: e);
      return false;
    }
  }
}

// ── Result Models ─────────────────────────────────────────────────────

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