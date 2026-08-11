import 'package:flutter/material.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../features/tenant/presentation/screens/condition_viewer_screen.dart';
import '../../services/condition_service.dart';
import '../models/condition_record.dart';

/// Both parties' move-out recordings for a tenancy.
///
/// Lived on the handover screen originally, which meant it could only be seen
/// once the tenancy had ENDED. But the tenant films while they still have keys
/// — during the notice period — so the landlord had no way to see the evidence
/// at the one time it might change what they do about the deposit. Shared so
/// the notice-period card can show the same list.
///
/// Renders nothing at all when there are no records, so it is safe to drop into
/// a card that usually has none.
class ConditionEvidenceList extends StatefulWidget {
  final String rentalId;
  final ConditionService service;

  const ConditionEvidenceList({
    super.key,
    required this.rentalId,
    required this.service,
  });

  @override
  State<ConditionEvidenceList> createState() => _ConditionEvidenceListState();
}

class _ConditionEvidenceListState extends State<ConditionEvidenceList> {
  /// Held rather than built in `build`. This sits on the rentals list, whose
  /// cards rebuild every time the rentals stream ticks; a stream created inline
  /// would be torn down and resubscribed on each one, and the list would blink
  /// out to nothing between them.
  late Stream<List<ConditionRecord>> _records;

  @override
  void initState() {
    super.initState();
    _records = widget.service
        .streamRecords(widget.rentalId, ConditionStage.moveOut);
  }

  @override
  void didUpdateWidget(ConditionEvidenceList old) {
    super.didUpdateWidget(old);
    if (old.rentalId != widget.rentalId) {
      _records = widget.service
          .streamRecords(widget.rentalId, ConditionStage.moveOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ConditionRecord>>(
      stream: _records,
      builder: (context, snap) {
        final records = snap.data ?? const <ConditionRecord>[];
        if (records.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What was recorded', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          ...records.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  // A pending record has nothing stored yet, so there is
                  // nothing to open — the row still shows, because "they tried
                  // and it is uploading" is itself worth knowing.
                  onTap: r.isEvidence
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ConditionViewerScreen(
                                rentalId: widget.rentalId,
                                record: r,
                              ),
                            ),
                          )
                      : null,
                  child: Row(children: [
                    Icon(
                      r.hasVideo
                          ? Icons.videocam_outlined
                          : Icons.photo_camera_outlined,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.pending
                            ? '${r.partyRole}: still uploading'
                            : '${r.partyRole}: ${r.videoPaths.length} video, '
                                '${r.imagePaths.length} photo',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                    if (r.isEvidence)
                      Icon(Icons.chevron_right,
                          size: 18, color: AppColors.textSecondary),
                  ]),
                ),
              )),
        ]);
      },
    );
  }
}
