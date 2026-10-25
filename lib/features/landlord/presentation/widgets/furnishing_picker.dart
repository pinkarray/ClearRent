import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';

/// The three furnishing levels as tappable rows, each with a line saying what
/// it means, so "partly" isn't left to the landlord's own reading.
///
/// [onChanged] null shows the current value without letting it change (an
/// occupied listing: the sitting tenant moved in on what it says).
class FurnishingPicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String>? onChanged;

  const FurnishingPicker({super.key, required this.value, this.onChanged});

  static const Map<String, String> _hints = {
    'unfurnished': 'An empty space. The tenant brings everything.',
    'partly': 'Some furniture or fittings stay, such as wardrobes or a cooker.',
    'fully': 'Ready to live in: beds, seating and kitchen items included.',
  };

  static const Map<String, IconData> _icons = {
    'unfurnished': Icons.meeting_room_outlined,
    'partly': Icons.chair_outlined,
    'fully': Icons.king_bed_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children:
          PropertyModel.furnishingLabels.entries.map((e) {
            final selected = value == e.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onChanged == null ? null : () => onChanged!(e.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color:
                        selected
                            ? AppColors.primary.withAlpha(20)
                            : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _icons[e.key],
                        size: 20,
                        color:
                            selected
                                ? AppColors.primary
                                : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.value,
                              style: AppTextStyles.labelMedium.copyWith(
                                color:
                                    selected
                                        ? AppColors.primary
                                        : AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _hints[e.key]!,
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle,
                          size: 20,
                          color: AppColors.primary,
                        ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
    );
  }
}
