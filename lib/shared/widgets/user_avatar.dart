import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Reusable avatar widget that shows profile image or initials fallback.
/// Use everywhere a user's avatar is displayed for consistent look.
///
/// Usage:
/// ```dart
/// UserAvatar(name: 'Mide Oredugba', imageUrl: user.profileImageUrl, size: 48)
/// UserAvatar(name: 'Mide', size: 90, onTap: () => _pickImage(), showEditBadge: true)
/// UserAvatar.fromInitial(initial: 'M', size: 48, backgroundColor: AppColors.primary)
/// ```
class UserAvatar extends StatelessWidget {
  final String? name;
  final String? imageUrl;
  final File? imageFile; // For showing locally picked file before upload
  final double size;
  final Color? backgroundColor;
  final Color? textColor;
  final VoidCallback? onTap;
  final bool showEditBadge;
  final double? fontSize;
  final Border? border;

  const UserAvatar({
    super.key,
    this.name,
    this.imageUrl,
    this.imageFile,
    this.size = 48,
    this.backgroundColor,
    this.textColor,
    this.onTap,
    this.showEditBadge = false,
    this.fontSize,
    this.border,
  });

  /// Quick constructor when you only have an initial letter
  const UserAvatar.fromInitial({
    super.key,
    required String initial,
    this.size = 48,
    this.backgroundColor,
    this.textColor,
    this.onTap,
    this.fontSize,
    this.border,
  })  : name = initial,
        imageUrl = null,
        imageFile = null,
        showEditBadge = false;

  String get _initial {
    if (name == null || name!.isEmpty) return '?';
    return name![0].toUpperCase();
  }

  Color get _bgColor {
    if (backgroundColor != null) return backgroundColor!;
    // Generate consistent color from name
    final colors = [
      AppColors.primary,
      AppColors.info,
      AppColors.success,
      AppColors.warning,
      const Color(0xFF9C27B0), // purple
      const Color(0xFFE91E63), // pink
      const Color(0xFF00BCD4), // cyan
      const Color(0xFFFF5722), // deep orange
    ];
    if (name == null || name!.isEmpty) return colors[0];
    final index = name!.codeUnitAt(0) % colors.length;
    return colors[index];
  }

  bool get _hasImage =>
      imageFile != null ||
      (imageUrl != null && imageUrl!.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: _hasImage ? AppColors.border : _bgColor.withAlpha(51),
              shape: BoxShape.circle,
              border: border ?? Border.all(
                color: _hasImage ? AppColors.border : _bgColor.withAlpha(77),
                width: size > 60 ? 2.5 : 1.5,
              ),
            ),
            child: ClipOval(
              child: _buildContent(),
            ),
          ),

          // Edit badge
          if (showEditBadge)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: size * 0.32,
                height: size * 0.32,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(26),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.camera_alt,
                  size: size * 0.16,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // Priority: local file > network image > initials
    if (imageFile != null) {
      return Image.file(
        imageFile!,
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => _buildInitials(),
        errorWidget: (_, __, ___) => _buildInitials(),
      );
    }

    return _buildInitials();
  }

  Widget _buildInitials() {
    final effectiveFontSize = fontSize ?? (size * 0.38);
    return Container(
      width: size,
      height: size,
      color: _bgColor.withAlpha(51),
      child: Center(
        child: Text(
          _initial,
          style: TextStyle(
            fontSize: effectiveFontSize,
            fontWeight: FontWeight.w600,
            color: textColor ?? _bgColor,
          ),
        ),
      ),
    );
  }
}

/// Avatar specifically styled for the profile header (gradient background).
/// Shows white text/border on transparent background to work over gradients.
class UserAvatarProfile extends StatelessWidget {
  final String? name;
  final String? imageUrl;
  final File? imageFile;
  final double size;
  final VoidCallback? onTap;
  final bool showEditBadge;
  final bool isLoading;

  const UserAvatarProfile({
    super.key,
    this.name,
    this.imageUrl,
    this.imageFile,
    this.size = 90,
    this.onTap,
    this.showEditBadge = true,
    this.isLoading = false,
  });

  String get _initial {
    if (name == null || name!.isEmpty) return '?';
    return name![0].toUpperCase();
  }

  bool get _hasImage =>
      imageFile != null ||
      (imageUrl != null && imageUrl!.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: _hasImage ? Colors.white : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(26),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipOval(
              child: isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    )
                  : _buildContent(),
            ),
          ),

          if (showEditBadge && !isLoading)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: size * 0.32,
                height: size * 0.32,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(26),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.camera_alt,
                  size: size * 0.16,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (imageFile != null) {
      return Image.file(imageFile!, width: size, height: size, fit: BoxFit.cover);
    }

    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => _buildInitials(),
        errorWidget: (_, __, ___) => _buildInitials(),
      );
    }

    return _buildInitials();
  }

  Widget _buildInitials() {
    return Container(
      width: size,
      height: size,
      color: Colors.white,
      child: Center(
        child: Text(
          _initial,
          style: AppTextStyles.h2.copyWith(color: AppColors.primary),
        ),
      ),
    );
  }
}