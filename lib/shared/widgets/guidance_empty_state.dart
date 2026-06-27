import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A consistent "nothing here yet — here's what to do next" empty state.
///
/// Use this for every empty list/tab so users are never left on a blank
/// screen wondering what to do. Pass [actionLabel] + [onAction] to surface a
/// next-step button (e.g. "Browse Properties", "Add a property"); omit them
/// for genuinely passive states (history, resolved) where there's nothing for
/// the user to do.
///
/// Replaces the per-screen `_EmptyState` copies that were duplicated across
/// the inspection / issues / list screens.
class GuidanceEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;

  /// One short line telling the user what will land here, or what to do next.
  final String subtitle;

  final String? actionLabel;
  final VoidCallback? onAction;

  /// Icon for the action button. Defaults to a forward arrow; pass
  /// [Icons.search] for browse-style actions, [Icons.add] for create, etc.
  final IconData actionIcon;

  const GuidanceEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.actionIcon = Icons.arrow_forward,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: AppColors.primary),
            ),
            const SizedBox(height: 24),
            Text(title, style: AppTextStyles.h4, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon, size: 18),
                label: Text(actionLabel!),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
