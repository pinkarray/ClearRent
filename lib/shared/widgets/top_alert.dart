import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A message that drops in from the top of the screen and leaves on its own.
///
/// Form validation used to fail silently from the user's point of view. The
/// inline error renders beside the offending field, and on a long form that
/// field is usually scrolled out of sight — so the submit button simply looked
/// broken, and the only way to find out why was to scroll back up hunting for
/// red text. Someone entering one name instead of two had no way of knowing
/// that was the problem.
///
/// This puts the reason where the user is already looking: at the top, over
/// whatever they are on, without moving the page under them.
///
/// Deliberately an overlay rather than a SnackBar: a SnackBar animates up from
/// the bottom, which is where the button they just pressed is, and on this form
/// that is the one place the message is least likely to be read as an answer to
/// the tap.
class TopAlert {
  TopAlert._();

  static OverlayEntry? _entry;

  /// Show [message] over the current route.
  ///
  /// Any alert already on screen is replaced, so a second failed submit does
  /// not stack banners.
  static void show(
    BuildContext context,
    String message, {
    bool isError = true,
    Duration duration = const Duration(seconds: 4),
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    dismiss();
    final entry = OverlayEntry(
      builder: (context) => _TopAlertView(
        message: message,
        isError: isError,
        duration: duration,
        onDismissed: dismiss,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _TopAlertView extends StatefulWidget {
  const _TopAlertView({
    required this.message,
    required this.isError,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final bool isError;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_TopAlertView> createState() => _TopAlertViewState();
}

class _TopAlertViewState extends State<_TopAlertView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future.delayed(widget.duration, _close);
  }

  Future<void> _close() async {
    if (!mounted) return;
    await _controller.reverse();
    // The entry may already be gone if a second alert replaced this one.
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isError ? AppColors.error : AppColors.primary;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: GestureDetector(
                onTap: _close,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(38),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        widget.isError
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.message,
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
