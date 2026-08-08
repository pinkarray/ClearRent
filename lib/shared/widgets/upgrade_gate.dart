import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/app_version_service.dart';

/// Wraps the whole router so the upgrade gate covers every route with a single
/// subscription — the same reason [ConnectivityWrapper] sits where it does.
///
/// Two behaviours, driven by `config/app_version`:
///  * below `minSupportedBuild` → the app is replaced by a wall with no way
///    past it. Reserved for builds that are actively broken.
///  * below `latestBuild` → a dismissible card over the current route, shown
///    once per launch.
///
/// Both are drawn inline rather than pushed as routes: this sits ABOVE the
/// router's Navigator, so there is no Navigator or Material ancestor to show a
/// dialog or sheet with — the same constraint [ConnectivityWrapper] works
/// around by painting its banner directly.
///
/// [AppVersionService] fails open, so when the config is missing, unreadable
/// or malformed this widget is a pass-through.
class UpgradeGate extends StatefulWidget {
  final Widget child;

  const UpgradeGate({super.key, required this.child});

  @override
  State<UpgradeGate> createState() => _UpgradeGateState();
}

class _UpgradeGateState extends State<UpgradeGate> {
  late AppVersionGate _gate;
  StreamSubscription<AppVersionGate>? _sub;

  /// The nudge is dismissible and stays dismissed for the rest of the launch.
  /// Re-showing it on every config frame would be its own kind of unusable.
  bool _nudgeDismissed = false;

  @override
  void initState() {
    super.initState();
    _gate = AppVersionService.instance.current;
    AppVersionService.instance.start();
    _sub = AppVersionService.instance.changes.listen((gate) {
      if (mounted) setState(() => _gate = gate);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _openStore() async {
    final uri = Uri.parse(_gate.storeUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_gate.blocked) return _buildBlockingWall();

    if (!_gate.updateAvailable || _nudgeDismissed) return widget.child;

    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: _buildNudge(),
        ),
      ],
    );
  }

  Widget _buildNudge() {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.system_update, color: AppColors.primary, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Update available', style: AppTextStyles.labelMedium),
                  const SizedBox(height: 2),
                  Text(
                    _gate.message ?? 'A newer version of ClearRent is out.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _openStore,
              style: TextButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                'Update',
                style: AppTextStyles.labelSmall.copyWith(color: Colors.white),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 18, color: AppColors.textSecondary),
              onPressed: () => setState(() => _nudgeDismissed = true),
            ),
          ],
        ),
      ),
    );
  }

  /// No back button, no dismiss, no route underneath — a blocked build has
  /// nothing safe to show.
  Widget _buildBlockingWall() {
    return Material(
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.system_update, size: 56, color: AppColors.primary),
                const SizedBox(height: 24),
                Text(
                  'Update required',
                  style: AppTextStyles.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  _gate.message ??
                      'This version of ClearRent is no longer supported. '
                          'Update to continue.',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _openStore,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Update ClearRent'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
