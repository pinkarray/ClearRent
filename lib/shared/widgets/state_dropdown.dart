import 'package:flutter/material.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../core/utils/inspection_pricing.dart';
import '../models/landlord_residence.dart';
import '../utils/sheet_insets.dart';

/// A state picker with the same field and bottom sheet as [AreaDropdown], so a
/// screen asking for state and area does not mix a stock Material dropdown with
/// our own styled field. The states we carry areas for are listed first,
/// because almost every answer is one of them.
class StateDropdown extends StatelessWidget {
  final String? selectedState;
  final ValueChanged<String> onSelected;
  final String? label;
  final String hint;
  final String? helperText;

  const StateDropdown({
    super.key,
    required this.onSelected,
    this.selectedState,
    this.label,
    this.hint = 'Select state',
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    final chosen = selectedState;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label!, style: AppTextStyles.labelMedium),
          if (helperText != null) ...[
            const SizedBox(height: 4),
            Text(
              helperText!,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 8),
        ],
        GestureDetector(
          onTap: () => _showPicker(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: chosen != null
                    ? AppColors.primary.withAlpha(80)
                    : AppColors.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 20,
                  color:
                      chosen != null ? AppColors.primary : AppColors.textHint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chosen ?? hint,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: chosen != null
                          ? AppColors.textPrimary
                          : AppColors.textHint,
                    ),
                  ),
                ),
                Icon(Icons.keyboard_arrow_down,
                    color: AppColors.textSecondary, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showPicker(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _StatePickerSheet(
        selectedState: selectedState,
        onSelected: (state) {
          Navigator.pop(ctx);
          onSelected(state);
        },
      ),
    );
  }
}

class _StatePickerSheet extends StatefulWidget {
  final String? selectedState;
  final ValueChanged<String> onSelected;

  const _StatePickerSheet({this.selectedState, required this.onSelected});

  @override
  State<_StatePickerSheet> createState() => _StatePickerSheetState();
}

class _StatePickerSheetState extends State<_StatePickerSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Two groups: the states we carry areas for, then the rest. The first group
  /// comes from the area list itself, so opening a new state adds it here too.
  List<Map<String, dynamic>> get _groups {
    final covered = InspectionPricing.statesWithAreas;
    final others =
        nigerianStates.where((s) => !covered.contains(s)).toList();
    bool matches(String s) =>
        _query.isEmpty || s.toLowerCase().contains(_query.toLowerCase());
    return [
      {
        'label': 'Where ClearRent operates',
        'states': covered.where(matches).toList(),
      },
      {'label': 'All other states', 'states': others.where(matches).toList()},
    ].where((g) => (g['states'] as List).isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Text('Select State', style: AppTextStyles.h4),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search state...',
                hintStyle: TextStyle(color: AppColors.textHint),
                prefixIcon: Icon(Icons.search, color: AppColors.textHint),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear,
                            color: AppColors.textHint, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Text(
                      'No state matches "$_query"',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                        left: 20, right: 20, bottom: sheetBottomInset(context)),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      final states = group['states'] as List<String>;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (index > 0) const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              group['label'] as String,
                              style: AppTextStyles.labelSmall.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          ...states.map((state) {
                            final isSelected = state == widget.selectedState;
                            return InkWell(
                              onTap: () => widget.onSelected(state),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 11),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppColors.primary.withAlpha(15)
                                      : null,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        state,
                                        style:
                                            AppTextStyles.bodyMedium.copyWith(
                                          color: isSelected
                                              ? AppColors.primary
                                              : AppColors.textPrimary,
                                          fontWeight: isSelected
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      Icon(Icons.check,
                                          color: AppColors.primary, size: 18),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
