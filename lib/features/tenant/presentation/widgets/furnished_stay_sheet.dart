import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/utils/sheet_insets.dart';

/// What the tenant chose for a furnished stay.
typedef StayPick = ({int months, String startDay});

/// Asks how many months (within the landlord's range) and from which day.
/// Null when dismissed. The server re-checks both and prices the stay itself;
/// the total here is the rent part only, shown so the choice is informed.
Future<StayPick?> showFurnishedStaySheet(
  BuildContext context,
  PropertyModel property,
) {
  return showModalBottomSheet<StayPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _FurnishedStaySheet(property: property),
  );
}

class _FurnishedStaySheet extends StatefulWidget {
  final PropertyModel property;
  const _FurnishedStaySheet({required this.property});

  @override
  State<_FurnishedStaySheet> createState() => _FurnishedStaySheetState();
}

class _FurnishedStaySheetState extends State<_FurnishedStaySheet> {
  late int _months;
  DateTime? _start;

  PropertyModel get _p => widget.property;

  /// Today, or the listing's available-from day if that is later.
  DateTime get _earliest {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = _p.availableFrom;
    if (from == null) return today;
    final fromDay = DateTime(from.year, from.month, from.day);
    return fromDay.isAfter(today) ? fromDay : today;
  }

  @override
  void initState() {
    super.initState();
    _months = _p.minStayMonths > 0 ? _p.minStayMonths : 1;
  }

  String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final min = _p.minStayMonths > 0 ? _p.minStayMonths : 1;
    final max = _p.maxStayMonths > 0 ? _p.maxStayMonths : 11;
    final start = _start;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + sheetBottomInset(context)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your stay', style: AppTextStyles.h4),
          const SizedBox(height: 4),
          Text(
            'Choose how long and when you move in. You pay for the whole stay '
            'once the landlord accepts and the agreement is signed.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          Text('How many months', style: AppTextStyles.labelMedium),
          Row(children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed:
                  _months > min ? () => setState(() => _months--) : null,
            ),
            Text('$_months', style: AppTextStyles.h4),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed:
                  _months < max ? () => setState(() => _months++) : null,
            ),
            const SizedBox(width: 8),
            Text(
              '$min to $max allowed',
              style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
            ),
          ]),
          const SizedBox(height: 12),
          Text('Move-in day', style: AppTextStyles.labelMedium),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(start == null
                ? 'Choose a day'
                : '${start.day}/${start.month}/${start.year}'),
            onPressed: () async {
              final earliest = _earliest;
              final picked = await showDatePicker(
                context: context,
                initialDate: start ?? earliest,
                firstDate: earliest,
                // The server allows 90 days ahead of the earliest day.
                lastDate: earliest.add(const Duration(days: 90)),
              );
              if (picked != null) setState(() => _start = picked);
            },
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Rent: ${InspectionPricing.formatNaira(_p.rent * _months)} '
              '(${InspectionPricing.formatNaira(_p.rent)} x $_months). '
              'The deal fee and any agent fee are added at payment.',
              style: AppTextStyles.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: start == null
                  ? null
                  : () => Navigator.pop<StayPick>(
                        context,
                        (months: _months, startDay: _day(start)),
                      ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Send interest',
                style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
