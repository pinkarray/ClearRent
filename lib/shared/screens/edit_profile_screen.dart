import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/auth_service.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final AuthService _authService = AuthService();
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();

  bool _isLoading = true;
  bool _isSavingPhone = false;
  bool _isUploadingPhoto = false;

  String _fullName = '';
  String _email = '';
  String _phone = '';
  String? _photoUrl;
  bool _isVerified = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();

    // Listen for phone field losing focus to auto-save
    _phoneFocusNode.addListener(() {
      if (!_phoneFocusNode.hasFocus) {
        _savePhoneIfChanged();
      }
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await _authService.getUserProfile();

      if (!mounted) return;

      if (profile != null) {
        final storedEmail = profile['email'] as String?;
        setState(() {
          _fullName = profile['fullName'] ?? '';
          _email =
              (storedEmail != null && storedEmail.isNotEmpty)
                  ? storedEmail
                  : FirebaseAuth.instance.currentUser?.email ?? '';
          _phone = profile['phone'] ?? '';
          _photoUrl = profile['photoUrl'];
          _isVerified = profile['verificationStatus'] == 'verified';
          _phoneController.text = _phone;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      developer.log(
        '❌ Error loading profile: $e',
        name: 'EditProfileScreen',
        error: e,
        stackTrace: StackTrace.current,
      );
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _savePhoneIfChanged() async {
    final newPhone = _phoneController.text.trim();
    if (newPhone == _phone || newPhone.isEmpty) return;

    setState(() => _isSavingPhone = true);

    final success = await _authService.updateUserProfile({'phone': newPhone});

    if (!mounted) return;

    setState(() => _isSavingPhone = false);

    if (success) {
      setState(() => _phone = newPhone);
      _showSuccess('Phone number updated');
    } else {
      _phoneController.text = _phone;
      _showError('Failed to update phone number');
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    if (!_isVerified) {
      _showError('Get verified to change your profile photo');
      return;
    }

    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );

    if (image == null) return;

    setState(() => _isUploadingPhoto = true);

    try {
      final cloudinary = CloudinaryPublic(
        'den5t1dai',
        'clearrent_uploads',
        cache: false,
      );
      final userId = FirebaseAuth.instance.currentUser?.uid;

      final response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          image.path,
          folder: 'clearrent/profiles/$userId',
          resourceType: CloudinaryResourceType.Image,
        ),
      );

      final photoUrl = response.secureUrl;

      final success = await _authService.updateUserProfile({
        'photoUrl': photoUrl,
      });

      if (!mounted) return;

      if (success) {
        setState(() {
          _photoUrl = photoUrl;
          _isUploadingPhoto = false;
        });
        _showSuccess('Profile photo updated');
      } else {
        setState(() => _isUploadingPhoto = false);
        _showError('Failed to save photo');
      }
    } catch (e) {
      developer.log(
        '❌ Photo upload error: $e',
        name: 'EditProfileScreen',
        error: e,
        stackTrace: StackTrace.current,
      );
      if (mounted) {
        setState(() => _isUploadingPhoto = false);
        _showError('Failed to upload photo');
      }
    }
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Edit Profile', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body:
          _isLoading
              ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
              : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // Profile photo section
                    _buildPhotoSection(),

                    const SizedBox(height: 32),

                    // Form fields
                    _buildFormSection(),

                    const SizedBox(height: 24),

                    // Info note
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.info.withAlpha(77)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppColors.info,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Your name and email are linked to your account verification and cannot be changed directly. Contact support if you need to update them.',
                              style: AppTextStyles.bodySmall.copyWith(
                                color: AppColors.info,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _buildPhotoSection() {
    return Column(
      children: [
        // Photo with edit button
        Stack(
          children: [
            GestureDetector(
              onTap: _isVerified ? _pickAndUploadPhoto : null,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryLight.withAlpha(26),
                  border: Border.all(
                    color: _isVerified ? AppColors.primary : AppColors.border,
                    width: 3,
                  ),
                  image:
                      _photoUrl != null
                          ? DecorationImage(
                            image: NetworkImage(_photoUrl!),
                            fit: BoxFit.cover,
                          )
                          : null,
                ),
                child:
                    _isUploadingPhoto
                        ? const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                            strokeWidth: 2,
                          ),
                        )
                        : _photoUrl == null
                        ? Center(
                          child: Text(
                            _fullName.isNotEmpty
                                ? _fullName[0].toUpperCase()
                                : '?',
                            style: AppTextStyles.h1.copyWith(
                              color: AppColors.primary,
                            ),
                          ),
                        )
                        : null,
              ),
            ),

            // Edit badge
            if (_isVerified)
              Positioned(
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  onTap: _pickAndUploadPhoto,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ),
          ],
        ),

        const SizedBox(height: 12),

        // Verification status
        if (!_isVerified)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(26),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline, size: 14, color: AppColors.warning),
                const SizedBox(width: 6),
                Text(
                  'Get verified to change your photo',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFormSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Full Name (read-only)
        _buildReadOnlyField(
          label: 'Full Name',
          value: _fullName,
          icon: Icons.person_outline,
        ),

        const SizedBox(height: 20),

        // Email (read-only)
        _buildReadOnlyField(
          label: 'Email',
          value: _email,
          icon: Icons.email_outlined,
        ),

        const SizedBox(height: 20),

        // Phone (editable)
        Text(
          'Phone Number',
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _phoneController,
          focusNode: _phoneFocusNode,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
            LengthLimitingTextInputFormatter(15),
          ],
          onSubmitted: (_) => _savePhoneIfChanged(),
          decoration: InputDecoration(
            hintText: 'Enter your phone number',
            hintStyle: TextStyle(color: AppColors.textHint),
            prefixIcon: Icon(Icons.phone_outlined, color: AppColors.textHint),
            suffixIcon:
                _isSavingPhone
                    ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      ),
                    )
                    : null,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Changes are saved automatically',
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textHint,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _buildReadOnlyField({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.textHint, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  value.isNotEmpty ? value : 'Not set',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color:
                        value.isNotEmpty
                            ? AppColors.textPrimary
                            : AppColors.textHint,
                  ),
                ),
              ),
              Icon(Icons.lock_outline, color: AppColors.textHint, size: 16),
            ],
          ),
        ),
      ],
    );
  }
}
