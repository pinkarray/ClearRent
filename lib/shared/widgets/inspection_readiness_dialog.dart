import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Non-blocking readiness reminder shown to the handler (agent/landlord)
/// before they approve an inspection request. Nudges them to confirm the
/// listing is accurate and the unit is ready to show. Returns true if they
/// tap "Confirm & Approve", false if they cancel or dismiss.
Future<bool> confirmInspectionReadiness(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.checklist_rounded, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(child: Text('Before you approve', style: AppTextStyles.h4)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick check — make sure the property is on point so the tenant '
            'has a good inspection:',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          _bullet('Photos and details match the actual unit'),
          _bullet('Rent and fees are up to date'),
          _bullet('Access is arranged for the scheduled time'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Confirm & Approve'),
        ),
      ],
    ),
  );
  return result ?? false;
}

Widget _bullet(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: AppColors.success),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppTextStyles.bodySmall)),
        ],
      ),
    );
