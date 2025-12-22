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

  late final AuthService _authService;
  bool _isLoading = false;
  bool _showBvnInfo = false;
  String? _errorMessage;
  String? _userEmail;

  bool get _isLandlord => widget.accountType == 'landlord';

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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

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
        phone: _isLandlord ? _phoneController.text.trim() : null,
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
                  _isLandlord 
                      ? 'Tell us about yourself so tenants can reach you'
                      : 'Tell us a bit about yourself',
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
                        child: const Icon(
                          Icons.person,
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

                // Phone number (for landlords only)
                if (_isLandlord) ...[
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
                    'Tenants will use this number to contact you',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // BVN/NIN
                AppTextField(
                  label: _isLandlord ? 'NIN (National Identification Number)' : AppStrings.bvn,
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
                        _isLandlord ? 'Why do we need your NIN?' : AppStrings.whyBvn,
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
                            _isLandlord 
                                ? 'Your NIN helps us verify your identity and build trust with tenants. This information is securely stored and only used for verification purposes.'
                                : AppStrings.bvnExplanation,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}