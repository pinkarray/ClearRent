import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../services/auth_service.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../../../../shared/widgets/user_avatar.dart';
import '../../../../services/property_service.dart';

class ProfileSetupScreen extends StatefulWidget {
  final String accountType;

  const ProfileSetupScreen({super.key, required this.accountType});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _bvnController = TextEditingController();
  final _phoneController = TextEditingController();
  final _customAreaController = TextEditingController();

  late final AuthService _authService;
  bool _isLoading = false;
  bool _showBvnInfo = false;
  String? _errorMessage;
  String? _userEmail;

  // Agent-specific fields
  String? _selectedBaseLocation;
  final List<String> _selectedServiceAreas = [];
  bool _showCustomAreaInput = false;

  File? _profileImageFile;
  final PropertyService _profileUploadService = PropertyService();

  // Real Lagos neighbourhoods and areas — accurate for on-the-ground agents
  static const List<String> _lagosAreas = [
    // Island / High-end
    'Victoria Island',
    'Ikoyi',
    'Lekki Phase 1',
    'Lekki Phase 2',
    'Lekki',
    'Ajah',
    'Sangotedo',
    'Chevron',
    'Ilasan',
    'Oniru',
    'Obalende',
    'Marina',
    'Lagos Island',
    'Ibeju-Lekki',
    'Epe',
    // Mainland — Central
    'Ikeja',
    'GRA Ikeja',
    'Alausa',
    'Oregun',
    'Omole',
    'Ojodu',
    'Ogba',
    'Berger',
    'Isheri',
    'Maryland',
    'Anthony',
    'Palmgrove',
    'Gbagada',
    'Ogudu',
    // Mainland — South
    'Yaba',
    'Surulere',
    'Bariga',
    'Shomolu',
    'Fadeyi',
    'Mushin',
    'Isolo',
    'Ikotun',
    'Egbeda',
    'Alimosho',
    'Oshodi',
    'Mafoluku',
    'Festac',
    'Amuwo-Odofin',
    'Apapa',
    'Ajegunle',
    // Mainland — North / Outer
    'Ketu',
    'Mile 12',
    'Ojota',
    'Agege',
    'Magodo',
    'Ifako-Ijaiye',
    'Ikorodu',
    'Badagry',
    'Ojo',
    // Other
    'Other',
  ];

  bool get _isLandlord => widget.accountType == 'landlord';
  bool get _isAgent => widget.accountType == 'agent';

  // All selectable areas (excluding 'Other')
  List<String> get _selectableAreas =>
      _lagosAreas.where((a) => a != 'Other').toList();

  bool get _allSelected =>
      _selectableAreas.every((a) => _selectedServiceAreas.contains(a));

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selectedServiceAreas.clear();
      } else {
        _selectedServiceAreas.clear();
        _selectedServiceAreas.addAll(_selectableAreas);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _loadUserEmail();
  }

  void _loadUserEmail() {
    final user = _authService.currentUser;
    if (user != null) {
      setState(() {
        _userEmail = user.email;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bvnController.dispose();
    _phoneController.dispose();
    _customAreaController.dispose();
    super.dispose();
  }

  String? _validateName(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your full name';
    }
    if (value.split(' ').length < 2) {
      return 'Please enter your first and last name';
    }
    return null;
  }

  String? _validateBvn(String? value) {
    if (value == null || value.isEmpty) {
      return AppStrings.errorInvalidBvn;
    }
    if (value.length != 11) {
      return AppStrings.errorInvalidBvn;
    }
    return null;
  }

  String? _validatePhone(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your phone number';
    }
    if (value.length < 10 || value.length > 11) {
      return 'Please enter a valid phone number';
    }
    return null;
  }

  void _toggleServiceArea(String area) {
    setState(() {
      if (area == 'Other') {
        _showCustomAreaInput = !_showCustomAreaInput;
        if (!_showCustomAreaInput) {
          _customAreaController.clear();
        }
      } else {
        if (_selectedServiceAreas.contains(area)) {
          _selectedServiceAreas.remove(area);
        } else {
          _selectedServiceAreas.add(area);
        }
      }
    });
  }

  void _addCustomArea() {
    final customArea = _customAreaController.text.trim();
    if (customArea.isNotEmpty && !_selectedServiceAreas.contains(customArea)) {
      setState(() {
        _selectedServiceAreas.add(customArea);
        _customAreaController.clear();
      });
    }
  }

  Future<void> _pickProfileImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text('Profile Photo', style: AppTextStyles.h4),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildImageSourceOption(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    onTap: () => Navigator.pop(ctx, ImageSource.camera),
                  ),
                  _buildImageSourceOption(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                  ),
                  if (_profileImageFile != null)
                    _buildImageSourceOption(
                      icon: Icons.delete_outline,
                      label: 'Remove',
                      onTap: () {
                        Navigator.pop(ctx, null);
                        setState(() => _profileImageFile = null);
                      },
                      color: AppColors.error,
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );

    if (source == null) return;

    try {
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;
      setState(() => _profileImageFile = File(image.path));
    } catch (e) {
      debugPrint('❌ Error picking profile image: $e');
    }
  }

  Widget _buildImageSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: (color ?? AppColors.primary).withAlpha(26),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color ?? AppColors.primary, size: 32),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: AppTextStyles.labelMedium.copyWith(
              color: color ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // Agent-specific validation
    if (_isAgent) {
      if (_selectedBaseLocation == null) {
        setState(() {
          _errorMessage = 'Please select your base location';
        });
        return;
      }
      if (_selectedServiceAreas.isEmpty) {
        setState(() {
          _errorMessage = 'Please select at least one service area';
        });
        return;
      }
    }

    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await _authService.saveUserProfile(
        fullName: _nameController.text.trim(),
        email: _authService.currentUser?.email ?? '',
        accountType: widget.accountType,
        bvn: _bvnController.text.trim(),
        phone: _phoneController.text.trim(),
        // Agent-specific fields
        baseLocation: _isAgent ? _selectedBaseLocation : null,
        serviceAreas: _isAgent ? _selectedServiceAreas : null,
      );

      if (!success) {
        setState(() {
          _errorMessage = 'Failed to save profile. Please try again.';
          _isLoading = false;
        });
        return;
      }

      if (_profileImageFile != null) {
        try {
          final imageUrl =
              await _profileUploadService.uploadImage(_profileImageFile!);
          if (imageUrl != null && imageUrl.isNotEmpty) {
            await _authService.updateUserProfile({
              'profileImageUrl': imageUrl,
            });
          }
        } catch (e) {
          debugPrint('⚠️ Profile image upload failed (non-blocking): $e');
        }
      }
    } catch (e) {
      debugPrint('❌ Profile save error: $e');
      setState(() {
        _errorMessage = 'An error occurred. Please try again.';
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = false);

    if (!mounted) return;

    // Profile saved — navigate to home based on account type
    final accountType = widget.accountType.toLowerCase();
    switch (accountType) {
      case 'landlord':
        context.go('/landlord/home');
        break;
      case 'agent':
        context.go('/agent/home');
        break;
      default:
        context.go('/tenant/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/account-type'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(AppStrings.setupProfile, style: AppTextStyles.h2),
                const SizedBox(height: 8),
                Text(
                  _getSubtitle(),
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),

                const SizedBox(height: 32),

                // Profile picture
                Center(
                  child: UserAvatar(
                    name: _nameController.text.isNotEmpty
                        ? _nameController.text
                        : null,
                    imageFile: _profileImageFile,
                    size: 100,
                    showEditBadge: true,
                    onTap: _pickProfileImage,
                  ),
                ),
                const SizedBox(height: 24),

                // Show email (read-only)
                if (_userEmail != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.email_outlined,
                          color: AppColors.textSecondary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Email',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _userEmail!,
                                style: AppTextStyles.bodyMedium.copyWith(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.check_circle,
                          color: AppColors.success,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Error message
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.error.withAlpha(26),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.error.withAlpha(77)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: AppColors.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Full name
                AppTextField(
                  label: AppStrings.fullName,
                  hint: 'John Doe',
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  validator: _validateName,
                ),

                const SizedBox(height: 20),

                // Phone number — all roles
                AppTextField(
                  label: 'Phone Number',
                  hint: '08012345678',
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  validator: _validatePhone,
                  prefixIcon: Icon(
                    Icons.phone_outlined,
                    color: AppColors.textSecondary,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _isAgent
                      ? 'Landlords and tenants will use this number to contact you'
                      : _isLandlord
                          ? 'Tenants will use this number to contact you'
                          : 'You\'ll verify this number with a one-time code',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),

                // Agent-specific: Base Location + Service Areas
                if (_isAgent) ...[
                  _buildBaseLocationSelector(),
                  const SizedBox(height: 20),
                  _buildServiceAreasSelector(),
                  const SizedBox(height: 20),
                ],

                // BVN/NIN
                AppTextField(
                  label: (_isLandlord || _isAgent)
                      ? 'NIN (National Identification Number)'
                      : AppStrings.bvn,
                  hint: AppStrings.bvnHint,
                  controller: _bvnController,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  validator: _validateBvn,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                  onSubmitted: (_) => _submit(),
                ),

                const SizedBox(height: 8),

                // Why BVN/NIN?
                GestureDetector(
                  onTap: () => setState(() => _showBvnInfo = !_showBvnInfo),
                  child: Row(
                    children: [
                      Icon(
                        _showBvnInfo
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        (_isLandlord || _isAgent)
                            ? 'Why do we need your NIN?'
                            : AppStrings.whyBvn,
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),

                // BVN/NIN explanation
                if (_showBvnInfo) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.infoLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 20,
                          color: AppColors.info,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _getNinExplanation(),
                            style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.info,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 40),

                // Submit button
                AppButton(
                  text: AppStrings.continueText,
                  onPressed: _submit,
                  isLoading: _isLoading,
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getSubtitle() {
    if (_isLandlord) {
      return 'Tell us about yourself so tenants can reach you';
    } else if (_isAgent) {
      return 'Tell us about yourself and where you operate';
    } else {
      return 'Tell us a bit about yourself';
    }
  }

  String _getNinExplanation() {
    if (_isAgent) {
      return 'Your NIN helps us verify your identity and build trust with landlords and tenants. Verified agents get a badge and more assignment opportunities.';
    } else if (_isLandlord) {
      return 'Your NIN helps us verify your identity and build trust with tenants. This information is securely stored and only used for verification purposes.';
    } else {
      return AppStrings.bvnExplanation;
    }
  }

  Widget _buildBaseLocationSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Base Location',
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Where are you based? This helps us calculate inspection distances.',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedBaseLocation,
              hint: Text(
                'Select your area',
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              isExpanded: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                color: AppColors.textSecondary,
              ),
              items: _selectableAreas.map((area) {
                return DropdownMenuItem(
                  value: area,
                  child: Text(area, style: AppTextStyles.bodyMedium),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedBaseLocation = value;
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildServiceAreasSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Service Areas',
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Which areas can you cover for inspections? Select all that apply.',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),

        // Selected areas chips
        if (_selectedServiceAreas.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _selectedServiceAreas.map((area) {
              return Chip(
                label: Text(
                  area,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.primary,
                  ),
                ),
                backgroundColor: AppColors.primary.withAlpha(26),
                deleteIcon: const Icon(Icons.close, size: 18),
                deleteIconColor: AppColors.primary,
                onDeleted: () => _toggleServiceArea(area),
                side: BorderSide.none,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
        ],

        // Area selection grid
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row with count + Select All / Clear All
              Row(
                children: [
                  Text(
                    'Tap to select areas:',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _toggleSelectAll,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _allSelected
                            ? AppColors.error.withAlpha(26)
                            : AppColors.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _allSelected
                              ? AppColors.error.withAlpha(77)
                              : AppColors.primary.withAlpha(77),
                        ),
                      ),
                      child: Text(
                        _allSelected ? 'Clear All' : 'Select All',
                        style: AppTextStyles.labelSmall.copyWith(
                          color: _allSelected
                              ? AppColors.error
                              : AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Area chips
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _lagosAreas.map((area) {
                  final isSelected = _selectedServiceAreas.contains(area) ||
                      (area == 'Other' && _showCustomAreaInput);
                  return GestureDetector(
                    onTap: () => _toggleServiceArea(area),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.background,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        area,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: isSelected
                              ? Colors.white
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),

        // Custom area input
        if (_showCustomAreaInput) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  label: 'Other Area',
                  hint: 'Enter area name',
                  controller: _customAreaController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addCustomArea(),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: IconButton(
                  onPressed: _addCustomArea,
                  icon: Icon(
                    Icons.add_circle,
                    color: AppColors.primary,
                    size: 32,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}