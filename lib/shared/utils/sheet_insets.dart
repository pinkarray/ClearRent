import 'package:flutter/material.dart';

/// The space a bottom sheet must leave beneath its content.
///
/// `viewInsets.bottom` is the KEYBOARD and nothing else. `padding.bottom` is
/// the system intrusion — the gesture bar or on-screen navigation buttons.
/// A sheet that accounts for one but not the other looks correct while typing
/// and then, the instant the keyboard is dismissed, drops its primary action
/// underneath the navigation bar — which is precisely the moment the user
/// reaches for that button. That is how "Send invitation" ended up
/// unreachable on the caretaker invite sheet.
///
/// Use this anywhere a sheet pads its own bottom edge.
double sheetBottomInset(BuildContext context) {
  final mq = MediaQuery.of(context);
  return mq.viewInsets.bottom + mq.padding.bottom;
}
