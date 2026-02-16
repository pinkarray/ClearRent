import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/connectivity_service.dart';

/// Wraps any screen and shows a banner when offline.
/// Shows "No internet connection" when offline, and briefly
/// shows "Back online" when connection is restored.
///
/// Usage:
///   ConnectivityWrapper(
///     child: YourScreen(),
///   )
class ConnectivityWrapper extends StatefulWidget {
  final Widget child;

  const ConnectivityWrapper({super.key, required this.child});

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper>
    with SingleTickerProviderStateMixin {
  final ConnectivityService _connectivity = ConnectivityService();
  late StreamSubscription<bool> _subscription;

  bool _isOnline = true;
  bool _showBanner = false;
  bool _wasOffline = false;
  Timer? _hideBannerTimer;

  @override
  void initState() {
    super.initState();
    _isOnline = _connectivity.isOnline;
    _showBanner = !_isOnline;

    _subscription = _connectivity.onConnectivityChanged.listen((online) {
      if (!mounted) return;

      if (!online) {
        // Went offline
        setState(() {
          _isOnline = false;
          _showBanner = true;
          _wasOffline = true;
        });
        _hideBannerTimer?.cancel();
      } else if (_wasOffline) {
        // Came back online after being offline
        setState(() {
          _isOnline = true;
          _showBanner = true; // Show "Back online" briefly
        });
        _hideBannerTimer?.cancel();
        _hideBannerTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _showBanner = false;
              _wasOffline = false;
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    _hideBannerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Banner
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: _showBanner ? null : 0,
          child: _showBanner
              ? MaterialBanner(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  backgroundColor:
                      _isOnline ? AppColors.success : const Color(0xFF424242),
                  content: Row(
                    children: [
                      Icon(
                        _isOnline ? Icons.wifi : Icons.wifi_off,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _isOnline
                              ? 'Back online'
                              : 'No internet connection',
                          style: AppTextStyles.labelMedium
                              .copyWith(color: Colors.white),
                        ),
                      ),
                      if (!_isOnline)
                        GestureDetector(
                          onTap: () async {
                            await _connectivity.checkConnection();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(51),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text('Retry',
                                style: AppTextStyles.labelSmall
                                    .copyWith(color: Colors.white)),
                          ),
                        ),
                    ],
                  ),
                  actions: const [SizedBox.shrink()],
                )
              : const SizedBox.shrink(),
        ),
        // Main content
        Expanded(child: widget.child),
      ],
    );
  }
}

/// Simpler version — just an offline indicator without wrapping.
/// Use anywhere in a Column/Stack.
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({super.key});

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  final ConnectivityService _connectivity = ConnectivityService();
  late StreamSubscription<bool> _subscription;
  bool _isOnline = true;

  @override
  void initState() {
    super.initState();
    _isOnline = _connectivity.isOnline;
    _subscription = _connectivity.onConnectivityChanged.listen((online) {
      if (mounted) setState(() => _isOnline = online);
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isOnline) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFF424242),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(
            'No internet connection',
            style: AppTextStyles.labelSmall.copyWith(color: Colors.white),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _connectivity.checkConnection(),
            child: Text(
              'Retry',
              style: AppTextStyles.labelSmall.copyWith(
                color: Colors.white,
                decoration: TextDecoration.underline,
                decorationColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}