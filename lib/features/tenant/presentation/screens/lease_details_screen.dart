import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/conversation_service.dart';

class LeaseDetailsScreen extends StatefulWidget {
  final ActiveRental rental;
  const LeaseDetailsScreen({super.key, required this.rental});

  @override
  State<LeaseDetailsScreen> createState() => _LeaseDetailsScreenState();
}

class _LeaseDetailsScreenState extends State<LeaseDetailsScreen> {
  late ActiveRental _rental;
  final ActiveRentalService _rentalService = ActiveRentalService();
  bool _isAccepting = false;
  bool _isDisputing = false;

  @override
  void initState() {
    super.initState();
    _rental = widget.rental;
    _refreshRental(); // Get latest data
  }

  Future<void> _refreshRental() async {
    final updated = await _rentalService.getRentalById(_rental.id);
    if (updated != null && mounted) {
      setState(() => _rental = updated);
    }
  }

  String _formatAmount(double amount) => NumberFormat('#,###').format(amount);
  String _formatDate(DateTime date) => DateFormat('d MMMM y').format(date);

  @override
  Widget build(BuildContext context) {
    final daysLeft = _rental.daysUntilLeaseEnd;
    final leaseProgress = _calculateLeaseProgress();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // ── App Bar ──
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: AppColors.primary,
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(77),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              ),
              onPressed: () => context.pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _rental.propertyImage.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: _rental.propertyImage, fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: AppColors.primary,
                            child: const Icon(Icons.home, size: 60, color: Colors.white38),
                          ),
                        )
                      : Container(color: AppColors.primary,
                          child: const Icon(Icons.home, size: 60, color: Colors.white38)),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withAlpha(153)],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16, left: 16, right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _rental.isActive ? AppColors.success : AppColors.textHint,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(_rental.statusDisplay,
                              style: AppTextStyles.caption.copyWith(
                                  color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(height: 8),
                        Text(_rental.propertyTitle,
                            style: AppTextStyles.h3.copyWith(color: Colors.white),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Row(children: [
                          const Icon(Icons.location_on_outlined, size: 14, color: Colors.white70),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(_rental.propertyAddress,
                                style: AppTextStyles.bodySmall.copyWith(color: Colors.white70),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Lease Progress ──
                  _sectionTitle('Lease Progress'),
                  const SizedBox(height: 12),
                  _buildLeaseProgress(leaseProgress, daysLeft),

                  const SizedBox(height: 24),

                  // ── Financial Summary ──
                  _sectionTitle('Financial Summary'),
                  const SizedBox(height: 12),
                  _buildFinancialSummary(),

                  const SizedBox(height: 24),

                  // ── Landlord Info ──
                  _sectionTitle('Landlord'),
                  const SizedBox(height: 12),
                  _buildLandlordCard(),

                  const SizedBox(height: 24),

                  // ── Tenancy Agreement ──
                  _sectionTitle('Tenancy Agreement'),
                  const SizedBox(height: 12),
                  _buildAgreementSection(),

                  const SizedBox(height: 24),

                  // ── Stamp Duty Notice ──
                  _buildStampDutyNotice(),

                  const SizedBox(height: 24),

                  // ── Actions ──
                  if (_rental.isActive) ...[
                    _sectionTitle('Actions'),
                    const SizedBox(height: 12),
                    _actionTile(
                      icon: Icons.report_problem_outlined,
                      title: 'Report an Issue',
                      subtitle: 'Report maintenance or property issues',
                      color: AppColors.warning,
                      onTap: () => context.push('/tenant/report-issue', extra: {
                        'propertyId': _rental.propertyId,
                        'propertyTitle': _rental.propertyTitle,
                        'tenantId': _rental.tenantId,
                        'tenantName': _rental.tenantName,
                        'landlordId': _rental.landlordId,
                        'landlordName': _rental.landlordName,
                      }),
                    ),
                    const SizedBox(height: 8),
                    _actionTile(
                      icon: Icons.chat_outlined,
                      title: 'Message Landlord',
                      subtitle: 'Send a message about this property',
                      color: AppColors.primary,
                      onTap: () => _messageLandlord(),
                    ),
                  ],

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Agreement Section — the main new piece ──
  Widget _buildAgreementSection() {
    if (!_rental.hasAgreement) {
      // No agreement uploaded yet
      return _card(
        child: Row(children: [
          _iconBox(Icons.pending_outlined, AppColors.warning),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pending from Landlord',
                    style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning)),
                Text('Your landlord hasn\'t uploaded the agreement yet.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ]),
      );
    }

    // Agreement exists — show based on status
    switch (_rental.agreementStatus) {
      case AgreementStatus.pendingReview:
        return _buildPendingReviewCard();
      case AgreementStatus.accepted:
        return _buildAcceptedCard();
      case AgreementStatus.disputed:
        return _buildDisputedCard();
      case AgreementStatus.finalized:
        return _buildFinalizedCard();
      case AgreementStatus.none:
        // Has URL but no status set (legacy data) — treat as pending review
        return _buildPendingReviewCard();
    }
  }

  Widget _buildPendingReviewCard() {
    return _card(
      borderColor: AppColors.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _iconBox(Icons.rate_review_outlined, AppColors.info),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Review Required',
                      style: AppTextStyles.labelMedium.copyWith(color: AppColors.info)),
                  if (_rental.agreementUploadedAt != null)
                    Text('Uploaded ${_formatDate(_rental.agreementUploadedAt!)}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Text('Your landlord has sent the tenancy agreement. Please review it carefully before accepting.',
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 16),

          // View button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _viewAgreement(),
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: const Text('View Agreement'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Accept + Raise Concern buttons
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isDisputing ? null : () => _showDisputeDialog(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: AppColors.warning),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text('Raise Concern',
                    style: TextStyle(color: AppColors.warning)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _isAccepting ? null : () => _showAcceptDialog(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _isAccepting
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('I Accept'),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildAcceptedCard() {
    return _card(
      borderColor: AppColors.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _iconBox(Icons.check_circle, AppColors.success),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You Accepted This Agreement',
                      style: AppTextStyles.labelMedium.copyWith(color: AppColors.success)),
                  if (_rental.tenantAcceptedAt != null)
                    Text('Accepted on ${_formatDate(_rental.tenantAcceptedAt!)}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(13),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(Icons.hourglass_top, size: 18, color: AppColors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Waiting for your landlord to finalize the agreement.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          _viewAgreementButton(),
        ],
      ),
    );
  }

  Widget _buildDisputedCard() {
    return _card(
      borderColor: AppColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _iconBox(Icons.warning_amber_rounded, AppColors.warning),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Concern Raised',
                      style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning)),
                  Text('Waiting for landlord to address your concerns.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ]),
          if (_rental.tenantDisputeReason != null && _rental.tenantDisputeReason!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your concern:', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 4),
                  Text(_rental.tenantDisputeReason!,
                      style: AppTextStyles.bodySmall.copyWith(fontStyle: FontStyle.italic)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _viewAgreementButton()),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _messageLandlord(),
                icon: const Icon(Icons.chat_outlined, size: 18),
                label: const Text('Chat'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: AppColors.primary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildFinalizedCard() {
    return _card(
      borderColor: AppColors.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.success,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.verified, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Agreement Finalized',
                      style: AppTextStyles.labelLarge.copyWith(color: AppColors.success)),
                  if (_rental.landlordFinalizedAt != null)
                    Text('Finalized on ${_formatDate(_rental.landlordFinalizedAt!)}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          _viewAgreementButton(),
        ],
      ),
    );
  }

  // ── Stamp Duty Notice ──
  Widget _buildStampDutyNotice() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.info.withAlpha(51)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.gavel_outlined, size: 22, color: AppColors.info),
            const SizedBox(width: 10),
            Text('Legal Notice', style: AppTextStyles.labelLarge.copyWith(color: AppColors.info)),
          ]),
          const SizedBox(height: 12),
          Text(
            'For full legal protection and court admissibility, tenancy agreements in Nigeria should be stamped at your State Internal Revenue Service (SIRS) office — e.g. LIRS in Lagos.',
            style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'Stamp duty for tenancies under 1 year is typically ₦500–₦1,000. For longer tenancies, it\'s a small percentage of the annual rent.',
            style: AppTextStyles.naira(AppTextStyles.bodySmall).copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'An unstamped agreement is still valid between parties but may not be admissible as evidence in court proceedings.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── Dialogs ──
  Future<void> _showAcceptDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accept Agreement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('By tapping "I Accept", you acknowledge that you have read and agree to the terms in this tenancy agreement.',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning.withAlpha(51)),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 18, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('This creates a digital record of your acceptance. For court-admissible proof, get the agreement stamped at LIRS/SIRS.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ),
              ]),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success, foregroundColor: Colors.white),
            child: const Text('I Accept'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isAccepting = true);

    final success = await _rentalService.tenantAcceptAgreement(_rental.id);
    if (mounted) {
      setState(() => _isAccepting = false);
      if (success) {
        _refreshRental();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Agreement accepted! Your landlord has been notified.'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  Future<void> _showDisputeDialog() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Raise a Concern'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Describe your concern with the agreement. Your landlord will be notified and can address it or upload a revised version.',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'e.g. The maintenance clause needs to be clarified...',
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.warning, foregroundColor: Colors.white),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (reason == null || reason.isEmpty) return;
    setState(() => _isDisputing = true);

    final success = await _rentalService.tenantDisputeAgreement(_rental.id, reason);
    if (mounted) {
      setState(() => _isDisputing = false);
      if (success) {
        _refreshRental();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Concern submitted. Your landlord has been notified.'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  void _viewAgreement() {
    if (_rental.agreementUrl != null) {
      launchUrl(Uri.parse(_rental.agreementUrl!), mode: LaunchMode.externalApplication);
    }
  }

  Widget _viewAgreementButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _viewAgreement(),
        icon: const Icon(Icons.visibility_outlined, size: 18),
        label: const Text('View Agreement'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: AppColors.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Future<void> _messageLandlord() async {
    try {
      final conv = await ConversationService().getOrCreateConversation(
        propertyId: _rental.propertyId,
        propertyTitle: _rental.propertyTitle,
        propertyImage: _rental.propertyImage,
        landlordId: _rental.landlordId,
        landlordName: _rental.landlordName,
        tenantId: _rental.tenantId,
        tenantName: _rental.tenantName,
      );
      if (conv != null && mounted) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': _rental.propertyTitle,
          'propertyImage': _rental.propertyImage.isNotEmpty ? _rental.propertyImage : null,
        });
      }
    } catch (_) {}
  }

  // ── Helper widgets ──
  double _calculateLeaseProgress() {
    final total = _rental.leaseEndDate.difference(_rental.leaseStartDate).inDays;
    if (total <= 0) return 1.0;
    return DateTime.now().difference(_rental.leaseStartDate).inDays / total;
  }

  Widget _sectionTitle(String t) =>
      Text(t, style: AppTextStyles.labelLarge.copyWith(color: AppColors.textSecondary));

  Widget _card({required Widget child, Color? borderColor}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor ?? AppColors.border),
        ),
        child: child,
      );

  Widget _iconBox(IconData icon, Color color) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withAlpha(26),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 24),
      );

  Widget _actionTile({required IconData icon, required String title,
      required String subtitle, required Color color, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: _card(
        child: Row(children: [
          _iconBox(icon, color),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelMedium),
                Text(subtitle, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: AppColors.textHint),
        ]),
      ),
    );
  }

  Widget _buildLeaseProgress(double progress, int daysLeft) {
    return _card(
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${(progress * 100).clamp(0, 100).toInt()}% Complete', style: AppTextStyles.labelMedium),
          Text('$daysLeft days left',
              style: AppTextStyles.labelMedium.copyWith(
                color: daysLeft <= 30 ? AppColors.error : AppColors.primary,
                fontWeight: FontWeight.w600,
              )),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: AppColors.border,
            valueColor: AlwaysStoppedAnimation(daysLeft <= 30 ? AppColors.error : AppColors.primary),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _dateCol('Start Date', _formatDate(_rental.leaseStartDate), Icons.play_circle_outline)),
          Container(width: 1, height: 40, color: AppColors.border),
          Expanded(child: _dateCol('End Date', _formatDate(_rental.leaseEndDate), Icons.stop_circle_outlined)),
        ]),
      ]),
    );
  }

  Widget _dateCol(String label, String value, IconData icon) => Column(children: [
        Icon(icon, size: 18, color: AppColors.textHint),
        const SizedBox(height: 6),
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
        const SizedBox(height: 2),
        Text(value, style: AppTextStyles.labelSmall, textAlign: TextAlign.center),
      ]);

  Widget _buildFinancialSummary() {
    return _card(
      child: Column(children: [
        _finRow('Rent Amount', '₦${_formatAmount(_rental.rentAmount)}', bold: true),
        const SizedBox(height: 8),
        _finRow('Frequency', _rental.rentFrequency == 'yearly' ? 'Yearly' : 'Monthly'),
        if (_rental.agentFee > 0) ...[
          const SizedBox(height: 8),
          _finRow('Agent Fee', '₦${_formatAmount(_rental.agentFee)}'),
        ],
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),
        _finRow('Total Paid', '₦${_formatAmount(_rental.totalPaid)}', bold: true, color: AppColors.success),
      ]),
    );
  }

  Widget _finRow(String label, String value, {bool bold = false, Color? color}) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary)),
      Text(value, style: bold
          ? AppTextStyles.naira(AppTextStyles.labelLarge).copyWith(fontWeight: FontWeight.bold, color: color)
          : AppTextStyles.naira(AppTextStyles.bodySmall).copyWith(color: color)),
    ]);
  }

  Widget _buildLandlordCard() {
    return _card(
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.primary.withAlpha(26),
          child: Text(
            _rental.landlordName.isNotEmpty ? _rental.landlordName[0].toUpperCase() : 'L',
            style: AppTextStyles.h4.copyWith(color: AppColors.primary),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_rental.landlordName, style: AppTextStyles.labelLarge),
              Text('Property Owner', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        IconButton(
          onPressed: () => _messageLandlord(),
          icon: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), shape: BoxShape.circle),
            child: Icon(Icons.chat_outlined, color: AppColors.primary, size: 20),
          ),
        ),
      ]),
    );
  }
}