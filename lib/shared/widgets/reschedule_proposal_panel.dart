import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../models/inspection_request_model.dart';
import '../../services/inspection_service.dart';
import 'reschedule_propose_sheet.dart';
import 'refund_confirm_sheet.dart';

/// Panel rendered inside an inspection card when the request has a
/// pending reschedule proposal. Owns the buttons and service calls
/// for approve / counter / decline / abandon.
///
/// Caller is responsible only for placing this widget in the card —
/// the Firestore stream upstream of the card will redraw it once the
/// proposal state changes.
class RescheduleProposalPanel extends StatefulWidget {
  final InspectionRequest request;
  final String currentUserId;

  const RescheduleProposalPanel({
    super.key,
    required this.request,
    required this.currentUserId,
  });

  @override
  State<RescheduleProposalPanel> createState() =>
      _RescheduleProposalPanelState();
}

class _RescheduleProposalPanelState
    extends State<RescheduleProposalPanel> {
  final InspectionService _inspectionService = InspectionService();
  bool _busy = false;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
  }

  /// True when the current user proposed the active reschedule.
  bool get _isProposer =>
      widget.request.rescheduleProposal!.proposedByUserId ==
      widget.currentUserId;

  /// Display name of whoever proposed the active reschedule.
  String get _proposerName {
    final r = widget.request;
    final by = r.rescheduleProposal!.proposedBy;
    switch (by) {
      case 'tenant':
        return r.tenantName;
      case 'agent':
        return r.agentName ?? 'Agent';
      case 'landlord':
        return r.landlordName;
      default:
        return 'Someone';
    }
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            isError ? AppColors.error : AppColors.textPrimary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _onApprove() async {
    setState(() => _busy = true);
    final ok = await _inspectionService
        .approveReschedule(widget.request.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      ok ? 'Reschedule approved' : 'Couldn\'t approve, try again',
      isError: !ok,
    );
  }

  Future<void> _onCounter() async {
    final payload = await ReschedulePropoSheet.show(
      context,
      widget.request,
      isCounter: true,
    );
    if (payload == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await _inspectionService.counterProposeReschedule(
      requestId: widget.request.id,
      newDate: payload.date,
      newTimeSlot: payload.timeSlot,
      reason: payload.reason,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      ok
          ? 'Counter-proposal sent'
          : 'Couldn\'t send counter-proposal, try again',
      isError: !ok,
    );
  }

  Future<void> _onDecline() async {
    final r = widget.request;
    final feeText = NumberFormat('#,###').format(r.totalFee);
    final reason = await RefundConfirmSheet.show(
      context,
      title: 'Decline Reschedule',
      warningMessage:
          'Declining will end this inspection for '
          '${r.propertyTitle} and refund ₦$feeText to the tenant.',
      confirmButtonText: 'Decline & Refund',
    );
    if (reason == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await _inspectionService.declineReschedule(
      requestId: widget.request.id,
      reason: reason,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      ok
          ? 'Reschedule declined. Refund processing.'
          : 'Couldn\'t decline, try again',
      isError: !ok,
    );
  }

  Future<void> _onAbandon() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abandon proposal?'),
        content: const Text(
          'Your proposal will be dropped. The original date stands. '
          'You can propose again later if needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Abandon',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final ok = await _inspectionService
        .abandonReschedule(widget.request.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      ok ? 'Proposal abandoned' : 'Couldn\'t abandon, try again',
      isError: !ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    final proposal = widget.request.rescheduleProposal;
    if (proposal == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.info.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_repeat, size: 18, color: AppColors.info),
              const SizedBox(width: 8),
              Text(
                'Reschedule pending',
                style: AppTextStyles.labelMedium
                    .copyWith(color: AppColors.info),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _isProposer
                ? 'You proposed ${_formatDate(proposal.proposedDate)} '
                    '- ${proposal.proposedTimeDisplay}'
                : '$_proposerName proposed '
                    '${_formatDate(proposal.proposedDate)} '
                    '- ${proposal.proposedTimeDisplay}',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            'Reason: ${proposal.reason}',
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          if (_isProposer)
            _buildProposerActions()
          else
            _buildReceiverActions(proposal),
        ],
      ),
    );
  }

  Widget _buildProposerActions() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: _busy ? null : _onAbandon,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          'Abandon Proposal',
          style: AppTextStyles.labelMedium
              .copyWith(color: AppColors.textPrimary),
        ),
      ),
    );
  }

  Widget _buildReceiverActions(RescheduleProposal proposal) {
    final canCounter = !proposal.receiverCannotCounter;
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: _busy ? null : _onApprove,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Approve'),
          ),
        ),
        if (canCounter) ...[
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _onCounter,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                'Counter',
                style:
                    AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : _onDecline,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: BorderSide(color: AppColors.error),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'Decline',
              style: AppTextStyles.labelMedium
                  .copyWith(color: AppColors.error),
            ),
          ),
        ),
      ],
    );
  }
}