import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../models/inspection_request_model.dart';
import '../models/property_model.dart';
import '../../services/inspection_service.dart';
import 'app_button.dart';
import 'date_time_slot_picker.dart';

/// Result from the reschedule propose sheet.
class ReschedulePayload {
  final DateTime date;
  final String timeSlot;
  final String reason;

  ReschedulePayload({
    required this.date,
    required this.timeSlot,
    required this.reason,
  });
}

/// Bottom sheet for proposing or counter-proposing a reschedule.
/// Returns a [ReschedulePayload] when submitted, null when dismissed.
class ReschedulePropoSheet extends StatefulWidget {
  final InspectionRequest request;
  final bool isCounter;

  const ReschedulePropoSheet({
    super.key,
    required this.request,
    this.isCounter = false,
  });

  static Future<ReschedulePayload?> show(
    BuildContext context,
    InspectionRequest request, {
    bool isCounter = false,
  }) {
    return showModalBottomSheet<ReschedulePayload>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ReschedulePropoSheet(
        request: request,
        isCounter: isCounter,
      ),
    );
  }

  @override
  State<ReschedulePropoSheet> createState() =>
      _ReschedulePropoSheetState();
}

class _ReschedulePropoSheetState extends State<ReschedulePropoSheet> {
  final InspectionService _inspectionService = InspectionService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _reasonController = TextEditingController();

  PropertyModel? _property;
  DateTime? _selectedDate;
  String? _selectedTimeSlot;
  List<DateTime> _availableDates = [];
  List<String> _availableTimeSlots = [];

  bool _isLoadingProperty = true;
  bool _isLoadingSlots = false;
  bool _isSubmitting = false;

  static const int _minReasonLength = 10;

  @override
  void initState() {
    super.initState();
    _loadProperty();
    _reasonController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _loadProperty() async {
    try {
      final doc = await _firestore
          .collection('properties')
          .doc(widget.request.propertyId)
          .get();
      if (!doc.exists || doc.data() == null) {
        if (mounted) setState(() => _isLoadingProperty = false);
        return;
      }
      final property = PropertyModel.fromFirestore(doc.data()!, doc.id);
      final dates = await _inspectionService.getAvailableDates(property);
      // Filter out dates whose slot start is within the 2h cutoff.
      // For now, this means just dropping today if any slot is too
      // close — slot-level filtering happens once a date is picked.
      final filtered = dates.where((d) {
        final cutoff = DateTime.now().add(const Duration(hours: 2));
        // The earliest slot starts at 9 AM (per InspectionService.timeSlotDisplay).
        final earliestSlotStart =
            DateTime(d.year, d.month, d.day, 9, 0);
        return earliestSlotStart.isAfter(cutoff);
      }).toList();
      if (mounted) {
        setState(() {
          _property = property;
          _availableDates = filtered;
          _isLoadingProperty = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingProperty = false);
    }
  }

  Future<void> _loadTimeSlots(DateTime date) async {
    if (_property == null) return;
    setState(() {
      _isLoadingSlots = true;
      _selectedTimeSlot = null;
    });

    try {
      final slots = await _inspectionService.getAvailableTimeSlots(
        _property!,
        date,
      );
      // Filter slots within the 2h cutoff window for the chosen date.
      final cutoff = DateTime.now().add(const Duration(hours: 2));
      final slotStartHour = {
        'morning': 9,
        'afternoon': 12,
        'late_afternoon': 15,
        'evening': 18,
      };
      final filtered = slots.where((slot) {
        final hour = slotStartHour[slot] ?? 9;
        final slotStart =
            DateTime(date.year, date.month, date.day, hour, 0);
        return slotStart.isAfter(cutoff);
      }).toList();

      if (mounted) {
        setState(() {
          _availableTimeSlots = filtered;
          _isLoadingSlots = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingSlots = false);
    }
  }

  bool get _canSubmit =>
      _selectedDate != null &&
      _selectedTimeSlot != null &&
      _reasonController.text.trim().length >= _minReasonLength &&
      !_isSubmitting;

  Future<void> _handleSubmit() async {
    if (!_canSubmit) return;
    setState(() => _isSubmitting = true);

    final payload = ReschedulePayload(
      date: _selectedDate!,
      timeSlot: _selectedTimeSlot!,
      reason: _reasonController.text.trim(),
    );

    if (mounted) Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final title =
        widget.isCounter ? 'Counter-propose' : 'Propose Reschedule';

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: mediaQuery.size.height * 0.9,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textHint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: AppTextStyles.h3),
                        const SizedBox(height: 4),
                        Text(
                          widget.request.propertyTitle,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoadingProperty
                  ? Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Current scheduled date reminder
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.info.withAlpha(13),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppColors.info.withAlpha(51),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.event,
                                  size: 18,
                                  color: AppColors.info,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Current: ${_formatDate(widget.request.requestedDate)} '
                                    '— ${widget.request.requestedTimeDisplay}',
                                    style: AppTextStyles.bodySmall.copyWith(
                                      color: AppColors.info,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),

                          Text(
                            'New Date',
                            style: AppTextStyles.labelLarge,
                          ),
                          const SizedBox(height: 12),
                          DateStrip(
                            availableDates: _availableDates,
                            selectedDate: _selectedDate,
                            isLoading: false,
                            onDateSelected: (date) {
                              setState(() => _selectedDate = date);
                              _loadTimeSlots(date);
                            },
                            emptyMessage:
                                'No alternative dates available within '
                                'the property\'s schedule.',
                          ),
                          const SizedBox(height: 24),

                          Text(
                            'New Time',
                            style: AppTextStyles.labelLarge,
                          ),
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

                          Text(
                            'Reason',
                            style: AppTextStyles.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'The other party will see this.',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _reasonController,
                            maxLines: 3,
                            maxLength: 200,
                            decoration: InputDecoration(
                              hintText:
                                  'Why are you proposing this change?',
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
                              counterText:
                                  '${_reasonController.text.trim().length}'
                                  ' / $_minReasonLength',
                              counterStyle:
                                  AppTextStyles.caption.copyWith(
                                color: _reasonController.text.trim().length >=
                                        _minReasonLength
                                    ? AppColors.success
                                    : AppColors.textHint,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
            ),
            // Submit footer
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  top: BorderSide(color: AppColors.border),
                ),
              ),
              child: AppButton(
                text: widget.isCounter
                    ? 'Send Counter-proposal'
                    : 'Send Proposal',
                onPressed: _canSubmit ? _handleSubmit : null,
                isLoading: _isSubmitting,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}