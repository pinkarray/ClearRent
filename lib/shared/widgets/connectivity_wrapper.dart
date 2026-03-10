import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/connectivity_service.dart';

/// Wraps any screen and shows a floating banner when offline.
///
/// Uses a Stack overlay so the banner slides in OVER the content —
/// it never pushes or displaces anything below it.
///
/// Retry actually works: it re-checks the connection and updates
/// the UI directly regardless of whether the status changed.
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
  late AnimationController _animController;
  late Animation<Offset> _slideAnimation;

  bool _isOnline = true;
  bool _showBanner = false;
  bool _wasOffline = false;
  bool _isRetrying = false;
  Timer? _hideBannerTimer;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    _isOnline = _connectivity.isOnline;
    if (!_isOnline) {
      _showBanner = true;
      _wasOffline = true;
      _animController.value = 1.0; // already visible, skip animation on init
    }

    _subscription = _connectivity.onConnectivityChanged.listen(_onStatusChanged);
  }

  void _onStatusChanged(bool online) {
    if (!mounted) return;

    if (!online) {
      _hideBannerTimer?.cancel();
      setState(() {
        _isOnline = false;
        _showBanner = true;
        _wasOffline = true;
        _isRetrying = false;
      });
      _animController.forward();
    } else if (_wasOffline) {
      setState(() {
        _isOnline = true;
        _isRetrying = false;
      });
      // Show "Back online" briefly then slide out
      _hideBannerTimer?.cancel();
      _hideBannerTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          _animController.reverse().then((_) {
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
  }

  Future<void> _retry() async {
    if (_isRetrying) return;
    setState(() => _isRetrying = true);

    final online = await _connectivity.checkConnection();

    if (!mounted) return;

    // checkConnection() only emits to the stream if the status *changed*.
    // If we were already offline and got offline again, the stream won't fire,
    // so we manually trigger the UI update here.
    if (online) {
      _onStatusChanged(true);
    } else {
      setState(() => _isRetrying = false);
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    _hideBannerTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ── Main content — never moves ──
        widget.child,

        // ── Overlay banner — slides over content from top ──
        if (_showBanner)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SlideTransition(
              position: _slideAnimation,
              child: _NetworkBanner(
                isOnline: _isOnline,
                isRetrying: _isRetrying,
                onRetry: _retry,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Banner widget ─────────────────────────────────────────────────────────────

class _NetworkBanner extends StatelessWidget {
  final bool isOnline;
  final bool isRetrying;
  final VoidCallback onRetry;

  const _NetworkBanner({
    required this.isOnline,
    required this.isRetrying,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final bgColor = isOnline ? AppColors.success : const Color(0xFF323232);

    return Container(
      color: bgColor,
      padding: EdgeInsets.only(
        top: topPadding + 10,
        bottom: 10,
        left: 16,
        right: 16,
      ),
      child: Row(
        children: [
          Icon(
            isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isOnline ? 'Back online' : 'No internet connection',
              style: AppTextStyles.labelMedium.copyWith(color: Colors.white),
            ),
          ),

          // Retry button — only shown when offline
          if (!isOnline)
            GestureDetector(
              onTap: isRetrying ? null : onRetry,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: isRetrying
                    ? const SizedBox(
                        key: ValueKey('loading'),
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Container(
                        key: const ValueKey('retry'),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(40),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withAlpha(80),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          'Retry',
                          style: AppTextStyles.labelSmall
                              .copyWith(color: Colors.white),
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OfflineBanner — simpler standalone widget for use inside a Column or Stack
// ─────────────────────────────────────────────────────────────────────────────

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
      color: const Color(0xFF323232),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(
            'No internet connection',
            style: AppTextStyles.labelSmall.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}