import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../services/auth_service.dart';

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

  // Lagos LGAs for location selection
  static const List<String> _lagosAreas = [
    'Agege',
    'Ajeromi-Ifelodun',
    'Alimosho',
    'Amuwo-Odofin',
    'Apapa',
    'Badagry',
    'Epe',
    'Eti-Osa',
    'Ibeju-Lekki',
    'Ifako-Ijaiye',
    'Ikeja',
    'Ikorodu',
    'Kosofe',
    'Lagos Island',
    'Lagos Mainland',
    'Mushin',
    'Ojo',
    'Oshodi-Isolo',
    'Shomolu',
    'Surulere',
    'Lekki',
    'Victoria Island',
    'Yaba',
    'Ajah',
    'Ikoyi',
    'Other',
  ];

  bool get _isLandlord => widget.accountType == 'landlord';
  bool get _isAgent => widget.accountType == 'agent';

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
        phone: (_isLandlord || _isAgent) ? _phoneController.text.trim() : null,
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
    } catch (e) {
      debugPrint('❌ Profile save error: $e');
      setState(() {
        _errorMessage = 'An error occurred. Please try again.';
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = false);

    if (mounted) {
      if (widget.accountType == 'landlord') {
        context.go('/landlord/home');
      } else if (widget.accountType == 'agent') {
        context.go('/agent/home');
      } else {
        context.go('/tenant/home');
      }
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
                Text(
                  AppStrings.setupProfile,
                  style: AppTextStyles.h2,
                ),
                const SizedBox(height: 8),
                Text(
                  _getSubtitle(),
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),

                const SizedBox(height: 32),

                // Profile picture placeholder
                Center(
                  child: Stack(
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight.withAlpha(51),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isAgent ? Icons.support_agent : Icons.person,
                          size: 50,
                          color: AppColors.primary,
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
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
                        Icon(Icons.error_outline, color: AppColors.error, size: 20),
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

                // Phone number (for landlords and agents)
                if (_isLandlord || _isAgent) ...[
                  AppTextField(
                    label: 'Phone Number',
                    hint: '08012345678',
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    validator: _validatePhone,
                    prefixIcon: const Icon(Icons.phone_outlined, color: AppColors.textSecondary),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(11),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isAgent
                        ? 'Landlords and tenants will use this number to contact you'
                        : 'Tenants will use this number to contact you',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Agent-specific: Base Location
                if (_isAgent) ...[
                  _buildBaseLocationSelector(),
                  const SizedBox(height: 20),
                  _buildServiceAreasSelector(),
                  const SizedBox(height: 20),
                ],

                // BVN/NIN
                AppTextField(
                  label: (_isLandlord || _isAgent) ? 'NIN (National Identification Number)' : AppStrings.bvn,
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
                        (_isLandlord || _isAgent) ? 'Why do we need your NIN?' : AppStrings.whyBvn,
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
                        const Icon(
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
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textSecondary,
          ),
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
              icon: const Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
              items: _lagosAreas.where((area) => area != 'Other').map((area) {
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
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textSecondary,
          ),
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
              Text(
                'Tap to select areas:',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _lagosAreas.map((area) {
                  final isSelected = _selectedServiceAreas.contains(area) || 
                                     (area == 'Other' && _showCustomAreaInput);
                  return GestureDetector(
                    onTap: () => _toggleServiceArea(area),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? AppColors.primary : AppColors.background,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Text(
                        area,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: isSelected ? Colors.white : AppColors.textPrimary,
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
                  icon: const Icon(Icons.add_circle, color: AppColors.primary, size: 32),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}