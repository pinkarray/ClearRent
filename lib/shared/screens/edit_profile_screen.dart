import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../widgets/option_picker_sheet.dart';
import '../../services/auth_service.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final AuthService _authService = AuthService();
  
  // Tenant profile controllers
  final _occupationController = TextEditingController();
  final _employerController = TextEditingController();
  final _budgetMinController = TextEditingController();
  final _budgetMaxController = TextEditingController();

  bool _isLoading = true;
  bool _isSavingTenantProfile = false;
  bool _isUploadingPhoto = false;

  String _fullName = '';
  String _email = '';
  String _phone = '';
  String? _photoUrl;
  bool _isVerified = false;
  String _accountType = 'tenant';

  // Tenant profile state
  String? _workMode;
  String? _workplaceArea;
  String? _incomeRange;
  String? _maritalStatus;
  List<String> _preferredAreas = [];
  bool _tenantProfileDirty = false;

  // Lagos areas for dropdowns
  static const List<String> _lagosAreas = [
    'Victoria Island', 'Ikoyi', 'Lekki Phase 1', 'Lekki Phase 2', 'Lekki',
    'Ajah', 'Sangotedo', 'Chevron', 'Ilasan', 'Oniru', 'Obalende',
    'Marina', 'Lagos Island', 'Ibeju-Lekki', 'Epe',
    'Ikeja', 'GRA Ikeja', 'Alausa', 'Oregun', 'Omole', 'Ojodu', 'Ogba',
    'Berger', 'Isheri', 'Maryland', 'Anthony', 'Palmgrove', 'Gbagada', 'Ogudu',
    'Yaba', 'Surulere', 'Bariga', 'Shomolu', 'Fadeyi', 'Mushin', 'Isolo',
    'Ikotun', 'Egbeda', 'Alimosho', 'Oshodi', 'Mafoluku', 'Festac',
    'Amuwo-Odofin', 'Apapa', 'Ajegunle',
    'Ketu', 'Mile 12', 'Ojota', 'Agege', 'Magodo', 'Ifako-Ijaiye',
    'Ikorodu', 'Badagry', 'Ojo',
  ];

  static const List<Map<String, String>> _incomeRanges = [
    {'id': 'below_100k', 'label': 'Below ₦100K'},
    {'id': '100k_200k', 'label': '₦100K - ₦200K'},
    {'id': '200k_500k', 'label': '₦200K - ₦500K'},
    {'id': '500k_1m', 'label': '₦500K - ₦1M'},
    {'id': 'above_1m', 'label': 'Above ₦1M'},
  ];

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _occupationController.dispose();
    _employerController.dispose();
    _budgetMinController.dispose();
    _budgetMaxController.dispose();
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
          _accountType = profile['accountType'] ?? 'tenant';

          // Load tenant profile fields
          _occupationController.text = profile['occupation'] ?? '';
          _employerController.text = profile['employer'] ?? '';
          _workMode = profile['workMode'] as String?;
          _workplaceArea = profile['workplaceArea'] as String?;
          _incomeRange = profile['incomeRange'] as String?;
          _maritalStatus = profile['maritalStatus'] as String?;
          _preferredAreas = List<String>.from(profile['preferredAreas'] ?? []);

          final budgetMin = (profile['budgetMin'] as num?)?.toDouble();
          final budgetMax = (profile['budgetMax'] as num?)?.toDouble();
          if (budgetMin != null && budgetMin > 0) {
            _budgetMinController.text = _formatForInput(budgetMin);
          }
          if (budgetMax != null && budgetMax > 0) {
            _budgetMaxController.text = _formatForInput(budgetMax);
          }

          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      developer.log('❌ Error loading profile: $e', name: 'EditProfileScreen', error: e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatForInput(double value) {
    final intValue = value.toInt();
    final chars = intValue.toString().split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  double _parseBudgetAmount(TextEditingController controller) {
    final cleaned = controller.text.replaceAll(',', '');
    return double.tryParse(cleaned) ?? 0;
  }

  Future<void> _saveTenantProfile() async {
    setState(() => _isSavingTenantProfile = true);

    final updates = <String, dynamic>{
      'occupation': _occupationController.text.trim(),
      'employer': _employerController.text.trim(),
      'workMode': _workMode,
      'workplaceArea': _workplaceArea,
      'incomeRange': _incomeRange,
      'maritalStatus': _maritalStatus,
      'preferredAreas': _preferredAreas,
      'budgetMin': _parseBudgetAmount(_budgetMinController),
      'budgetMax': _parseBudgetAmount(_budgetMaxController),
    };

    // Remove null values
    updates.removeWhere((key, value) => value == null);

    final success = await _authService.updateUserProfile(updates);

    if (!mounted) return;
    setState(() {
      _isSavingTenantProfile = false;
      _tenantProfileDirty = false;
    });

    if (success) {
      _showSuccess('Profile updated');
    } else {
      _showError('Failed to save profile');
    }
  }

  void _markDirty() {
    if (!_tenantProfileDirty) {
      setState(() => _tenantProfileDirty = true);
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
      developer.log('❌ Photo upload error: $e', name: 'EditProfileScreen', error: e);
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
            Expanded(child: Text(message)),
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
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Edit Profile', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body:
          _isLoading
              ? Center(child: CircularProgressIndicator(color: AppColors.primary))
              : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _buildPhotoSection(),
                    const SizedBox(height: 32),
                    _buildFormSection(),

                    // Tenant profile section
                    if (_accountType == 'tenant') ...[
                      const SizedBox(height: 32),
                      _buildTenantProfileSection(),
                    ],

                    const SizedBox(height: 24),

                    // Info note
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.info.withAlpha(50)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 20, color: AppColors.info),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Your name and email are linked to your account verification and cannot be changed directly. Contact support if you need to update them.',
                              style: AppTextStyles.bodySmall.copyWith(color: AppColors.info),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
    );
  }

  // ── Photo Section (unchanged) ──

  Widget _buildPhotoSection() {
    return Column(
      children: [
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
                  image: _photoUrl != null
                      ? DecorationImage(image: NetworkImage(_photoUrl!), fit: BoxFit.cover)
                      : null,
                ),
                child: _isUploadingPhoto
                    ? Center(child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2))
                    : _photoUrl == null
                        ? Center(
                            child: Text(
                              _fullName.isNotEmpty ? _fullName[0].toUpperCase() : '?',
                              style: AppTextStyles.h1.copyWith(color: AppColors.primary),
                            ),
                          )
                        : null,
              ),
            ),
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
                    child: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
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
                Text('Get verified to change your photo',
                    style: AppTextStyles.caption.copyWith(color: AppColors.warning)),
              ],
            ),
          ),
      ],
    );
  }

  // ── Core Form Section (name, email, phone) ──

  Widget _buildFormSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildReadOnlyField(label: 'Full Name', value: _fullName, icon: Icons.person_outline),
        const SizedBox(height: 20),
        _buildReadOnlyField(label: 'Email', value: _email, icon: Icons.email_outlined),
        const SizedBox(height: 6),
        Text('Contact support to change',
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
        const SizedBox(height: 20),
        _buildReadOnlyField(label: 'Phone Number', value: _phone, icon: Icons.phone_outlined),
        const SizedBox(height: 6),
        Text('Contact support to change',
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
      ],
    );
  }

  // ── Tenant Profile Section ──

  Widget _buildTenantProfileSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            Icon(Icons.person_search_outlined, size: 22, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tenant Profile', style: AppTextStyles.h4),
                  Text(
                    'Helps agents and landlords find the right property for you.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Occupation
        _buildEditableField(
          label: 'Occupation',
          hint: 'e.g. Software Engineer, Banker',
          controller: _occupationController,
          icon: Icons.work_outline,
          onChanged: (_) => _markDirty(),
        ),
        const SizedBox(height: 16),

        // Employer
        _buildEditableField(
          label: 'Employer (Optional)',
          hint: 'e.g. Access Bank, MTN, Self-employed',
          controller: _employerController,
          icon: Icons.business_outlined,
          onChanged: (_) => _markDirty(),
        ),
        const SizedBox(height: 20),

        // Work mode
        Text('How do you work?', style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildWorkModeChip('Remote', 'remote', Icons.home_outlined),
            const SizedBox(width: 8),
            _buildWorkModeChip('Hybrid', 'hybrid', Icons.sync_alt),
            const SizedBox(width: 8),
            _buildWorkModeChip('Commute', 'commute', Icons.directions_car_outlined),
          ],
        ),
        const SizedBox(height: 20),

        // Workplace area (only for commute/hybrid)
        if (_workMode == 'commute' || _workMode == 'hybrid') ...[
          Text('Where do you work?', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          _buildDropdown(
            value: _workplaceArea,
            hint: 'Select workplace area',
            items: _lagosAreas,
            onChanged: (v) {
              setState(() => _workplaceArea = v);
              _markDirty();
            },
          ),
          const SizedBox(height: 20),
        ],

        // Marital status
        Text('Marital Status', style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildChipOption('Single', 'single', _maritalStatus, (v) {
              setState(() => _maritalStatus = v);
              _markDirty();
            }),
            const SizedBox(width: 8),
            _buildChipOption('Married', 'married', _maritalStatus, (v) {
              setState(() => _maritalStatus = v);
              _markDirty();
            }),
            const SizedBox(width: 8),
            _buildChipOption('Family', 'family', _maritalStatus, (v) {
              setState(() => _maritalStatus = v);
              _markDirty();
            }),
          ],
        ),
        const SizedBox(height: 20),

        // Income range
        Text('Monthly Income Range', style: AppTextStyles.labelMedium),
        const SizedBox(height: 4),
        Text('This is private and helps match you with affordable properties.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _incomeRanges.map((range) {
            final isSelected = _incomeRange == range['id'];
            return GestureDetector(
              onTap: () {
                setState(() => _incomeRange = range['id']);
                _markDirty();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
                ),
                child: Text(
                  range['label']!,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: isSelected ? AppColors.primary : AppColors.textSecondary,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),

        // Budget range
        Text('Rent Budget (₦)', style: AppTextStyles.labelMedium),
        const SizedBox(height: 4),
        Text('Annual rent range you can afford.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _buildBudgetInput(_budgetMinController, 'Min')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('to', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
            ),
            Expanded(child: _buildBudgetInput(_budgetMaxController, 'Max')),
          ],
        ),
        const SizedBox(height: 20),

        // Preferred areas
        Text('Preferred Areas', style: AppTextStyles.labelMedium),
        const SizedBox(height: 4),
        Text('Where are you looking to rent?',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        if (_preferredAreas.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _preferredAreas.map((area) => Chip(
              label: Text(area, style: AppTextStyles.bodySmall.copyWith(color: AppColors.primary)),
              backgroundColor: AppColors.primary.withAlpha(26),
              deleteIcon: const Icon(Icons.close, size: 16),
              deleteIconColor: AppColors.primary,
              onDeleted: () {
                setState(() => _preferredAreas.remove(area));
                _markDirty();
              },
              side: BorderSide.none,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            )).toList(),
          ),
          const SizedBox(height: 8),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxHeight: 200),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _lagosAreas.map((area) {
                final isSelected = _preferredAreas.contains(area);
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _preferredAreas.remove(area);
                      } else {
                        _preferredAreas.add(area);
                      }
                    });
                    _markDirty();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.primary : AppColors.background,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
                    ),
                    child: Text(
                      area,
                      style: AppTextStyles.caption.copyWith(
                        color: isSelected ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Save button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isSavingTenantProfile ? null : _saveTenantProfile,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: _isSavingTenantProfile
                ? SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    _tenantProfileDirty ? 'Save Changes' : 'Save Profile',
                    style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
                  ),
          ),
        ),
      ],
    );
  }

  // ── Reusable Widgets ──

  Widget _buildWorkModeChip(String label, String value, IconData icon) {
    final isSelected = _workMode == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _workMode = value);
          _markDirty();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
          ),
          child: Column(
            children: [
              Icon(icon, size: 22, color: isSelected ? AppColors.primary : AppColors.textSecondary),
              const SizedBox(height: 4),
              Text(label, style: AppTextStyles.labelSmall.copyWith(
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChipOption(String label, String value, String? selected, ValueChanged<String> onTap) {
    final isSelected = selected == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
          ),
          child: Center(
            child: Text(label, style: AppTextStyles.labelMedium.copyWith(
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            )),
          ),
        ),
      ),
    );
  }

  Widget _buildDropdown({
    required String? value,
    required String hint,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return GestureDetector(
      onTap: () => showOptionPicker(
        context,
        title: hint,
        options: items,
        selected: value,
        onSelected: (v) => onChanged(v),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value ?? hint,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: value == null
                      ? AppColors.textSecondary
                      : AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildBudgetInput(TextEditingController controller, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          _ThousandsSeparator(),
        ],
        onChanged: (_) => _markDirty(),
        style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Text('₦', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary, fontFamily: 'Roboto')),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
    );
  }

  Widget _buildEditableField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required IconData icon,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: AppColors.textHint),
            prefixIcon: Icon(icon, color: AppColors.textHint),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
        Text(label, style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
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
                    color: value.isNotEmpty ? AppColors.textPrimary : AppColors.textHint,
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

/// Thousands separator for budget inputs
class _ThousandsSeparator extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.isEmpty) {
      return const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
    }
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