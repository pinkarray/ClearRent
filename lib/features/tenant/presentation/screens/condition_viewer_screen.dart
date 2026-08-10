import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/condition_service.dart';
import '../../../../shared/models/condition_record.dart';

/// Plays back one party's condition recording.
///
/// The media lives under the RECORDER's own uid in Storage, so the
/// counterparty cannot read it directly — Storage rules cannot check tenancy
/// membership. Every URL here is minted by `getConditionMediaUrl`, which does
/// that check server-side and hands back a short-lived link.
///
/// Signed one item at a time, on demand: a walkthrough plus a dozen photos
/// would otherwise mean signing everything up front, most of it never opened,
/// with every link live for fifteen minutes regardless.
class ConditionViewerScreen extends StatelessWidget {
  final String rentalId;
  final ConditionRecord record;

  const ConditionViewerScreen({
    super.key,
    required this.rentalId,
    required this.record,
  });

  @override
  Widget build(BuildContext context) {
    final service = ConditionService();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('${record.partyRole == 'tenant' ? "Tenant" : "Landlord"}'
            "'s recording"),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (record.notes.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(record.notes, style: AppTextStyles.bodyMedium),
            ),
            const SizedBox(height: 16),
          ],

          if (record.videoPaths.isNotEmpty) ...[
            Text('Walkthrough', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            ...record.videoPaths.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SignedVideo(
                      rentalId: rentalId, path: p, service: service),
                )),
          ],

          if (record.imagePaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Photos', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            ...record.imagePaths.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SignedImage(
                      rentalId: rentalId, path: p, service: service),
                )),
          ],
        ],
      ),
    );
  }
}

class _SignedImage extends StatelessWidget {
  final String rentalId;
  final String path;
  final ConditionService service;

  const _SignedImage({
    required this.rentalId,
    required this.path,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: service.mediaUrl(rentalId, path),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _MediaPlaceholder(label: 'Loading…');
        }
        final url = snap.data;
        if (url == null) {
          return const _MediaPlaceholder(label: 'Could not load this photo');
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(url, fit: BoxFit.cover),
        );
      },
    );
  }
}

class _SignedVideo extends StatefulWidget {
  final String rentalId;
  final String path;
  final ConditionService service;

  const _SignedVideo({
    required this.rentalId,
    required this.path,
    required this.service,
  });

  @override
  State<_SignedVideo> createState() => _SignedVideoState();
}

class _SignedVideoState extends State<_SignedVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await widget.service.mediaUrl(widget.rentalId, widget.path);
    if (!mounted) return;
    if (url == null) {
      setState(() => _failed = true);
      return;
    }
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() => _controller = c);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const _MediaPlaceholder(label: 'Could not load this video');
    }
    final c = _controller;
    if (c == null) return const _MediaPlaceholder(label: 'Loading video…');

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        child: Stack(alignment: Alignment.center, children: [
          VideoPlayer(c),
          VideoProgressIndicator(c, allowScrubbing: true),
          IconButton(
            iconSize: 48,
            icon: Icon(
              c.value.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill,
              color: Colors.white.withAlpha(220),
            ),
            onPressed: () => setState(
                () => c.value.isPlaying ? c.pause() : c.play()),
          ),
        ]),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  final String label;
  const _MediaPlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(label,
          style: AppTextStyles.caption
              .copyWith(color: AppColors.textSecondary)),
    );
  }
}
