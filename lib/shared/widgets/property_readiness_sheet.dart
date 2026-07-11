import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/property_service.dart';
import '../models/property_model.dart';
import 'app_button.dart';

/// Handler-facing readiness checklist (Phase 2). The assigned agent — or the
/// landlord when self-handled — confirms the property meets ClearRent's
/// standard before it becomes bookable for inspection. Every item must be
/// ticked. Returns `true` (via Navigator.pop) once the property is marked ready.
class PropertyReadinessSheet extends StatefulWidget {
  final PropertyModel property;

  const PropertyReadinessSheet({super.key, required this.property});

  /// Show the sheet. Resolves to `true` when the property was marked ready.
  static Future<bool?> show(BuildContext context, PropertyModel property) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PropertyReadinessSheet(property: property),
    );
  }

  @override
  State<PropertyReadinessSheet> createState() => _PropertyReadinessSheetState();
}

class _PropertyReadinessSheetState extends State<PropertyReadinessSheet> {
  final PropertyService _propertyService = PropertyService();

  // Item key -> confirmed. Seeded from the shared checklist so a new item is
  // automatically required here without touching this screen.
  late final Map<String, bool> _confirmed = {
    for (final key in PropertyService.readinessChecklistItems.keys) key: false,
  };

  bool _submitting = false;

  bool get _allConfirmed => _confirmed.values.every((v) => v);

  Future<void> _submit() async {
    if (!_allConfirmed || _submitting) return;
    setState(() => _submitting = true);

    final error = await _propertyService.markReadyForInspections(
      propertyId: widget.property.id,
      confirmedItems: _confirmed,
    );

    if (!mounted) return;
    if (error != null) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    final items = PropertyService.readinessChecklistItems;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Confirm readiness', style: AppTextStyles.h3),
                      const SizedBox(height: 4),
                      Text(
                        widget.property.title,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.background,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tenants pay to inspect. Confirm this property meets the '
                    'standard so nobody pays for a place that isn\'t ready.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...items.entries.map((e) => _buildCheckItem(e.key, e.value)),
                  const SizedBox(height: 24),
                  AppButton(
                    text: 'Mark ready for inspections',
                    onPressed: _allConfirmed && !_submitting ? _submit : null,
                    isLoading: _submitting,
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'You can update the listing anytime; you\'re confirming '
                      'it\'s accurate right now.',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckItem(String key, String label) {
    final checked = _confirmed[key] ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _submitting
            ? null
            : () => setState(() => _confirmed[key] = !checked),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: checked
                ? AppColors.primary.withAlpha(13)
                : AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: checked
                  ? AppColors.primary.withAlpha(102)
                  : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                checked ? Icons.check_circle : Icons.circle_outlined,
                color: checked ? AppColors.primary : AppColors.textHint,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: checked
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
