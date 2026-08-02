import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// The app's bottom navigation: a floating capsule, matching the web app.
///
/// Replaces three identical private `_NavItem` copies — one per home screen —
/// which drifted only in which tabs they listed. Keeping the chrome here means
/// a change lands on tenant, landlord and agent at once.
///
/// Only the ACTIVE tab carries its label, inside a filled pill; the rest are
/// icon-only. That is what keeps the bar narrow enough to float, and it makes
/// the current section legible at a glance rather than by comparing four
/// near-identical stacks.
class CapsuleNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  /// Small count over the icon — saved properties, unread messages.
  final String? badge;

  const CapsuleNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.badge,
  });
}

class CapsuleNav extends StatelessWidget {
  final List<CapsuleNavItem> items;

  const CapsuleNav({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    // Transparent host: the bar itself is the capsule inside, so content
    // scrolls behind it rather than stopping at a hard edge.
    return Container(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: AppColors.border),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadowMedium,
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (final item in items) _CapsuleItem(item: item)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CapsuleItem extends StatelessWidget {
  final CapsuleNavItem item;

  const _CapsuleItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final active = item.isActive;

    return GestureDetector(
      onTap: item.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: active ? 16 : 14,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  active ? item.activeIcon : item.icon,
                  color: active ? Colors.white : AppColors.textHint,
                  size: 22,
                ),
                if (item.badge != null)
                  Positioned(
                    right: -7,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.error,
                        borderRadius: BorderRadius.circular(10),
                        // Ring in the surrounding colour so the badge stays
                        // readable on the filled pill as well as off it.
                        border: Border.all(
                          color: active ? AppColors.primary : AppColors.surface,
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        item.badge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),

            // The label expands rather than appearing, so the icon never jumps.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              child:
                  active
                      ? Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          item.label,
                          style: AppTextStyles.labelSmall.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
