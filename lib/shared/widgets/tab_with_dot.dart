import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';

/// A Tab label with an optional unread dot indicator.
///
/// Usage:
///   Tab(child: TabWithDot(label: 'Pending', showDot: count > 0))
class TabWithDot extends StatelessWidget {
  final String label;
  final bool showDot;

  const TabWithDot({
    super.key,
    required this.label,
    required this.showDot,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label),
        if (showDot) ...[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: AppColors.error,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}