import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A small inline hint that tells the user "what happens now" after an action
/// (e.g. after submitting an inspection request, accepting a link, reporting
/// an issue) so they always know what to expect next.
///
/// Matches the existing "Tip for today" info box used in the inspection
/// screens. [color] tints the icon, text and border — defaults to the brand
/// primary; pass [AppColors.warning]/[AppColors.success]/[AppColors.info] to
/// match the tone of the surrounding state.
class WhatHappensNowHint extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;

  const WhatHappensNowHint({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withAlpha(13),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withAlpha(51)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodySmall.copyWith(color: c, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
