import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A Tab label with a count badge that tells the user where things need
/// attention:
///   • count <= 0 → no indicator
///   • count == 1 → a small dot
///   • count >= 2 → a pill showing the number (99+ above 99)
///
/// Usage: `Tab(child: TabBadge(label: 'Open', count: openCount))`
class TabBadge extends StatelessWidget {
  final String label;
  final int count;

  const TabBadge({super.key, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Flexible so a long label (e.g. "In Progress") ellipsizes within a
        // width-constrained tab instead of overflowing when the count
        // pill/dot is also shown.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count == 1) ...[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: AppColors.error,
              shape: BoxShape.circle,
            ),
          ),
        ] else if (count >= 2) ...[
          const SizedBox(width: 6),
          Container(
            constraints: const BoxConstraints(minWidth: 16),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.error,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
