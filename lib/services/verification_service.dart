import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:developer' as developer;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/utils/phone_utils.dart';


enum VerificationStatus { none, pending, verified, rejected, expired }

// Verification fee structure
class VerificationFees {
  static const double landlordFee = 12000;
  static const double tenantFee = 3000;
  static const double agentFee = 7000;

  static double getFee(String accountType) {
    switch (accountType) {
      case 'landlord': return landlordFee;
      case 'tenant': return tenantFee;
      case 'agent': return agentFee;
      default: return 0;
    }
  }

  static String getFeeLabel(String accountType) {
    switch (accountType) {
      case 'landlord': return '₦12,000';
      case 'tenant': return '₦3,000';
      case 'agent': return '₦7,000';
      default: return '₦0';
    }
  }
}

// Document model for all user types
class VerificationDocument {
  final String? ninUrl;
  final String? propertyDocUrl;
  final String? utilityBillUrl;
  // Tenant specific
  final String? proofOfIncomeUrl;
  // Agent specific
  final String? proofOfAddressUrl;
  final String? guarantorIdUrl;
  final String? experienceProofUrl;

  VerificationDocument({
    this.ninUrl,
    this.propertyDocUrl,
    this.utilityBillUrl,
    this.proofOfIncomeUrl,
    this.proofOfAddressUrl,
    this.guarantorIdUrl,
    this.experienceProofUrl,
  });

  factory VerificationDocument.fromMap(Map<String, dynamic>? map) {
    if (map == null) return VerificationDocument();
    return VerificationDocument(
      ninUrl: map['nin'] ?? map['ninUrl'],
      propertyDocUrl: map['propertyDoc'] ?? map['propertyDocUrl'],
      utilityBillUrl: map['utilityBill'] ?? map['utilityBillUrl'],
      proofOfIncomeUrl: map['proofOfIncome'] ?? map['proofOfIncomeUrl'],
      proofOfAddressUrl: map['proofOfAddress'] ?? map['proofOfAddressUrl'],
      guarantorIdUrl: map['guarantorId'] ?? map['guarantorIdUrl'],
      experienceProofUrl: map['experienceProof'] ?? map['experienceProofUrl'],
    );
  }
}

class VerificationData {
  final VerificationStatus status;
  final VerificationDocument documents;
  final bool isVerified;
  // True once the user has submitted an annual renewal. Persisted so the
  // renewal shape (role proof only, no NIN) survives the status moving on to
  // pending/rejected — a rejected renewal is still a renewal.
  final bool isRenewal;
  /// When the current verification lapses. Written server-side by the
  /// onVerificationVerified trigger; null for records verified before the
  /// annual clock shipped (the sweep backfills those).
  final DateTime? expiresAt;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;
  final String? accountType;
  // Agent guarantor info
  final String? guarantorName;
  final String? guarantorPhone;
  final String? guarantorAddress;
  // Payment
  final String? paymentReference;
  final double paymentAmount;
  final String? paymentStatus;
  // Legacy field — kept for backward compat with old records
  final String? paymentProofUrl;

  VerificationData({
    this.status = VerificationStatus.none,
    this.isVerified = false,
    this.isRenewal = false,
    this.expiresAt,
    VerificationDocument? documents,
    this.submittedAt,
    this.reviewedAt,
    this.rejectionReason,
    this.accountType,
    this.guarantorName,
    this.guarantorPhone,
    this.guarantorAddress,
    this.paymentReference,
    this.paymentAmount = 0,
    this.paymentStatus,
    this.paymentProofUrl,
  }) : documents = documents ?? VerificationDocument();

  factory VerificationData.fromMap(Map<String, dynamic>? map) {
    if (map == null) return VerificationData();
    return VerificationData(
      status: _parseStatus(map['verificationStatus']),
      isVerified: map['isVerified'] == true,
      isRenewal: map['isRenewal'] == true,
      expiresAt: (map['verificationExpiresAt'] as Timestamp?)?.toDate(),
      documents: VerificationDocument.fromMap(map['verificationDocs'] ?? map),
      submittedAt: (map['verificationSubmittedAt'] as Timestamp?)?.toDate(),
      reviewedAt: (map['verificationReviewedAt'] as Timestamp?)?.toDate(),
      rejectionReason: map['rejectionReason'],
      accountType: map['accountType'],
      guarantorName: map['guarantorName'],
      guarantorPhone: map['guarantorPhone'],
      guarantorAddress: map['guarantorAddress'],
      paymentReference: map['verificationPaymentReference'],
      paymentAmount: (map['verificationPaymentAmount'] ?? 0).toDouble(),
      paymentStatus: map['verificationPaymentStatus'],
      paymentProofUrl: map['verificationPaymentProofUrl'],
    );
  }

  static VerificationStatus _parseStatus(String? status) {
    switch (status) {
      case 'pending': return VerificationStatus.pending;
      case 'verified': return VerificationStatus.verified;
      case 'rejected': return VerificationStatus.rejected;
      case 'expired': return VerificationStatus.expired;
      default: return VerificationStatus.none;
    }
  }

  bool get hasExperienceProof => documents.experienceProofUrl != null;
}

class VerificationResult {
  final bool success;
  final String? message;
  final String? error;

  VerificationResult({required this.success, this.message, this.error});
}

class PendingVerification {
  final String uid;
  final String requestId;
  final String fullName;
  final String email;
  final String phone;
  final String userType;
  final VerificationDocument documents;
  final DateTime? submittedAt;
  // Agent guarantor info
  final String? guarantorName;
  final String? guarantorPhone;
  final String? guarantorAddress;
  // Payment
  final String? paymentReference;
  final double? paymentAmount;
  final String? paymentStatus;
  // Legacy
  final String? paymentProofUrl;

  PendingVerification({
    required this.uid,
    required this.requestId,
    required this.fullName,
    required this.email,
    this.phone = '',
    required this.userType,
    required this.documents,
    this.submittedAt,
    this.guarantorName,
    this.guarantorPhone,
    this.guarantorAddress,
    this.paymentReference,
    this.paymentAmount,
    this.paymentStatus,
    this.paymentProofUrl,
  });
}

class VerificationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  String? get _currentUserId => _auth.currentUser?.uid;

  // ============ GET STATUS ============
  Future<VerificationData> getVerificationStatus() async {
    try {
      if (_currentUserId == null) return VerificationData();
      final doc = await _firestore.collection('users').doc(_currentUserId).get();
      return VerificationData.fromMap(doc.data());
    } catch (e) {
      developer.log('❌ Error getting verification status: $e', name: 'VerificationService', error: e);
      return VerificationData();
    }
  }

  Stream<VerificationData> streamVerificationStatus() {
    if (_currentUserId == null) return Stream.value(VerificationData());
    return _firestore
        .collection('users')
        .doc(_currentUserId)
        .snapshots()
        .map((doc) => VerificationData.fromMap(doc.data()));
  }

  // ============ UPLOAD DOCUMENT ============
  Future<String?> _uploadDocument(File file, String folder) async {
    try {
      developer.log('📤 Uploading to $folder...', name: 'VerificationService');
      // Timestamped so every submission is a distinct object: an approved
      // document is never overwritten, and an annual renewal keeps the
      // previous year's document for the admin to compare against.
      final version = DateTime.now().millisecondsSinceEpoch;
      final path = 'verification/$_currentUserId/$folder/$version';
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putFile(file);
      developer.log('✅ Upload successful: $path', name: 'VerificationService');
      return path;
    } catch (e) {
      developer.log('❌ Upload failed: $e', name: 'VerificationService', error: e);
      return null;
    }
  }

  /// Encrypts and stores the user's NIN via the submitNin Cloud Function.
  /// The raw NIN never persists in plaintext — the CF validates, encrypts
  /// (AES-256-GCM), and writes ciphertext to users/{uid}.nin.
  Future<bool> submitNin(String nin) async {
    try {
      final callable = _functions.httpsCallable('submitNin');
      final result = await callable.call<Map<String, dynamic>>({
        'nin': nin,
      });
      final success = result.data['success'] == true;
      if (!success) {
        developer.log('❌ submitNin returned success=false',
            name: 'VerificationService');
      }
      return success;
    } on FirebaseFunctionsException catch (e) {
      developer.log('❌ submitNin failed: ${e.code} — ${e.message}',
          name: 'VerificationService');
      return false;
    } catch (e) {
      developer.log('❌ submitNin error: $e', name: 'VerificationService');
      return false;
    }
  }

  /// The NIN document URL already stored for the current user (from their
  /// original verification). Used on renewal, where the NIN — a permanent
  /// number — is not re-collected, so the existing slip is carried forward.
  Future<String?> _existingNinUrl() async {
    if (_currentUserId == null) return null;
    final snap =
        await _firestore.collection('users').doc(_currentUserId).get();
    return ((snap.data()?['verificationDocs'] as Map?)?['nin']) as String?;
  }

  // ============ LANDLORD VERIFICATION ============
  Future<VerificationResult> submitLandlordVerification({
    File? ninFile,
    required File utilityBillFile,
    required String paymentReference,
    required double paymentAmount,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(success: false, error: 'User not authenticated');
      }

      // Renewal (ninFile == null) reuses the NIN already on file — it never
      // changes. First-time verification uploads the NIN slip.
      final ninUrl = ninFile != null
          ? await _uploadDocument(ninFile, 'nin')
          : await _existingNinUrl();
      final utilityBillUrl = await _uploadDocument(utilityBillFile, 'utility_bill');

      if (ninUrl == null || utilityBillUrl == null) {
        return VerificationResult(success: false, error: 'Failed to upload one or more documents');
      }

      await _firestore.collection('users').doc(_currentUserId).update({
        'verificationStatus': 'pending',
        // Renewal submissions carry no new NIN — lets admin distinguish an
        // annual renewal from a first-time application in the review queue.
        'isRenewal': ninFile == null,
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'verificationDocs': {
          'nin': ninUrl,
          'utilityBill': utilityBillUrl,
        },
        'verificationPaymentReference': paymentReference,
        'verificationPaymentAmount': paymentAmount,
        'verificationPaymentStatus': 'paid',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('verification_requests').add({
        'userId': _currentUserId,
        'userType': 'landlord',
        'status': 'pending',
        'ninUrl': ninUrl,
        'utilityBillUrl': utilityBillUrl,
        'paymentReference': paymentReference,
        'paymentAmount': paymentAmount,
        'paymentStatus': 'paid',
        'submittedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Landlord verification submitted (payment: $paymentReference)', name: 'VerificationService');
      return VerificationResult(success: true, message: 'Verification submitted successfully');
    } catch (e) {
      developer.log('❌ Landlord verification failed: $e', name: 'VerificationService', error: e);
      return VerificationResult(success: false, error: e.toString());
    }
  }

  // ============ TENANT VERIFICATION ============
  Future<VerificationResult> submitTenantVerification({
    File? ninFile,
    required File proofOfIncomeFile,
    required String paymentReference,
    required double paymentAmount,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(success: false, error: 'User not authenticated');
      }

      // Renewal (ninFile == null) reuses the NIN already on file — it never
      // changes. First-time verification uploads the NIN slip.
      final ninUrl = ninFile != null
          ? await _uploadDocument(ninFile, 'nin')
          : await _existingNinUrl();
      final proofOfIncomeUrl = await _uploadDocument(proofOfIncomeFile, 'proof_of_income');

      if (ninUrl == null || proofOfIncomeUrl == null) {
        return VerificationResult(success: false, error: 'Failed to upload one or more documents');
      }

      await _firestore.collection('users').doc(_currentUserId).update({
        'verificationStatus': 'pending',
        // Renewal submissions carry no new NIN — lets admin distinguish an
        // annual renewal from a first-time application in the review queue.
        'isRenewal': ninFile == null,
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'verificationDocs': {
          'nin': ninUrl,
          'proofOfIncome': proofOfIncomeUrl,
        },
        'verificationPaymentReference': paymentReference,
        'verificationPaymentAmount': paymentAmount,
        'verificationPaymentStatus': 'paid',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('verification_requests').add({
        'userId': _currentUserId,
        'userType': 'tenant',
        'status': 'pending',
        'ninUrl': ninUrl,
        'proofOfIncomeUrl': proofOfIncomeUrl,
        'paymentReference': paymentReference,
        'paymentAmount': paymentAmount,
        'paymentStatus': 'paid',
        'submittedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Tenant verification submitted (payment: $paymentReference)', name: 'VerificationService');
      return VerificationResult(success: true, message: 'Verification submitted successfully');
    } catch (e) {
      developer.log('❌ Tenant verification failed: $e', name: 'VerificationService', error: e);
      return VerificationResult(success: false, error: e.toString());
    }
  }

  // ============ AGENT VERIFICATION ============
  Future<VerificationResult> submitAgentVerification({
    File? ninFile,
    required File proofOfAddressFile,
    required File guarantorIdFile,
    required String guarantorName,
    required String guarantorPhone,
    required String guarantorAddress,
    required String paymentReference,
    required double paymentAmount,
    File? experienceProofFile,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(success: false, error: 'User not authenticated');
      }

      // Renewal (ninFile == null) reuses the NIN already on file — it never
      // changes. First-time verification uploads the NIN slip.
      final ninUrl = ninFile != null
          ? await _uploadDocument(ninFile, 'nin')
          : await _existingNinUrl();
      final proofOfAddressUrl = await _uploadDocument(proofOfAddressFile, 'proof_of_address');
      final guarantorIdUrl = await _uploadDocument(guarantorIdFile, 'guarantor_id');

      if (ninUrl == null || proofOfAddressUrl == null || guarantorIdUrl == null) {
        return VerificationResult(success: false, error: 'Failed to upload one or more documents');
      }

      String? experienceProofUrl;
      if (experienceProofFile != null) {
        experienceProofUrl = await _uploadDocument(experienceProofFile, 'experience_proof');
      }
      // Upstream form validation guarantees a valid Nigerian phone.
      // If that contract breaks, the `!` will surface the bug loudly.
      final normalizedGuarantorPhone = phoneToE164(guarantorPhone)!;
      final verificationDocs = <String, dynamic>{
        'nin': ninUrl,
        'proofOfAddress': proofOfAddressUrl,
        'guarantorId': guarantorIdUrl,
      };
      if (experienceProofUrl != null) {
        verificationDocs['experienceProof'] = experienceProofUrl;
      }

      await _firestore.collection('users').doc(_currentUserId).update({
        'verificationStatus': 'pending',
        // Renewal submissions carry no new NIN — lets admin distinguish an
        // annual renewal from a first-time application in the review queue.
        'isRenewal': ninFile == null,
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'verificationDocs': verificationDocs,
        'guarantorName': guarantorName,
        'guarantorPhone': normalizedGuarantorPhone,
        'guarantorAddress': guarantorAddress,
        'verificationPaymentReference': paymentReference,
        'verificationPaymentAmount': paymentAmount,
        'verificationPaymentStatus': 'paid',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final requestData = <String, dynamic>{
        'userId': _currentUserId,
        'userType': 'agent',
        'status': 'pending',
        'ninUrl': ninUrl,
        'proofOfAddressUrl': proofOfAddressUrl,
        'guarantorIdUrl': guarantorIdUrl,
        'guarantorName': guarantorName,
        'guarantorPhone': normalizedGuarantorPhone,
        'guarantorAddress': guarantorAddress,
        'paymentReference': paymentReference,
        'paymentAmount': paymentAmount,
        'paymentStatus': 'paid',
        'submittedAt': FieldValue.serverTimestamp(),
      };
      if (experienceProofUrl != null) {
        requestData['experienceProofUrl'] = experienceProofUrl;
      }

      await _firestore.collection('verification_requests').add(requestData);

      developer.log('✅ Agent verification submitted (payment: $paymentReference)', name: 'VerificationService');
      return VerificationResult(success: true, message: 'Verification submitted successfully');
    } catch (e) {
      developer.log('❌ Agent verification failed: $e', name: 'VerificationService', error: e);
      return VerificationResult(success: false, error: e.toString());
    }
  }

  // ============ LEGACY METHOD ============
  Future<VerificationResult> submitVerification({
    File? ninFile,
    required File utilityBillFile,
  }) async {
    developer.log('⚠️ Legacy submitVerification called — use Paystack payment flow', name: 'VerificationService');
    return VerificationResult(success: false, error: 'Please use the updated payment flow');
  }

  // ============ ADMIN METHODS ============

  Future<List<PendingVerification>> getPendingVerifications() async {
    try {
      final snapshot = await _firestore
          .collection('verification_requests')
          .where('status', isEqualTo: 'pending')
          .orderBy('submittedAt', descending: false)
          .get();

      final List<PendingVerification> verifications = [];

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final userDoc = await _firestore.collection('users').doc(data['userId']).get();
        final userData = userDoc.data() ?? {};
        final userType = data['userType'] ?? 'landlord';

        verifications.add(PendingVerification(
          uid: data['userId'],
          requestId: doc.id,
          fullName: userData['fullName'] ?? 'Unknown',
          email: userData['email'] ?? '',
          phone: userData['phone'] ?? '',
          userType: userType,
          documents: VerificationDocument(
            ninUrl: data['ninUrl'],
            propertyDocUrl: data['propertyDocUrl'],
            utilityBillUrl: data['utilityBillUrl'],
            proofOfIncomeUrl: data['proofOfIncomeUrl'],
            proofOfAddressUrl: data['proofOfAddressUrl'],
            guarantorIdUrl: data['guarantorIdUrl'],
            experienceProofUrl: data['experienceProofUrl'],
          ),
          submittedAt: (data['submittedAt'] as Timestamp?)?.toDate(),
          guarantorName: data['guarantorName'],
          guarantorPhone: data['guarantorPhone'],
          guarantorAddress: data['guarantorAddress'],
          paymentReference: data['paymentReference'],
          paymentAmount: (data['paymentAmount'] ?? 0).toDouble(),
          paymentStatus: data['paymentStatus'],
          paymentProofUrl: data['paymentProofUrl'],
        ));
      }

      return verifications;
    } catch (e) {
      developer.log('❌ Error getting pending verifications: $e', name: 'VerificationService', error: e);
      return _getPendingVerificationsLegacy();
    }
  }

  Future<List<PendingVerification>> _getPendingVerificationsLegacy() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('verificationStatus', isEqualTo: 'pending')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return PendingVerification(
          uid: doc.id,
          requestId: doc.id,
          fullName: data['fullName'] ?? 'Unknown',
          email: data['email'] ?? '',
          phone: data['phone'] ?? '',
          userType: data['accountType'] ?? 'landlord',
          documents: VerificationDocument.fromMap(data['verificationDocs']),
          submittedAt: (data['verificationSubmittedAt'] as Timestamp?)?.toDate(),
          guarantorName: data['guarantorName'],
          guarantorPhone: data['guarantorPhone'],
          guarantorAddress: data['guarantorAddress'],
          paymentReference: data['verificationPaymentReference'],
          paymentAmount: (data['verificationPaymentAmount'] ?? 0).toDouble(),
          paymentStatus: data['verificationPaymentStatus'],
          paymentProofUrl: data['verificationPaymentProofUrl'],
        );
      }).toList();
    } catch (e) {
      developer.log('❌ Error in legacy pending verifications: $e', name: 'VerificationService');
      return [];
    }
  }

  Future<bool> approveVerification(String uid, {String? requestId}) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'verificationStatus': 'verified',
        'isVerified': true,
        'verificationReviewedAt': FieldValue.serverTimestamp(),
        'verificationPaymentStatus': 'verified',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (requestId != null) {
        await _firestore.collection('verification_requests').doc(requestId).update({
          'status': 'approved',
          'paymentStatus': 'verified',
          'reviewedAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Verification approved for $uid', name: 'VerificationService');
      return true;
    } catch (e) {
      developer.log('❌ Error approving verification: $e', name: 'VerificationService', error: e);
      return false;
    }
  }

  Future<bool> rejectVerification(String uid, String reason, {String? requestId}) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'verificationStatus': 'rejected',
        'isVerified': false,
        'rejectionReason': reason,
        'verificationReviewedAt': FieldValue.serverTimestamp(),
        'verificationPaymentStatus': 'rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (requestId != null) {
        await _firestore.collection('verification_requests').doc(requestId).update({
          'status': 'rejected',
          'rejectionReason': reason,
          'paymentStatus': 'rejected',
          'reviewedAt': FieldValue.serverTimestamp(),
        });
      }

      developer.log('✅ Verification rejected for $uid', name: 'VerificationService');
      return true;
    } catch (e) {
      developer.log('❌ Error rejecting verification: $e', name: 'VerificationService', error: e);
      return false;
    }
  }
}