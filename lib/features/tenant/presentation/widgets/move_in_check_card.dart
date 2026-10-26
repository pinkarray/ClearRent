import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/property_model.dart';
import '../../../landlord/presentation/widgets/inventory_editor.dart';

/// The furnished-stay move-in check: the tenant compares the place and its
/// item list with the listing and confirms, or says what does not match.
/// The landlord's payout waits for this (or for 48 hours of silence).
class MoveInCheckCard extends StatefulWidget {
  final ActiveRental rental;
  const MoveInCheckCard({super.key, required this.rental});

  @override
  State<MoveInCheckCard> createState() => _MoveInCheckCardState();
}

class _MoveInCheckCardState extends State<MoveInCheckCard> {
  final _service = ActiveRentalService();
  // The list frozen on the rental at acceptance; the listing's copy only for
  // a rental from before the snapshot existed.
  late final Future<List<InventoryItem>> _items =
      widget.rental.inventory.isNotEmpty
          ? Future.value(widget.rental.inventory)
          : PropertyService()
              .getProperty(widget.rental.propertyId)
              .then((p) => p?.inventory ?? const <InventoryItem>[]);
  bool _busy = false;
  // Shown until the rental stream catches up with the server's write.
  String? _done;

  void _snack(String text, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    final err = await _service.confirmMoveIn(widget.rental.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err == null) _done = 'Thanks. The landlord will now be paid.';
    });
    if (err != null) _snack(err, AppColors.error);
  }

  Future<void> _report() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What does not match?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. No fridge, and the air conditioner does not work',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Send report')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final err = await _service.reportMoveInProblem(widget.rental.id, text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err == null) {
        _done = 'Reported. ClearRent will contact you, and the landlord is '
            'not paid until it is settled.';
      }
    });
    if (err != null) _snack(err, AppColors.error);
  }

  @override
  Widget build(BuildContext context) {
    final deadline = widget.rental.moveInCheckDeadline;
    final hoursLeft =
        deadline?.difference(DateTime.now()).inHours.clamp(0, 48);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.fact_check_outlined, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
                child: Text('Check the place', style: AppTextStyles.h4)),
          ]),
          const SizedBox(height: 6),
          Text(
            _done ??
                'Does the place, and everything on this list, match the '
                    'listing? The landlord is paid once you confirm'
                    '${hoursLeft == null ? '' : ', or in $hoursLeft hours if you say nothing'}.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          if (_done == null) ...[
            const SizedBox(height: 12),
            FutureBuilder<List<InventoryItem>>(
              future: _items,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return InventoryEditor(items: snap.data ?? const []);
              },
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _report,
                  child: const Text('Something is wrong'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _confirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                  ),
                  child: Text(
                    'All good',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: Colors.white),
                  ),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}
