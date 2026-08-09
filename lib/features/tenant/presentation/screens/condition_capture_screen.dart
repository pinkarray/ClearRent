import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/condition_service.dart';
import '../../../../shared/models/condition_record.dart';

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

  final List<File> _videos = [];
  final List<File> _images = [];
  bool _submitting = false;
  String? _error;

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
      _videos.add(File(x.path));
      _error = null;
    });
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
  }

  Future<void> _submit() async {
    if (_videos.isEmpty) {
      setState(() => _error = 'Record a walkthrough video first.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    final ok = await _service.submit(
      rentalId: widget.rentalId,
      stage: widget.stage,
      partyRole: widget.partyRole,
      videos: _videos,
      images: _images,
      notes: _notes.text.trim(),
    );

    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      // The record exists and is marked pending, so this is genuinely a retry
      // rather than starting again — say so, or people re-shoot everything.
      _error = 'Upload did not finish. Your recording is saved — try again '
          'when you have a better connection.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMoveOut = widget.stage == ConditionStage.moveOut;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(widget.stage.label)),
      body: AbsorbPointer(
        absorbing: _submitting,
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

            _CaptureTile(
              icon: Icons.videocam_outlined,
              title: 'Walkthrough video',
              subtitle: _videos.isEmpty
                  ? 'Required · up to 3 minutes'
                  : '${_videos.length} recorded',
              done: _videos.isNotEmpty,
              onTap: _recordVideo,
            ),
            const SizedBox(height: 10),
            _CaptureTile(
              icon: Icons.photo_camera_outlined,
              title: 'Close-up photos',
              subtitle: _images.isEmpty
                  ? 'Optional · anything worth a closer look'
                  : '${_images.length} taken',
              done: _images.isNotEmpty,
              onTap: _takePhoto,
            ),

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

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
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
