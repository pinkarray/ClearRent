import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/building_service.dart';
import '../../../../services/residence_service.dart';
import '../../../../shared/models/landlord_residence.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/utils/document_file_picker.dart';

/// "I live in this building", on the owner's view of a listed unit.
///
/// Shown only to a landlord who said they live in a property they own, and
/// only on a unit inside a building: a whole property goes to one tenant, so it
/// cannot also be the landlord's home. There is one home, so switching it on
/// here moves it off any other building, after saying so.
///
/// Switching it on asks for a utility bill for this building. Tenants are told
/// the landlord lives on the premises only once an admin has accepted it.
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

  void _show(String message, {bool error = true}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.error : null,
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Asks for the bill and submits the claim. Used both to switch on and to
  /// send another bill after a rejection.
  Future<void> _submitProof() async {
    final r = _residence;
    final buildingId = widget.property.buildingId;
    if (r == null || buildingId == null) return;
    final file = await DocumentFilePicker.pick(
      context,
      hint: 'A recent utility bill for this building, showing its address.',
    );
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    String? error;
    try {
      final path = await _service.uploadHomeProof(file);
      // The building's own name; older units carry no label of their own.
      final building = await BuildingService().getBuilding(buildingId);
      error = path == null
          ? 'You must be signed in.'
          : await _service.markHome(buildingId,
              building?.name ?? widget.property.unitBuildingLabel ?? 'Your building', path);
    } catch (_) {
      error = 'Could not upload the bill. Please try again.';
    }
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      _show(error);
    } else {
      _show('Sent. We will check the bill and then tell tenants you live here.',
          error: false);
    }
  }

  Future<void> _toggle(bool on) async {
    final r = _residence;
    final buildingId = widget.property.buildingId;
    if (r == null || buildingId == null) return;

    if (!on) {
      setState(() => _busy = true);
      final error = await _service.clearHome();
      await _load();
      if (!mounted) return;
      setState(() => _busy = false);
      if (error != null) _show(error);
      return;
    }

    if (r.homeBuildingId != null && r.homeBuildingId != buildingId) {
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
    await _submitProof();
  }

  @override
  Widget build(BuildContext context) {
    final r = _residence;
    final buildingId = widget.property.buildingId;
    if (r == null || !r.canMarkHome || (buildingId ?? '').isEmpty) {
      return const SizedBox.shrink();
    }
    final here = r.livesAt(buildingId);
    final status = here ? r.homeProofStatus : null;

    final String subtitle;
    Color? subtitleColor;
    if (status == LandlordResidence.proofAccepted) {
      subtitle =
          'Checked. Tenants of units here see that their landlord lives on the premises.';
    } else if (status == LandlordResidence.proofPending) {
      subtitle =
          'We are checking your utility bill. Until then tenants see that you live elsewhere.';
      subtitleColor = AppColors.warning;
    } else if (status == LandlordResidence.proofRejected) {
      final reason = r.homeProofRejectionReason;
      subtitle = 'Your utility bill was not accepted'
          '${(reason ?? '').isNotEmpty ? ': $reason' : ''}. Send another.';
      subtitleColor = AppColors.error;
    } else {
      subtitle =
          'Needs a utility bill for this building. Tenants then see that their landlord lives on the premises.';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          SwitchListTile(
            value: here,
            onChanged: _busy ? null : _toggle,
            title: Text('I live in this building',
                style: AppTextStyles.labelMedium),
            subtitle: Text(
              subtitle,
              style: AppTextStyles.caption
                  .copyWith(color: subtitleColor ?? AppColors.textSecondary),
            ),
          ),
          if (status == LandlordResidence.proofRejected)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton(
                onPressed: _busy ? null : _submitProof,
                child: const Text('Send another utility bill'),
              ),
            ),
        ],
      ),
    );
  }
}
