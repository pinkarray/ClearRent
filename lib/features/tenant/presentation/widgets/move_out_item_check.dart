import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/utils/sheet_insets.dart';

const _stateLabels = {'ok': 'Fine', 'damaged': 'Damaged', 'missing': 'Missing'};

/// Furnished stay, move-out: the landlord goes through the item list the
/// tenant moved in with and says what each is now. Null when dismissed. A
/// damaged or missing item must say what is wrong, since it is what a caution
/// deduction (and any contest of it) is judged against.
Future<List<ItemCheck>?> showMoveOutItemCheck(
  BuildContext context,
  List<InventoryItem> items,
) {
  return showModalBottomSheet<List<ItemCheck>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ItemCheckSheet(items: items),
  );
}

class _ItemCheckSheet extends StatefulWidget {
  final List<InventoryItem> items;
  const _ItemCheckSheet({required this.items});

  @override
  State<_ItemCheckSheet> createState() => _ItemCheckSheetState();
}

class _ItemCheckSheetState extends State<_ItemCheckSheet> {
  late final List<String> _states =
      List.filled(widget.items.length, 'ok', growable: false);
  late final List<TextEditingController> _notes =
      List.generate(widget.items.length, (_) => TextEditingController());
  String? _error;

  @override
  void dispose() {
    for (final c in _notes) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    for (var i = 0; i < widget.items.length; i++) {
      if (_states[i] != 'ok' && _notes[i].text.trim().isEmpty) {
        setState(() => _error =
            'Say what is wrong with ${widget.items[i].name}.');
        return;
      }
    }
    Navigator.pop<List<ItemCheck>>(context, [
      for (var i = 0; i < widget.items.length; i++)
        ItemCheck(
          name: widget.items[i].name,
          qty: widget.items[i].qty,
          state: _states[i],
          note: _states[i] == 'ok' ? null : _notes[i].text.trim(),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + sheetBottomInset(context)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Check each item', style: AppTextStyles.h4),
            const SizedBox(height: 4),
            Text(
              'This is the list the tenant moved in with. The tenant sees '
              'what you mark and can contest it.',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.items.length,
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (context, i) {
                  final item = widget.items[i];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${item.name} x ${item.qty}',
                          style: AppTextStyles.labelMedium),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, children: [
                        for (final e in _stateLabels.entries)
                          ChoiceChip(
                            label: Text(e.value),
                            selected: _states[i] == e.key,
                            onSelected: (_) =>
                                setState(() => _states[i] = e.key),
                          ),
                      ]),
                      if (_states[i] != 'ok')
                        TextField(
                          controller: _notes[i],
                          maxLength: 300,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'What is wrong with it',
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text('I have checked it',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The landlord's move-out item check, read-only, for both sides.
class MoveOutItemSummary extends StatelessWidget {
  final List<ItemCheck> items;
  const MoveOutItemSummary({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final problems = items.where((i) => i.state != 'ok').toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Item check at move-out', style: AppTextStyles.labelMedium),
          const SizedBox(height: 4),
          Text(
            problems.isEmpty
                ? 'The landlord marked all ${items.length} items fine.'
                : '${problems.length} of ${items.length} items marked as a '
                    'problem:',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary),
          ),
          for (final p in problems) ...[
            const SizedBox(height: 8),
            Text('${p.name}: ${_stateLabels[p.state] ?? p.state}',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.warning)),
            if ((p.note ?? '').isNotEmpty)
              Text(p.note!, style: AppTextStyles.bodySmall),
          ],
        ],
      ),
    );
  }
}
