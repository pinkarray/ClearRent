import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/inspection_service.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../widgets/manual_payment_sheet.dart';

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
    if (widget.property.inspectionHandler != 'agent') return;

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

  bool get _canSubmit =>
      _selectedDate != null &&
      _selectedTimeSlot != null &&
      !_isSubmitting &&
      !_hasExistingRequest;

  Future<void> _submitRequest() async {
    if (!_canSubmit) return;

    // If agent-handled, show manual payment sheet
    if (_isAgentHandled) {
      // Close this sheet first
      Navigator.pop(context);
      
      // Get the fee breakdown (use default if not loaded)
      final feeBreakdown = _feeBreakdown ?? InspectionPricing.calculateFee(distanceKm: 0);
      
      // Show the manual payment sheet
      final result = await ManualPaymentSheet.show(
        context,
        property: widget.property,
        selectedDate: _selectedDate!,
        selectedTimeSlot: _selectedTimeSlot!,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        feeBreakdown: feeBreakdown,
      );
      
      // If payment was submitted successfully, trigger callback
      if (result == true) {
        widget.onRequestSent?.call();
      }
      return;
    }

    // Self-handled: create request directly (no payment needed)
    setState(() => _isSubmitting = true);

    try {
      final result = await _inspectionService.createInspectionRequest(
        property: widget.property,
        requestedDate: _selectedDate!,
        requestedTimeSlot: _selectedTimeSlot!,
        notes:
            _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
      );

      if (!mounted) return;

      if (result == 'already_pending') {
        _showError('You already have a pending request for this property');
        setState(() => _isSubmitting = false);
        return;
      }

      if (result != null) {
        Navigator.pop(context, true);
        _showSuccess(
          'Inspection request sent! The landlord will review it shortly.',
        );
        widget.onRequestSent?.call();
      } else {
        _showError('Failed to send request. Please try again.');
        setState(() => _isSubmitting = false);
      }
    } catch (e) {
      debugPrint('❌ Error submitting request: $e');
      _showError('Something went wrong. Please try again.');
      setState(() => _isSubmitting = false);
    }
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                  _buildDateSelection(),
                  const SizedBox(height: 24),

                  // Time slot selection
                  Text('Select Time', style: AppTextStyles.labelLarge),
                  const SizedBox(height: 12),
                  _buildTimeSlotSelection(),
                  const SizedBox(height: 24),

                  // Notes (optional)
                  Text('Notes (Optional)', style: AppTextStyles.labelLarge),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    maxLines: 3,
                    maxLength: 200,
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

                  // Fee breakdown (for agent-handled)
                  if (_isAgentHandled) ...[
                    const SizedBox(height: 24),
                    _buildFeeBreakdown(),
                  ],

                  const SizedBox(height: 24),

                  // Submit button
                  AppButton(
                    text:
                        _isAgentHandled
                            ? (_feeBreakdown != null 
                                ? 'Pay ₦${NumberFormat('#,###').format(_feeBreakdown!.totalFee)} & Request'
                                : 'Continue to Payment')
                            : 'Send Request',
                    onPressed: _canSubmit ? _submitRequest : null,
                    isLoading: _isSubmitting,
                  ),

                  const SizedBox(height: 12),

                  // Info text
                  Center(
                    child: Text(
                      _isAgentHandled
                          ? 'You\'ll transfer payment and upload proof on the next screen'
                          : 'The landlord will review and respond to your request',
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

  Widget _buildDateSelection() {
    if (_isLoadingDates) {
      return Container(
        height: 80,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (_availableDates.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(Icons.event_busy, size: 40, color: AppColors.textHint),
            const SizedBox(height: 8),
            Text(
              'No available dates',
              style: AppTextStyles.labelMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'The property owner hasn\'t set inspection availability',
              style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _availableDates.length,
        itemBuilder: (context, index) {
          final date = _availableDates[index];
          final isSelected =
              _selectedDate != null &&
              _selectedDate!.year == date.year &&
              _selectedDate!.month == date.month &&
              _selectedDate!.day == date.day;

          final isToday =
              DateTime.now().year == date.year &&
              DateTime.now().month == date.month &&
              DateTime.now().day == date.day;

          final isTomorrow =
              DateTime.now().add(const Duration(days: 1)).year == date.year &&
              DateTime.now().add(const Duration(days: 1)).month == date.month &&
              DateTime.now().add(const Duration(days: 1)).day == date.day;

          return GestureDetector(
            onTap: () {
              setState(() => _selectedDate = date);
              _loadTimeSlots(date);
            },
            child: Container(
              width: 70,
              margin: EdgeInsets.only(
                right: index < _availableDates.length - 1 ? 12 : 0,
              ),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    DateFormat('EEE').format(date),
                    style: AppTextStyles.caption.copyWith(
                      color:
                          isSelected
                              ? Colors.white.withAlpha(179)
                              : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('d').format(date),
                    style: AppTextStyles.h3.copyWith(
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    DateFormat('MMM').format(date),
                    style: AppTextStyles.caption.copyWith(
                      color:
                          isSelected
                              ? Colors.white.withAlpha(179)
                              : AppColors.textSecondary,
                    ),
                  ),
                  if (isToday || isTomorrow) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color:
                            isSelected
                                ? Colors.white.withAlpha(51)
                                : AppColors.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isToday ? 'Today' : 'Tomorrow',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? Colors.white : AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTimeSlotSelection() {
    if (_selectedDate == null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            'Select a date first',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }

    if (_isLoadingSlots) {
      return Container(
        height: 60,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (_availableTimeSlots.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            'No time slots available for this date',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children:
          _availableTimeSlots.map((slot) {
            final isSelected = _selectedTimeSlot == slot;
            final label = InspectionService.timeSlotLabels[slot] ?? slot;
            final time = InspectionService.timeSlotDisplay[slot] ?? '';

            return GestureDetector(
              onTap: () => setState(() => _selectedTimeSlot = slot),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.border,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTextStyles.labelMedium.copyWith(
                        color:
                            isSelected ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: AppTextStyles.caption.copyWith(
                        color:
                            isSelected
                                ? Colors.white.withAlpha(179)
                                : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
    );
  }

  Widget _buildFeeBreakdown() {
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
            _buildFeeRow('Agent Service Fee', _feeBreakdown!.agentServiceFee),
            _buildFeeRow('Transport Fee', _feeBreakdown!.transportFee),
            _buildFeeRow('Platform Fee', _feeBreakdown!.clearrentFee),
            const Divider(height: 16),
            _buildFeeRow('Total', _feeBreakdown!.totalFee, isTotal: true),
          ] else ...[
            _buildFeeRow('Agent Service Fee', 5000),
            _buildFeeRow('Transport Fee', 2000),
            _buildFeeRow('Platform Fee', 3000),
            const Divider(height: 16),
            _buildFeeRow('Total', 10000, isTotal: true),
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
                    ? AppTextStyles.naira(AppTextStyles.h4).copyWith(color: AppColors.primary)
                    : AppTextStyles.naira(AppTextStyles.labelMedium),
          ),
        ],
      ),
    );
  }
}