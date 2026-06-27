import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/tenant_rental.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/paystack_service.dart';
import '../../../../shared/screens/paystack_checkout_screen.dart';

/// Renewal / promotion payment screen (System D). Forked from
/// RentalPaymentScreen rather than reusing it: there is no RentalInterest or
/// InspectionRequest here, the receipt is written server-side by the CF (not
/// client-side), and the success path returns to the dashboard rather than
/// the inspections list.
///
/// Charges rent + the tenant's ₦5,000 deal-completion fee. The matching CF
/// (completeActiveRenewal / completeLinkedPromotion, dispatched by
/// [ActiveRentalService.completeRenewal]) re-verifies the payment, extends or
/// creates the rental, and fires payout/receipt side-effects.
class RenewalPaymentScreen extends StatefulWidget {
  final TenantRental rental;

  const RenewalPaymentScreen({super.key, required this.rental});

  @override
  State<RenewalPaymentScreen> createState() => _RenewalPaymentScreenState();
}

class _RenewalPaymentScreenState extends State<RenewalPaymentScreen> {
  final ActiveRentalService _activeRentalService = ActiveRentalService();
  bool _isProcessing = false;
  String? _paymentReference;

  static const double _dealFee = 5000;

  double get _rent => widget.rental.rental.rentAmount;
  double get _amount => _rent + _dealFee;

  String get _formattedAmount => '₦${NumberFormat('#,###').format(_amount)}';

  Future<void> _initiatePayment() async {
    setState(() => _isProcessing = true);

    try {
      final paymentResult = await PaystackCheckoutScreen.launch(
        context: context,
        amount: _amount,
        type: PaystackService.typeRenewal,
        metadata: {
          'sourceId': widget.rental.sourceId,
          'propertyTitle': widget.rental.rental.propertyTitle,
          'tenantId': widget.rental.rental.tenantId,
          'landlordId': widget.rental.rental.landlordId,
          'description':
              'Tenancy renewal for ${widget.rental.rental.propertyTitle}',
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

      _paymentReference = paymentResult.reference;

      // CF re-verifies, extends/creates the rental, writes receipt + feeds.
      final ok = await _activeRentalService.completeRenewal(
        widget.rental,
        paymentResult.reference,
      );

      if (!mounted) return;

      if (ok) {
        _showSuccessDialog();
      } else {
        _showUpdateFailureDialog();
      }
    } catch (e) {
      developer.log('❌ Renewal payment error: $e', name: 'RenewalPayment');
      if (!mounted) return;
      // If we have a reference, the charge likely went through — steer the
      // tenant to support rather than implying they lost money.
      if (_paymentReference != null) {
        _showUpdateFailureDialog();
      } else {
        _showError('Payment failed. Please try again.');
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
              child:
                  Icon(Icons.check_circle, size: 48, color: AppColors.success),
            ),
            const SizedBox(height: 24),
            Text('Tenancy Renewed!',
                style: AppTextStyles.h3, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Your tenancy has been renewed and full access to this rental '
              'is restored.',
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
                      Text('Amount',
                          style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.textSecondary)),
                      Text(_formattedAmount,
                          style: AppTextStyles.labelMedium
                              .copyWith(fontFamily: 'Roboto')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Property',
                          style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.textSecondary)),
                      Flexible(
                        child: Text(
                          widget.rental.rental.propertyTitle,
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
                  Navigator.pop(ctx);
                  context.go('/tenant/home');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Back to Dashboard',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: Colors.white)),
              ),
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
            Text('Payment Received',
                style: AppTextStyles.h3, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Your payment was successful but we couldn\'t finalize the '
              'renewal automatically. Please contact support with your '
              'reference: ${_paymentReference ?? 'N/A'}',
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
                  context.go('/tenant/home');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('OK',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: Colors.white)),
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
        title: Text('Renew Tenancy', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPropertySummary(),
            const SizedBox(height: 24),
            _buildPaymentBreakdown(),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withAlpha(51)),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined,
                      color: AppColors.success, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Payments are processed securely by Paystack. ClearRent '
                      'never sees your card details.',
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: _isProcessing
                    ? 'Processing...'
                    : 'Pay $_formattedAmount',
                onPressed: _isProcessing ? null : _initiatePayment,
                isLoading: _isProcessing,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                'Renewing extends your tenancy for another year',
                style:
                    AppTextStyles.caption.copyWith(color: AppColors.textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPropertySummary() {
    final r = widget.rental.rental;
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
              image: r.propertyImage.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(r.propertyImage),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: r.propertyImage.isEmpty
                ? Icon(Icons.home, color: AppColors.textHint)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.propertyTitle,
                    style: AppTextStyles.labelLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(r.propertyAddress,
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
          _paymentRow(
              'Rent Amount', '₦${NumberFormat('#,###').format(_rent)}'),
          const SizedBox(height: 8),
          _paymentRow('Deal Completion Fee',
              '₦${NumberFormat('#,###').format(_dealFee)}'),
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
        Text(label,
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary)),
        Text(value,
            style:
                AppTextStyles.labelMedium.copyWith(fontFamily: 'Roboto')),
      ],
    );
  }
}