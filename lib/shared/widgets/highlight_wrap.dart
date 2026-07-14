import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';

/// Wraps a list card with a highlight border when it's the item a
/// notification deep-linked to (via `param_requestId`). Paired with pinning
/// the matched item to the top of its tab list, so the user lands directly on
/// the inspection the notification was about. When [active] is false it's a
/// pass-through (no visual change).
class HighlightWrap extends StatelessWidget {
  final bool active;
  final Widget child;

  const HighlightWrap({super.key, required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    // A soft tinted "mat" around the card rather than a second border line.
    // Some cards (e.g. the Scheduled inspection card) draw their own border; a
    // bordered highlight here sat right against it and read as a doubled
    // outline. A translucent fill with a gap emphasises the card without ever
    // looking like two borders, regardless of the child's own decoration.
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(56),
        borderRadius: BorderRadius.circular(22),
      ),
      child: child,
    );
  }
}

/// Returns a copy of [items] with the first element matching [isTarget] moved
/// to the front (stable order otherwise). Used so a notification's target
/// inspection appears at the top of its tab.
List<T> pinToFront<T>(List<T> items, bool Function(T) isTarget) {
  final idx = items.indexWhere(isTarget);
  if (idx <= 0) return items;
  final copy = [...items];
  final target = copy.removeAt(idx);
  copy.insert(0, target);
  return copy;
}
