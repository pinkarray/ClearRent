import 'package:cloud_firestore/cloud_firestore.dart';

import '../shared/models/refund_model.dart';

/// Service for reading refund records.
///
/// Refunds are created server-side by the `onInspectionRefundTriggered`
/// Cloud Function. This service is read-only — clients never write to
/// the `refunds` collection (rules enforce this).
class RefundService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Stream the refund record for a given inspection request, if one
  /// exists. Emits null while the refund doc is absent (e.g. before the
  /// trigger has fired, or for non-refunded inspections).
  ///
  /// Doc ID convention: refunds/{inspectionRequestId}.
  Stream<Refund?> streamForInspection(String inspectionRequestId) {
    return _streamByDocId(inspectionRequestId);
  }

  /// Stream the refund record for a losing rental interest, if one exists.
  /// Doc ID convention: refunds/{rentalInterestId} (created by
  /// onRentalInterestAccepted for each loser).
  Stream<Refund?> streamForRental(String rentalInterestId) {
    return _streamByDocId(rentalInterestId);
  }

  Stream<Refund?> _streamByDocId(String refundId) {
    return _firestore
        .collection('refunds')
        .doc(refundId)
        .snapshots()
        .map((snap) => snap.exists ? Refund.fromFirestore(snap) : null);
  }
}