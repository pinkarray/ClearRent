import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/constants/colors.dart';
import '../../services/issue_photo_service.dart';

/// One issue photo, whichever way it is stored: a legacy public URL, a
/// private path on a saved issue (signed link), or the reporter's own path
/// while drafting ([issueId] null, read directly).
class IssuePhotoImage extends StatelessWidget {
  final String photo;
  final String? issueId;
  final double? width;
  final double? height;
  final BoxFit fit;

  const IssuePhotoImage({
    super.key,
    required this.photo,
    this.issueId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  Widget _placeholder({bool broken = false}) => Container(
        width: width,
        height: height,
        color: AppColors.border,
        alignment: Alignment.center,
        child: broken
            ? const Icon(Icons.broken_image)
            : const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      );

  Widget _network(String url, {String? cacheKey}) => CachedNetworkImage(
        imageUrl: url,
        // A signed link changes every 15 minutes; key the disk cache on the
        // path so the same photo is not downloaded again each time.
        cacheKey: cacheKey,
        width: width,
        height: height,
        fit: fit,
        placeholder: (_, _) => _placeholder(),
        errorWidget: (_, _, _) => _placeholder(broken: true),
      );

  @override
  Widget build(BuildContext context) {
    if (IssuePhotoService.isLegacyUrl(photo)) return _network(photo);
    final service = IssuePhotoService.instance;
    if (issueId == null) {
      return FutureBuilder<Uint8List?>(
        future: service.ownBytes(photo),
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) return _placeholder();
          final bytes = snap.data;
          if (bytes == null) return _placeholder(broken: true);
          return Image.memory(bytes, width: width, height: height, fit: fit);
        },
      );
    }
    return FutureBuilder<String?>(
      future: service.signedUrl(issueId!, photo),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) return _placeholder();
        final url = snap.data;
        if (url == null) return _placeholder(broken: true);
        return _network(url, cacheKey: photo);
      },
    );
  }
}
