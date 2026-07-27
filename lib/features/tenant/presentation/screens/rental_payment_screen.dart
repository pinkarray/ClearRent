import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/rental_interest_service.dart';
import '../../../../services/paystack_service.dart';
import '../../../../shared/screens/paystack_checkout_screen.dart';

class RentalPaymentScreen extends StatefulWidget {
  final RentalInterest rentalInterest;
  // Optional: the pay-after-accept entry point (the finalized-agreement card in
  // lease_details) has only the rental, not the original inspection request.
  // The screen doesn't read it, so it's not required.
  final InspectionRequest? inspectionRequest;

  const RentalPaymentScreen({
    super.key,
    required this.rentalInterest,
    this.inspectionRequest,
  });

  @override
  State<RentalPaymentScreen> createState() => _RentalPaymentScreenState();
}

class _RentalPaymentScreenState extends State<RentalPaymentScreen> {
  final RentalInterestService _rentalInterestService = RentalInterestService();
  bool _isProcessing = false;
  bool _paymentSuccessful = false;
  String? _paymentReference;

  double get _amount => widget.rentalInterest.paymentAmount;

  String get _formattedAmount =>
      '₦${NumberFormat('#,###').format(_amount)}';

  Future<void> _initiatePayment() async {
    setState(() => _isProcessing = true);

    try {
      final paymentResult = await PaystackCheckoutScreen.launch(
        context: context,
        amount: _amount,
        type: PaystackService.typeRent,
        metadata: {
          'rentalInterestId': widget.rentalInterest.id,
          'propertyId': widget.rentalInterest.propertyId,
          'propertyTitle': widget.rentalInterest.propertyTitle,
          'tenantId': widget.rentalInterest.tenantId,
          'landlordId': widget.rentalInterest.landlordId,
          'description': 'Rent payment for ${widget.rentalInterest.propertyTitle}',
        },
      );

      if (!mounted) return;

      if (paymentResult == null) {
        setState(() => _isProcessing = false);
        return;
      }

      if (!paymentResult.success) {
        _showError('Payment was not completed. Please try again.');
        setState(() => _isProcessing = false);
        return;
      }

      // Payment successful
      _paymentReference = paymentResult.reference;
      setState(() => _paymentSuccessful = true);

      // Record payment
      await PaystackService().recordPayment(
        reference: paymentResult.reference,
        type: PaystackService.typeRent,
        amount: paymentResult.amountPaid ?? _amount,
        status: 'completed',
        extra: {
          'rentalInterestId': widget.rentalInterest.id,
          'propertyId': widget.rentalInterest.propertyId,
          'rentAmount': widget.rentalInterest.rentAmount,
          'agentFee': widget.rentalInterest.agentFee,
          'tenantDealFee': widget.rentalInterest.tenantDealFee,
          'landlordPayout': widget.rentalInterest.landlordPayout,
          'agentPayout': widget.rentalInterest.agentPayout,
          'clearrentEarnings': widget.rentalInterest.clearrentEarnings,
        },
      );

      // Update rental interest to paymentVerified (skip admin)
      await _updateRentalInterest();
    } catch (e) {
      developer.log('❌ Payment error: $e', name: 'RentalPayment');
      _showError('Payment failed. Please try again.');
      setState(() {
        _isProcessing = false;
        _paymentSuccessful = false;
      });
    }
  }

  Future<void> _updateRentalInterest() async {
    try {
      final success = await _rentalInterestService.recordRentPayment(
        widget.rentalInterest.id,
        paymentReference: _paymentReference,
      );

      if (!mounted) return;

      if (success) {
        _showSuccessDialog();
      } else {
        // Payment succeeded but status update failed — show partial success
        _showUpdateFailureDialog();
      }
    } catch (e) {
      developer.log('❌ Error updating rental interest: $e',
          name: 'RentalPayment');
      if (_paymentSuccessful) {
        _showUpdateFailureDialog();
      } else {
        _showError('Something went wrong. Please contact support.');
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_circle, size: 48, color: AppColors.success),
            ),
            const SizedBox(height: 24),
            Text('Payment Confirmed!', style: AppTextStyles.h3,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Your rent payment is confirmed and your tenancy is complete. '
              'Welcome to your new home!',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Amount', style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textSecondary)),
                      Text(_formattedAmount, style: AppTextStyles.labelMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Property', style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textSecondary)),
                      Flexible(
                        child: Text(
                          widget.rentalInterest.propertyTitle,
                          style: AppTextStyles.labelMedium,
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  // Rent is paid — they're a tenant now, so send them to the
                  // home DASHBOARD (tab 0). The `reset` nonce forces a fresh
                  // home so it doesn't reuse whatever tab (e.g. Profile) the
                  // tenant was last on.
                  Navigator.pop(ctx);
                  context.go('/tenant/home', extra: {
                    'initialTab': 0,
                    'reset': DateTime.now().millisecondsSinceEpoch,
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Go to My Home',
                    style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.pop();
              },
              child: Text('Done',
                  style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  void _showUpdateFailureDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.warning_amber_rounded,
                  size: 48, color: AppColors.warning),
            ),
            const SizedBox(height: 24),
            Text('Payment Received', style: AppTextStyles.h3,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Your payment was successful but we couldn\'t update the status automatically. Please contact support with your reference: ${_paymentReference ?? 'N/A'}',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  context.pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('OK',
                    style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: _isProcessing ? null : () => context.pop(),
        ),
        title: Text('Rental Payment', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Property summary
            _buildPropertySummary(),
            const SizedBox(height: 24),

            // Payment breakdown
            _buildPaymentBreakdown(),
            const SizedBox(height: 24),

            // Security note
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withAlpha(51)),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, color: AppColors.success, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Payments are processed securely by Paystack. ClearRent never sees your card details.',
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Pay button
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: _isProcessing ? 'Processing...' : 'Pay $_formattedAmount',
                onPressed: _isProcessing ? null : _initiatePayment,
                isLoading: _isProcessing,
              ),
            ),
            const SizedBox(height: 16),

            // Commit note: payment happens only after the landlord has accepted
            // you and the agreement is finalized, so this is the final step.
            Center(
              child: Text(
                'You\'re accepted and your agreement is finalized — this '
                'completes your move-in.',
                textAlign: TextAlign.center,
                style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPropertySummary() {
    final interest = widget.rentalInterest;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.background,
              image: interest.propertyImage.isNotEmpty
                  ? DecorationImage(
                      image: CachedNetworkImageProvider(interest.propertyImage),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: interest.propertyImage.isEmpty
                ? Icon(Icons.home, color: AppColors.textHint)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(interest.propertyTitle,
                    style: AppTextStyles.labelLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(interest.propertyAddress,
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentBreakdown() {
    final interest = widget.rentalInterest;
    final rentAmount = interest.rentAmount > 0 ? interest.rentAmount : _amount;
    final agentFee = interest.agentFee;
    final dealFee = interest.tenantDealFee > 0 ? interest.tenantDealFee : 5000.0;
    final hasAgent = agentFee > 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Text('Payment Summary', style: AppTextStyles.labelLarge),
            ],
          ),
          const SizedBox(height: 16),
          _paymentRow('Rent Amount', '₦${NumberFormat('#,###').format(rentAmount)}'),
          if (hasAgent) ...[
            const SizedBox(height: 8),
            _paymentRow('Agent Fee', '₦${NumberFormat('#,###').format(agentFee)}'),
          ],
          const SizedBox(height: 8),
          _paymentRow('Deal Completion Fee', '₦${NumberFormat('#,###').format(dealFee)}'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'Unlocks maintenance & issue reporting services',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textHint,
                fontSize: 10,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: AppTextStyles.labelLarge),
              Text(
                _formattedAmount,
                style: AppTextStyles.h4.copyWith(
                  color: AppColors.primary,
                  fontFamily: 'Roboto',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _paymentRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTextStyles.bodySmall.copyWith(
            color: AppColors.textSecondary)),
        Text(value, style: AppTextStyles.labelMedium.copyWith(
            fontFamily: 'Roboto')),
      ],
    );
  }
}