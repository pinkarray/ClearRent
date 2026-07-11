import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A tidy, height-capped bottom-sheet picker for choosing one option from a
/// list — a nicer replacement for Material's [DropdownButton], whose menu
/// balloons to cover the screen on long lists. Has a grab handle, a search
/// field, the current selection highlighted, and lifts above the keyboard.
///
/// [iconBuilder] optionally customises each row's leading icon; by default a
/// radio icon reflects selection.
Future<void> showOptionPicker(
  BuildContext context, {
  required String title,
  required List<String> options,
  required String? selected,
  required ValueChanged<String> onSelected,
  String searchHint = 'Search...',
  IconData Function(String option, bool isSelected)? iconBuilder,
}) {
  final searchController = TextEditingController();
  List<String> filtered = List.from(options);

  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => Padding(
        // Lift the sheet above the keyboard when the search field is focused.
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.6,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTextStyles.h4),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        hintText: searchHint,
                        hintStyle: TextStyle(color: AppColors.textHint),
                        prefixIcon:
                            Icon(Icons.search, color: AppColors.textHint),
                        filled: true,
                        fillColor: AppColors.background,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      onChanged: (query) {
                        setSheetState(() {
                          filtered = options
                              .where((o) => o
                                  .toLowerCase()
                                  .contains(query.toLowerCase()))
                              .toList();
                        });
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, index) {
                    final option = filtered[index];
                    final isSelected = option == selected;
                    return ListTile(
                      leading: Icon(
                        iconBuilder?.call(option, isSelected) ??
                            (isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off),
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.textSecondary,
                        size: 20,
                      ),
                      title: Text(
                        option,
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.textPrimary,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check_circle,
                              color: AppColors.primary, size: 20)
                          : null,
                      onTap: () {
                        onSelected(option);
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
