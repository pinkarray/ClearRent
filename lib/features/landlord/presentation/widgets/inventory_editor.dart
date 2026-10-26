import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/property_model.dart';

/// The item list for a furnished stay: what comes with the place, each with
/// an optional photo. Both sides check it at move-in and move-out, so a photo
/// is what a "missing" or "damaged" claim is later measured against.
///
/// [onChanged] null shows the list without letting it change (an occupied
/// stay: firestore.rules freezes the list while a tenant is in).
class InventoryEditor extends StatefulWidget {
  final List<InventoryItem> items;
  final ValueChanged<List<InventoryItem>>? onChanged;

  const InventoryEditor({super.key, required this.items, this.onChanged});

  @override
  State<InventoryEditor> createState() => _InventoryEditorState();
}

class _InventoryEditorState extends State<InventoryEditor> {
  static const _suggestions = [
    'Bed', 'Mattress', 'Wardrobe', 'Sofa', 'Dining table', 'Chairs',
    'TV', 'Fridge', 'Cooker', 'Microwave', 'Air conditioner', 'Fan',
    'Curtains', 'Washing machine', 'Water heater', 'Pots and plates',
  ];

  final _property = PropertyService();
  int? _uploadingIndex;

  bool get _editable => widget.onChanged != null;

  void _set(List<InventoryItem> next) => widget.onChanged?.call(next);

  void _add(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final at = widget.items.indexWhere(
        (i) => i.name.toLowerCase() == clean.toLowerCase());
    if (at >= 0) {
      _setQty(at, widget.items[at].qty + 1);
      return;
    }
    if (widget.items.length >= 60) return;
    _set([...widget.items, InventoryItem(name: clean)]);
  }

  void _setQty(int index, int qty) {
    final next = [...widget.items];
    final i = next[index];
    next[index] = InventoryItem(name: i.name, qty: qty.clamp(1, 99), photoUrl: i.photoUrl);
    _set(next);
  }

  void _remove(int index) => _set([...widget.items]..removeAt(index));

  Future<void> _photo(int index) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    setState(() => _uploadingIndex = index);
    final url = await _property.uploadImage(File(picked.path));
    if (!mounted) return;
    setState(() => _uploadingIndex = null);
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('That photo did not upload. Try again.'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final next = [...widget.items];
    final i = next[index];
    next[index] = InventoryItem(name: i.name, qty: i.qty, photoUrl: url);
    _set(next);
  }

  Future<void> _addCustom() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add an item'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Standing mirror'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Add')),
        ],
      ),
    );
    if (name != null) _add(name);
  }

  @override
  Widget build(BuildContext context) {
    final have = widget.items.map((i) => i.name.toLowerCase()).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...widget.items.asMap().entries.map((e) => _row(e.key, e.value)),
        if (widget.items.isEmpty)
          Text('No items yet.',
              style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
        if (_editable) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._suggestions.where((s) => !have.contains(s.toLowerCase())).map(
                    (s) => ActionChip(
                      label: Text('+ $s'),
                      onPressed: () => _add(s),
                    ),
                  ),
              ActionChip(
                avatar: Icon(Icons.add, size: 16, color: AppColors.primary),
                label: const Text('Something else'),
                onPressed: _addCustom,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _row(int index, InventoryItem item) {
    final hasPhoto = item.photoUrl != null && item.photoUrl!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _editable ? () => _photo(index) : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 48,
                height: 48,
                color: AppColors.background,
                child: _uploadingIndex == index
                    ? const Center(
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : hasPhoto
                        ? Image.network(item.photoUrl!, fit: BoxFit.cover)
                        : Icon(Icons.add_a_photo_outlined,
                            size: 20, color: AppColors.textHint),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(item.name, style: AppTextStyles.labelMedium)),
          if (_editable) ...[
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 18),
              onPressed: item.qty > 1 ? () => _setQty(index, item.qty - 1) : null,
            ),
            Text('${item.qty}', style: AppTextStyles.labelMedium),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => _setQty(index, item.qty + 1),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 18, color: AppColors.error),
              onPressed: () => _remove(index),
            ),
          ] else
            Text('× ${item.qty}', style: AppTextStyles.labelMedium),
        ],
      ),
    );
  }
}
