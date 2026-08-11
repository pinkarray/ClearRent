import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Picks a document — a PDF, or a photo of one.
///
/// Every document flow here was built on `ImagePicker.pickImage`, which takes
/// exactly ONE gallery photo and cannot select a PDF at all. Tenancy agreements
/// were fixed first; ownership documents had the same problem and the same
/// cause. A certificate of occupancy or a deed of assignment runs to several
/// pages, so a one-image picker made it impossible to submit the real document
/// — a landlord could only photograph the first page and hope.
///
/// Deliberately does NOT re-compress: the image paths used `imageQuality: 85`
/// or `90`, which is fine for a property photo and wrong for a page of text
/// that somebody has to read a plot number off.
class DocumentFilePicker {
  /// Returns the chosen file, or null if the user backed out.
  ///
  /// Offers the camera as well, because photographing a document you are
  /// holding is the common case.
  static Future<File?> pick(
    BuildContext context, {
    String hint = 'A multi-page document should be a single PDF.',
  }) async {
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
                hint,
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
