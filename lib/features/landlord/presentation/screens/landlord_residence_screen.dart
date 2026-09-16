import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/residence_service.dart';
import '../../../../shared/models/landlord_residence.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../shared/widgets/area_dropdown.dart';

/// "Where do you live?" - asked once, here, rather than on every listing.
///
/// Pops `true` once saved, so a caller that sent the landlord here (the home
/// prompt, add-property) can carry on.
class LandlordResidenceScreen extends StatefulWidget {
  const LandlordResidenceScreen({super.key});

  @override
  State<LandlordResidenceScreen> createState() =>
      _LandlordResidenceScreenState();
}

class _LandlordResidenceScreenState extends State<LandlordResidenceScreen> {
  final _service = ResidenceService();
  final _country = TextEditingController();
  LandlordResidence? _existing;
  String? _kind;
  String? _state;
  String? _area;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service.get().then((r) {
      if (!mounted) return;
      setState(() {
        _existing = r;
        _kind = r?.kind;
        _state = r?.state;
        _area = r?.area;
        _country.text = r?.country ?? '';
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _country.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final kind = _kind;
    if (kind == null) return _show('Choose where you live.');
    if (kind != LandlordResidence.abroad && _state == null) {
      return _show('Choose your state.');
    }
    if (kind == LandlordResidence.abroad && _country.text.trim().isEmpty) {
      return _show('Enter the country you live in.');
    }
    setState(() => _saving = true);
    final keepHome = kind == LandlordResidence.own;
    final error = await _service.save(LandlordResidence(
      kind: kind,
      state: kind == LandlordResidence.abroad ? null : _state,
      area: _state == 'Lagos' && kind != LandlordResidence.abroad ? _area : null,
      country:
          kind == LandlordResidence.abroad ? _country.text.trim() : null,
      homeBuildingId: keepHome ? _existing?.homeBuildingId : null,
      homeBuildingName: keepHome ? _existing?.homeBuildingName : null,
    ));
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) return _show(error);
    Navigator.of(context).pop(true);
  }

  void _show(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _choice(String kind, String label, String subtitle, IconData icon) {
    final selected = _kind == kind;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () {
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => _kind = kind);
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color:
                selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon,
                color: selected ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: selected
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      )),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary, height: 1.5)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final abroad = _kind == LandlordResidence.abroad;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Where you live')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Tenants are told whether their landlord lives on the '
                  'premises, elsewhere, or outside Nigeria. They never see '
                  'your address.',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 20),
                _choice(
                  LandlordResidence.own,
                  'In a property I own',
                  'If it is one you list, you can mark it "I live here" on '
                      'that listing.',
                  Icons.home_outlined,
                ),
                _choice(
                  LandlordResidence.rent,
                  'In a place I rent',
                  'You live somewhere you do not own.',
                  Icons.apartment_outlined,
                ),
                _choice(
                  LandlordResidence.abroad,
                  'Outside Nigeria',
                  'An agent or a caretaker will need to show your '
                      'properties to tenants.',
                  Icons.flight_outlined,
                ),
                const SizedBox(height: 10),
                if (_kind != null && !abroad) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _state,
                    decoration: const InputDecoration(labelText: 'State'),
                    items: nigerianStates
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setState(() {
                      _state = v;
                      if (v != 'Lagos') _area = null;
                    }),
                  ),
                  if (_state == 'Lagos') ...[
                    const SizedBox(height: 16),
                    AreaDropdown(
                      label: 'Area (optional)',
                      hint: 'Select area',
                      selectedArea: _area,
                      onSelected: (a) => setState(() => _area = a),
                    ),
                  ],
                ],
                if (abroad)
                  AppTextField(
                    controller: _country,
                    label: 'Country',
                    hint: 'e.g. United Kingdom',
                  ),
                const SizedBox(height: 28),
                AppButton(
                  text: 'Save',
                  isLoading: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
    );
  }
}
