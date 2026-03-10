import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';

class AgentAvailabilityScreen extends StatefulWidget {
  const AgentAvailabilityScreen({super.key});

  @override
  State<AgentAvailabilityScreen> createState() => _AgentAvailabilityScreenState();
}

class _AgentAvailabilityScreenState extends State<AgentAvailabilityScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _isLoading = true;
  bool _isSaving = false;

  // Available days
  final List<String> _allDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  List<String> _selectedDays = [];

  // Available time slots
  final Map<String, String> _allTimeSlots = {
    'morning': 'Morning (9AM - 12PM)',
    'afternoon': 'Afternoon (12PM - 3PM)',
    'late_afternoon': 'Late Afternoon (3PM - 6PM)',
    'evening': 'Evening (6PM - 8PM)',
  };
  List<String> _selectedTimeSlots = [];

  // Blocked dates
  List<BlockedDateRange> _blockedDates = [];

  @override
  void initState() {
    super.initState();
    _loadAvailability();
  }

  Future<void> _loadAvailability() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      final data = doc.data();

      if (data != null) {
        setState(() {
          _selectedDays = List<String>.from(data['availableDays'] ?? [
            'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
          ]);
          _selectedTimeSlots = List<String>.from(data['availableTimeSlots'] ?? [
            'morning', 'afternoon', 'late_afternoon'
          ]);
          
          // Parse blocked dates
          final blockedList = List<Map<String, dynamic>>.from(data['blockedDates'] ?? []);
          _blockedDates = blockedList.map((b) => BlockedDateRange(
            start: DateTime.parse(b['start']),
            end: DateTime.parse(b['end']),
            reason: b['reason'] ?? '',
          )).toList();
          
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('❌ Error loading availability: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveAvailability() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    if (_selectedDays.isEmpty) {
      _showError('Please select at least one available day');
      return;
    }

    if (_selectedTimeSlots.isEmpty) {
      _showError('Please select at least one time slot');
      return;
    }

    setState(() => _isSaving = true);

    try {
      await _firestore.collection('users').doc(userId).update({
        'availableDays': _selectedDays,
        'availableTimeSlots': _selectedTimeSlots,
        'blockedDates': _blockedDates.map((b) => b.toJson()).toList(),
        'availabilityUpdatedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Availability saved successfully!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        context.pop();
      }
    } catch (e) {
      debugPrint('❌ Error saving availability: $e');
      _showError('Failed to save availability. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _toggleDay(String day) {
    setState(() {
      if (_selectedDays.contains(day)) {
        _selectedDays.remove(day);
      } else {
        _selectedDays.add(day);
      }
    });
  }

  void _toggleTimeSlot(String slot) {
    setState(() {
      if (_selectedTimeSlots.contains(slot)) {
        _selectedTimeSlots.remove(slot);
      } else {
        _selectedTimeSlots.add(slot);
      }
    });
  }

  Future<void> _addBlockedDates() async {
    final result = await showDialog<BlockedDateRange>(
      context: context,
      builder: (context) => const _AddBlockedDatesDialog(),
    );

    if (result != null) {
      setState(() {
        _blockedDates.add(result);
        // Sort by start date
        _blockedDates.sort((a, b) => a.start.compareTo(b.start));
      });
    }
  }

  void _removeBlockedDate(int index) {
    setState(() {
      _blockedDates.removeAt(index);
    });
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
          onPressed: () => context.pop(),
        ),
        title: Text('My Availability', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.info.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.info.withAlpha(77)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: AppColors.info, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Set your availability so tenants can only request inspections when you\'re free.',
                            style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Available Days Section
                  _buildSectionHeader(
                    'Available Days',
                    'Days you can conduct inspections',
                    Icons.calendar_today_outlined,
                  ),
                  const SizedBox(height: 12),
                  _buildDaysSelector(),

                  const SizedBox(height: 24),

                  // Time Slots Section
                  _buildSectionHeader(
                    'Time Slots',
                    'Times you\'re available for inspections',
                    Icons.access_time_outlined,
                  ),
                  const SizedBox(height: 12),
                  _buildTimeSlotsSelector(),

                  const SizedBox(height: 24),

                  // Blocked Dates Section
                  _buildSectionHeader(
                    'Blocked Dates',
                    'Mark dates when you\'re unavailable',
                    Icons.event_busy_outlined,
                  ),
                  const SizedBox(height: 12),
                  _buildBlockedDatesSection(),

                  const SizedBox(height: 32),

                  // Save Button
                  SizedBox(
                    width: double.infinity,
                    child: AppButton(
                      text: 'Save Availability',
                      onPressed: _isSaving ? null : _saveAvailability,
                      isLoading: _isSaving,
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title, String subtitle, IconData icon) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(26),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTextStyles.h4),
              Text(
                subtitle,
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDaysSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _allDays.map((day) {
          final isSelected = _selectedDays.contains(day);
          return GestureDetector(
            onTap: () => _toggleDay(day),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : AppColors.background,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSelected) ...[
                    const Icon(Icons.check, color: Colors.white, size: 16),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    day.substring(0, 3), // Mon, Tue, etc.
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTimeSlotsSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: _allTimeSlots.entries.map((entry) {
          final isSelected = _selectedTimeSlots.contains(entry.key);
          return GestureDetector(
            onTap: () => _toggleTimeSlot(entry.key),
            child: Container(
              margin: EdgeInsets.only(
                bottom: entry.key != _allTimeSlots.keys.last ? 8 : 0,
              ),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                ),
              ),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected ? AppColors.primary : AppColors.textHint,
                        width: 2,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 16)
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: isSelected ? AppColors.primary : AppColors.textPrimary,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBlockedDatesSection() {
    return Column(
      children: [
        // Add button
        GestureDetector(
          onTap: _addBlockedDates,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border, style: BorderStyle.solid),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.add, color: AppColors.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  'Add Blocked Dates',
                  style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
                ),
              ],
            ),
          ),
        ),

        if (_blockedDates.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: _blockedDates.asMap().entries.map((entry) {
                final index = entry.key;
                final blocked = entry.value;
                final isLast = index == _blockedDates.length - 1;
                final isPast = blocked.end.isBefore(DateTime.now());

                return Column(
                  children: [
                    Opacity(
                      opacity: isPast ? 0.5 : 1.0,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isPast
                                    ? AppColors.textHint.withAlpha(26)
                                    : AppColors.warning.withAlpha(26),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.event_busy,
                                color: isPast ? AppColors.textHint : AppColors.warning,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    blocked.displayRange,
                                    style: AppTextStyles.labelMedium,
                                  ),
                                  if (blocked.reason.isNotEmpty)
                                    Text(
                                      blocked.reason,
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  if (isPast)
                                    Text(
                                      'Past',
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.textHint,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => _removeBlockedDate(index),
                              icon: Icon(
                                Icons.close,
                                color: AppColors.error.withAlpha(179),
                                size: 20,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!isLast) const Divider(height: 1, indent: 14, endIndent: 14),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }
}

// ============ BLOCKED DATE RANGE MODEL ============

class BlockedDateRange {
  final DateTime start;
  final DateTime end;
  final String reason;

  BlockedDateRange({
    required this.start,
    required this.end,
    this.reason = '',
  });

  String get displayRange {
    final formatter = DateFormat('MMM d');
    final yearFormatter = DateFormat('MMM d, yyyy');
    
    if (start.year != end.year) {
      return '${yearFormatter.format(start)} - ${yearFormatter.format(end)}';
    } else if (start.month == end.month && start.day == end.day) {
      return yearFormatter.format(start);
    } else {
      return '${formatter.format(start)} - ${formatter.format(end)}, ${start.year}';
    }
  }

  Map<String, dynamic> toJson() => {
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'reason': reason,
  };
}

// ============ ADD BLOCKED DATES DIALOG ============

class _AddBlockedDatesDialog extends StatefulWidget {
  const _AddBlockedDatesDialog();

  @override
  State<_AddBlockedDatesDialog> createState() => _AddBlockedDatesDialogState();
}

class _AddBlockedDatesDialogState extends State<_AddBlockedDatesDialog> {
  DateTime? _startDate;
  DateTime? _endDate;
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              surface: AppColors.surface,
              onSurface: AppColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (date != null) {
      setState(() {
        _startDate = date;
        // If end date is before start, reset it
        if (_endDate != null && _endDate!.isBefore(date)) {
          _endDate = date;
        }
      });
    }
  }

  Future<void> _pickEndDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _startDate ?? DateTime.now().add(const Duration(days: 1)),
      firstDate: _startDate ?? DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              surface: AppColors.surface,
              onSurface: AppColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (date != null) {
      setState(() {
        _endDate = date;
      });
    }
  }

  void _save() {
    if (_startDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a start date')),
      );
      return;
    }

    Navigator.pop(
      context,
      BlockedDateRange(
        start: _startDate!,
        end: _endDate ?? _startDate!,
        reason: _reasonController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('EEE, MMM d, yyyy');

    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(26),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.event_busy, color: AppColors.warning, size: 20),
          ),
          const SizedBox(width: 12),
          const Text('Block Dates'),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mark dates when you won\'t be available for inspections.',
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),

            // Start Date
            Text('Start Date *', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickStartDate,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _startDate != null
                            ? dateFormatter.format(_startDate!)
                            : 'Select start date',
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: _startDate != null ? AppColors.textPrimary : AppColors.textHint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // End Date
            Text('End Date', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _startDate != null ? _pickEndDate : null,
              child: Opacity(
                opacity: _startDate != null ? 1.0 : 0.5,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today, size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _endDate != null
                              ? dateFormatter.format(_endDate!)
                              : 'Same as start (single day)',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: _endDate != null ? AppColors.textPrimary : AppColors.textHint,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Reason (optional)
            Text('Reason (optional)', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _reasonController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'e.g., Family vacation, Medical appointment',
                hintStyle: AppTextStyles.bodySmall.copyWith(color: AppColors.textHint),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.primary),
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _startDate != null ? _save : null,
          child: Text(
            'Add',
            style: TextStyle(
              color: _startDate != null ? AppColors.primary : AppColors.textHint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}