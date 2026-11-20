import 'package:flutter/material.dart';

/// Asked before a landlord marks a listing occupied while viewings are still
/// booked: taking it down cancels them, and the paid ones are refunded
/// (onPropertyTaken on the server). True means go ahead.
Future<bool> confirmTakeDown(BuildContext context, int openViewings) async {
  if (openViewings <= 0) return true;
  final plural = openViewings == 1 ? '' : 's';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Cancel booked viewings?'),
      content: Text(
        'This will cancel $openViewings booked viewing$plural. Tenants who '
        'paid get their viewing fee back, minus the booking charge, plus a '
        'free booking on their next viewing.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep listing'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Mark occupied'),
        ),
      ],
    ),
  );
  return ok == true;
}
