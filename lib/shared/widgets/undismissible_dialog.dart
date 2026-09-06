import 'package:flutter/material.dart';

/// A dialog the user cannot dismiss by accident — barrier tap AND system back.
///
/// `barrierDismissible: false` alone stops the barrier tap and nothing else:
/// the Android back gesture still pops the route. On the payment screens that
/// was a money bug, not a cosmetic one. Backing out of "Payment Confirmed!"
/// dropped the tenant onto a payment form that still looked unpaid, they read
/// it as the payment having been cancelled, and they paid a second time.
///
/// Use this wherever the dialog is REPORTING a completed side effect (a charge,
/// a submission) rather than asking a question. For a dialog the user is
/// genuinely allowed to walk away from, plain `showDialog` is correct.
Future<T?> showUndismissibleDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(canPop: false, child: builder(ctx)),
  );
}
