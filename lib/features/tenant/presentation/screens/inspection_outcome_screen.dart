import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/inspection_service.dart';
import '../../../../shared/models/inspection_request_model.dart';
import 'tenant_inspections_screen.dart';

/// The outcome of an inspection the tenant has already had on this property,
/// with the rent decision on it.
///
/// Reached from the property detail screen, which used to offer "Request
/// Inspection" regardless of whether the tenant had already inspected the
/// place — inviting a second paid inspection fee on the same property. The
/// tenant sees what the visit found, and decides about renting, before any
/// further money is involved.
///
/// Deliberately thin: [TenantInspectionOutcomeCard] already owns the rating,
/// the live rental-interest subscription and the decision buttons, so this is
/// a frame around it rather than a second implementation of the same rules.
class InspectionOutcomeScreen extends StatelessWidget {
  final InspectionRequest request;

  const InspectionOutcomeScreen({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: const Text('Your inspection'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              request.propertyTitle,
              style: AppTextStyles.h3,
            ),
            const SizedBox(height: 4),
            Text(
              'You have already inspected this property. Review what it '
              'found, then decide whether you want to rent it.',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            TenantInspectionOutcomeCard(
              request: request,
              inspectionService: InspectionService(),
            ),
          ],
        ),
      ),
    );
  }
}
