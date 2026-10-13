import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/location_service.dart';
import '../../services/property_service.dart';

/// "Is this pin where the property really is?" for the landlord, agent or
/// caretaker. A pin dropped on a map from elsewhere can be anywhere; one set
/// from the phone's GPS while standing there can be trusted, and video
/// viewings check the handler's presence against it.
///
/// Loads its own state, so a screen only has to place it. [onConfirmed] lets
/// the screen reload its map once the pin has moved.
class PinConfirmationCard extends StatefulWidget {
  final String propertyId;
  final VoidCallback? onConfirmed;

  const PinConfirmationCard({
    super.key,
    required this.propertyId,
    this.onConfirmed,
  });

  @override
  State<PinConfirmationCard> createState() => _PinConfirmationCardState();
}

class _PinConfirmationCardState extends State<PinConfirmationCard> {
  final _propertyService = PropertyService();
  final _locationService = LocationService();
  PinStatus? _status;
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final status = await _propertyService.getPinStatus(widget.propertyId);
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _confirm() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you at the property now?'),
        content: const Text(
          'ClearRent will read your location once, now, and set this '
          "property's pin to where you are standing. Only do this at the "
          'property itself.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("I'm here"),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _working = true);
    String? error;
    bool needsSettings = false;
    try {
      final reading = await _locationService.currentReading();
      error = await _propertyService.confirmPinOnSite(
        widget.propertyId,
        reading,
      );
    } on LocationUnavailable catch (e) {
      error = e.message;
      needsSettings = e.needsSettings;
    }
    if (!mounted) return;
    setState(() => _working = false);

    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(SnackBar(
        content: Text(error),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.error,
        action: needsSettings
            ? SnackBarAction(
                label: 'Settings',
                textColor: Colors.white,
                onPressed: _locationService.openSettings,
              )
            : null,
      ));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: const Text('Pin confirmed on site'),
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.success,
    ));
    await _load();
    widget.onConfirmed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    // Still loading, or the caller can't read the location at all.
    if (_loading || s == null) return const SizedBox.shrink();

    final IconData icon;
    final Color tone;
    final String title;
    final String body;
    if (s.isConfirmed) {
      icon = Icons.verified_outlined;
      tone = AppColors.success;
      title = 'Pin confirmed on site';
      final when = s.confirmedAt!;
      body = 'Set by the ${s.confirmedRole ?? 'handler'} standing at the '
          'property on ${when.day}/${when.month}/${when.year}'
          '${s.accuracyM != null ? ', accurate to about ${s.accuracyM}m' : ''}.';
    } else if (s.confirmedAt != null) {
      icon = Icons.wrong_location_outlined;
      tone = AppColors.warning;
      title = 'Pin moved since it was confirmed';
      body = 'The pin was changed by hand after it was confirmed on site. '
          'Confirm it again next time you are at the property.';
    } else {
      icon = Icons.add_location_alt_outlined;
      tone = AppColors.info;
      title = s.hasPin ? 'Pin not confirmed on site' : 'No map pin yet';
      body = 'Next time you are at the property, tap below to set the pin '
          'from your phone. A confirmed pin is needed for video viewings and '
          'helps tenants find the place.';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: tone, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.labelLarge.copyWith(color: tone),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(body, style: AppTextStyles.bodySmall),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: s.isConfirmed
                ? TextButton(
                    onPressed: _working ? null : _confirm,
                    child: Text(_working ? 'Getting your location...' : 'Re-confirm'),
                  )
                : FilledButton.icon(
                    onPressed: _working ? null : _confirm,
                    icon: _working
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location, size: 18),
                    label: Text(
                      _working
                          ? 'Getting your location...'
                          : "I'm at the property, set the pin here",
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
