import 'package:cloud_firestore/cloud_firestore.dart';

/// Which end of the tenancy a condition record describes.
enum ConditionStage { moveIn, moveOut }

extension ConditionStageX on ConditionStage {
  String get key => this == ConditionStage.moveIn ? 'move_in' : 'move_out';

  String get label =>
      this == ConditionStage.moveIn ? 'Move-in condition' : 'Move-out condition';
}

/// One party's record of what a property looked like, at one end of a tenancy.
///
/// Stored at `active_rentals/{rentalId}/condition/{stage}/parties/{uid}` — one
/// document per person, deliberately. A caution-deposit deduction is argued
/// over exactly this evidence, so neither side may overwrite the other's, and
/// rules seal a record once [capturedAt] is set.
///
/// [pending] is the retry-later state. The tenancy has already ended by the
/// time a move-out record is written, so a failed upload must never trap
/// anyone — but until the media actually lands there is nothing to judge a
/// deduction on, which is why a pending record does not count as evidence.
class ConditionRecord {
  final String partyId;
  /// 'tenant' | 'landlord' — who recorded it, for display without a lookup.
  final String partyRole;
  final List<String> videoPaths;
  final List<String> imagePaths;
  final String notes;
  final bool pending;
  final DateTime? capturedAt;
  final DateTime? createdAt;

  const ConditionRecord({
    required this.partyId,
    required this.partyRole,
    this.videoPaths = const [],
    this.imagePaths = const [],
    this.notes = '',
    this.pending = false,
    this.capturedAt,
    this.createdAt,
  });

  /// A record only counts once its media has finished uploading.
  bool get isEvidence =>
      !pending && (videoPaths.isNotEmpty || imagePaths.isNotEmpty);

  /// Walkthrough video is the stronger record: a photo shows a corner, a video
  /// shows the room it sits in and cannot be as easily cropped to flatter.
  bool get hasVideo => videoPaths.isNotEmpty;

  factory ConditionRecord.fromFirestore(Map<String, dynamic> d, String id) {
    return ConditionRecord(
      partyId: id,
      partyRole: (d['partyRole'] as String?) ?? '',
      videoPaths: List<String>.from(d['videoPaths'] ?? const []),
      imagePaths: List<String>.from(d['imagePaths'] ?? const []),
      notes: (d['notes'] as String?) ?? '',
      pending: d['pending'] == true,
      capturedAt: (d['capturedAt'] as Timestamp?)?.toDate(),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
