import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/condition_service.dart';
import '../../../../shared/models/condition_record.dart';
import 'condition_viewer_screen.dart';

/// Records the condition of a property, on camera, at one end of a tenancy.
///
/// Capture is CAMERA-ONLY and that is the whole point. A gallery picker would
/// happily accept a video shot on move-IN day as proof of move-OUT condition,
/// which is precisely the claim the record exists to test. `ImageSource.camera`
/// means the footage is taken now, in the property.
///
/// A video is required and photos are optional, in that order: a photo shows a
/// corner, a walkthrough shows the room it sits in and is far harder to frame
/// selectively.
class ConditionCaptureScreen extends StatefulWidget {
  final String rentalId;
  final String propertyTitle;
  final ConditionStage stage;

  /// 'tenant' | 'landlord' — recorded on the document so the other side can
  /// see who made it without a second read.
  final String partyRole;

  const ConditionCaptureScreen({
    super.key,
    required this.rentalId,
    required this.propertyTitle,
    required this.stage,
    required this.partyRole,
  });

  @override
  State<ConditionCaptureScreen> createState() => _ConditionCaptureScreenState();
}

class _ConditionCaptureScreenState extends State<ConditionCaptureScreen> {
  final _picker = ImagePicker();
  final _service = ConditionService();
  final _notes = TextEditingController();

  /// Above this, a recording is transcoded before it is uploaded. Below it,
  /// re-encoding costs the person time and quality for nothing.
  static const double _maxVideoMb = 25;

  final List<File> _videos = [];
  final List<File> _images = [];
  bool _submitting = false;
  String? _error;

  /// 0..1 while a recording is being transcoded, null otherwise.
  double? _compressProgress;

  /// 0..1 while media is uploading, null before it starts.
  double? _uploadProgress;

  /// This party's own sealed record, if they already made one.
  ConditionRecord? _sealed;
  bool _checking = true;

  /// Set when captures were recovered after the activity was destroyed, so the
  /// screen can say so rather than silently appearing to have them all along.
  bool _recovered = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadExisting();
    // A sealed record means there is nothing in progress to restore.
    if (!mounted || _sealed != null) return;
    await _restoreDraft();
    await _recoverLostCapture();
    if (!mounted) return;
    if (_videos.isNotEmpty || _images.isNotEmpty) {
      setState(() {});
      await _saveDraft();
    }
  }

  // ── Surviving the activity being killed ───────────────────────────────────
  //
  // Launching the camera hands the foreground to another activity, and Android
  // is free to destroy this one to reclaim memory — routine on a low-RAM
  // phone. Everything captured so far lives in these two lists, i.e. in
  // memory, so coming back from the camera showed a BLANK screen with the
  // earlier recording gone. A walkthrough is not something anyone should be
  // asked to shoot twice, so the paths are written down as they are captured
  // and read back when the screen is rebuilt.
  //
  // Only the paths are stored. The files themselves sit in the app's cache
  // directory, which survives both activity death and a reboot; anything that
  // did not survive is dropped on restore rather than resurrected as a
  // dangling reference.

  String get _draftKey =>
      'condition_draft_${widget.rentalId}_${widget.stage.key}';

  Future<void> _saveDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _draftKey,
        jsonEncode({
          'videos': _videos.map((f) => f.path).toList(),
          'images': _images.map((f) => f.path).toList(),
        }),
      );
    } catch (e) {
      developer.log('⚠️ Could not save capture draft: $e',
          name: 'ConditionCapture');
    }
  }

  Future<void> _clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_draftKey);
    } catch (_) {}
  }

  Future<void> _restoreDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      var found = false;
      for (final p in (m['videos'] as List? ?? const [])) {
        final f = File(p as String);
        if (await f.exists()) {
          _videos.add(f);
          found = true;
        }
      }
      for (final p in (m['images'] as List? ?? const [])) {
        final f = File(p as String);
        if (await f.exists()) {
          _images.add(f);
          found = true;
        }
      }
      if (found) _recovered = true;
    } catch (e) {
      developer.log('⚠️ Could not restore capture draft: $e',
          name: 'ConditionCapture');
    }
  }

  /// Collects a capture that was still in the camera when the activity died.
  ///
  /// image_picker parks that result rather than losing it, but ONLY hands it
  /// over when asked — which is why the photo being taken at the moment of the
  /// kill disappeared entirely.
  Future<void> _recoverLostCapture() async {
    if (!Platform.isAndroid) return;
    try {
      final lost = await _picker.retrieveLostData();
      if (lost.isEmpty || lost.file == null) return;
      // The parked result is a path, not a guarantee — the activity died and
      // the cache may have been reaped since. _restoreDraft already checks
      // this; without the same check here a dead path reached _compressVideo,
      // whose source.length() throws PathNotFoundException.
      final file = File(lost.file!.path);
      if (!await file.exists()) {
        developer.log('⚠️ Lost capture no longer on disk: ${file.path}',
            name: 'ConditionCapture');
        return;
      }
      if (lost.type == RetrieveType.video) {
        _videos.add(await _compressVideo(file));
      } else {
        _images.add(file);
      }
      _recovered = true;
    } catch (e) {
      developer.log('⚠️ Could not recover lost capture: $e',
          name: 'ConditionCapture');
    }
  }

  /// A sealed record cannot be replaced — rules refuse the write, and that is
  /// the entire point of the seal.
  ///
  /// Checked BEFORE the camera is offered. Without this, someone who has
  /// already recorded shoots a second full walkthrough, waits out the
  /// transcode and the upload, and is then told the upload failed — which is
  /// false, and which no amount of retrying can fix.
  Future<void> _loadExisting() async {
    ConditionRecord? r;
    try {
      r = await _service.myRecord(widget.rentalId, widget.stage);
    } catch (e) {
      // A courtesy check, not a gate. If the read fails, fall through to the
      // camera rather than trap them behind a spinner that never resolves —
      // the seal is enforced by rules regardless of what this screen believes.
      developer.log('⚠️ Could not check for an existing record: $e',
          name: 'ConditionCapture');
    }
    if (!mounted) return;
    setState(() {
      _sealed = r?.capturedAt != null ? r : null;
      _checking = false;
    });
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _recordVideo() async {
    final x = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 3),
    );
    if (x == null || !mounted) return;
    setState(() {
      _compressProgress = 0;
      _error = null;
    });
    // Transcode HERE rather than at submit: the wait happens while they are
    // still writing notes, instead of being tacked onto an upload that already
    // feels too long.
    final file = await _compressVideo(File(x.path));
    if (!mounted) return;
    setState(() => _videos.add(file));
    await _saveDraft();
  }

  /// Transcodes to 720p so a walkthrough is uploadable on mobile data.
  ///
  /// Phones record at roughly 9 Mbps, so three minutes lands near 200 MB —
  /// which over a Nigerian mobile connection is not a slow upload so much as
  /// one that never finishes. Mirrors the listing-video path in
  /// add_property_screen.
  ///
  /// A failed transcode returns the original untouched. Evidence that exists is
  /// worth more than evidence that is small, and this is the one recording the
  /// tenant cannot go back and make again.
  Future<File> _compressVideo(File source) async {
    final originalMb = await source.length() / (1024 * 1024);
    if (originalMb <= _maxVideoMb) return source;

    final sub = VideoCompress.compressProgress$.subscribe((progress) {
      if (mounted) setState(() => _compressProgress = progress / 100);
    });

    try {
      final info = await VideoCompress.compressVideo(
        source.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );
      final out = info?.file;
      if (out == null) return source;
      final outMb = await out.length() / (1024 * 1024);
      developer.log(
        '🎬 Condition video: ${originalMb.toStringAsFixed(0)}MB → '
        '${outMb.toStringAsFixed(0)}MB',
        name: 'ConditionCapture',
      );
      return outMb < originalMb ? out : source;
    } catch (e) {
      developer.log('❌ Condition video compression failed, using original: $e',
          name: 'ConditionCapture');
      return source;
    } finally {
      sub.unsubscribe();
      if (mounted) setState(() => _compressProgress = null);
    }
  }

  Future<void> _takePhoto() async {
    // Not compressed to death: this is evidence of small damage, and the
    // aggressive quality settings used for listing photos would smooth out
    // exactly the scuffs and cracks being argued about.
    final x = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (x == null || !mounted) return;
    setState(() {
      _images.add(File(x.path));
      _error = null;
    });
    await _saveDraft();
  }

  Future<void> _submit() async {
    // Drop anything the OS reaped since it was captured. Uploading a path that
    // no longer exists fails deep inside the upload with nothing the person
    // can act on; telling them a clip is gone while they are still standing in
    // the property means they can shoot it again.
    final goneVideos = <File>[];
    for (final f in _videos) {
      if (!await f.exists()) goneVideos.add(f);
    }
    final goneImages = <File>[];
    for (final f in _images) {
      if (!await f.exists()) goneImages.add(f);
    }
    if (goneVideos.isNotEmpty || goneImages.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _videos.removeWhere(goneVideos.contains);
        _images.removeWhere(goneImages.contains);
        _error = 'Your phone cleared some of what you captured. '
            'Please record it again before submitting.';
      });
      await _saveDraft();
      return;
    }

    if (_videos.isEmpty) {
      setState(() => _error = 'Record a walkthrough video first.');
      return;
    }
    setState(() {
      _submitting = true;
      _uploadProgress = null;
      _error = null;
    });

    final ok = await _service.submit(
      rentalId: widget.rentalId,
      stage: widget.stage,
      partyRole: widget.partyRole,
      videos: _videos,
      images: _images,
      notes: _notes.text.trim(),
      onProgress: (f) {
        if (mounted) setState(() => _uploadProgress = f);
      },
    );

    if (!mounted) return;
    if (ok == ConditionSubmitResult.success) {
      // The captures are on the server and the record is sealed, so the local
      // draft has nothing left to protect.
      await _clearDraft();
      if (!mounted) return;
      // Popping straight back to the dashboard read as nothing having
      // happened — the recording was sealed and the person had no way to
      // know it. Say so before leaving.
      await _confirmSubmitted();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }
    if (ok == ConditionSubmitResult.alreadySealed) {
      // Never a retry. Swap the whole screen over to the sealed state rather
      // than show an error above a button that cannot work.
      setState(() {
        _submitting = false;
        _uploadProgress = null;
        _error = null;
        _checking = true;
      });
      await _loadExisting();
      return;
    }
    setState(() {
      _submitting = false;
      _uploadProgress = null;
      // The record exists and is marked pending, so this is genuinely a retry
      // rather than starting again — say so, or people re-shoot everything.
      _error = 'Upload did not finish. Your recording is saved — try again '
          'when you have a better connection.';
    });
  }

  /// Tells them it worked, and what it now means.
  ///
  /// Worth a dialog rather than a snackbar: this is the one irreversible act
  /// in the flow, and a snackbar on the screen behind would be gone before
  /// they had read it.
  Future<void> _confirmSubmitted() {
    final isMoveOut = widget.stage == ConditionStage.moveOut;
    final isTenant = widget.partyRole == 'tenant';
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.check_circle_outline,
            color: AppColors.success, size: 36),
        title: const Text('Recorded'),
        content: Text(
          isMoveOut
              ? 'Your walkthrough is saved and sealed — nobody can change or '
                  'delete it now, including you. '
                  '${isTenant ? 'Your landlord' : 'Your tenant'} can see that '
                  'it exists, and any argument about the caution deposit has '
                  'to be made against it.'
              : 'Your baseline is saved and sealed. If something in this '
                  'property is already damaged, this is what proves it was '
                  'not you.',
          style: AppTextStyles.caption
              .copyWith(color: AppColors.textSecondary, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// What has been captured so far, each one removable.
  ///
  /// Submitting seals the record permanently, so a blurry photo or a clip
  /// taken by accident had to be fixable BEFORE that point — until now
  /// anything captured was in for good.
  Widget _captureChips(List<File> files, {required bool video}) {
    if (files.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(files.length, (i) {
          return Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (video)
                Icon(Icons.movie_outlined,
                    size: 16, color: AppColors.textSecondary)
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  // errorBuilder is not optional here. These are camera temp
                  // files, and Android can purge the cache between capture and
                  // render — FileImage then throws PathNotFoundException
                  // ("Cannot retrieve length of file"). Worse, the default
                  // ErrorWidget has no size constraint, so it replaced a 22px
                  // thumbnail and burst the chip's Row: the crash and the
                  // "overflowed by N pixels" underneath were the same fault.
                  child: Image.file(
                    files[i],
                    width: 22,
                    height: 22,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => SizedBox(
                      width: 22,
                      height: 22,
                      child: Icon(Icons.broken_image_outlined,
                          size: 14, color: AppColors.textHint),
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              Text('${video ? 'Video' : 'Photo'} ${i + 1}',
                  style: AppTextStyles.caption),
              IconButton(
                icon: const Icon(Icons.close, size: 14),
                color: AppColors.textSecondary,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.only(left: 6, right: 4),
                tooltip: 'Remove',
                onPressed: () async {
                  setState(() => files.removeAt(i));
                  await _saveDraft();
                },
              ),
            ]),
          );
        }),
      ),
    );
  }

  /// Shown instead of the camera when this party has already recorded.
  ///
  /// Offers the recording rather than just refusing: someone who comes back
  /// here usually wants to know what they captured, and until now the only
  /// answer they got was a failed upload.
  Widget _buildSealed(ConditionRecord r) {
    final at = r.capturedAt;
    final when = at == null
        ? null
        : '${at.day} '
            '${const [
              'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
              'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
            ][at.month - 1]} '
            '${at.year}';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(widget.propertyTitle, style: AppTextStyles.labelLarge),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.success.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.success.withAlpha(77)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.check_circle_outline,
                  size: 20, color: AppColors.success),
              const SizedBox(width: 10),
              Expanded(
                child: Text('You have already recorded this',
                    style: AppTextStyles.labelLarge),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              '${when == null ? 'Your recording' : 'Recorded on $when'} — '
              '${r.videoPaths.length} video, ${r.imagePaths.length} photo. '
              'It is sealed, so it cannot be changed or replaced by anyone, '
              'including you. That is exactly what makes it worth something '
              'if the deposit is argued over.',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary, height: 1.4),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        if (r.isEvidence)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConditionViewerScreen(
                    rentalId: widget.rentalId,
                    record: r,
                  ),
                ),
              ),
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('View what you recorded'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMoveOut = widget.stage == ConditionStage.moveOut;
    if (_checking) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(widget.stage.label)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final sealed = _sealed;
    if (sealed != null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(widget.stage.label)),
        body: _buildSealed(sealed),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(widget.stage.label)),
      body: AbsorbPointer(
        // Transcoding is as blocking as uploading — a second recording started
        // mid-transcode would fight the first for the encoder.
        absorbing: _submitting || _compressProgress != null,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(widget.propertyTitle, style: AppTextStyles.labelLarge),
            const SizedBox(height: 6),
            Text(
              isMoveOut
                  ? 'Record the state you are leaving it in. This is what a '
                      'deduction from your caution deposit has to be argued '
                      'against — without it there is nothing on your side.'
                  : 'Record the state you are taking it on. If something is '
                      'already damaged, this is what proves it was not you.',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),

            // Say it out loud. Coming back to find the work apparently intact
            // is exactly the moment someone doubts whether it really is.
            if (_recovered) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.restore, size: 16, color: AppColors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your phone closed this screen while the camera was '
                      'open. What you had already captured has been brought '
                      'back — carry on where you left off.',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            _CaptureTile(
              icon: Icons.videocam_outlined,
              title: 'Walkthrough video',
              subtitle: _compressProgress != null
                  ? 'Optimising for upload — '
                      '${(_compressProgress! * 100).round()}%'
                  // Multiple recordings were always allowed — a small "+" icon
                  // was the only thing saying so, which read as a limit of one.
                  // A one-room walkthrough is rarely one clip.
                  : _videos.isEmpty
                      ? 'Required · up to 3 minutes each'
                      : '${_videos.length} recorded · tap to add another',
              done: _videos.isNotEmpty,
              onTap: _recordVideo,
            ),
            _captureChips(_videos, video: true),
            if (_compressProgress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _compressProgress,
                  minHeight: 4,
                  backgroundColor: AppColors.border,
                ),
              ),
            ],
            const SizedBox(height: 10),
            _CaptureTile(
              icon: Icons.photo_camera_outlined,
              title: 'Close-up photos',
              subtitle: _images.isEmpty
                  ? 'Optional · as many as you need'
                  : '${_images.length} taken · tap to add another',
              done: _images.isNotEmpty,
              onTap: _takePhoto,
            ),
            _captureChips(_images, video: false),

            const SizedBox(height: 20),
            TextField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'Anything the camera does not show',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),

            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(Icons.lock_outline, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Once submitted this cannot be changed or deleted — by '
                    'you or by the other party. That is what makes it worth '
                    'anything.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ]),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: AppTextStyles.caption.copyWith(color: AppColors.error)),
            ],

            // A bare spinner made a working upload look identical to a frozen
            // one, which on a slow connection is the difference between
            // waiting and force-closing the app mid-transfer.
            if (_submitting) ...[
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _uploadProgress,
                  minHeight: 6,
                  backgroundColor: AppColors.border,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _uploadProgress == null
                    ? 'Starting upload…'
                    : 'Uploading — ${(_uploadProgress! * 100).round()}%. Keep '
                        'this screen open; a walkthrough takes a few minutes '
                        'on mobile data.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting || _compressProgress != null
                    ? null
                    : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Submit recording'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool done;
  final VoidCallback onTap;

  const _CaptureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: done ? AppColors.success : AppColors.border,
          ),
        ),
        child: Row(children: [
          Icon(icon,
              size: 22,
              color: done ? AppColors.success : AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelMedium),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          Icon(done ? Icons.add_circle_outline : Icons.chevron_right,
              size: 20, color: AppColors.textSecondary),
        ]),
      ),
    );
  }
}
