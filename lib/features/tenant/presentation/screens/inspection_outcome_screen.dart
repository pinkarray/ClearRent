import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/models/property_model.dart';
import '../widgets/request_inspection_sheet.dart';
import 'tenant_inspections_screen.dart';

/// The outcome of an inspection the tenant has already had on this property,
/// with the rent decision on it.
///
/// Reached from the property detail screen, which used to offer "Request
/// Inspection" regardless of whether the tenant had already inspected the
/// place - inviting a second paid inspection fee on the same property. The
/// tenant sees what the visit found, and decides about renting, before any
/// further money is involved.
///
/// It also asks whether they have reconsidered. Someone who viewed months ago,
/// or who rented here and moved out, could reach this screen and find no way
/// back in: the old visit was all the app would ever show them. The offer of
/// another viewing appears ONLY while the place is actually up for rent, so
/// nobody is invited to pay for a viewing of somewhere already taken.
///
/// Deliberately thin otherwise: [TenantInspectionOutcomeCard] already owns the
/// rating, the live rental-interest subscription and the decision buttons, so
/// this is a frame around it rather than a second implementation of the rules.
class InspectionOutcomeScreen extends StatefulWidget {
  final InspectionRequest request;

  const InspectionOutcomeScreen({super.key, required this.request});

  @override
  State<InspectionOutcomeScreen> createState() =>
      _InspectionOutcomeScreenState();
}

class _InspectionOutcomeScreenState extends State<InspectionOutcomeScreen> {
  final PropertyService _propertyService = PropertyService();
  PropertyModel? _property;

  @override
  void initState() {
    super.initState();
    _loadProperty();
  }

  Future<void> _loadProperty() async {
    final property =
        await _propertyService.getProperty(widget.request.propertyId);
    if (mounted) setState(() => _property = property);
  }

  /// Still on the market and able to take a viewing. A listing that is let,
  /// unverified or not marked ready is not offered a second visit.
  bool get _canBookAgain {
    final p = _property;
    return p != null && p.isListable && p.readyForInspections;
  }

  Future<void> _bookAgain() async {
    final booked = await RequestInspectionSheet.show(context, _property!);
    if (booked == true && mounted) Navigator.of(context).pop();
  }

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
              widget.request.propertyTitle,
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
              request: widget.request,
              inspectionService: InspectionService(),
            ),
            if (_canBookAgain) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary.withAlpha(64)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Had a change of heart?',
                      style: AppTextStyles.labelMedium
                          .copyWith(color: AppColors.primary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This place is still up for rent. If things have changed '
                      'since your visit, you can book another viewing.',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _bookAgain,
                        icon: Icon(Icons.event_available_outlined,
                            size: 18, color: AppColors.primary),
                        label: Text(
                          'Book another viewing',
                          style: AppTextStyles.labelMedium
                              .copyWith(color: AppColors.primary),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: AppColors.primary),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
