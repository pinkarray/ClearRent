import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/inspection_service.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../services/paystack_service.dart';
import '../../../../shared/screens/paystack_checkout_screen.dart';
class InspectionPaymentScreen extends StatefulWidget {
  final PropertyModel property;
  final DateTime selectedDate;
  final String selectedTimeSlot;
  final String? notes;
  final InspectionFeeBreakdown? feeBreakdown;

  const InspectionPaymentScreen({
    super.key,
    required this.property,
    required this.selectedDate,
    required this.selectedTimeSlot,
    this.notes,
    this.feeBreakdown,
  });

  @override
  State<InspectionPaymentScreen> createState() =>
      _InspectionPaymentScreenState();
}

class _InspectionPaymentScreenState extends State<InspectionPaymentScreen> {
  final InspectionService _inspectionService = InspectionService();

  bool _isProcessing = false;
  bool _paymentSuccessful = false;
  String? _paymentReference;

  InspectionFeeBreakdown get _fee =>
      widget.feeBreakdown ??
      InspectionFeeBreakdown(
        agentCluster: 'maryland_ikeja',
        propertyCluster: 'maryland_ikeja',
        oneWayFare: 0,
        transportFee: 0,
        agentServiceFee: 10000,
        tenantServiceCharge: 3000,
        totalFee: 13000,
        agentEarnings: 7000,
        clearrentEarnings: 6000,
      );

  String get _formattedDate {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];

    return '${weekdays[widget.selectedDate.weekday - 1]}, ${months[widget.selectedDate.month - 1]} ${widget.selectedDate.day}';
  }

  String get _formattedTime {
    return InspectionService.timeSlotDisplay[widget.selectedTimeSlot] ??
        widget.selectedTimeSlot;
  }

  Future<void> _initiatePayment() async {
    setState(() => _isProcessing = true);

    try {
      // Launch Paystack checkout
      final paymentResult = await PaystackCheckoutScreen.launch(
        context: context,
        amount: _fee.totalFee,
        type: PaystackService.typeInspection,
        metadata: {
          'propertyId': widget.property.id,
          'propertyTitle': widget.property.title,
          'inspectionDate': widget.selectedDate.toIso8601String(),
          'timeSlot': widget.selectedTimeSlot,
          'description': 'Inspection fee for ${widget.property.title}',
        },
      );

      if (!mounted) return;

      if (paymentResult == null) {
        // User cancelled
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
        type: PaystackService.typeInspection,
        amount: paymentResult.amountPaid ?? _fee.totalFee,
        status: 'completed',
        extra: {'propertyId': widget.property.id},
      );

      // Create inspection request after successful payment
      await _createInspectionRequest();
    } catch (e) {
      debugPrint('❌ Payment error: $e');
      _showError('Payment failed. Please try again.');
      setState(() {
        _isProcessing = false;
        _paymentSuccessful = false;
      });
    }
  }

  Future<void> _createInspectionRequest() async {
    try {
      final result = await _inspectionService.createInspectionRequest(
        property: widget.property,
        requestedDate: widget.selectedDate,
        requestedTimeSlot: widget.selectedTimeSlot,
        notes: widget.notes,
        feeBreakdown: _fee,
        paymentReference: _paymentReference,
      );

      if (!mounted) return;

      if (result == 'already_pending') {
        _showError('You already have a pending request for this property');
        setState(() => _isProcessing = false);
        context.pop();
        return;
      }

      if (result != null) {
        // Show success and navigate
        _showSuccessDialog();
      } else {
        // Payment succeeded but request failed - show error with retry option
        _showRequestFailureDialog();
      }
    } catch (e) {
      debugPrint('❌ Error creating request: $e');
      if (_paymentSuccessful) {
        // Payment was successful, but request creation failed
        _showRequestFailureDialog(error: e.toString());
      } else {
        _showError('Something went wrong. Please contact support.');
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _retryCreateRequest() async {
    // Retry without re-charging (payment already successful)
    setState(() => _isProcessing = true);
    Navigator.pop(context); // Close the failure dialog
    await _createInspectionRequest();
  }

  void _showRequestFailureDialog({String? error}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
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
                  child: Icon(
                    Icons.info_outline,
                    color: AppColors.warning,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Request Failed',
                  style: AppTextStyles.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(13),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.success.withAlpha(51)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: AppColors.success,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Payment (₦${NumberFormat('#,###').format(_fee.totalFee)}) was successful',
                          style: AppTextStyles.naira(AppTextStyles.caption).copyWith(
                            color: AppColors.success,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Failed to submit your inspection request, but your payment has been secured.',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _retryCreateRequest,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _isProcessing ? 'Retrying...' : 'Retry Request',
                      style: AppTextStyles.labelLarge.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed:
                      _isProcessing
                          ? null
                          : () {
                            Navigator.pop(context);
                            _showContactSupportOption();
                          },
                  child: Text(
                    'Contact Support',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  void _showContactSupportOption() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.support_agent, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Payment Reference (Share with support)',
                    style: AppTextStyles.labelSmall.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    _paymentReference ?? 'N/A',
                    style: AppTextStyles.caption.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.info,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
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
                  child: Icon(
                    Icons.check_circle,
                    color: AppColors.success,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Request Sent!',
                  style: AppTextStyles.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your inspection request has been sent to the agent. You\'ll be notified once they respond.',
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
                        children: [
                          Icon(
                            Icons.calendar_today,
                            size: 16,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formattedDate,
                            style: AppTextStyles.labelMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 16,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formattedTime,
                            style: AppTextStyles.labelMedium,
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
                      Navigator.pop(context); // Close dialog
                      context.go('/tenant/inspections'); // Go to inspections
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'View My Inspections',
                      style: AppTextStyles.labelLarge.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context); // Close dialog
                    context.pop(); // Go back to property
                  },
                  child: Text(
                    'Back to Property',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
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
        title: Text('Confirm & Pay', style: AppTextStyles.h4),
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

            // Schedule summary
            _buildScheduleSummary(),
            const SizedBox(height: 24),

            // Agent info
            _buildAgentInfo(),
            const SizedBox(height: 24),

            // Payment breakdown
            _buildPaymentBreakdown(),
            const SizedBox(height: 24),

            // Refund policy
            _buildRefundPolicy(),
            const SizedBox(height: 32),

            // Pay button
            AppButton(
              text: 'Pay ₦${NumberFormat('#,###').format(_fee.totalFee)}',
              onPressed: _isProcessing ? null : _initiatePayment,
              isLoading: _isProcessing,
            ),

            const SizedBox(height: 16),

            // Security note
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock, size: 14, color: AppColors.textHint),
                  const SizedBox(width: 6),
                  Text(
                    'Secured by Paystack',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPropertySummary() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child:
                widget.property.images.isNotEmpty
                    ? Image.network(
                      widget.property.images.first,
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      errorBuilder:
                          (_, __, ___) => Container(
                            width: 80,
                            height: 80,
                            color: AppColors.background,
                            child: Icon(
                              Icons.home,
                              color: AppColors.textHint,
                            ),
                          ),
                    )
                    : Container(
                      width: 80,
                      height: 80,
                      color: AppColors.background,
                      child: Icon(Icons.home, color: AppColors.textHint),
                    ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.property.title,
                  style: AppTextStyles.labelLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.location_on,
                      size: 14,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${widget.property.city}, ${widget.property.state}',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  widget.property.formattedRent,
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleSummary() {
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
          Text('Inspection Schedule', style: AppTextStyles.labelLarge),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.calendar_today,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Date',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(_formattedDate, style: AppTextStyles.labelMedium),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.access_time, color: AppColors.info),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Time',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(_formattedTime, style: AppTextStyles.labelMedium),
                  ],
                ),
              ),
            ],
          ),
          if (widget.notes != null && widget.notes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.warning.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.note, color: AppColors.warning),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Notes',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(widget.notes!, style: AppTextStyles.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAgentInfo() {
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
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.support_agent,
              color: AppColors.info,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.property.assignedAgentName ?? 'Agent',
                        style: AppTextStyles.labelLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success.withAlpha(26),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified,
                            size: 10,
                            color: AppColors.success,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            'Verified',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.success,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Will conduct your inspection',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
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
          Text('Payment Breakdown', style: AppTextStyles.labelLarge),
          const SizedBox(height: 16),

          _buildPaymentRow('Agent Service Fee', _fee.agentServiceFee),
          const SizedBox(height: 8),
          _buildPaymentRow(
            'Transport Fee',
            _fee.transportFee,
            subtitle:
                _fee.agentCluster != _fee.propertyCluster
                    ? '${InspectionPricing.getClusterLabel(_fee.agentCluster)} → ${InspectionPricing.getClusterLabel(_fee.propertyCluster)}'
                    : 'Same zone',
          ),
          const SizedBox(height: 8),
          _buildPaymentRow('Platform Fee', _fee.clearrentFee),

          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: AppTextStyles.naira(AppTextStyles.h4)),
              Text(
                '₦${NumberFormat('#,###').format(_fee.totalFee)}',
                style: AppTextStyles.naira(AppTextStyles.h3).copyWith(color: AppColors.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentRow(String label, double amount, {String? subtitle}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTextStyles.bodyMedium),
            if (subtitle != null)
              Text(
                subtitle,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                ),
              ),
          ],
        ),
        Text(
          '₦${NumberFormat('#,###').format(amount)}',
          style: AppTextStyles.naira(AppTextStyles.labelMedium),
        ),
      ],
    );
  }

  Widget _buildRefundPolicy() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withAlpha(51)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: AppColors.success, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Full Refund Guarantee',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'If your inspection request is declined, you\'ll receive a full refund within 24 hours.',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}