import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../services/location_service.dart';
import '../../services/video_viewing_service.dart';
import '../../core/utils/inspection_pricing.dart';
import '../../shared/models/inspection_request_model.dart';
import 'video_call_screen.dart';

/// The video viewing's one action, whatever stage it is at, on a paid,
/// approved video viewing (nothing otherwise). Host: check in at the property
/// by GPS, then start the call, then rejoin. Tenant: say they are ready, then
/// join once the host starts. The request comes from a live stream, so each
/// step appears the moment the other side acts.
class VideoViewingButton extends StatefulWidget {
  final InspectionRequest request;
  final bool isHost;

  const VideoViewingButton({
    super.key,
    required this.request,
    required this.isHost,
  });

  @override
  State<VideoViewingButton> createState() => _VideoViewingButtonState();
}

class _VideoViewingButtonState extends State<VideoViewingButton> {
  bool _busy = false;
  Timer? _opensTimer;

  // The call window, matching video_viewing_ops.ts: from 30 minutes before
  // the slot until it ends (evening is 6-8 PM, the others three hours).
  DateTime get _start => widget.request.requestedDate;
  DateTime get _opensAt => _start.subtract(const Duration(minutes: 30));
  DateTime get _checkInBy => _start.add(const Duration(minutes: 30));

  @override
  void initState() {
    super.initState();
    // Turn "The call opens at ..." into a live button on time, without the
    // user having to reopen the screen.
    final wait = _opensAt.difference(DateTime.now());
    if (!wait.isNegative) {
      _opensTimer = Timer(wait, () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _opensTimer?.cancel();
    super.dispose();
  }

  String _time(DateTime t) => TimeOfDay.fromDateTime(t).format(context);

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on VideoViewingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.error,
        action: e.needsSettings
            ? SnackBarAction(
                label: 'Settings',
                textColor: Colors.white,
                onPressed: LocationService().openSettings,
              )
            : null,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCall(Future<VideoCallCredentials> Function() creds) =>
      _run(() async {
        final c = await creds();
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => VideoCallScreen(
            requestId: widget.request.id,
            propertyTitle: widget.request.propertyTitle,
            isHost: widget.isHost,
            credentials: c,
          ),
        ));
      });

  Widget _button(String label, IconData icon, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy ? null : onPressed,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon),
        label: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    if (!r.isVideo ||
        r.status != InspectionStatus.approved ||
        r.paymentStatus != 'paid') {
      return const SizedBox.shrink();
    }
    final service = VideoViewingService();

    // Before the window: say when, rather than offer a button that errors.
    if (DateTime.now().isBefore(_opensAt)) {
      return _button(
          'The call opens at ${_time(_opensAt)}', Icons.schedule, null);
    }

    if (widget.isHost) {
      if (r.videoCheckedInAt == null && r.videoStartedAt == null) {
        // What is at stake, said where the host acts on it.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _button(
              _busy ? 'Checking your location...' : "I'm at the property",
              Icons.where_to_vote_outlined,
              () => _run(() => service.checkIn(r.id)),
            ),
            const SizedBox(height: 6),
            Text(
              'Check in by ${_time(_checkInBy)}. If the tenant is waiting '
              "and you haven't, they're refunded and you won't be paid.",
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        );
      }
      if (r.videoStartedAt == null) {
        return _button(
          _busy ? 'Starting...' : 'Start video viewing',
          Icons.videocam_outlined,
          () => _openCall(() => service.start(
                r.id,
                checkedIn: r.videoCheckedInAt != null,
              )),
        );
      }
      return _button(
        _busy ? 'Joining...' : 'Rejoin video viewing',
        Icons.videocam_outlined,
        () => _openCall(() => service.join(r.id)),
      );
    }

    // Tenant. They can't join before the host starts; saying they are ready
    // is what makes a host who never arrives a provable no-show.
    if (r.videoStartedAt == null) {
      if (r.tenantReadyAt == null) {
        return _button(
          _busy ? 'Saving...' : "I'm ready for the call",
          Icons.front_hand_outlined,
          () => _run(() => service.markReady(r.id)),
        );
      }
      return _button(
        r.videoCheckedInAt != null
            ? 'Your host is at the property. Waiting for the call'
            : "You're ready. Waiting for your host",
        Icons.hourglass_top,
        null,
      );
    }
    return _button(
      _busy ? 'Joining...' : 'Join video call',
      Icons.videocam_outlined,
      () => _openCall(() => service.join(r.id)),
    );
  }
}

/// Marks a viewing as a video call on every card, whatever the day, so the
/// mode is never a surprise on the day itself.
class VideoViewingBadge extends StatelessWidget {
  const VideoViewingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(26),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_outlined, size: 16, color: AppColors.info),
          const SizedBox(width: 6),
          Text(
            'Video viewing',
            style: TextStyle(
              color: AppColors.info,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Before a host approves a video viewing: what they are agreeing to, and
/// what happens to the fee if they are not there. True to go ahead.
Future<bool> confirmVideoViewingTerms(
  BuildContext context,
  InspectionRequest r,
) async {
  final start = r.requestedDate;
  final checkInBy = start.add(const Duration(minutes: 30));
  String time(DateTime t) => TimeOfDay.fromDateTime(t).format(context);
  final fee = InspectionPricing.formatNaira(r.agentEarnings);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('This is a video viewing'),
      content: SingleChildScrollView(
        child: Text(
          'The tenant watches from wherever they are while you walk them '
          'through the property on a live call. You still go to the property.'
          '\n\n'
          '1. Be at the property by ${time(start)} and tap "I\'m at the '
          'property". Your phone\'s location is checked against the '
          'property\'s pin.\n'
          '2. Then start the call and show them round.\n'
          '3. If the tenant is waiting and you haven\'t checked in by '
          '${time(checkInBy)}, they are refunded and you are not paid.\n'
          '4. If you checked in and the tenant never shows, you are still '
          'paid $fee.\n'
          '5. If you checked in but the call can\'t connect, nobody is '
          'penalised: we help the tenant rebook.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('I understand, approve'),
        ),
      ],
    ),
  );
  return ok == true;
}
