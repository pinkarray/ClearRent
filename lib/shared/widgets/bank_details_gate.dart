import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/auth_service.dart';

/// Client-side gate for money-bearing inspection actions: a handler accepting a
/// request must have a payout account on file first, so their inspection
/// earnings — and any dispute payout — have a destination admin can settle to.
///
/// Returns true when bank details are present (caller proceeds). When missing,
/// shows [reason] and routes to [bankDetailsRoute], returning false so the
/// caller aborts. The Firestore rules enforce the same requirement server-side;
/// this is just the friendly nudge that gets there first.
Future<bool> ensureBankDetailsOnFile(
  BuildContext context, {
  required String bankDetailsRoute,
  required String reason,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  final hasBank = await AuthService().hasBankDetails();
  if (!context.mounted) return false;
  if (hasBank) return true;
  messenger.showSnackBar(
    SnackBar(content: Text(reason), behavior: SnackBarBehavior.floating),
  );
  router.push(bankDetailsRoute);
  return false;
}
