import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/building_service.dart';
import '../../../../services/residence_service.dart';
import '../../../../shared/models/landlord_residence.dart';
import '../../../../shared/models/property_model.dart';

/// "I live in this building", on the owner's view of a listed unit.
///
/// Shown only to a landlord who said they live in a property they own, and
/// only on a unit inside a building: a whole property goes to one tenant, so it
/// cannot also be the landlord's home. There is one home, so switching it on
/// here moves it off any other building, after saying so.
class HomeBuildingToggle extends StatefulWidget {
  final PropertyModel property;
  const HomeBuildingToggle({super.key, required this.property});

  @override
  State<HomeBuildingToggle> createState() => _HomeBuildingToggleState();
}

class _HomeBuildingToggleState extends State<HomeBuildingToggle> {
  final _service = ResidenceService();
  LandlordResidence? _residence;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _service.get();
    if (mounted) setState(() => _residence = r);
  }

  Future<void> _toggle(bool on) async {
    final r = _residence;
    final buildingId = widget.property.buildingId;
    if (r == null || buildingId == null) return;
    if (on && r.homeBuildingId != null && r.homeBuildingId != buildingId) {
      final move = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Move your home here?'),
          content: Text(
            'You said you live at ${r.homeBuildingName ?? 'another building'}. '
            'You can only live in one, so tenants there will be told you live '
            'elsewhere.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Move it here'),
            ),
          ],
        ),
      );
      if (move != true || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    // The building's own name; older units carry no label of their own.
    final building = on ? await BuildingService().getBuilding(buildingId) : null;
    final error = on
        ? await _service.markHome(buildingId,
            building?.name ?? widget.property.unitBuildingLabel ?? 'Your building')
        : await _service.clearHome();
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(
        content: Text(error),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _residence;
    if (r == null ||
        !r.canMarkHome ||
        (widget.property.buildingId ?? '').isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: SwitchListTile(
        value: r.livesAt(widget.property.buildingId),
        onChanged: _busy ? null : _toggle,
        title: Text('I live in this building',
            style: AppTextStyles.labelMedium),
        subtitle: Text(
          'Tenants of units here see that their landlord lives on the premises.',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
