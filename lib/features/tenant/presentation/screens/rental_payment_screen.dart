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
import '../../../../shared/widgets/undismissible_dialog.dart';
import '../../../../services/rental_interest_service.dart';
import '../../../../services/property_service.dart';
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
  /// Shown, never charged — see the note in [_buildPaymentBreakdown].
  /// Read from the property because `RentalInterest` does not carry it: the
  /// interest holds only what ClearRent actually collects.
  double _cautionDeposit = 0;
  bool _cautionDepositRefundable = true;

  @override
  void initState() {
    super.initState();
    _loadCautionDeposit();
  }

  Future<void> _loadCautionDeposit() async {
    final property = await PropertyService()
        .getProperty(widget.rentalInterest.propertyId);
    if (!mounted || property == null) return;
    setState(() {
      _cautionDeposit = property.cautionDeposit;
      _cautionDepositRefundable = property.cautionDepositRefundable;
    });
  }

  double get _amount => widget.rentalInterest.paymentAmount;

  String get _formattedAmount =>
      '₦${NumberFormat('#,###').format(_amount)}';

  Future<void> _initiatePayment() async {
    // Never charge twice for the same tenancy.
    //
    // `widget.rentalInterest` is a FROZEN snapshot handed over through
    // go_router's `extra`, so it still says "accepted" no matter what has
    // happened since — including a payment this very screen already took.
    // recordRentPayment is idempotent, but it runs AFTER the money moves, so
    // idempotency there cannot stop a second charge. This is the only check
    // that sits in front of Paystack.
    setState(() => _isProcessing = true);
    final fresh =
        await _rentalInterestService.getInterestById(widget.rentalInterest.id);
    if (!mounted) return;
    if (fresh != null && fresh.isRentPaid) {
      setState(() {
        _isProcessing = false;
        _paymentSuccessful = true;
      });
      _showAlreadyPaidDialog();
      return;
    }
    // A read that FAILED is not a licence to charge: `fresh == null` means we
    // could not find out, so say so rather than risk a duplicate.
    if (fresh == null) {
      setState(() => _isProcessing = false);
      _showError(
          'Could not confirm your rent status. Check your connection and try '
          'again — this is to make sure you are never charged twice.');
      return;
    }

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

  /// The tenancy was already paid for before this screen even opened a
  /// checkout. Reached from the pre-flight check in [_initiatePayment].
  void _showAlreadyPaidDialog() {
    showUndismissibleDialog(
      context: context,
      builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Already paid', style: AppTextStyles.h4),
          content: Text(
            'Your rent for ${widget.rentalInterest.propertyTitle} is already '
            'paid — we did not charge you again.',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.go('/tenant/home', extra: {
                  'initialTab': 0,
                  'reset': DateTime.now().millisecondsSinceEpoch,
                });
              },
              child: const Text('Go to My Home'),
            ),
          ],
      ),
    );
  }

  void _showSuccessDialog() {
    // The charge is done and recorded, so this screen must stop behaving like
    // a payment form: `_isProcessing` used to stay true forever here, which
    // left the Pay button reading "Processing..." AND the app-bar back arrow
    // disabled — a dead end whose only exit was killing the app.
    setState(() => _isProcessing = false);
    showUndismissibleDialog(
      context: context,
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
    // Same reasoning as the success dialog: the money HAS moved, so the form
    // must stop looking payable and the screen must stay escapable.
    setState(() => _isProcessing = false);
    showUndismissibleDialog(
      context: context,
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
          // Disabled only while a checkout is genuinely in flight. Once the
          // payment has landed the tenant must always be able to leave — this
          // arrow staying dead after success is what made the screen a trap.
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
                text: _paymentSuccessful
                    ? 'Paid'
                    : (_isProcessing ? 'Processing...' : 'Pay $_formattedAmount'),
                // `_paymentSuccessful` is a SEPARATE latch from
                // `_isProcessing`: the spinner has to clear so the screen can
                // be left, but the button must never become payable again.
                onPressed: (_isProcessing || _paymentSuccessful)
                    ? null
                    : _initiatePayment,
                isLoading: _isProcessing,
              ),
            ),
            const SizedBox(height: 16),

            // Commit note: payment happens only after the landlord has accepted
            // you and the agreement is finalized, so this is the final step.
            Center(
              child: Text(
                'You\'re accepted and your agreement is finalized - this '
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
              Text('You pay now', style: AppTextStyles.labelLarge),
              Text(
                _formattedAmount,
                style: AppTextStyles.h4.copyWith(
                  color: AppColors.primary,
                  fontFamily: 'Roboto',
                ),
              ),
            ],
          ),

          // The caution deposit, stated but NOT charged.
          //
          // ClearRent deliberately never holds this money — paymentAmount is
          // rent + agent fee + deal fee and nothing else. But until now
          // nothing anywhere told the tenant the deposit existed or that they
          // owed it to the landlord directly, so a tenant could complete this
          // screen believing they had paid everything they owed. Saying the
          // amount and saying who collects it is the whole fix.
          if (_cautionDeposit > 0) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withAlpha(60)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Caution deposit',
                          style: AppTextStyles.labelMedium),
                      Text(
                        '₦${NumberFormat('#,###').format(_cautionDeposit)}',
                        style: AppTextStyles.labelMedium
                            .copyWith(fontFamily: 'Roboto'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Not included above and not collected by ClearRent. You '
                    'pay this directly to your landlord. '
                    '${_cautionDepositRefundable ? 'It is refundable at '
                        'move-out if the property is left in good condition.' :
                        'Your landlord has marked this deposit as '
                        'non-refundable.'}',
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
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