import 'package:flutter/material.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../features/tenant/presentation/screens/condition_capture_screen.dart';
import '../../services/condition_service.dart';
import '../models/condition_record.dart';

/// Asks a party to record what the property looked like when the tenancy
/// STARTED, if they never did.
///
/// Without a baseline, "this was damaged" and "it was already like that" are
/// the same sentence with nobody able to prove either. The move-out flow
/// treats a missing baseline as weakening a deduction rather than blocking it,
/// which is the fair reading — but it is a poor substitute for having one.
///
/// Shown to BOTH sides, and to tenancies already underway: every existing
/// tenancy predates this feature, so the alternative is a baseline that only
/// ever exists for tenants who move in from now on.
///
/// Renders nothing once this user has recorded, so it disappears rather than
/// nagging.
class MoveInBaselinePrompt extends StatefulWidget {
  final String rentalId;
  final String propertyTitle;

  /// 'tenant' | 'landlord'
  final String partyRole;

  const MoveInBaselinePrompt({
    super.key,
    required this.rentalId,
    required this.propertyTitle,
    required this.partyRole,
  });

  @override
  State<MoveInBaselinePrompt> createState() => _MoveInBaselinePromptState();
}

class _MoveInBaselinePromptState extends State<MoveInBaselinePrompt> {
  final _service = ConditionService();
  ConditionRecord? _mine;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _service.myRecord(widget.rentalId, ConditionStage.moveIn);
    if (!mounted) return;
    setState(() {
      _mine = r;
      _loaded = true;
    });
  }

  Future<void> _record() async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ConditionCaptureScreen(
          rentalId: widget.rentalId,
          propertyTitle: widget.propertyTitle,
          stage: ConditionStage.moveIn,
          partyRole: widget.partyRole,
        ),
      ),
    );
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing until we know, so the card doesn't flash a prompt at someone who
    // already recorded one.
    if (!_loaded || _mine != null) return const SizedBox.shrink();

    final isTenant = widget.partyRole == 'tenant';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(13),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withAlpha(64)),
      ),
      child: Row(children: [
        Icon(Icons.camera_outlined, size: 18, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Record the condition now',
                  style: AppTextStyles.labelMedium),
              const SizedBox(height: 2),
              Text(
                isTenant
                    ? 'If anything is already damaged, this is what proves it '
                        'was not you when you leave.'
                    : 'This is what a deduction can be measured against when '
                        'the tenancy ends.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: _record, child: const Text('Record')),
      ]),
    );
  }
}
