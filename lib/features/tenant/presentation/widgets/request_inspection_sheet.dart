import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/date_time_slot_picker.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../core/utils/inspection_pricing.dart';
import 'package:go_router/go_router.dart';

class RequestInspectionSheet extends StatefulWidget {
  final PropertyModel property;
  final VoidCallback? onRequestSent;

  const RequestInspectionSheet({
    super.key,
    required this.property,
    this.onRequestSent,
  });

  /// Show the bottom sheet
  static Future<bool?> show(BuildContext context, PropertyModel property) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => RequestInspectionSheet(property: property),
    );
  }

  @override
  State<RequestInspectionSheet> createState() => _RequestInspectionSheetState();
}

class _RequestInspectionSheetState extends State<RequestInspectionSheet> {
  final InspectionService _inspectionService = InspectionService();
  final AuthService _authService = AuthService();
  final TextEditingController _notesController = TextEditingController();

  DateTime? _selectedDate;
  String? _selectedTimeSlot;
  List<DateTime> _availableDates = [];
  List<String> _availableTimeSlots = [];

  bool _isLoadingDates = true;
  bool _isLoadingSlots = false;
  bool _isSubmitting = false;
  bool _hasExistingRequest = false;

  InspectionFeeBreakdown? _feeBreakdown;

  @override
  void initState() {
    super.initState();
    _loadAvailableDates();
    _checkExistingRequest();
    _loadFeeBreakdown();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _checkExistingRequest() async {
    final hasRequest = await _inspectionService.hasPendingRequest(
      widget.property.id,
    );
    if (mounted) {
      setState(() => _hasExistingRequest = hasRequest);
    }
  }

  Future<void> _loadAvailableDates() async {
    setState(() => _isLoadingDates = true);

    try {
      final dates = await _inspectionService.getAvailableDates(widget.property);
      if (mounted) {
        setState(() {
          _availableDates = dates;
          _isLoadingDates = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading dates: $e');
      if (mounted) {
        setState(() => _isLoadingDates = false);
      }
    }
  }

  Future<void> _loadTimeSlots(DateTime date) async {
    setState(() {
      _isLoadingSlots = true;
      _selectedTimeSlot = null;
    });

    try {
      final slots = await _inspectionService.getAvailableTimeSlots(
        widget.property,
        date,
      );
      if (mounted) {
        setState(() {
          _availableTimeSlots = slots;
          _isLoadingSlots = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading time slots: $e');
      if (mounted) {
        setState(() => _isLoadingSlots = false);
      }
    }
  }

  Future<void> _loadFeeBreakdown() async {
    try {
      final breakdown = await _inspectionService.calculateInspectionFee(
        property: widget.property,
      );
      if (mounted) {
        setState(() => _feeBreakdown = breakdown);
      }
    } catch (e) {
      debugPrint('❌ Error loading fee: $e');
    }
  }

  bool get _isAgentHandled =>
      widget.property.inspectionHandler == 'agent' &&
      widget.property.assignedAgentId != null;

  // Readiness gate (Phase 2): a property is only bookable once its handler has
  // vetted it. Block before payment so the tenant is never charged and blocked.
  bool get _notReady => !widget.property.readyForInspections;

  bool get _canSubmit =>
      _selectedDate != null &&
      _selectedTimeSlot != null &&
      !_isSubmitting &&
      !_hasExistingRequest &&
      !_notReady;

  Future<void> _submitRequest() async {
    if (!_canSubmit) return;
    // Latch before the first await below. Setting this only at the write call
    // left a round-trip-wide window in which a second tap still passed
    // _canSubmit, so both taps reached createInspectionRequest and both read
    // the already_pending check before either had written.
    setState(() => _isSubmitting = true);

    // Gate: the tenant must have a payout account on file before requesting.
    // If an inspection falls through in dispute (e.g. handler no-show), the
    // refund needs somewhere to go — and admin can only settle it if the
    // account exists. Enforced server-side in firestore.rules too. Checked
    // before payment so the tenant is never charged and then blocked.
    final hasBank = await _authService.hasBankDetails();
    if (!mounted) return;
    if (!hasBank) {
      setState(() => _isSubmitting = false);
      final router = GoRouter.of(context);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context); // close the sheet
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Add your bank account first - it\'s where your money goes if an '
            'inspection is refunded.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      router.push('/tenant/bank-details');
      return;
    }

    // Build the fee breakdown — use calculated or a sensible fallback
    final feeBreakdown = _feeBreakdown ?? (_isAgentHandled
        ? InspectionPricing.calculateFee(
            agentCluster: 'maryland_ikeja',
            propertyCluster: 'maryland_ikeja',
          )
        : InspectionPricing.calculateSelfHandledFee(
            landlordLivesInProperty: widget.property.landlordLivesInProperty,
            propertyCluster: 'maryland_ikeja',
          ));

    final notes = _notesController.text.trim().isEmpty
        ? null
        : _notesController.text.trim();

    // Pay-after-approve: create the request UNPAID now. The tenant pays only
    // after the handler approves (no navigation to a payment screen here).
    final messenger = ScaffoldMessenger.of(context);

    final result = await _inspectionService.createInspectionRequest(
      property: widget.property,
      requestedDate: _selectedDate!,
      requestedTimeSlot: _selectedTimeSlot!,
      notes: notes,
      feeBreakdown: feeBreakdown,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    Navigator.pop(context); // close the sheet

    // Success returns the new request id; everything else is an error code.
    const errorMessages = {
      'not_verified': 'Your account isn\'t verified yet.',
      'landlord_not_verified': 'This property\'s owner isn\'t verified yet.',
      'agent_not_verified': 'The assigned agent isn\'t verified yet.',
      // Distinct from the three above on purpose: we could not reach the
      // server to check, which is not the same as a failed check. Saying
      // "not verified" here told verified users their account wasn't.
      'check_failed':
          'Couldn\'t confirm account details. Check your connection and '
              'try again.',
      'property_not_ready': 'This property isn\'t ready for inspections yet.',
      'already_pending':
          'You already have a pending request for this property.',
    };
    if (result == null || errorMessages.containsKey(result)) {
      messenger.showSnackBar(SnackBar(
        content: Text(errorMessages[result] ??
            'Something went wrong. Please try again.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    messenger.showSnackBar(const SnackBar(
      content: Text(
        'Inspection request sent! You\'ll be asked to pay once the handler '
        'approves - no charge until then.',
      ),
      behavior: SnackBarBehavior.floating,
    ));
    widget.onRequestSent?.call();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Request Inspection', style: AppTextStyles.h3),
                      const SizedBox(height: 4),
                      Text(
                        widget.property.title,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.background,
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Content
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Not-ready gate — the handler hasn't vetted this property yet.
                  if (_notReady) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.info.withAlpha(77)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.hourglass_top,
                              color: AppColors.info, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _isAgentHandled
                                  ? 'The agent is preparing this property for '
                                      'inspections. Check back soon.'
                                  : 'The landlord is preparing this property '
                                      'for inspections. Check back soon.',
                              style: AppTextStyles.bodySmall.copyWith(
                                color: AppColors.info,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Already has request warning
                  if (_hasExistingRequest) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.warning.withAlpha(77),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppColors.warning,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'You already have an active inspection request for this property.',
                              style: AppTextStyles.bodySmall.copyWith(
                                color: AppColors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Handler info
                  _buildHandlerInfo(),
                  const SizedBox(height: 24),

                  // Date selection
                  Text('Select Date', style: AppTextStyles.labelLarge),
                  const SizedBox(height: 12),
                  DateStrip(
                    availableDates: _availableDates,
                    selectedDate: _selectedDate,
                    isLoading: _isLoadingDates,
                    onDateSelected: (date) {
                      setState(() => _selectedDate = date);
                      _loadTimeSlots(date);
                    },
                  ),
                  const SizedBox(height: 24),

                  // Time slot selection
                  Text('Select Time', style: AppTextStyles.labelLarge),
                  const SizedBox(height: 12),
                  TimeSlotWrap(
                    availableTimeSlots: _availableTimeSlots,
                    selectedTimeSlot: _selectedTimeSlot,
                    selectedDate: _selectedDate,
                    isLoading: _isLoadingSlots,
                    onTimeSlotSelected: (slot) =>
                        setState(() => _selectedTimeSlot = slot),
                  ),
                  const SizedBox(height: 24),

                  // Notes (optional)
                  Text('Notes (Optional)', style: AppTextStyles.labelLarge),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    maxLines: 3,
                    maxLength: 200,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Any special requests or questions...',
                      hintStyle: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textHint,
                      ),
                      filled: true,
                      fillColor: AppColors.background,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),

                  // Fee breakdown (always shown)
                  const SizedBox(height: 24),
                  _buildFeeBreakdown(),

                  const SizedBox(height: 24),

                  // Submit button
                  AppButton(
                    // Pay-after-approve: no charge happens at this tap, so the
                    // label must not promise one. The fee is shown in the
                    // breakdown above.
                    text: 'Request Inspection',
                    onPressed: _canSubmit ? _submitRequest : null,
                    isLoading: _isSubmitting,
                  ),

                  const SizedBox(height: 12),

                  // Info text
                  Center(
                    child: Text(
                      'You\'ll transfer payment and upload proof on the next screen',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHandlerInfo() {
    final isAgent = _isAgentHandled;
    final handlerName =
        isAgent
            ? (widget.property.assignedAgentName ?? 'Agent')
            : (widget.property.landlordName ?? 'Landlord');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color:
                  isAgent
                      ? AppColors.info.withAlpha(26)
                      : AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isAgent ? Icons.support_agent : Icons.person,
              color: isAgent ? AppColors.info : AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAgent ? 'Handled by Agent' : 'Handled by Landlord',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: isAgent ? AppColors.info : AppColors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(handlerName, style: AppTextStyles.bodyMedium),
              ],
            ),
          ),
          if (isAgent)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(26),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.verified,
                    size: 12,
                    color: AppColors.success,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Verified',
                    style: AppTextStyles.labelSmall.copyWith(
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeeBreakdown() {
    final isAgent = _isAgentHandled;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.info.withAlpha(51)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long, size: 20, color: AppColors.info),
              const SizedBox(width: 8),
              Text(
                'Inspection Fee',
                style: AppTextStyles.labelLarge.copyWith(color: AppColors.info),
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (_feeBreakdown != null) ...[
            // Agent-handled shows agent service fee; self-handled shows booking fee
            if (isAgent)
              _buildFeeRow('Agent Service Fee', _feeBreakdown!.agentServiceFee)
            else
              _buildFeeRow('Booking Fee', _feeBreakdown!.tenantServiceCharge),
            if (_feeBreakdown!.transportFee > 0)
              _buildFeeRow('Transport Fee', _feeBreakdown!.transportFee),
            if (isAgent)
              _buildFeeRow('Platform Fee', _feeBreakdown!.clearrentFee),
            const Divider(height: 16),
            _buildFeeRow('Total', _feeBreakdown!.totalFee, isTotal: true),
          ] else ...[
            // Fallback while loading
            if (isAgent) ...[
              _buildFeeRow('Agent Service Fee', 10000),
              _buildFeeRow('Transport Fee', 1000),
              _buildFeeRow('Platform Fee', 3000),
              const Divider(height: 16),
              _buildFeeRow('Total', 14000, isTotal: true),
            ] else ...[
              _buildFeeRow('Booking Fee', 3000),
              const Divider(height: 16),
              _buildFeeRow('Total', 3000, isTotal: true),
            ],
          ],

          const SizedBox(height: 8),
          Text(
            'Full refund if inspection is declined',
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildFeeRow(String label, double amount, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style:
                isTotal
                    ? AppTextStyles.labelLarge
                    : AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
          ),
          Text(
            '₦${NumberFormat('#,###').format(amount)}',
            style:
                isTotal
                    ? AppTextStyles.h4.copyWith(color: AppColors.primary)
                    : AppTextStyles.labelMedium,
          ),
        ],
      ),
    );
  }
}
