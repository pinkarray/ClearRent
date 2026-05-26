import 'package:cloud_firestore/cloud_firestore.dart';

/// A refund record from the `refunds` collection.
///
/// Created server-side by the `onInspectionRefundTriggered` Cloud Function
/// when an inspection request's paymentStatus flips to 'refunded'. Marked
/// paid by an admin calling the `markRefundPaid` Cloud Function.
///
/// Doc ID matches the source inspection request ID (1:1 mapping for
/// inspection refunds), so lookup is a single doc read.
class Refund {
  final String id;
  final String status; // 'pending' | 'paid' | 'cancelled'
  final double amount;
  final String beneficiaryId;
  final String beneficiaryRole; // 'tenant' | 'landlord' | 'agent'
  final String source;
  final String sourceCollection;
  final String sourceDocId;
  final String reason;
  final String? propertyId;
  final String? propertyTitle;
  final DateTime createdAt;
  final DateTime? paidAt;
  final String? paidBy;

  Refund({
    required this.id,
    required this.status,
    required this.amount,
    required this.beneficiaryId,
    required this.beneficiaryRole,
    required this.source,
    required this.sourceCollection,
    required this.sourceDocId,
    required this.reason,
    this.propertyId,
    this.propertyTitle,
    required this.createdAt,
    this.paidAt,
    this.paidBy,
  });

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';

  factory Refund.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Refund(
      id: doc.id,
      status: data['status'] ?? 'pending',
      amount: (data['amount'] ?? 0).toDouble(),
      beneficiaryId: data['beneficiaryId'] ?? '',
      beneficiaryRole: data['beneficiaryRole'] ?? '',
      source: data['source'] ?? '',
      sourceCollection: data['sourceCollection'] ?? '',
      sourceDocId: data['sourceDocId'] ?? '',
      reason: data['reason'] ?? '',
      propertyId: data['propertyId'],
      propertyTitle: data['propertyTitle'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      paidAt: (data['paidAt'] as Timestamp?)?.toDate(),
      paidBy: data['paidBy'],
    );
  }
}