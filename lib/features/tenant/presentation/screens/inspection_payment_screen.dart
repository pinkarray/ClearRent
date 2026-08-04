import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/paystack_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/screens/paystack_checkout_screen.dart';

/// Pay-after-approve: this screen pays for an inspection request the handler has
/// ALREADY approved. It no longer creates the request (the request is created
/// unpaid from the request sheet). On a successful charge it calls the
/// confirmInspectionPayment callable, which flips the request to paid and
/// reveals the exact address server-side.
class InspectionPaymentScreen extends StatefulWidget {
  final InspectionRequest request;

  const InspectionPaymentScreen({
    super.key,
    required this.request,
  });

  @override
  State<InspectionPaymentScreen> createState() =>
      _InspectionPaymentScreenState();
}

class _InspectionPaymentScreenState extends State<InspectionPaymentScreen> {
  final InspectionService _inspectionService = InspectionService();
  final ConversationService _conversationService = ConversationService();
  final AuthService _authService = AuthService();

  /// Openers offered to the tenant in the chat once payment is in. The fee buys
  /// the connection — transport is settled directly with the handler, so that's
  /// the question most tenants actually need to ask first.
  static const List<String> _handlerSuggestions = [
    'How much would transport to the property cost?',
    'How do I get to the property?',
    'Hi — I\'ve just paid for the inspection. Anything I should know before I come?',
  ];

  bool _isProcessing = false;
  String? _paymentReference;

  double get _totalFee => widget.request.totalFee;

  String get _formattedDate {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    final d = widget.request.requestedDate;
    return '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
  }

  String get _formattedTime {
    return InspectionService.timeSlotDisplay[widget.request.requestedTimeSlot] ??
        widget.request.requestedTimeDisplay;
  }

  Future<void> _initiatePayment() async {
    setState(() => _isProcessing = true);

    try {
      final paymentResult = await PaystackCheckoutScreen.launch(
        context: context,
        amount: _totalFee,
        type: PaystackService.typeInspection,
        metadata: {
          'propertyId': widget.request.propertyId,
          'propertyTitle': widget.request.propertyTitle,
          'requestId': widget.request.id,
          'description': 'Inspection fee for ${widget.request.propertyTitle}',
        },
      );

      if (!mounted) return;

      if (paymentResult == null) {
        setState(() => _isProcessing = false); // cancelled
        return;
      }

      if (!paymentResult.success) {
        _showError('Payment was not completed. Please try again.');
        setState(() => _isProcessing = false);
        return;
      }

      _paymentReference = paymentResult.reference;

      // Record the payment (display receipt); the webhook reconciles it.
      await PaystackService().recordPayment(
        reference: paymentResult.reference,
        type: PaystackService.typeInspection,
        amount: paymentResult.amountPaid ?? _totalFee,
        status: 'completed',
        extra: {
          'propertyId': widget.request.propertyId,
          'requestId': widget.request.id,
        },
      );

      // Confirm server-side: flips the request to paid and reveals the exact
      // address (both must happen server-side — the reveal is handler-only by
      // rule). This is what "unlocks" the inspection.
      await _confirmPayment();
    } catch (e) {
      debugPrint('❌ Payment error: $e');
      _showError('Payment failed. Please try again.');
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _confirmPayment() async {
    try {
      final ok = await _inspectionService.confirmInspectionPayment(
        widget.request.id,
        paymentReference: _paymentReference,
      );

      if (!mounted) return;

      if (ok) {
        _showSuccessDialog();
      } else {
        // Payment succeeded but the server couldn't confirm — offer retry.
        _showConfirmFailureDialog();
      }
    } catch (e) {
      debugPrint('❌ Error confirming payment: $e');
      if (mounted) _showConfirmFailureDialog(error: e.toString());
    }
  }

  Future<void> _retryConfirm() async {
    setState(() => _isProcessing = true);
    Navigator.pop(context); // close the failure dialog
    await _confirmPayment();
  }

  /// Open (or reuse) the tenant↔handler thread and drop the tenant into it with
  /// openers to tap. Called from the success dialog (already popped by now).
  Future<void> _messageHandler() async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final profile = await _authService.getUserProfile();
    if (!mounted) return;

    final conversation = await _conversationService.getOrCreateConversation(
      propertyId: widget.request.propertyId,
      propertyTitle: widget.request.propertyTitle,
      propertyImage: widget.request.propertyImage,
      landlordId: widget.request.landlordId,
      landlordName: widget.request.landlordName,
      tenantId: _authService.currentUser?.uid ?? '',
      tenantName: profile?['fullName'] ?? 'Tenant',
      agentId: widget.request.agentId,
      agentName: widget.request.agentName,
    );

    if (!mounted) return;

    if (conversation == null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'Could not open the chat. You can message them from Inspections.',
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      router.go('/tenant/inspections');
      return;
    }

    router.pushReplacement('/chat', extra: {
      'conversationId': conversation.id,
      'propertyTitle': widget.request.propertyTitle,
      'propertyImage': widget.request.propertyImage,
      'suggestions': _handlerSuggestions,
    });
  }

  void _showConfirmFailureDialog({String? error}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
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
              child: Icon(Icons.info_outline, color: AppColors.warning, size: 48),
            ),
            const SizedBox(height: 24),
            Text('Confirmation Failed',
                style: AppTextStyles.h3, textAlign: TextAlign.center),
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
                  Icon(Icons.check_circle, color: AppColors.success, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Payment (₦${NumberFormat('#,###').format(_totalFee)}) was successful',
                      style: AppTextStyles.naira(AppTextStyles.caption)
                          .copyWith(color: AppColors.success),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Your payment went through, but we couldn\'t confirm your '
              'inspection automatically. Tap retry.',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isProcessing ? null : _retryConfirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(_isProcessing ? 'Retrying...' : 'Retry',
                    style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _isProcessing
                  ? null
                  : () {
                      Navigator.pop(context);
                      _showContactSupportOption();
                    },
              child: Text('Contact Support',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.error)),
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
                  Text('Payment Reference (Share with support)',
                      style: AppTextStyles.labelSmall
                          .copyWith(color: Colors.white)),
                  Text(_paymentReference ?? 'N/A',
                      style: AppTextStyles.caption.copyWith(color: Colors.white)),
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
      builder: (context) => AlertDialog(
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
              child: Icon(Icons.check_circle, color: AppColors.success, size: 48),
            ),
            const SizedBox(height: 24),
            Text('Inspection Confirmed!',
                style: AppTextStyles.h3, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Your payment is confirmed and the exact address is now unlocked. '
              'Message the handler to agree on directions and transport before '
              'your visit.',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
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
                      Icon(Icons.calendar_today,
                          size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(_formattedDate, style: AppTextStyles.labelMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.access_time,
                          size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(_formattedTime, style: AppTextStyles.labelMedium),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _messageHandler();
                },
                icon: const Icon(Icons.chat_bubble_outline,
                    size: 18, color: Colors.white),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                label: Text('Message the handler',
                    style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.go('/tenant/inspections');
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: AppColors.primary.withAlpha(77)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('View My Inspections',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.primary)),
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
            _buildApprovedBanner(),
            const SizedBox(height: 24),
            _buildPropertySummary(),
            const SizedBox(height: 24),
            _buildScheduleSummary(),
            const SizedBox(height: 24),
            _buildHandlerInfo(),
            const SizedBox(height: 24),
            _buildPaymentBreakdown(),
            const SizedBox(height: 32),
            AppButton(
              text: 'Pay ₦${NumberFormat('#,###').format(_totalFee)}',
              onPressed: _isProcessing ? null : _initiatePayment,
              isLoading: _isProcessing,
            ),
            const SizedBox(height: 16),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock, size: 14, color: AppColors.textHint),
                  const SizedBox(width: 6),
                  Text('Secured by Paystack',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApprovedBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withAlpha(64)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified, size: 20, color: AppColors.success),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Approved by the handler',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.success)),
                const SizedBox(height: 2),
                Text(
                  'Pay now to confirm your inspection and unlock the exact '
                  'address.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
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
            child: widget.request.propertyImage.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: widget.request.propertyImage,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => Container(
                      width: 80,
                      height: 80,
                      color: AppColors.background,
                      child: Icon(Icons.home, color: AppColors.textHint),
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
                Text(widget.request.propertyTitle,
                    style: AppTextStyles.labelLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.location_on,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.request.propertyAddress,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
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
                child: Icon(Icons.calendar_today, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Date',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary)),
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
                    Text('Time',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary)),
                    Text(_formattedTime, style: AppTextStyles.labelMedium),
                  ],
                ),
              ),
            ],
          ),
          if (widget.request.notes != null &&
              widget.request.notes!.isNotEmpty) ...[
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
                      Text('Notes',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary)),
                      Text(widget.request.notes!,
                          style: AppTextStyles.bodySmall),
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

  Widget _buildHandlerInfo() {
    final isAgent = widget.request.isAgentHandled;
    final handlerName = isAgent
        ? (widget.request.agentName ?? 'Agent')
        : widget.request.landlordName;

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
              color: isAgent
                  ? AppColors.info.withAlpha(26)
                  : AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isAgent ? Icons.support_agent : Icons.person,
              color: isAgent ? AppColors.info : AppColors.primary,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(handlerName,
                    style: AppTextStyles.labelLarge,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(
                  isAgent
                      ? 'Agent will conduct your inspection'
                      : 'Landlord will handle your inspection',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
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
          _buildPaymentRow('Inspection fee', _totalFee),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: AppTextStyles.naira(AppTextStyles.h4)),
              Text(
                '₦${NumberFormat('#,###').format(_totalFee)}',
                style: AppTextStyles.naira(AppTextStyles.h3)
                    .copyWith(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withAlpha(64)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.directions_car_outlined,
                    size: 16, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Transport to and from the property is arranged directly '
                    'with the agent or landlord. ClearRent does not collect '
                    'transport money.',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentRow(String label, double amount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTextStyles.bodyMedium),
        Text(
          '₦${NumberFormat('#,###').format(amount)}',
          style: AppTextStyles.naira(AppTextStyles.labelMedium),
        ),
      ],
    );
  }
}
