import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Picks a tenancy agreement — a PDF, or a photo of one.
///
/// Agreements were picked with `ImagePicker.pickImage`, which takes exactly ONE
/// gallery photo and cannot select a PDF at all. A real tenancy agreement runs
/// to several pages, so the flow was unusable for anything but a one-pager.
/// Web already accepted `application/pdf`; this brings the app in line.
///
/// Deliberately does NOT re-compress: the image paths used `imageQuality: 85`,
/// which is fine for a property photo and wrong for a page of text.
class AgreementFilePicker {
  /// Returns the chosen file, or null if the user backed out.
  ///
  /// Offers the camera as well, because photographing a freshly signed page is
  /// the common case for a tenant who has just signed in front of you.
  static Future<File?> pick(BuildContext context) async {
    final source = await showModalBottomSheet<_Source>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'A multi-page agreement should be a single PDF.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading:
                  Icon(Icons.picture_as_pdf_outlined, color: AppColors.primary),
              title: Text('Choose a PDF', style: AppTextStyles.bodyMedium),
              subtitle: Text('Any number of pages',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
              onTap: () => Navigator.pop(ctx, _Source.pdf),
            ),
            ListTile(
              leading: Icon(Icons.image_outlined, color: AppColors.primary),
              title: Text('Choose an image', style: AppTextStyles.bodyMedium),
              subtitle: Text('For a single page',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
              onTap: () => Navigator.pop(ctx, _Source.image),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source == null) return null;

    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: source == _Source.pdf
          ? ['pdf']
          : ['jpg', 'jpeg', 'png', 'heic', 'webp'],
    );

    final path = picked?.path;
    if (path == null) return null;
    return File(path);
  }
}

enum _Source { pdf, image }
