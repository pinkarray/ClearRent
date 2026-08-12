import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'dart:io';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../services/auth_service.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../shared/widgets/user_avatar.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/widgets/area_dropdown.dart';

class ProfileSetupScreen extends StatefulWidget {
  final String accountType;
  const ProfileSetupScreen({super.key, required this.accountType});
  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _customAreaController = TextEditingController();

  // Tenant-specific controllers
  final _occupationController = TextEditingController();
  final _employerController = TextEditingController();
  final _budgetMinController = TextEditingController();
  final _budgetMaxController = TextEditingController();

  late final AuthService _authService;
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // Agent-specific fields
  String? _selectedBaseLocation;
  final List<String> _selectedServiceAreas = [];

  // Tenant-specific fields
  String? _selectedWorkMode;
  String? _selectedWorkplaceArea;
  String? _selectedIncomeRange;
  String? _selectedMaritalStatus;
  final List<String> _selectedPreferredAreas = [];

  File? _profileImageFile;
  final PropertyService _profileUploadService = PropertyService();

  bool get _isLandlord => widget.accountType == 'landlord';
  bool get _isAgent => widget.accountType == 'agent';
  bool get _isTenant => widget.accountType == 'tenant';

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _loadDraft();

    // Auto-save draft when text fields lose focus
    _nameController.addListener(_debounceSaveDraft);
    _emailController.addListener(_debounceSaveDraft);
    _occupationController.addListener(_debounceSaveDraft);
    _employerController.addListener(_debounceSaveDraft);
    _budgetMinController.addListener(_debounceSaveDraft);
    _budgetMaxController.addListener(_debounceSaveDraft);
  }

  // Simple debounce: only save after user stops typing for 1.5s
  Timer? _draftTimer;
  void _debounceSaveDraft() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1500), _saveDraft);
  }

  /// Load any saved draft and pre-fill form fields.
  Future<void> _loadDraft() async {
    final draft = await _authService.getProfileDraft();
    if (draft == null || !mounted) return;

    setState(() {
      // Common fields
      if (draft['fullName'] != null) _nameController.text = draft['fullName'];
      if (draft['email'] != null) _emailController.text = draft['email'];

      // Agent fields
      if (draft['baseLocation'] != null) _selectedBaseLocation = draft['baseLocation'];
      if (draft['serviceAreas'] != null) {
        _selectedServiceAreas.clear();
        _selectedServiceAreas.addAll(List<String>.from(draft['serviceAreas']));
      }

      // Tenant fields
      if (draft['occupation'] != null) _occupationController.text = draft['occupation'];
      if (draft['employer'] != null) _employerController.text = draft['employer'];
      if (draft['workMode'] != null) _selectedWorkMode = draft['workMode'];
      if (draft['workplaceArea'] != null) _selectedWorkplaceArea = draft['workplaceArea'];
      if (draft['incomeRange'] != null) _selectedIncomeRange = draft['incomeRange'];
      if (draft['maritalStatus'] != null) _selectedMaritalStatus = draft['maritalStatus'];
      if (draft['budgetMin'] != null && (draft['budgetMin'] as num) > 0) {
        _budgetMinController.text = _formatDraftAmount(draft['budgetMin']);
      }
      if (draft['budgetMax'] != null && (draft['budgetMax'] as num) > 0) {
        _budgetMaxController.text = _formatDraftAmount(draft['budgetMax']);
      }
      if (draft['preferredAreas'] != null) {
        _selectedPreferredAreas.clear();
        _selectedPreferredAreas.addAll(List<String>.from(draft['preferredAreas']));
      }
    });
  }

  String _formatDraftAmount(dynamic value) {
    final amount = (value as num).toInt();
    if (amount <= 0) return '';
    final chars = amount.toString().split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  /// Save current form state as a draft (fire-and-forget).
  void _saveDraft() {
    final draft = <String, dynamic>{
      'fullName': _nameController.text.trim(),
      'email': _emailController.text.trim(),
    };

    if (_isAgent) {
      draft['baseLocation'] = _selectedBaseLocation;
      draft['serviceAreas'] = _selectedServiceAreas;
    }

    if (_isTenant) {
      draft['occupation'] = _occupationController.text.trim();
      draft['employer'] = _employerController.text.trim();
      draft['workMode'] = _selectedWorkMode;
      draft['workplaceArea'] = _selectedWorkplaceArea;
      draft['incomeRange'] = _selectedIncomeRange;
      draft['maritalStatus'] = _selectedMaritalStatus;
      draft['budgetMin'] = _parseBudgetAmount(_budgetMinController);
      draft['budgetMax'] = _parseBudgetAmount(_budgetMaxController);
      draft['preferredAreas'] = _selectedPreferredAreas;
    }

    _authService.saveProfileDraft(draft);
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _nameController.removeListener(_debounceSaveDraft);
    _emailController.removeListener(_debounceSaveDraft);
    _occupationController.removeListener(_debounceSaveDraft);
    _employerController.removeListener(_debounceSaveDraft);
    _budgetMinController.removeListener(_debounceSaveDraft);
    _budgetMaxController.removeListener(_debounceSaveDraft);
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _customAreaController.dispose();
    _occupationController.dispose();
    _employerController.dispose();
    _budgetMinController.dispose();
    _budgetMaxController.dispose();
    super.dispose();
  }

  String? _validateName(String? value) {
    if (value == null || value.isEmpty) return 'Please enter your full name';
    if (value.split(' ').length < 2) return 'Please enter your first and last name';
    return null;
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) return 'Please enter your email address';
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value)) return 'Please enter a valid email address';
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Please enter a password';
    if (value.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) return 'Please confirm your password';
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Text('Profile Photo', style: AppTextStyles.h4),
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _buildImageSourceOption(icon: Icons.camera_alt_rounded, label: 'Camera',
                onTap: () => Navigator.pop(ctx, ImageSource.camera)),
              _buildImageSourceOption(icon: Icons.photo_library_rounded, label: 'Gallery',
                onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
              if (_profileImageFile != null)
                _buildImageSourceOption(icon: Icons.delete_outline, label: 'Remove',
                  onTap: () { Navigator.pop(ctx, null); setState(() => _profileImageFile = null); },
                  color: AppColors.error),
            ]),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
    if (source == null) return;
    try {
      final XFile? image = await picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 85);
      if (image == null) return;
      setState(() => _profileImageFile = File(image.path));
    } catch (e) {
      debugPrint('❌ Error picking profile image: $e');
    }
  }

  Widget _buildImageSourceOption({required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(width: 64, height: 64,
          decoration: BoxDecoration(color: (color ?? AppColors.primary).withAlpha(26), borderRadius: BorderRadius.circular(16)),
          child: Icon(icon, color: color ?? AppColors.primary, size: 32)),
        const SizedBox(height: 8),
        Text(label, style: AppTextStyles.labelMedium.copyWith(color: color ?? AppColors.textPrimary)),
      ]),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_isAgent) {
      if (_selectedBaseLocation == null) {
        setState(() => _errorMessage = 'Please select your base location');
        return;
      }
      if (_selectedServiceAreas.isEmpty) {
        setState(() => _errorMessage = 'Please select at least one service area');
        return;
      }
    }

    if (_isTenant) {
      if (_occupationController.text.trim().isEmpty) {
        setState(() => _errorMessage = 'Please enter your occupation');
        return;
      }
      if (_selectedWorkMode == null) {
        setState(() => _errorMessage = 'Please select how you work');
        return;
      }
      if ((_selectedWorkMode == 'commute' || _selectedWorkMode == 'hybrid') && _selectedWorkplaceArea == null) {
        setState(() => _errorMessage = 'Please select your workplace area');
        return;
      }
    }

    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      final success = await _authService.saveUserProfile(
        fullName: _nameController.text.trim(),
        email: _emailController.text.trim(),
        accountType: widget.accountType,
        baseLocation: _isAgent ? _selectedBaseLocation : null,
        serviceAreas: _isAgent ? _selectedServiceAreas : null,
        occupation: _isTenant ? _occupationController.text.trim() : null,
        employer: _isTenant ? _employerController.text.trim() : null,
        workMode: _isTenant ? _selectedWorkMode : null,
        workplaceArea: _isTenant ? _selectedWorkplaceArea : null,
        incomeRange: _isTenant ? _selectedIncomeRange : null,
        budgetMin: _isTenant ? _parseBudgetAmount(_budgetMinController) : null,
        budgetMax: _isTenant ? _parseBudgetAmount(_budgetMaxController) : null,
        preferredAreas: _isTenant ? _selectedPreferredAreas : null,
        maritalStatus: _isTenant ? _selectedMaritalStatus : null,
      );

      if (!success) {
        setState(() { _errorMessage = 'Failed to save profile. Please try again.'; _isLoading = false; });
        return;
      }

      if (_profileImageFile != null) {
        try {
          final imageUrl = await _profileUploadService.uploadImage(_profileImageFile!);
          if (imageUrl != null && imageUrl.isNotEmpty) {
            await _authService.updateUserProfile({'profileImageUrl': imageUrl});
          }
        } catch (e) {
          debugPrint('⚠️ Profile image upload failed (non-blocking): $e');
        }
      }

      // Link email + password to the phone account
      final linkResult = await _authService.linkEmailToPhoneAccount(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      if (!linkResult.success) {
        if (!mounted) return;
        setState(() { _errorMessage = linkResult.error; _isLoading = false; });
        return;
      }
    } catch (e) {
      debugPrint('❌ Profile save error: $e');
      setState(() { _errorMessage = 'An error occurred. Please try again.'; _isLoading = false; });
      return;
    }

    setState(() => _isLoading = false);
    if (!mounted) return;

    // Clear draft after successful completion
    _authService.clearProfileDraft();

    switch (widget.accountType) {
      case 'landlord': context.go('/landlord/home'); break;
      case 'agent': context.go('/agent/home'); break;
      default: context.go('/tenant/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: Text(AppStrings.setupProfile, style: AppTextStyles.h4),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_getSubtitle(), style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 32),

                // Profile picture
                Center(child: UserAvatar(
                  name: _nameController.text.isNotEmpty ? _nameController.text : null,
                  imageFile: _profileImageFile, size: 100, showEditBadge: true, onTap: _pickProfileImage)),
                const SizedBox(height: 24),

                // Phone number display (read-only — already verified)
                if (_authService.currentUser?.phoneNumber != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface, borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border)),
                    child: Row(children: [
                      Icon(Icons.phone_outlined, color: AppColors.textSecondary, size: 20),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Phone Number', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                        const SizedBox(height: 2),
                        Text(_authService.currentUser!.phoneNumber!,
                          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textPrimary)),
                      ])),
                      Icon(Icons.check_circle, color: AppColors.success, size: 20),
                    ]),
                  ),
                  const SizedBox(height: 20),
                ],

                // Error message
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.error.withAlpha(26), borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.error.withAlpha(77))),
                    child: Row(children: [
                      Icon(Icons.error_outline, color: AppColors.error, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_errorMessage!, style: AppTextStyles.bodySmall.copyWith(color: AppColors.error))),
                    ]),
                  ),
                  const SizedBox(height: 16),
                ],

                // Full name
                AppTextField(
                  label: AppStrings.fullName, hint: 'John Doe', controller: _nameController,
                  textCapitalization: TextCapitalization.words, textInputAction: TextInputAction.next,
                  validator: _validateName),
                const SizedBox(height: 20),

                // Email address
                AppTextField(
                  label: 'Email Address', hint: 'you@example.com', controller: _emailController,
                  keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next,
                  // `username` beside a `newPassword` field is what tells an
                  // autofill service this is a REGISTRATION form — the thing
                  // that makes it offer to generate and save a password.
                  autofillHints: const [AutofillHints.username],
                  validator: _validateEmail,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.email_outlined, color: AppColors.textHint))),
                const SizedBox(height: 20),

                // Password
                AppTextField(
                  label: 'Password', hint: 'At least 6 characters', controller: _passwordController,
                  obscureText: _obscurePassword, textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: _validatePassword,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.lock_outlined, color: AppColors.textHint)),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: AppColors.textHint),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword))),
                const SizedBox(height: 20),

                // Confirm Password
                AppTextField(
                  label: 'Confirm Password', hint: 'Re-enter your password', controller: _confirmPasswordController,
                  obscureText: _obscureConfirmPassword, textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: _validateConfirmPassword,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.lock_outlined, color: AppColors.textHint)),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility, color: AppColors.textHint),
                    onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword))),
                const SizedBox(height: 8),

                // Password hint
                Text(
                  'This password lets you sign in with email instead of OTP',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 20),

                // Agent-specific
                if (_isAgent) ...[
                  _buildBaseLocationSelector(), const SizedBox(height: 20),
                  _buildServiceAreasSelector(), const SizedBox(height: 20),
                ],

                // Tenant-specific
                if (_isTenant) ...[
                  _buildTenantSectionHeader(), const SizedBox(height: 16),
                  _buildOccupationField(), const SizedBox(height: 20),
                  _buildEmployerField(), const SizedBox(height: 20),
                  _buildWorkModeSelector(), const SizedBox(height: 20),
                  if (_selectedWorkMode == 'commute' || _selectedWorkMode == 'hybrid') ...[
                    _buildWorkplaceAreaSelector(), const SizedBox(height: 20),
                  ],
                  _buildMaritalStatusSelector(), const SizedBox(height: 20),
                  _buildIncomeRangeSelector(), const SizedBox(height: 20),
                  _buildBudgetRangeFields(), const SizedBox(height: 20),
                  _buildPreferredAreasSelector(), const SizedBox(height: 20),
                ],

                const SizedBox(height: 20),

                // Submit button
                AppButton(text: 'Complete Setup', onPressed: _submit, isLoading: _isLoading),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getSubtitle() {
    if (_isLandlord) return 'Tell us about yourself so tenants can reach you';
    if (_isAgent) return 'Tell us about yourself and where you operate';
    return 'Help us find the perfect property for you';
  }

  static const List<Map<String, String>> _incomeRanges = [
    {'id': 'below_100k', 'label': 'Below ₦100K'},
    {'id': '100k_200k', 'label': '₦100K - ₦200K'},
    {'id': '200k_500k', 'label': '₦200K - ₦500K'},
    {'id': '500k_1m', 'label': '₦500K - ₦1M'},
    {'id': 'above_1m', 'label': 'Above ₦1M'},
  ];

  double _parseBudgetAmount(TextEditingController controller) {
    final cleanedText = controller.text.replaceAll(',', '');
    return double.tryParse(cleanedText) ?? 0;
  }

  Widget _buildTenantSectionHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(13), borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(50))),
      child: Row(children: [
        Icon(Icons.person_outline, size: 24, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Tell us about yourself', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary)),
          const SizedBox(height: 4),
          Text('This helps landlords and agents find the right property for you.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        ])),
      ]),
    );
  }

  Widget _buildOccupationField() => AppTextField(
    label: 'Occupation', hint: 'e.g. Software Engineer, Banker, Teacher',
    controller: _occupationController, textCapitalization: TextCapitalization.words,
    textInputAction: TextInputAction.next,
    prefixIcon: Icon(Icons.work_outline, color: AppColors.textSecondary));

  Widget _buildEmployerField() => AppTextField(
    label: 'Employer (Optional)', hint: 'e.g. Access Bank, MTN, Self-employed',
    controller: _employerController, textCapitalization: TextCapitalization.words,
    textInputAction: TextInputAction.next,
    prefixIcon: Icon(Icons.business_outlined, color: AppColors.textSecondary));

  Widget _buildWorkModeSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('How do you work?', style: AppTextStyles.labelMedium), const SizedBox(height: 8),
    Row(children: [
      _buildWorkModeChip('Remote', 'remote', Icons.home_outlined), const SizedBox(width: 8),
      _buildWorkModeChip('Hybrid', 'hybrid', Icons.sync_alt), const SizedBox(width: 8),
      _buildWorkModeChip('Commute', 'commute', Icons.directions_car_outlined),
    ]),
  ]);

  Widget _buildWorkModeChip(String label, String value, IconData icon) {
    final isSelected = _selectedWorkMode == value;
    return Expanded(child: GestureDetector(
      onTap: () { setState(() => _selectedWorkMode = value); _saveDraft(); },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? AppColors.primary : AppColors.border)),
        child: Column(children: [
          Icon(icon, size: 24, color: isSelected ? AppColors.primary : AppColors.textSecondary),
          const SizedBox(height: 6),
          Text(label, style: AppTextStyles.labelSmall.copyWith(
            color: isSelected ? AppColors.primary : AppColors.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
        ]),
      ),
    ));
  }

  Widget _buildWorkplaceAreaSelector() => AreaDropdown(
    label: 'Where do you work?',
    helperText: 'This helps match you with properties near your workplace.',
    hint: 'Select your workplace area',
    selectedArea: _selectedWorkplaceArea,
    onSelected: (value) { setState(() => _selectedWorkplaceArea = value); _saveDraft(); },
  );

  Widget _buildMaritalStatusSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Marital Status', style: AppTextStyles.labelMedium), const SizedBox(height: 8),
    Row(children: [
      _buildMaritalChip('Single', 'single'), const SizedBox(width: 8),
      _buildMaritalChip('Married', 'married'), const SizedBox(width: 8),
      _buildMaritalChip('Family', 'family'),
    ]),
  ]);

  Widget _buildMaritalChip(String label, String value) {
    final isSelected = _selectedMaritalStatus == value;
    return Expanded(child: GestureDetector(
      onTap: () { setState(() => _selectedMaritalStatus = value); _saveDraft(); },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? AppColors.primary : AppColors.border)),
        child: Center(child: Text(label, style: AppTextStyles.labelMedium.copyWith(
          color: isSelected ? AppColors.primary : AppColors.textSecondary,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal))),
      ),
    ));
  }

  Widget _buildIncomeRangeSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Monthly Income Range', style: AppTextStyles.labelMedium), const SizedBox(height: 4),
    Text('This is private and helps us match you with properties you can afford.',
      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: _incomeRanges.map((range) {
      final isSelected = _selectedIncomeRange == range['id'];
      return GestureDetector(
        onTap: () { setState(() => _selectedIncomeRange = range['id']); _saveDraft(); },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isSelected ? AppColors.primary : AppColors.border)),
          child: Text(range['label']!, style: AppTextStyles.labelSmall.copyWith(
            color: isSelected ? AppColors.primary : AppColors.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal, fontFamily: 'Roboto')),
        ),
      );
    }).toList()),
  ]);

  Widget _buildBudgetRangeFields() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Rent Budget (₦)', style: AppTextStyles.labelMedium), const SizedBox(height: 4),
    Text('What range of rent can you afford per year?', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
    const SizedBox(height: 8),
    Row(children: [
      Expanded(child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: TextField(controller: _budgetMinController, keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, _ThousandsSeparator()],
          style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
          decoration: InputDecoration(hintText: 'Min', hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
            prefixIcon: Padding(padding: const EdgeInsets.only(left: 12, right: 4),
              child: Text('₦', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary, fontFamily: 'Roboto'))),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14))))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text('to', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary))),
      Expanded(child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: TextField(controller: _budgetMaxController, keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, _ThousandsSeparator()],
          style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
          decoration: InputDecoration(hintText: 'Max', hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
            prefixIcon: Padding(padding: const EdgeInsets.only(left: 12, right: 4),
              child: Text('₦', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary, fontFamily: 'Roboto'))),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14))))),
    ]),
  ]);

  Widget _buildPreferredAreasSelector() => AreaMultiSelect(
    label: 'Preferred Areas',
    helperText: 'Where are you looking to rent? Select all areas that interest you.',
    selectedAreas: _selectedPreferredAreas,
    onChanged: (areas) {
      setState(() {
        _selectedPreferredAreas.clear();
        _selectedPreferredAreas.addAll(areas);
      });
      _saveDraft();
    },
  );

  Widget _buildBaseLocationSelector() => AreaDropdown(
    label: 'Base Location',
    helperText: 'Where are you based? This helps us calculate inspection distances.',
    hint: 'Select your area',
    selectedArea: _selectedBaseLocation,
    onSelected: (value) { setState(() => _selectedBaseLocation = value); _saveDraft(); },
  );

  Widget _buildServiceAreasSelector() => AreaMultiSelect(
    label: 'Service Areas',
    helperText: 'Which areas can you cover for inspections? Select all that apply.',
    selectedAreas: _selectedServiceAreas,
    onChanged: (areas) {
      setState(() {
        _selectedServiceAreas.clear();
        _selectedServiceAreas.addAll(areas);
      });
      _saveDraft();
    },
  );
}

class _ThousandsSeparator extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.isEmpty) return const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
    final chars = digitsOnly.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    final formatted = result.reversed.join('');
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}