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
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.primary, width: 2),
        borderRadius: BorderRadius.circular(16),
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
