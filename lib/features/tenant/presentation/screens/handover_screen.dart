import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/condition_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/condition_record.dart';
import 'condition_capture_screen.dart';

/// Works a move-out through to settlement, for whichever party is looking.
///
/// One screen rather than two because both sides are watching the SAME
/// sequence and mostly need to see where it has got to, not act. Splitting it
/// would have duplicated the whole state machine to change two buttons.
///
/// The framing throughout is deliberate: the tenant's tenancy is over and they
/// are free. What is unresolved is the caution deposit, and the property — not
/// the tenant — is what stays gated until it is.
class HandoverScreen extends StatefulWidget {
  final String rentalId;
  const HandoverScreen({super.key, required this.rentalId});

  @override
  State<HandoverScreen> createState() => _HandoverScreenState();
}

class _HandoverScreenState extends State<HandoverScreen> {
  final _rentalService = ActiveRentalService();
  final _conditionService = ConditionService();
  bool _busy = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> _run(Future<bool> Function() action, String failure) async {
    setState(() => _busy = true);
    final ok = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Move-out')),
      body: StreamBuilder<ActiveRental?>(
        stream: _rentalService.streamRentalById(widget.rentalId),
        builder: (context, snap) {
          final rental = snap.data;
          if (rental == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final isTenant = rental.tenantId == _uid;

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(rental.propertyTitle, style: AppTextStyles.labelLarge),
              const SizedBox(height: 4),
              Text(
                isTenant
                    ? 'Your tenancy has ended. What is left is your caution '
                        'deposit.'
                    : 'This tenancy has ended. The property cannot be listed '
                        'again until the caution deposit is settled.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),

              _StageTrail(stage: rental.handoverStage),
              const SizedBox(height: 20),

              if (rental.isHandoverClosed)
                _Done(isTenant: isTenant)
              else if (isTenant)
                _TenantActions(
                  rental: rental,
                  busy: _busy,
                  onCapture: () => _capture(rental),
                  onConfirmPaid: () => _run(
                    () => _rentalService.handoverConfirmPaid(rental.id),
                    'Could not confirm. Try again.',
                  ),
                  onContest: () => _contest(rental),
                )
              else
                _LandlordActions(
                  rental: rental,
                  busy: _busy,
                  onCapture: () => _capture(rental),
                  onConfirmCondition: () => _confirmCondition(rental),
                  onSettle: () => _settle(rental),
                ),

              const SizedBox(height: 24),
              _EvidenceList(
                rentalId: rental.id,
                service: _conditionService,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _capture(ActiveRental rental) async {
    final isTenant = rental.tenantId == _uid;
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ConditionCaptureScreen(
          rentalId: rental.id,
          propertyTitle: rental.propertyTitle,
          stage: ConditionStage.moveOut,
          partyRole: isTenant ? 'tenant' : 'landlord',
        ),
      ),
    );
    // Only the TENANT's recording advances the stage. The landlord's own
    // footage is corroboration; it is not what the tenant is waiting on.
    if (done == true && isTenant && mounted) {
      await _run(
        () => _rentalService.handoverEvidenceRecorded(rental.id),
        'Recording saved, but the status did not update.',
      );
    }
  }

  Future<void> _confirmCondition(ActiveRental rental) async {
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm you have checked it'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Say that you have physically seen the property since the tenant '
            'left. You cannot list it again until you do.',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notes,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Anything you noticed (optional)',
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not yet')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('I have checked it')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(
      () => _rentalService.handoverConfirmCondition(
        rental.id,
        notes: notes.text.trim(),
      ),
      'Could not record that. Try again.',
    );
  }

  Future<void> _settle(ActiveRental rental) async {
    final result = await showModalBottomSheet<_Settlement>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => _SettleSheet(rental: rental),
    );
    if (result == null || !mounted) return;

    String? proofPath;
    if (result.proof != null) {
      final uid = _uid;
      if (uid != null) {
        try {
          proofPath = 'condition/$uid/${rental.id}/'
              'proof_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await FirebaseStorage.instance.ref(proofPath).putFile(result.proof!);
        } catch (_) {
          proofPath = null;
        }
      }
    }
    if (!mounted) return;
    await _run(
      () => _rentalService.handoverSettle(
        rental.id,
        deductionAmount: result.deduction,
        deductionReason: result.reason,
        proofPath: proofPath,
      ),
      'Could not record the settlement. A deduction needs a reason.',
    );
  }

  Future<void> _contest(ActiveRental rental) async {
    final statement = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Say what is wrong'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'ClearRent will review this. The property stays off the market '
            'until it is resolved, so this does not simply time out.',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: statement,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What happened',
              hintText: 'Nothing was transferred / the damage was already there',
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Submit')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(
      () => _rentalService.handoverContest(rental.id, statement.text),
      'Could not submit. Say what happened first.',
    );
  }
}

// ── Progress ────────────────────────────────────────────────────────────────

class _StageTrail extends StatelessWidget {
  final String stage;
  const _StageTrail({required this.stage});

  static const _order = [
    ('awaiting_evidence', 'Condition recorded'),
    ('awaiting_condition', 'Landlord checked it'),
    ('awaiting_settlement', 'Deposit settled'),
    ('awaiting_confirm', 'Tenant confirmed'),
    ('closed', 'Done'),
  ];

  @override
  Widget build(BuildContext context) {
    final idx = _order.indexWhere((e) => e.$1 == stage);
    return Column(
      children: List.generate(_order.length, (i) {
        final done = idx < 0 || i < idx || stage == 'closed';
        final current = i == idx && stage != 'closed';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(
              done
                  ? Icons.check_circle
                  : current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
              size: 18,
              color: done
                  ? AppColors.success
                  : current
                      ? AppColors.primary
                      : AppColors.border,
            ),
            const SizedBox(width: 10),
            Text(
              _order[i].$2,
              style: AppTextStyles.bodyMedium.copyWith(
                color: current ? AppColors.textPrimary : AppColors.textSecondary,
                fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ]),
        );
      }),
    );
  }
}

class _Done extends StatelessWidget {
  final bool isTenant;
  const _Done({required this.isTenant});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(Icons.check_circle_outline, color: AppColors.success, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            isTenant
                ? 'Settled. Nothing else is outstanding on your side.'
                : 'Settled. You can list this property again.',
            style: AppTextStyles.bodyMedium,
          ),
        ),
      ]),
    );
  }
}

// ── Party actions ───────────────────────────────────────────────────────────

class _TenantActions extends StatelessWidget {
  final ActiveRental rental;
  final bool busy;
  final VoidCallback onCapture;
  final VoidCallback onConfirmPaid;
  final VoidCallback onContest;

  const _TenantActions({
    required this.rental,
    required this.busy,
    required this.onCapture,
    required this.onConfirmPaid,
    required this.onContest,
  });

  @override
  Widget build(BuildContext context) {
    if (rental.handoverStage == 'awaiting_evidence') {
      return _ActionCard(
        title: 'Record the condition you left it in',
        body: 'Your walkthrough is what a deduction has to be argued against. '
            'Without it, a claim on your deposit has nothing to answer to.',
        cta: 'Record now',
        busy: busy,
        onTap: onCapture,
      );
    }
    if (rental.handoverStage == 'awaiting_confirm') {
      final kept = rental.cautionDeductionAmount ?? 0;
      final owed = (rental.cautionDeposit - kept).clamp(0, double.infinity);
      return Column(children: [
        _ActionCard(
          title: 'Were you paid?',
          body: kept > 0
              ? 'Your landlord kept '
                  '${InspectionPricing.formatNaira(kept)} '
                  '("${rental.cautionDeductionReason ?? ''}") and says they '
                  'sent back ${InspectionPricing.formatNaira(owed.toDouble())}.'
              : 'Your landlord says they returned your deposit in full — '
                  '${InspectionPricing.formatNaira(owed.toDouble())}.',
          cta: 'Yes, I was paid',
          busy: busy,
          onTap: onConfirmPaid,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: busy ? null : onContest,
          child: const Text('No — something is wrong'),
        ),
      ]);
    }
    return _Waiting(text: rental.handoverNextStep);
  }
}

class _LandlordActions extends StatelessWidget {
  final ActiveRental rental;
  final bool busy;
  final VoidCallback onCapture;
  final VoidCallback onConfirmCondition;
  final VoidCallback onSettle;

  const _LandlordActions({
    required this.rental,
    required this.busy,
    required this.onCapture,
    required this.onConfirmCondition,
    required this.onSettle,
  });

  @override
  Widget build(BuildContext context) {
    switch (rental.handoverStage) {
      case 'awaiting_evidence':
        return _Waiting(
          text: 'Waiting for your former tenant to record the condition. You '
              'can record your own now if you prefer.',
          action: TextButton(
            onPressed: busy ? null : onCapture,
            child: const Text('Record my own'),
          ),
        );
      case 'awaiting_condition':
        return _ActionCard(
          title: 'Check the property',
          body: 'Confirm you have physically seen it since they left. This is '
              'what releases the listing — nothing else does.',
          cta: 'I have checked it',
          busy: busy,
          onTap: onConfirmCondition,
        );
      case 'awaiting_settlement':
        return _ActionCard(
          title: 'Settle the caution deposit',
          body: 'Send it back and record what you sent. Keeping any of it '
              'needs a reason, and your former tenant sees it.',
          cta: 'Record the settlement',
          busy: busy,
          onTap: onSettle,
        );
      default:
        return _Waiting(
          text: 'Waiting for your former tenant to confirm they were paid. '
              'If they do not reply within a week, upload proof of transfer '
              'and it closes on its own.',
        );
    }
  }
}

class _ActionCard extends StatelessWidget {
  final String title;
  final String body;
  final String cta;
  final bool busy;
  final VoidCallback onTap;

  const _ActionCard({
    required this.title,
    required this.body,
    required this.cta,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(77)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: AppTextStyles.labelLarge),
        const SizedBox(height: 6),
        Text(body,
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: busy ? null : onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(cta),
          ),
        ),
      ]),
    );
  }
}

class _Waiting extends StatelessWidget {
  final String text;
  final Widget? action;
  const _Waiting({required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.hourglass_empty,
              size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary)),
          ),
        ]),
        if (action != null) ...[const SizedBox(height: 4), action!],
      ]),
    );
  }
}

// ── Evidence ────────────────────────────────────────────────────────────────

class _EvidenceList extends StatelessWidget {
  final String rentalId;
  final ConditionService service;
  const _EvidenceList({required this.rentalId, required this.service});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ConditionRecord>>(
      stream: service.streamRecords(rentalId, ConditionStage.moveOut),
      builder: (context, snap) {
        final records = snap.data ?? const <ConditionRecord>[];
        if (records.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What was recorded', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          ...records.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
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
                ]),
              )),
        ]);
      },
    );
  }
}

// ── Settlement sheet ────────────────────────────────────────────────────────

class _Settlement {
  final double deduction;
  final String? reason;
  final File? proof;
  const _Settlement(this.deduction, this.reason, this.proof);
}

class _SettleSheet extends StatefulWidget {
  final ActiveRental rental;
  const _SettleSheet({required this.rental});

  @override
  State<_SettleSheet> createState() => _SettleSheetState();
}

class _SettleSheetState extends State<_SettleSheet> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  File? _proof;
  bool _withholding = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deposit = widget.rental.cautionDeposit;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Settle the caution deposit', style: AppTextStyles.labelLarge),
        const SizedBox(height: 4),
        Text(
          'On record: ${InspectionPricing.formatNaira(deposit)}. ClearRent '
          'does not hold this money — you send it directly.',
          style:
              AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('I am keeping some of it'),
          subtitle: Text(
            'Default is returning it in full',
            style:
                AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          value: _withholding,
          onChanged: (v) => setState(() => _withholding = v),
        ),
        if (_withholding) ...[
          TextField(
            controller: _amount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Amount kept (₦)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reason,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Why',
              hintText: 'Your former tenant sees this',
            ),
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () async {
            final x = await ImagePicker()
                .pickImage(source: ImageSource.gallery, imageQuality: 85);
            if (x != null && mounted) setState(() => _proof = File(x.path));
          },
          icon: const Icon(Icons.receipt_long_outlined, size: 18),
          label: Text(_proof == null
              ? 'Attach proof of transfer'
              : 'Proof attached'),
        ),
        const SizedBox(height: 4),
        Text(
          'Without proof, a tenant who never replies leaves this open and the '
          'property stays off the market.',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              final amt = _withholding
                  ? (double.tryParse(_amount.text.trim()) ?? 0)
                  : 0.0;
              if (_withholding &&
                  (amt <= 0 || _reason.text.trim().isEmpty)) {
                return;
              }
              Navigator.pop(
                context,
                _Settlement(
                    amt, _withholding ? _reason.text.trim() : null, _proof),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Record settlement'),
          ),
        ),
      ]),
    );
  }
}
