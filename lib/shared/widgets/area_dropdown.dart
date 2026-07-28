import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../core/utils/inspection_pricing.dart';

/// A searchable dropdown that lists all Lagos areas from InspectionPricing,
/// grouped by transport cluster. Used across all roles:
///
/// - **Add Property** → property location (city field)
/// - **Add Property** → landlord's own location (when they don't live in property)
/// - **Profile Setup** → agent base location
/// - **Profile Setup** → tenant preferred areas (multi-select variant)
///
/// Single source of truth for area names ↔ cluster mapping.
class AreaDropdown extends StatefulWidget {
  /// Currently selected area (Title Case display name, e.g. "Lekki Phase 1")
  final String? selectedArea;

  /// Called when the user picks an area.
  /// Returns the Title Case display name — call
  /// `InspectionPricing.normalizeAreaName(value)` if you need the lowercase key.
  final ValueChanged<String> onSelected;

  /// Hint text shown when nothing is selected
  final String hint;

  /// Optional label shown above the dropdown
  final String? label;

  /// Optional helper text below the label
  final String? helperText;

  const AreaDropdown({
    super.key,
    this.selectedArea,
    required this.onSelected,
    this.hint = 'Select area',
    this.label,
    this.helperText,
  });

  @override
  State<AreaDropdown> createState() => _AreaDropdownState();
}

class _AreaDropdownState extends State<AreaDropdown> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: AppTextStyles.labelMedium),
          if (widget.helperText != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.helperText!,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 8),
        ],
        GestureDetector(
          onTap: () => _showAreaPicker(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selectedArea != null
                    ? AppColors.primary.withAlpha(80)
                    : AppColors.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.location_on_outlined,
                  size: 20,
                  color: widget.selectedArea != null
                      ? AppColors.primary
                      : AppColors.textHint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.selectedArea ?? widget.hint,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: widget.selectedArea != null
                          ? AppColors.textPrimary
                          : AppColors.textHint,
                    ),
                  ),
                ),
                // Show cluster badge if selected
                if (widget.selectedArea != null) ...[
                  _buildClusterBadge(widget.selectedArea!),
                  const SizedBox(width: 6),
                ],
                Icon(
                  Icons.keyboard_arrow_down,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildClusterBadge(String areaName) {
    final normalized = InspectionPricing.normalizeAreaName(areaName);
    final cluster = InspectionPricing.getClusterForArea(normalized);
    if (cluster == null) return const SizedBox.shrink();

    final label = InspectionPricing.getClusterLabel(cluster);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(20),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(
          color: AppColors.primary,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _showAreaPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AreaPickerSheet(
        selectedArea: widget.selectedArea,
        onSelected: (area) {
          Navigator.pop(ctx);
          widget.onSelected(area);
        },
      ),
    );
  }
}

// ─── Multi-select variant for tenant preferred areas & agent service areas ───

class AreaMultiSelect extends StatelessWidget {
  /// Currently selected areas (Title Case display names)
  final List<String> selectedAreas;

  /// Called when selection changes
  final ValueChanged<List<String>> onChanged;

  /// Label shown above the selector
  final String label;

  /// Optional helper text
  final String? helperText;

  /// Maximum number of selections (0 = unlimited)
  final int maxSelections;

  const AreaMultiSelect({
    super.key,
    required this.selectedAreas,
    required this.onChanged,
    this.label = 'Select areas',
    this.helperText,
    this.maxSelections = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.labelMedium),
            const Spacer(),
            if (selectedAreas.isNotEmpty)
              Text(
                '${selectedAreas.length} selected',
                style: AppTextStyles.caption.copyWith(color: AppColors.primary),
              ),
          ],
        ),
        if (helperText != null) ...[
          const SizedBox(height: 4),
          Text(
            helperText!,
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _showMultiPicker(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selectedAreas.isNotEmpty
                    ? AppColors.primary.withAlpha(80)
                    : AppColors.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 20,
                  color: selectedAreas.isNotEmpty
                      ? AppColors.primary
                      : AppColors.textHint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    selectedAreas.isEmpty
                        ? 'Tap to select areas'
                        : selectedAreas.take(3).join(', ') +
                            (selectedAreas.length > 3
                                ? ' +${selectedAreas.length - 3} more'
                                : ''),
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: selectedAreas.isNotEmpty
                          ? AppColors.textPrimary
                          : AppColors.textHint,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        // Show selected chips
        if (selectedAreas.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: selectedAreas.map((area) {
              return Chip(
                label: Text(area, style: AppTextStyles.caption),
                deleteIcon: Icon(Icons.close, size: 14),
                onDeleted: () {
                  final updated = List<String>.from(selectedAreas)..remove(area);
                  onChanged(updated);
                },
                backgroundColor: AppColors.primary.withAlpha(20),
                deleteIconColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary.withAlpha(50)),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  void _showMultiPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AreaMultiPickerSheet(
        selectedAreas: selectedAreas,
        maxSelections: maxSelections,
        onDone: (areas) {
          Navigator.pop(ctx);
          onChanged(areas);
        },
      ),
    );
  }
}

// ─── Single-select bottom sheet ──────────────────────────────────────────────

class _AreaPickerSheet extends StatefulWidget {
  final String? selectedArea;
  final ValueChanged<String> onSelected;

  const _AreaPickerSheet({this.selectedArea, required this.onSelected});

  @override
  State<_AreaPickerSheet> createState() => _AreaPickerSheetState();
}

class _AreaPickerSheetState extends State<_AreaPickerSheet> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  late final List<Map<String, dynamic>> _groups;

  @override
  void initState() {
    super.initState();
    _groups = InspectionPricing.getAreasGroupedByCluster();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filteredGroups {
    if (_searchQuery.isEmpty) return _groups;
    return _groups.map((group) {
      final areas = (group['areas'] as List<String>)
          .where((a) => a.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
      return {...group, 'areas': areas};
    }).where((g) => (g['areas'] as List).isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
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

          // Title
          Text('Select Area', style: AppTextStyles.h4),
          const SizedBox(height: 16),

          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search area...',
                hintStyle: TextStyle(color: AppColors.textHint),
                prefixIcon: Icon(Icons.search, color: AppColors.textHint),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: AppColors.textHint, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: _filteredGroups.length,
              itemBuilder: (context, groupIndex) {
                final group = _filteredGroups[groupIndex];
                final label = group['label'] as String;
                final areas = group['areas'] as List<String>;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (groupIndex > 0) const SizedBox(height: 8),
                    // Cluster header
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        label,
                        style: AppTextStyles.labelSmall.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    // Area items
                    ...areas.map((area) {
                      final isSelected = area == widget.selectedArea;
                      return InkWell(
                        onTap: () => widget.onSelected(area),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primary.withAlpha(15) : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  area,
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: isSelected ? AppColors.primary : AppColors.textPrimary,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isSelected)
                                Icon(Icons.check, color: AppColors.primary, size: 18),
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

// ─── Multi-select bottom sheet ───────────────────────────────────────────────

class _AreaMultiPickerSheet extends StatefulWidget {
  final List<String> selectedAreas;
  final int maxSelections;
  final ValueChanged<List<String>> onDone;

  const _AreaMultiPickerSheet({
    required this.selectedAreas,
    required this.maxSelections,
    required this.onDone,
  });

  @override
  State<_AreaMultiPickerSheet> createState() => _AreaMultiPickerSheetState();
}

class _AreaMultiPickerSheetState extends State<_AreaMultiPickerSheet> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  late List<String> _selected;
  late final List<Map<String, dynamic>> _groups;

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.selectedAreas);
    _groups = InspectionPricing.getAreasGroupedByCluster();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _allFilteredSelected {
    final allFilteredAreas = <String>[
      for (final g in _filteredGroups) ...(g['areas'] as List<String>),
    ];
    return allFilteredAreas.isNotEmpty &&
        allFilteredAreas.every((a) => _selected.contains(a));
  }

  List<Map<String, dynamic>> get _filteredGroups {
    if (_searchQuery.isEmpty) return _groups;
    return _groups.map((group) {
      final areas = (group['areas'] as List<String>)
          .where((a) => a.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
      return {...group, 'areas': areas};
    }).where((g) => (g['areas'] as List).isNotEmpty).toList();
  }

  void _toggleArea(String area) {
    setState(() {
      if (_selected.contains(area)) {
        _selected.remove(area);
      } else {
        if (widget.maxSelections > 0 && _selected.length >= widget.maxSelections) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Maximum ${widget.maxSelections} areas allowed'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        _selected.add(area);
      }
    });
  }

  /// Select (or clear) every area across all currently-filtered groups.
  /// Mirrors _selectAllInCluster's behaviour of ignoring maxSelections.
  void _toggleSelectAll() {
    final allFilteredAreas = <String>[
      for (final g in _filteredGroups) ...(g['areas'] as List<String>),
    ];
    final allSelected =
        allFilteredAreas.every((a) => _selected.contains(a));
    setState(() {
      if (allSelected) {
        // Clear only the filtered ones (preserve selections outside search)
        _selected.removeWhere(allFilteredAreas.contains);
      } else {
        for (final area in allFilteredAreas) {
          if (!_selected.contains(area)) _selected.add(area);
        }
      }
    });
  }

  void _selectAllInCluster(List<String> areas) {
    setState(() {
      for (final area in areas) {
        if (!_selected.contains(area)) _selected.add(area);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header with select-all + done button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text('Select Areas', style: AppTextStyles.h4),
                const Spacer(),
                TextButton(
                  onPressed: _toggleSelectAll,
                  child: Text(
                    _allFilteredSelected ? 'Clear all' : 'Select all',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () => widget.onDone(_selected),
                  child: Text(
                    'Done (${_selected.length})',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.primary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search area...',
                hintStyle: TextStyle(color: AppColors.textHint),
                prefixIcon: Icon(Icons.search, color: AppColors.textHint),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: AppColors.textHint, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: _filteredGroups.length,
              itemBuilder: (context, groupIndex) {
                final group = _filteredGroups[groupIndex];
                final label = group['label'] as String;
                final areas = group['areas'] as List<String>;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (groupIndex > 0) const SizedBox(height: 8),
                    // Cluster header with select-all
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            label,
                            style: AppTextStyles.labelSmall.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () => _selectAllInCluster(areas),
                            child: Text(
                              'Select all',
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Area checkboxes
                    ...areas.map((area) {
                      final isSelected = _selected.contains(area);
                      return InkWell(
                        onTap: () => _toggleArea(area),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primary.withAlpha(15) : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                color: isSelected ? AppColors.primary : AppColors.textHint,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  area,
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: isSelected ? AppColors.primary : AppColors.textPrimary,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                ),
                              ),
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