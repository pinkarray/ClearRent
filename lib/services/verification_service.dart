import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum VerificationStatus { none, pending, verified, rejected }

class VerificationDocument {
  final String? ninUrl;
  final String? propertyDocUrl;
  final String? utilityBillUrl;

  VerificationDocument({this.ninUrl, this.propertyDocUrl, this.utilityBillUrl});

  factory VerificationDocument.fromMap(Map<String, dynamic>? map) {
    if (map == null) return VerificationDocument();
    return VerificationDocument(
      ninUrl: map['nin'],
      propertyDocUrl: map['propertyDoc'],
      utilityBillUrl: map['utilityBill'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'nin': ninUrl,
      'propertyDoc': propertyDocUrl,
      'utilityBill': utilityBillUrl,
    };
  }

  bool get isComplete =>
      ninUrl != null && propertyDocUrl != null && utilityBillUrl != null;
}

class VerificationData {
  final VerificationStatus status;
  final VerificationDocument documents;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;

  VerificationData({
    this.status = VerificationStatus.none,
    VerificationDocument? documents,
    this.submittedAt,
    this.reviewedAt,
    this.rejectionReason,
  }) : documents = documents ?? VerificationDocument();

  factory VerificationData.fromMap(Map<String, dynamic>? map) {
    if (map == null) return VerificationData();
    return VerificationData(
      status: _parseStatus(map['verificationStatus']),
      documents: VerificationDocument.fromMap(map['verificationDocs']),
      submittedAt: (map['verificationSubmittedAt'] as Timestamp?)?.toDate(),
      reviewedAt: (map['verificationReviewedAt'] as Timestamp?)?.toDate(),
      rejectionReason: map['rejectionReason'],
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

  String get statusString {
    switch (status) {
      case VerificationStatus.none:
        return 'none';
      case VerificationStatus.pending:
        return 'pending';
      case VerificationStatus.verified:
        return 'verified';
      case VerificationStatus.rejected:
        return 'rejected';
    }
  }
}

class VerificationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Cloudinary configuration - using unsigned upload preset
  final cloudinary = CloudinaryPublic(
    'den5t1dai', // Your cloud name
    'clearrent_uploads', // Upload preset (create this in Cloudinary dashboard)
    cache: false,
  );

  String? get _currentUserId => _auth.currentUser?.uid;

  // Get current verification status
  Future<VerificationData> getVerificationStatus() async {
    try {
      if (_currentUserId == null) {
        return VerificationData();
      }

      final doc =
          await _firestore.collection('users').doc(_currentUserId).get();

      return VerificationData.fromMap(doc.data());
    } catch (e) {
      developer.log(
        '❌ Error getting verification status: $e',
        name: 'VerificationService',
        error: e,
        stackTrace: StackTrace.current,
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

  // Upload a document to Cloudinary
  Future<String?> uploadDocument(File file, String documentType) async {
    try {
      developer.log(
        '📤 Uploading $documentType to Cloudinary...',
        name: 'VerificationService',
      );

      final response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          file.path,
          folder: 'clearrent/verification/$_currentUserId',
          resourceType: CloudinaryResourceType.Auto,
        ),
      );

      developer.log(
        '✅ Upload successful: ${response.secureUrl}',
        name: 'VerificationService',
      );
      return response.secureUrl;
    } catch (e) {
      developer.log(
        '❌ Upload failed for $documentType: $e',
        name: 'VerificationService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return null;
    }
  }

  // Submit verification documents
  Future<VerificationResult> submitVerification({
    required File ninFile,
    required File propertyDocFile,
    required File utilityBillFile,
  }) async {
    try {
      if (_currentUserId == null) {
        return VerificationResult(
          success: false,
          error: 'User not authenticated',
        );
      }

      // Upload all documents
      developer.log(
        '📤 Starting document uploads...',
        name: 'VerificationService',
      );

      final ninUrl = await uploadDocument(ninFile, 'NIN');
      if (ninUrl == null) {
        return VerificationResult(
          success: false,
          error: 'Failed to upload NIN document',
        );
      }

      final propertyDocUrl = await uploadDocument(
        propertyDocFile,
        'PropertyDoc',
      );
      if (propertyDocUrl == null) {
        return VerificationResult(
          success: false,
          error: 'Failed to upload property document',
        );
      }

      final utilityBillUrl = await uploadDocument(
        utilityBillFile,
        'UtilityBill',
      );
      if (utilityBillUrl == null) {
        return VerificationResult(
          success: false,
          error: 'Failed to upload utility bill',
        );
      }

      // Update Firestore with verification data
      developer.log(
        '💾 Saving verification data to Firestore...',
        name: 'VerificationService',
      );

      await _firestore.collection('users').doc(_currentUserId).set({
        'verificationStatus': 'pending',
        'verificationDocs': {
          'nin': ninUrl,
          'propertyDoc': propertyDocUrl,
          'utilityBill': utilityBillUrl,
        },
        'verificationSubmittedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      developer.log(
        '✅ Verification submitted successfully',
        name: 'VerificationService',
      );

      return VerificationResult(
        success: true,
        message: 'Verification documents submitted successfully',
      );
    } catch (e) {
      developer.log(
        '❌ Verification submission failed: $e',
        name: 'VerificationService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return VerificationResult(
        success: false,
        error: 'Failed to submit verification: $e',
      );
    }
  }

  // ============ ADMIN METHODS ============

  // Get all pending verifications (for admin)
  Future<List<PendingVerification>> getPendingVerifications() async {
    try {
      final snapshot =
          await _firestore
              .collection('users')
              .where('verificationStatus', isEqualTo: 'pending')
              .where('accountType', isEqualTo: 'landlord')
              .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return PendingVerification(
          uid: doc.id,
          fullName: data['fullName'] ?? 'Unknown',
          email: data['email'] ?? '',
          documents: VerificationDocument.fromMap(data['verificationDocs']),
          submittedAt:
              (data['verificationSubmittedAt'] as Timestamp?)?.toDate(),
        );
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Error getting pending verifications: $e',
        name: 'VerificationService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return [];
    }
  }

  // Approve verification (admin)
  Future<bool> approveVerification(String uid) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'verificationStatus': 'verified',
        'verificationReviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log(
        '✅ Verification approved for $uid',
        name: 'VerificationService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error approving verification: $e',
        name: 'VerificationService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // Reject verification (admin)
  Future<bool> rejectVerification(String uid, String reason) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'verificationStatus': 'rejected',
        'rejectionReason': reason,
        'verificationReviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log(
        '✅ Verification rejected for $uid',
        name: 'VerificationService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error rejecting verification: $e',
        name: 'VerificationService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }
}

class VerificationResult {
  final bool success;
  final String? message;
  final String? error;

  VerificationResult({required this.success, this.message, this.error});
}

class PendingVerification {
  final String uid;
  final String fullName;
  final String email;
  final VerificationDocument documents;
  final DateTime? submittedAt;

  PendingVerification({
    required this.uid,
    required this.fullName,
    required this.email,
    required this.documents,
    this.submittedAt,
  });
}
