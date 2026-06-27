import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/inspection_service.dart';

/// Horizontal date strip used by inspection request and reschedule
/// flows. Stateless — the parent owns selection state and the list of
/// available dates.
///
/// Parent loads availableDates via InspectionService.getAvailableDates
/// and tracks selectedDate in its own State.
class DateStrip extends StatelessWidget {
  final List<DateTime> availableDates;
  final DateTime? selectedDate;
  final bool isLoading;
  final void Function(DateTime date) onDateSelected;
  final String emptyMessage;

  const DateStrip({
    super.key,
    required this.availableDates,
    required this.selectedDate,
    required this.isLoading,
    required this.onDateSelected,
    this.emptyMessage =
        'The property owner hasn\'t set inspection availability',
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return SizedBox(
        height: 90,
        child: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (availableDates.isEmpty) {
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
              emptyMessage,
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
        itemCount: availableDates.length,
        itemBuilder: (context, index) {
          final date = availableDates[index];
          final isSelected = selectedDate != null &&
              selectedDate!.year == date.year &&
              selectedDate!.month == date.month &&
              selectedDate!.day == date.day;

          final now = DateTime.now();
          final isToday = now.year == date.year &&
              now.month == date.month &&
              now.day == date.day;
          final tomorrow = now.add(const Duration(days: 1));
          final isTomorrow = tomorrow.year == date.year &&
              tomorrow.month == date.month &&
              tomorrow.day == date.day;

          return GestureDetector(
            onTap: () => onDateSelected(date),
            child: Container(
              width: 70,
              margin: EdgeInsets.only(
                right: index < availableDates.length - 1 ? 12 : 0,
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
                      color: isSelected
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
                      color: isSelected
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
                        color: isSelected
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
}

/// Wrap of selectable time slot chips. Stateless — parent owns
/// availableTimeSlots and selectedTimeSlot.
class TimeSlotWrap extends StatelessWidget {
  final List<String> availableTimeSlots;
  final String? selectedTimeSlot;
  final DateTime? selectedDate;
  final bool isLoading;
  final void Function(String slot) onTimeSlotSelected;

  const TimeSlotWrap({
    super.key,
    required this.availableTimeSlots,
    required this.selectedTimeSlot,
    required this.selectedDate,
    required this.isLoading,
    required this.onTimeSlotSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedDate == null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            'Select a date first',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }

    if (isLoading) {
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

    if (availableTimeSlots.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            'This date is fully booked or unavailable — please choose another day',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: availableTimeSlots.map((slot) {
        final isSelected = selectedTimeSlot == slot;
        final label = InspectionService.timeSlotLabels[slot] ?? slot;
        final time = InspectionService.timeSlotDisplay[slot] ?? '';

        return GestureDetector(
          onTap: () => onTimeSlotSelected(slot),
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
                    color: isSelected
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
}