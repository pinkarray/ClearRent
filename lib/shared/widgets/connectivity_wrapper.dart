import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/connectivity_service.dart';

/// Wraps the app (installed once in `MaterialApp.builder`) and shows a
/// floating banner when offline, on top of whatever route is showing.
///
/// The banner insets the page rather than covering it: it sits above the
/// router, so covering would hide app bars and back buttons on pushed routes
/// for as long as the connection is down.
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
  late Animation<double> _sizeAnimation;
  late AppLifecycleListener _lifecycleListener;

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

    _sizeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _isOnline = _connectivity.isOnline;
    if (!_isOnline) {
      _showBanner = true;
      _wasOffline = true;
      _animController.value = 1.0; // already visible, skip animation on init
    }

    _subscription = _connectivity.onConnectivityChanged.listen(_onStatusChanged);

    // connectivity_plus only fires when an interface changes. If the Wi-Fi
    // stays associated but the internet dies (data cap, captive portal), no
    // event arrives — so re-check whenever the user comes back to the app.
    _lifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(_connectivity.checkConnection()),
    );
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
    _lifecycleListener.dispose();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return Column(
      children: [
        // ── Banner — grows from the top edge, pushing the page down ──
        if (_showBanner)
          SizeTransition(
            sizeFactor: _sizeAnimation,
            alignment: Alignment.topLeft,
            // Sitting above the Navigator there is no Material ancestor, so
            // Text would fall back to MaterialApp's debug error style.
            child: Material(
              type: MaterialType.transparency,
              child: _NetworkBanner(
                isOnline: _isOnline,
                isRetrying: _isRetrying,
                onRetry: _retry,
              ),
            ),
          ),

        // ── Main content — Expanded gives the navigator a tight height ──
        Expanded(
          child: MediaQuery(
            // The banner has already absorbed the status-bar inset in its own
            // padding. Leaving it here too would make every SafeArea below
            // reserve a second status bar's worth of empty space.
            data: _showBanner
                ? media.copyWith(padding: media.padding.copyWith(top: 0))
                : media,
            child: widget.child,
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
