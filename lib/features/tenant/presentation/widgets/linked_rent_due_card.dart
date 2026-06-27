import 'package:flutter/material.dart';
import '../../../../../../core/constants/colors.dart';
import '../../../../../../core/constants/text_styles.dart';
import '../../../../../../shared/models/tenancy_link_model.dart';

/// Rent-due card for a linked tenancy.
///
/// Shows the link's own [TenancyLinkModel.rentAmount] — the rent the sitting
/// tenant agreed to. It deliberately does NOT read `property.rent`: a rent
/// review bumps `property.rent` immediately for FUTURE tenants, but a sitting
/// tenant is protected at their agreed figure until renewal. Reading the
/// property's live rent here showed the wrong amount and flickered between the
/// old and new values on every rebuild.
class LinkedRentDueCard extends StatelessWidget {
  final TenancyLinkModel link;

  const LinkedRentDueCard({super.key, required this.link});

  @override
  Widget build(BuildContext context) {
    final daysLeft = link.daysUntilDue;
    final isUrgent = daysLeft <= 3;
    final isDue = daysLeft == 0;

    final rentAmount = link.rentAmount;
    final rentFrequency = link.rentFrequency;

    String formattedRent;
    if (rentAmount >= 1000000) {
      formattedRent = '₦${(rentAmount / 1000000).toStringAsFixed(1)}M';
    } else if (rentAmount >= 1000) {
      formattedRent = '₦${(rentAmount / 1000).toStringAsFixed(0)}K';
    } else {
      formattedRent = '₦${rentAmount.toStringAsFixed(0)}';
    }
    final periodLabel = rentFrequency == 'yearly' ? 'per year' : 'per month';

    final Color cardColor;
    const Color textColor = Colors.white;
    final String dueLabel;
    final IconData dueIcon;

    if (isDue) {
      cardColor = AppColors.error;
      dueLabel = 'Rent is due TODAY';
      dueIcon = Icons.warning_rounded;
    } else if (isUrgent) {
      cardColor = AppColors.warning;
      dueLabel = 'Due in $daysLeft day${daysLeft != 1 ? 's' : ''}';
      dueIcon = Icons.schedule;
    } else {
      cardColor = AppColors.primary;
      dueLabel = 'Due in $daysLeft days';
      dueIcon = Icons.calendar_today_outlined;
    }

    final nextDue = link.nextDueDate;
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(dueIcon, color: textColor.withAlpha(200), size: 18),
          const SizedBox(width: 6),
          Text(dueLabel, style: AppTextStyles.labelMedium.copyWith(color: textColor.withAlpha(200))),
        ]),
        const SizedBox(height: 8),
        Text(formattedRent, style: AppTextStyles.h2.copyWith(color: textColor)),
        const SizedBox(height: 2),
        Text(
          '$periodLabel  •  due ${link.rentDueLabel}',
          style: AppTextStyles.caption.copyWith(color: textColor.withAlpha(180)),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.white.withAlpha(30), borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.event, size: 16, color: textColor),
            const SizedBox(width: 6),
            Text(
              'Next: ${months[nextDue.month - 1]} ${nextDue.day}, ${nextDue.year}',
              style: AppTextStyles.labelMedium.copyWith(color: textColor),
            ),
          ]),
        ),
      ]),
    );
  }
}
