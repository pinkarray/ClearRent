import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum VerificationStatus { none, pending, verified, rejected }

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

  bool get isComplete => ninUrl != null;
}

class VerificationData {
  final VerificationStatus status;
  final VerificationDocument documents;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;
  final String? accountType;
  // Agent guarantor info
  final String? guarantorName;
  final String? guarantorPhone;
  final String? guarantorAddress;

  VerificationData({
    this.status = VerificationStatus.none,
    VerificationDocument? documents,
    this.submittedAt,
    this.reviewedAt,
    this.rejectionReason,
    this.accountType,
    this.guarantorName,
    this.guarantorPhone,
    this.guarantorAddress,
  }) : documents = documents ?? VerificationDocument();

  factory VerificationData.fromMap(Map<String, dynamic>? map) {
    if (map == null) return VerificationData();
    return VerificationData(
      status: _parseStatus(map['verificationStatus']),
      documents: VerificationDocument.fromMap(map['verificationDocs'] ?? map),
      submittedAt: (map['verificationSubmittedAt'] as Timestamp?)?.toDate(),
      reviewedAt: (map['verificationReviewedAt'] as Timestamp?)?.toDate(),
      rejectionReason: map['rejectionReason'],
      accountType: map['accountType'],
      guarantorName: map['guarantorName'],
      guarantorPhone: map['guarantorPhone'],
      guarantorAddress: map['guarantorAddress'],
    );
  }

  static VerificationStatus _parseStatus(String? status) {
    switch (status) {
      case 'pending':
        return VerificationStatus.pending;
      case 'verified':
        return VerificationStatus.verified;
      case 'rejected':
        return VerificationStatus.rejected;
      default:
        return VerificationStatus.none;
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
  final String userType; // landlord, tenant, agent
  final VerificationDocument documents;
  final DateTime? submittedAt;
  // Agent guarantor info
  final String? guarantorName;
  final String? guarantorPhone;
  final String? guarantorAddress;

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
  });
}

class VerificationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final _cloudinary = CloudinaryPublic(
    'den5t1dai',
    'clearrent_uploads',
    cache: false,
  );

  String? get _currentUserId => _auth.currentUser?.uid;

  // ============ GET STATUS (backward compatible) ============
  Future<VerificationData> getVerificationStatus() async {
    try {
      if (_currentUserId == null) {
        return VerificationData();
      }

      final doc = await _firestore.collection('users').doc(_currentUserId).get();
      return VerificationData.fromMap(doc.data());
    } catch (e) {
      developer.log(
        '❌ Error getting verification status: $e',
        name: 'VerificationService',
        error: e,
      );
      return VerificationData();
    }
  }

  // Stream verification status for real-time updates
  Stream<VerificationData> streamVerificationStatus() {
    if (_currentUserId == null) {
      return Stream.value(VerificationData());
    }

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

      final response = await _cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          file.path,
          folder: 'clearrent/verification/$_currentUserId/$folder',
          resourceType: CloudinaryResourceType.Image,
        ),
      );

      developer.log('✅ Upload successful: ${response.secureUrl}', name: 'VerificationService');
      return response.secureUrl;
    } catch (e) {
      developer.log('❌ Upload failed: $e', name: 'VerificationService', error: e);
      return null;
    }
  }

  // ============ LANDLORD VERIFICATION ============
  Future<VerificationResult> submitLandlordVerification({
    required File ninFile,
    required File propertyDocFile,
    required File utilityBillFile,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(success: false, error: 'User not authenticated');
      }

      // Upload documents
      final ninUrl = await _uploadDocument(ninFile, 'nin');
      final propertyDocUrl = await _uploadDocument(propertyDocFile, 'property_doc');
      final utilityBillUrl = await _uploadDocument(utilityBillFile, 'utility_bill');

      if (ninUrl == null || propertyDocUrl == null || utilityBillUrl == null) {
        return VerificationResult(success: false, error: 'Failed to upload one or more documents');
      }

      // Update user document
      await _firestore.collection('users').doc(_currentUserId).update({
        'verificationStatus': 'pending',
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'verificationDocs': {
          'nin': ninUrl,
          'propertyDoc': propertyDocUrl,
          'utilityBill': utilityBillUrl,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Create verification request
      await _firestore.collection('verification_requests').add({
        'userId': _currentUserId,
        'userType': 'landlord',
        'status': 'pending',
        'ninUrl': ninUrl,
        'propertyDocUrl': propertyDocUrl,
        'utilityBillUrl': utilityBillUrl,
        'submittedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Landlord verification submitted', name: 'VerificationService');
      return VerificationResult(success: true, message: 'Verification submitted successfully');
    } catch (e) {
      developer.log('❌ Landlord verification failed: $e', name: 'VerificationService', error: e);
      return VerificationResult(success: false, error: e.toString());
    }
  }

  // ============ TENANT VERIFICATION ============
  Future<VerificationResult> submitTenantVerification({
    required File ninFile,
    required File proofOfIncomeFile,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(success: false, error: 'User not authenticated');
      }

      final ninUrl = await _uploadDocument(ninFile, 'nin');
      final proofOfIncomeUrl = await _uploadDocument(proofOfIncomeFile, 'proof_of_income');

      if (ninUrl == null || proofOfIncomeUrl == null) {
        return VerificationResult(success: false, error: 'Failed to upload one or more documents');
      }

      await _firestore.collection('users').doc(_currentUserId).update({
        'verificationStatus': 'pending',
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'verificationDocs': {
          'nin': ninUrl,
          'proofOfIncome': proofOfIncomeUrl,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('verification_requests').add({
        'userId': _currentUserId,
        'userType': 'tenant',
        'status': 'pending',
        'ninUrl': ninUrl,
        'proofOfIncomeUrl': proofOfIncomeUrl,
        'submittedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Tenant verification submitted', name: 'VerificationService');
      return VerificationResult(success: true, message: 'Verification submitted successfully');
    } catch (e) {
      developer.log('❌ Tenant verification failed: $e', name: 'VerificationService', error: e);
      return VerificationResult(success: false, error: e.toString());
    }
  }

  // ============ AGENT VERIFICATION ============
  Future<VerificationResult> submitAgentVerification({
    required File ninFile,
    required File proofOfAddressFile,
    required File guarantorIdFile,
    required String guarantorName,
    required String guarantorPhone,
    required String guarantorAddress,
    File? experienceProofFile,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(success: false, error: 'User not authenticated');
      }

      final ninUrl = await _uploadDocument(ninFile, 'nin');
      final proofOfAddressUrl = await _uploadDocument(proofOfAddressFile, 'proof_of_address');
      final guarantorIdUrl = await _uploadDocument(guarantorIdFile, 'guarantor_id');

      if (ninUrl == null || proofOfAddressUrl == null || guarantorIdUrl == null) {
        return VerificationResult(success: false, error: 'Failed to upload one or more documents');
      }

      String? experienceProofUrl;
      if (experienceProofFile != null) {
        experienceProofUrl = await _uploadDocument(experienceProofFile, 'experience_proof');
      }

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
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'verificationDocs': verificationDocs,
        'guarantorName': guarantorName,
        'guarantorPhone': guarantorPhone,
        'guarantorAddress': guarantorAddress,
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
        'guarantorPhone': guarantorPhone,
        'guarantorAddress': guarantorAddress,
        'submittedAt': FieldValue.serverTimestamp(),
      };
      if (experienceProofUrl != null) {
        requestData['experienceProofUrl'] = experienceProofUrl;
      }

      await _firestore.collection('verification_requests').add(requestData);

      developer.log('✅ Agent verification submitted', name: 'VerificationService');
      return VerificationResult(success: true, message: 'Verification submitted successfully');
    } catch (e) {
      developer.log('❌ Agent verification failed: $e', name: 'VerificationService', error: e);
      return VerificationResult(success: false, error: e.toString());
    }
  }

  // ============ LEGACY METHOD (backward compatibility) ============
  Future<VerificationResult> submitVerification({
    required File ninFile,
    required File propertyDocFile,
    required File utilityBillFile,
  }) async {
    return submitLandlordVerification(
      ninFile: ninFile,
      propertyDocFile: propertyDocFile,
      utilityBillFile: utilityBillFile,
    );
  }

  // ============ ADMIN METHODS ============

  /// Get all pending verifications for admin review
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
        
        // Get user info
        final userDoc = await _firestore
            .collection('users')
            .doc(data['userId'])
            .get();
        
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
        ));
      }

      return verifications;
    } catch (e) {
      developer.log('❌ Error getting pending verifications: $e', name: 'VerificationService', error: e);
      
      // Fallback to old method if verification_requests collection doesn't exist
      return _getPendingVerificationsLegacy();
    }
  }

  /// Legacy method - query users directly (for backward compatibility)
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
        );
      }).toList();
    } catch (e) {
      developer.log('❌ Error in legacy pending verifications: $e', name: 'VerificationService');
      return [];
    }
  }

  /// Approve verification
  Future<bool> approveVerification(String uid, {String? requestId}) async {
    try {
      // Update user document
      await _firestore.collection('users').doc(uid).update({
        'verificationStatus': 'verified',
        'isVerified': true,
        'verificationReviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Update verification request if exists
      if (requestId != null) {
        await _firestore.collection('verification_requests').doc(requestId).update({
          'status': 'approved',
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

  /// Reject verification
  Future<bool> rejectVerification(String uid, String reason, {String? requestId}) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'verificationStatus': 'rejected',
        'isVerified': false,
        'rejectionReason': reason,
        'verificationReviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (requestId != null) {
        await _firestore.collection('verification_requests').doc(requestId).update({
          'status': 'rejected',
          'rejectionReason': reason,
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