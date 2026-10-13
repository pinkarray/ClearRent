import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../services/location_service.dart';
import '../../services/video_viewing_service.dart';
import '../../shared/models/inspection_request_model.dart';
import 'video_call_screen.dart';

/// "Start video viewing" for the host, "Join video call" for the tenant, on a
/// paid, approved video viewing. Renders nothing otherwise. The request comes
/// from a live stream, so the tenant's button unlocks the moment the host
/// starts.
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

  // The call window: from 30 minutes before the slot to its end, matching
  // video_viewing_ops.ts.
  bool get _inWindow {
    final start = widget.request.requestedDate;
    final now = DateTime.now();
    return now.isAfter(start.subtract(const Duration(minutes: 30))) &&
        now.isBefore(start.add(const Duration(hours: 3)));
  }

  Future<void> _markReady() async {
    setState(() => _busy = true);
    try {
      await VideoViewingService().markReady(widget.request.id);
    } on VideoViewingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.error,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    final r = widget.request;
    setState(() => _busy = true);
    try {
      final service = VideoViewingService();
      // A host whose call is already open rejoins without a second GPS check.
      final creds = widget.isHost && r.videoStartedAt == null
          ? await service.start(r.id)
          : await service.join(r.id);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoCallScreen(
          requestId: r.id,
          propertyTitle: r.propertyTitle,
          isHost: widget.isHost,
          credentials: creds,
        ),
      ));
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

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    if (!r.isVideo ||
        r.status != InspectionStatus.approved ||
        r.paymentStatus != 'paid') {
      return const SizedBox.shrink();
    }
    final waiting = !widget.isHost && r.videoStartedAt == null;

    // The tenant can't join before the host starts. Saying "I'm ready" is what
    // makes a host who never starts a provable no-show.
    if (waiting && _inWindow && r.tenantReadyAt == null) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _busy ? null : _markReady,
          icon: const Icon(Icons.front_hand_outlined),
          label: Text(_busy ? 'Saving...' : "I'm ready for the call"),
        ),
      );
    }
    final label = _busy
        ? (widget.isHost ? 'Checking you are at the property...' : 'Joining...')
        : widget.isHost
            ? (r.videoStartedAt == null
                ? 'Start video viewing'
                : 'Rejoin video viewing')
            : (waiting
                ? (r.tenantReadyAt != null
                    ? "You're ready. Waiting for your host to start the call"
                    : 'Waiting for your host to start the call')
                : 'Join video call');

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy || waiting ? null : _open,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.videocam_outlined),
        label: Text(label),
      ),
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
