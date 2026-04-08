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
  bool _showCustomAreaInput = false;

  // Tenant-specific fields
  String? _selectedWorkMode;
  String? _selectedWorkplaceArea;
  String? _selectedIncomeRange;
  String? _selectedMaritalStatus;
  final List<String> _selectedPreferredAreas = [];
  bool _showPreferredAreaCustomInput = false;
  final _preferredAreaCustomController = TextEditingController();

  File? _profileImageFile;
  final PropertyService _profileUploadService = PropertyService();

  static const List<String> _lagosAreas = [
    'Victoria Island', 'Ikoyi', 'Lekki Phase 1', 'Lekki Phase 2', 'Lekki',
    'Ajah', 'Sangotedo', 'Chevron', 'Ilasan', 'Oniru', 'Obalende', 'Marina',
    'Lagos Island', 'Ibeju-Lekki', 'Epe',
    'Ikeja', 'GRA Ikeja', 'Alausa', 'Oregun', 'Omole', 'Ojodu', 'Ogba',
    'Berger', 'Isheri', 'Maryland', 'Anthony', 'Palmgrove', 'Gbagada', 'Ogudu',
    'Yaba', 'Surulere', 'Bariga', 'Shomolu', 'Fadeyi', 'Mushin', 'Isolo',
    'Ikotun', 'Egbeda', 'Alimosho', 'Oshodi', 'Mafoluku', 'Festac',
    'Amuwo-Odofin', 'Apapa', 'Ajegunle',
    'Ketu', 'Mile 12', 'Ojota', 'Agege', 'Magodo', 'Ifako-Ijaiye',
    'Ikorodu', 'Badagry', 'Ojo',
    'Other',
  ];

  bool get _isLandlord => widget.accountType == 'landlord';
  bool get _isAgent => widget.accountType == 'agent';
  bool get _isTenant => widget.accountType == 'tenant';

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

  bool get _allPreferredSelected =>
      _selectableAreas.every((a) => _selectedPreferredAreas.contains(a));

  void _toggleSelectAllPreferred() {
    setState(() {
      if (_allPreferredSelected) {
        _selectedPreferredAreas.clear();
      } else {
        _selectedPreferredAreas.clear();
        _selectedPreferredAreas.addAll(_selectableAreas);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _customAreaController.dispose();
    _occupationController.dispose();
    _employerController.dispose();
    _budgetMinController.dispose();
    _budgetMaxController.dispose();
    _preferredAreaCustomController.dispose();
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

  void _toggleServiceArea(String area) {
    setState(() {
      if (area == 'Other') {
        _showCustomAreaInput = !_showCustomAreaInput;
        if (!_showCustomAreaInput) _customAreaController.clear();
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
                  validator: _validateEmail,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.email_outlined, color: AppColors.textHint))),
                const SizedBox(height: 20),

                // Password
                AppTextField(
                  label: 'Password', hint: 'At least 6 characters', controller: _passwordController,
                  obscureText: _obscurePassword, textInputAction: TextInputAction.next,
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
    {'id': '100k_200k', 'label': '₦100K – ₦200K'},
    {'id': '200k_500k', 'label': '₦200K – ₦500K'},
    {'id': '500k_1m', 'label': '₦500K – ₦1M'},
    {'id': 'above_1m', 'label': 'Above ₦1M'},
  ];

  double _parseBudgetAmount(TextEditingController controller) {
    final cleanedText = controller.text.replaceAll(',', '');
    return double.tryParse(cleanedText) ?? 0;
  }

  void _togglePreferredArea(String area) {
    setState(() {
      if (area == 'Other') {
        _showPreferredAreaCustomInput = !_showPreferredAreaCustomInput;
        if (!_showPreferredAreaCustomInput) _preferredAreaCustomController.clear();
      } else {
        if (_selectedPreferredAreas.contains(area)) { _selectedPreferredAreas.remove(area); }
        else { _selectedPreferredAreas.add(area); }
      }
    });
  }

  void _addPreferredCustomArea() {
    final customArea = _preferredAreaCustomController.text.trim();
    if (customArea.isNotEmpty && !_selectedPreferredAreas.contains(customArea)) {
      setState(() { _selectedPreferredAreas.add(customArea); _preferredAreaCustomController.clear(); });
    }
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
      onTap: () => setState(() => _selectedWorkMode = value),
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

  Widget _buildWorkplaceAreaSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Where do you work?', style: AppTextStyles.labelMedium), const SizedBox(height: 4),
    Text('This helps match you with properties near your workplace.',
      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
    const SizedBox(height: 8),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border)),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: _selectedWorkplaceArea,
        hint: Text('Select your workplace area', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
        isExpanded: true, icon: Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
        items: _selectableAreas.map((area) => DropdownMenuItem(value: area, child: Text(area, style: AppTextStyles.bodyMedium))).toList(),
        onChanged: (value) => setState(() => _selectedWorkplaceArea = value),
      )),
    ),
  ]);

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
      onTap: () => setState(() => _selectedMaritalStatus = value),
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
        onTap: () => setState(() => _selectedIncomeRange = range['id']),
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

  Widget _buildPreferredAreasSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Preferred Areas', style: AppTextStyles.labelMedium), const SizedBox(height: 4),
    Text('Where are you looking to rent? Select all areas that interest you.',
      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
    const SizedBox(height: 12),
    Container(
      padding: const EdgeInsets.all(16), constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Tap to select areas:', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          const Spacer(),
          GestureDetector(onTap: _toggleSelectAllPreferred, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _allPreferredSelected ? AppColors.error.withAlpha(26) : AppColors.primary.withAlpha(26),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _allPreferredSelected ? AppColors.error.withAlpha(77) : AppColors.primary.withAlpha(77))),
            child: Text(_allPreferredSelected ? 'Clear All' : 'Select All',
              style: AppTextStyles.labelSmall.copyWith(
                color: _allPreferredSelected ? AppColors.error : AppColors.primary, fontWeight: FontWeight.w600)))),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: _lagosAreas.map((area) {
          final isSelected = _selectedPreferredAreas.contains(area) || (area == 'Other' && _showPreferredAreaCustomInput);
          return GestureDetector(onTap: () => _togglePreferredArea(area), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : AppColors.background, borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isSelected ? AppColors.primary : AppColors.border)),
            child: Text(area, style: AppTextStyles.bodySmall.copyWith(color: isSelected ? Colors.white : AppColors.textPrimary))));
        }).toList()),
      ])),
    ),
    if (_showPreferredAreaCustomInput) ...[
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: AppTextField(label: 'Other Area', hint: 'Enter area name',
          controller: _preferredAreaCustomController, textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done, onSubmitted: (_) => _addPreferredCustomArea())),
        const SizedBox(width: 12),
        Padding(padding: const EdgeInsets.only(top: 24),
          child: IconButton(onPressed: _addPreferredCustomArea, icon: Icon(Icons.add_circle, color: AppColors.primary, size: 32))),
      ]),
    ],
  ]);

  Widget _buildBaseLocationSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Base Location', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textPrimary)),
    const SizedBox(height: 4),
    Text('Where are you based? This helps us calculate inspection distances.',
      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
    const SizedBox(height: 12),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: _selectedBaseLocation,
        hint: Text('Select your area', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
        isExpanded: true, icon: Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
        items: _selectableAreas.map((area) => DropdownMenuItem(value: area, child: Text(area, style: AppTextStyles.bodyMedium))).toList(),
        onChanged: (value) => setState(() => _selectedBaseLocation = value),
      )),
    ),
  ]);

  Widget _buildServiceAreasSelector() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Service Areas', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textPrimary)),
    const SizedBox(height: 4),
    Text('Which areas can you cover for inspections? Select all that apply.',
      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
    const SizedBox(height: 12),
    Container(
      padding: const EdgeInsets.all(16), constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Tap to select areas:', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          const Spacer(),
          GestureDetector(onTap: _toggleSelectAll, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _allSelected ? AppColors.error.withAlpha(26) : AppColors.primary.withAlpha(26),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _allSelected ? AppColors.error.withAlpha(77) : AppColors.primary.withAlpha(77))),
            child: Text(_allSelected ? 'Clear All' : 'Select All',
              style: AppTextStyles.labelSmall.copyWith(
                color: _allSelected ? AppColors.error : AppColors.primary, fontWeight: FontWeight.w600)))),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: _lagosAreas.map((area) {
          final isSelected = _selectedServiceAreas.contains(area) || (area == 'Other' && _showCustomAreaInput);
          return GestureDetector(onTap: () => _toggleServiceArea(area), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : AppColors.background, borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isSelected ? AppColors.primary : AppColors.border)),
            child: Text(area, style: AppTextStyles.bodySmall.copyWith(color: isSelected ? Colors.white : AppColors.textPrimary))));
        }).toList()),
      ])),
    ),
    if (_showCustomAreaInput) ...[
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: AppTextField(label: 'Other Area', hint: 'Enter area name',
          controller: _customAreaController, textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done, onSubmitted: (_) => _addCustomArea())),
        const SizedBox(width: 12),
        Padding(padding: const EdgeInsets.only(top: 24),
          child: IconButton(onPressed: _addCustomArea, icon: Icon(Icons.add_circle, color: AppColors.primary, size: 32))),
      ]),
    ],
  ]);
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