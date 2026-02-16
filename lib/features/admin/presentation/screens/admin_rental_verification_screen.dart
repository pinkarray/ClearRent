import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../services/rental_interest_service.dart';

class AdminRentalVerificationScreen extends StatefulWidget {
  const AdminRentalVerificationScreen({super.key});

  @override
  State<AdminRentalVerificationScreen> createState() =>
      _AdminRentalVerificationScreenState();
}

class _AdminRentalVerificationScreenState
    extends State<AdminRentalVerificationScreen> {
  final RentalInterestService _rentalInterestService =
      RentalInterestService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Rental Payment Verification', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: StreamBuilder<List<RentalInterest>>(
        stream: _rentalInterestService.getPendingRentalVerifications(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: AppColors.primary));
          }

          if (snapshot.hasError) {
            developer.log('❌ Stream error: ${snapshot.error}',
                name: 'AdminRentalVerification');
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 48, color: AppColors.error),
                    const SizedBox(height: 16),
                    Text('Error loading verifications',
                        style: AppTextStyles.h4),
                    const SizedBox(height: 8),
                    Text('${snapshot.error}',
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.textSecondary),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }

          final interests = snapshot.data ?? [];

          if (interests.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                          color: AppColors.success.withAlpha(26),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.check_circle_outline,
                          size: 40, color: AppColors.success),
                    ),
                    const SizedBox(height: 24),
                    Text('All caught up!', style: AppTextStyles.h4),
                    const SizedBox(height: 8),
                    Text(
                        'No rental payments waiting for verification.',
                        style: AppTextStyles.bodyMedium
                            .copyWith(color: AppColors.textSecondary),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: interests.length,
            itemBuilder: (context, index) =>
                _VerificationCard(interest: interests[index]),
          );
        },
      ),
    );
  }
}

class _VerificationCard extends StatefulWidget {
  final RentalInterest interest;
  const _VerificationCard({required this.interest});

  @override
  State<_VerificationCard> createState() => _VerificationCardState();
}

class _VerificationCardState extends State<_VerificationCard> {
  final RentalInterestService _rentalInterestService =
      RentalInterestService();
  bool _isVerifying = false;
  bool _isRejecting = false;

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  Future<void> _viewProof() async {
    final interest = widget.interest;
    final receiptUrl = interest.paymentReceiptUrl;

    if (receiptUrl == null || receiptUrl.isEmpty) {
      _snack('No receipt image available', AppColors.error);
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.vertical(
                    top: Radius.circular(16)),
              ),
              child: Row(children: [
                const Icon(Icons.receipt_long,
                    color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('RENTAL PAYMENT PROOF',
                      style: AppTextStyles.labelLarge
                          .copyWith(color: Colors.white)),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: const Icon(Icons.close,
                      color: Colors.white, size: 20),
                ),
              ]),
            ),

            // Receipt image
            Container(
              constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.of(context).size.height * 0.5),
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: CachedNetworkImage(
                  imageUrl: receiptUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, __) => const Center(
                      child: Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(
                              color: AppColors.primary))),
                  errorWidget: (_, __, ___) => const Center(
                      child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.broken_image,
                                    size: 48,
                                    color: AppColors.error),
                                SizedBox(height: 8),
                                Text('Failed to load image'),
                              ]))),
                ),
              ),
            ),

            // Details
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _detailRow('Tenant', interest.tenantName),
                const SizedBox(height: 8),
                _detailRow('Property', interest.propertyTitle),
                const SizedBox(height: 8),
                _detailRow('Expected Amount',
                    interest.paymentAmount > 0
                        ? '₦${_formatAmount(interest.paymentAmount)}'
                        : 'Verify rent amount'),
                const SizedBox(height: 12),
                Text('Pinch to zoom • Verify amount matches',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                    textAlign: TextAlign.center),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary)),
        Flexible(
          child: Text(value,
              style: AppTextStyles.labelMedium,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Future<void> _verifyPayment() async {
    final interest = widget.interest;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Rental Payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Confirm receipt of:',
                style: AppTextStyles.bodyMedium),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(13),
                  borderRadius: BorderRadius.circular(8)),
              child: Column(children: [
                Text(
                    interest.paymentAmount > 0
                        ? '₦${_formatAmount(interest.paymentAmount)}'
                        : 'Rental payment',
                    style: AppTextStyles.h4
                        .copyWith(color: AppColors.success)),
                Text('from ${interest.tenantName}',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ]),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.warning.withAlpha(77))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 20, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'This will LOCK IN the landlord. They must accept the tenant and cannot refuse.',
                        style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.warning,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white),
            child: const Text('Verify Payment'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    setState(() => _isVerifying = true);

    final success = await _rentalInterestService
        .verifyRentalPayment(interest.id);

    if (!mounted) return;
    setState(() => _isVerifying = false);

    _snack(
        success
            ? 'Rental payment verified! Landlord is now locked in.'
            : 'Failed to verify. Please try again.',
        success ? AppColors.success : AppColors.error);
  }

  Future<void> _rejectPayment() async {
    final controller = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                'Provide a reason so the tenant knows what to fix:',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: InputDecoration(
                hintText:
                    'e.g. Amount doesn\'t match, wrong account, etc.',
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        const BorderSide(color: AppColors.border)),
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary))),
          TextButton(
              onPressed: () {
                if (controller.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: const Text('Please provide a reason'),
                    backgroundColor: AppColors.error,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ));
                  return;
                }
                Navigator.pop(ctx, controller.text.trim());
              },
              child: Text('Reject',
                  style: TextStyle(color: AppColors.error))),
        ],
      ),
    );

    if (reason == null || reason.isEmpty) return;
    setState(() => _isRejecting = true);

    final success = await _rentalInterestService
        .rejectRentalPayment(widget.interest.id, reason);

    if (!mounted) return;
    setState(() => _isRejecting = false);

    _snack(
        success
            ? 'Payment rejected. Tenant will be notified.'
            : 'Failed to reject. Please try again.',
        success ? AppColors.textSecondary : AppColors.error);
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final interest = widget.interest;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(13),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(8)),
            child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.home_outlined,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text('RENTAL PAYMENT',
                      style: AppTextStyles.labelSmall.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600)),
                ]),
          ),
          const SizedBox(height: 12),

          // Property info
          Text(interest.propertyTitle,
              style: AppTextStyles.labelLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.location_on_outlined,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Expanded(
                child: Text(interest.propertyAddress,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
          ]),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Tenant info
          Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.primary.withAlpha(26),
              child: Text(
                  interest.tenantName.isNotEmpty
                      ? interest.tenantName[0].toUpperCase()
                      : 'T',
                  style: AppTextStyles.labelLarge
                      .copyWith(color: AppColors.primary)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(interest.tenantName,
                      style: AppTextStyles.labelMedium),
                  Text('Tenant',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
            // Amount
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                    interest.paymentAmount > 0
                        ? '₦${_formatAmount(interest.paymentAmount)}'
                        : 'Amount TBD',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.primary)),
                Text('Rental',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ]),
          const SizedBox(height: 16),

          // Action buttons
          Row(children: [
            // View proof
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _viewProof,
                icon:
                    const Icon(Icons.image_outlined, size: 18),
                label: const Text('View Proof'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12),
                    side: const BorderSide(
                        color: AppColors.primary),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(10))),
              ),
            ),
            const SizedBox(width: 8),
            // Reject
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _isRejecting ? null : _rejectPayment,
                icon: _isRejecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2))
                    : const Icon(Icons.close, size: 18),
                label: const Text('Reject'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12),
                    side: const BorderSide(
                        color: AppColors.error),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(10))),
              ),
            ),
            const SizedBox(width: 8),
            // Verify
            Expanded(
              child: ElevatedButton.icon(
                onPressed:
                    _isVerifying ? null : _verifyPayment,
                icon: _isVerifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white))
                    : const Icon(Icons.check, size: 18),
                label: const Text('Verify'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(10))),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}