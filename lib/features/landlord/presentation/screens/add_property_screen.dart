import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../widgets/clearrent_location_picker.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../services/property_service.dart';
import '../../../../services/verification_service.dart';

/// Custom formatter that adds commas to numbers as you type
class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Remove all non-digits
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    
    if (digitsOnly.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    // Format with commas
    final formatted = _formatWithCommas(digitsOnly);
    
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  String _formatWithCommas(String value) {
    final chars = value.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) {
        result.add(',');
      }
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }
}

class AddPropertyScreen extends StatefulWidget {
  const AddPropertyScreen({super.key});

  @override
  State<AddPropertyScreen> createState() => _AddPropertyScreenState();
}

class _AddPropertyScreenState extends State<AddPropertyScreen> {
  final PageController _pageController = PageController();
  final PropertyService _propertyService = PropertyService();
  final VerificationService _verificationService = VerificationService();
  final ImagePicker _imagePicker = ImagePicker();
  
  int _currentStep = 0;
  final int _totalSteps = 5;
  bool _isPublishing = false;
  bool _isCheckingVerification = true;

  final List<File> _selectedImageFiles = [];
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _rentController = TextEditingController();

  double? _latitude;
  double? _longitude;

  String _propertyType = 'flat';
  int _bedrooms = 1;
  int _bathrooms = 1;
  int _toilets = 1;
  String _rentPeriod = 'yearly';
  final List<String> _selectedAmenities = [];
  final List<String> _selectedRules = [];

  // New inspection handling model
  String _inspectionHandler = 'self'; // 'self' or 'agent'

  // Inspection availability
  final List<String> _availableDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  final List<String> _availableTimeSlots = ['morning', 'afternoon', 'late_afternoon'];

  final List<String> _weekDays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];

  final List<Map<String, String>> _timeSlotOptions = [
    {'id': 'morning', 'label': 'Morning', 'time': '9:00 AM - 12:00 PM'},
    {'id': 'afternoon', 'label': 'Afternoon', 'time': '12:00 PM - 3:00 PM'},
    {'id': 'late_afternoon', 'label': 'Late Afternoon', 'time': '3:00 PM - 6:00 PM'},
    {'id': 'evening', 'label': 'Evening', 'time': '6:00 PM - 8:00 PM'},
  ];

  final List<String> _amenitiesList = [
    '24/7 Power Supply',
    'Running Water',
    'Security',
    'Parking Space',
    'Swimming Pool',
    'Gym',
    'Garden',
    'CCTV',
    'Prepaid Meter',
    'Tiled Floor',
    'POP Ceiling',
    'Wardrobe',
    'Kitchen Cabinets',
    'Water Heater',
    'Air Conditioning',
    'Balcony',
    'Boys Quarter (BQ)',
    'Gated Compound',
  ];

  final List<String> _rulesList = [
    'No pets allowed',
    'No smoking',
    'No parties',
    'No loud music after 10pm',
    'Maximum 2 occupants per room',
    'No subletting',
    'Visitors must sign in',
    'No commercial activities',
  ];

  @override
  void initState() {
    super.initState();
    _checkVerificationStatus();
  }

  /// Check if landlord is verified before allowing property listing
  Future<void> _checkVerificationStatus() async {
    try {
      final data = await _verificationService.getVerificationStatus();
      
      if (!mounted) return;
      
      if (data.status != VerificationStatus.verified) {
        // Show verification required dialog
        _showVerificationRequiredDialog(data.status);
      } else {
        setState(() => _isCheckingVerification = false);
      }
    } catch (e) {
      debugPrint('❌ Error checking verification: $e');
      setState(() => _isCheckingVerification = false);
    }
  }

  void _showVerificationRequiredDialog(VerificationStatus status) {
    String title;
    String message;
    String buttonText;
    IconData icon;
    Color color;

    switch (status) {
      case VerificationStatus.none:
        title = 'Verification Required';
        message = 'You need to verify your identity before listing properties. This helps build trust with tenants and protects everyone on the platform.';
        buttonText = 'Get Verified';
        icon = Icons.verified_user_outlined;
        color = AppColors.primary;
        break;
      case VerificationStatus.pending:
        title = 'Verification Pending';
        message = 'Your verification is being reviewed. You\'ll be able to list properties once approved. This usually takes 24-48 hours.';
        buttonText = 'Got it';
        icon = Icons.schedule;
        color = AppColors.warning;
        break;
      case VerificationStatus.rejected:
        title = 'Verification Failed';
        message = 'Your verification was not approved. Please review the feedback and submit again to start listing properties.';
        buttonText = 'Try Again';
        icon = Icons.error_outline;
        color = AppColors.error;
        break;
      case VerificationStatus.verified:
        setState(() => _isCheckingVerification = false);
        return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: color),
            ),
            const SizedBox(height: 24),
            Text(title, style: AppTextStyles.h3, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              message,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: buttonText,
                onPressed: () {
                  Navigator.pop(context);
                  if (status == VerificationStatus.pending) {
                    // Just go back to home
                    context.pop();
                  } else {
                    // Go to verification screen
                    context.pop();
                    context.push('/landlord/verification');
                  }
                },
              ),
            ),
            if (status != VerificationStatus.pending) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.pop();
                },
                child: Text(
                  'Maybe later',
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    _rentController.dispose();
    super.dispose();
  }

  /// Parse rent amount by removing commas
  double _parseRentAmount() {
    final cleanedText = _rentController.text.replaceAll(',', '');
    return double.tryParse(cleanedText) ?? 0.0;
  }

  void _nextStep() {
    if (_currentStep < _totalSteps - 1) {
      if (!_validateCurrentStep()) return;

      setState(() => _currentStep++);
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _showExitConfirmation();
    }
  }

  bool _validateCurrentStep() {
    switch (_currentStep) {
      case 0: // Photos
        if (_selectedImageFiles.isEmpty) {
          _showError('Please add at least one photo');
          return false;
        }
        return true;
      case 1: // Location
        if (_addressController.text.isEmpty) {
          _showError('Please enter the address');
          return false;
        }
        if (_cityController.text.isEmpty) {
          _showError('Please enter the city');
          return false;
        }
        if (_stateController.text.isEmpty) {
          _showError('Please enter the state');
          return false;
        }
        return true;
      case 2: // Details
        if (_titleController.text.isEmpty) {
          _showError('Please enter a title');
          return false;
        }
        if (_descriptionController.text.isEmpty) {
          _showError('Please enter a description');
          return false;
        }
        return true;
      case 3: // Pricing
        if (_rentController.text.isEmpty) {
          _showError('Please enter the rent amount');
          return false;
        }
        if (_parseRentAmount() <= 0) {
          _showError('Please enter a valid rent amount');
          return false;
        }
        if (_availableDays.isEmpty) {
          _showError('Please select at least one day for inspections');
          return false;
        }
        if (_availableTimeSlots.isEmpty) {
          _showError('Please select at least one time slot for inspections');
          return false;
        }
        return true;
      default:
        return true;
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  void _showExitConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard listing?'),
        content: const Text('You\'ll lose all the information you\'ve entered.'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Keep editing',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.pop();
            },
            child: Text(
              'Discard',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _publishProperty() async {
    setState(() => _isPublishing = true);

    try {
      // Step 1: Upload images to Cloudinary
      debugPrint('📸 Starting image upload...');
      debugPrint('📸 Number of images: ${_selectedImageFiles.length}');
      _showUploadProgress('Uploading images...');
      
      final imageUrls = await _propertyService.uploadImages(_selectedImageFiles);
      
      if (!mounted) return;
      
      debugPrint('📸 Uploaded ${imageUrls.length} images');
      
      if (imageUrls.isEmpty) {
        Navigator.pop(context); // Close progress dialog
        _showError('Failed to upload images. Please try again.');
        setState(() => _isPublishing = false);
        return;
      }

      // Step 2: Create property in Firestore
      debugPrint('🏠 Creating property in Firestore...');
      _updateUploadProgress('Saving property...');

      final rentAmount = _parseRentAmount();

      debugPrint('🏠 Property data:');
      debugPrint('   - Title: ${_titleController.text.trim()}');
      debugPrint('   - Type: $_propertyType');
      debugPrint('   - Rent: $rentAmount');
      debugPrint('   - Images: ${imageUrls.length}');
      debugPrint('   - Address: ${_addressController.text.trim()}');
      debugPrint('   - City: ${_cityController.text.trim()}');
      debugPrint('   - State: ${_stateController.text.trim()}');
      debugPrint('   - Inspection Handler: $_inspectionHandler');
      debugPrint('   - Inspection Days: $_availableDays');
      debugPrint('   - Inspection Time Slots: $_availableTimeSlots');

      final propertyId = await _propertyService.createProperty(
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        propertyType: _propertyType,
        bedrooms: _bedrooms,
        bathrooms: _bathrooms,
        toilets: _toilets,
        imageUrls: imageUrls,
        address: _addressController.text.trim(),
        city: _cityController.text.trim(),
        state: _stateController.text.trim(),
        latitude: _latitude,
        longitude: _longitude,
        rent: rentAmount,
        rentFrequency: _rentPeriod,
        amenities: _selectedAmenities,
        rules: _selectedRules,
        inspectionHandler: _inspectionHandler,
        inspectionDays: _availableDays,
        inspectionTimeSlots: _availableTimeSlots,
      );

      if (!mounted) return;

      Navigator.pop(context); // Close progress dialog

      debugPrint('🏠 Property creation result: $propertyId');

      if (propertyId == null) {
        _showError('Failed to save property. Please try again.');
        setState(() => _isPublishing = false);
        return;
      }

      debugPrint('✅ Property created successfully with ID: $propertyId');

      // If agent inspection selected, show agent selection prompt
      if (_inspectionHandler == 'agent') {
        _showAgentSelectionPrompt(propertyId);
      } else {
        _showSuccessDialog();
      }
    } catch (e, stackTrace) {
      if (mounted) {
        Navigator.pop(context); // Close progress dialog
      }
      debugPrint('❌ Publish error: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      _showError('Something went wrong: ${e.toString()}');
      setState(() => _isPublishing = false);
    }
  }

  void _showUploadProgress(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            Text(message, style: AppTextStyles.bodyMedium),
          ],
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  void _updateUploadProgress(String message) {
    Navigator.pop(context);
    _showUploadProgress(message);
  }

  void _showAgentSelectionPrompt(String propertyId) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.support_agent,
                size: 40,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Property Listed!',
              style: AppTextStyles.h3,
            ),
            const SizedBox(height: 8),
            Text(
              'Now let\'s assign a verified agent to handle property inspections.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: 'Choose Agent',
                onPressed: () {
                  Navigator.pop(context);
                  context.push('/landlord/select-agent', extra: {
                    'propertyId': propertyId,
                    'propertyCity': _cityController.text.trim(),
                  });
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.go('/landlord/home');
                },
                child: Text(
                  'I\'ll do this later',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.successLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check,
                size: 40,
                color: AppColors.success,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Property Listed!',
              style: AppTextStyles.h3,
            ),
            const SizedBox(height: 8),
            Text(
              'Your property is now live and visible to tenants. You\'ll handle inspections yourself.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: 'View My Properties',
                onPressed: () {
                  Navigator.pop(context);
                  context.go('/landlord/home');
                },
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  // ============ FIXED: Direct gallery picker ============
  Future<void> _pickFromGallery() async {
    try {
      debugPrint('📸 Opening gallery picker...');
      
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        debugPrint('📸 Image selected: ${image.path}');
        setState(() {
          _selectedImageFiles.add(File(image.path));
        });
      } else {
        debugPrint('📸 No image selected');
      }
    } catch (e) {
      debugPrint('❌ Gallery picker error: $e');
      _showError('Failed to pick image. Please try again.');
    }
  }

  // ============ FIXED: Direct camera capture ============
  Future<void> _takePhoto() async {
    try {
      debugPrint('📷 Opening camera...');
      
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        debugPrint('📷 Photo taken: ${image.path}');
        setState(() {
          _selectedImageFiles.add(File(image.path));
        });
      } else {
        debugPrint('📷 Camera cancelled');
      }
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      _showError('Failed to take photo. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show loading while checking verification
    if (_isCheckingVerification) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: Text('Add Property', style: AppTextStyles.h4),
          centerTitle: true,
        ),
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _previousStep();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: AppColors.textPrimary),
            onPressed: _showExitConfirmation,
          ),
          title: Text(
            'Add Property',
            style: AppTextStyles.h4,
          ),
          centerTitle: true,
        ),
        body: Column(
          children: [
            _buildProgressIndicator(),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildPhotosStep(),
                  _buildLocationStep(),
                  _buildDetailsStep(),
                  _buildPricingStep(),
                  _buildPreviewStep(),
                ],
              ),
            ),
            _buildBottomButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Container(
      padding: const EdgeInsets.all(20),
      color: AppColors.surface,
      child: Column(
        children: [
          Row(
            children: List.generate(_totalSteps, (index) {
              final isCompleted = index < _currentStep;
              final isCurrent = index == _currentStep;

              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: index < _totalSteps - 1 ? 8 : 0),
                  height: 4,
                  decoration: BoxDecoration(
                    color: isCompleted || isCurrent
                        ? AppColors.primary
                        : AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _getStepTitle(_currentStep),
                style: AppTextStyles.labelLarge,
              ),
              Text(
                'Step ${_currentStep + 1} of $_totalSteps',
                style: AppTextStyles.caption,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getStepTitle(int step) {
    switch (step) {
      case 0:
        return 'Photos';
      case 1:
        return 'Location';
      case 2:
        return 'Details';
      case 3:
        return 'Pricing';
      case 4:
        return 'Preview';
      default:
        return '';
    }
  }

  Widget _buildPhotosStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add photos of your property',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'Add at least 1 photo. Properties with more photos get more inquiries.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),

          // Selected images
          if (_selectedImageFiles.isNotEmpty) ...[
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _selectedImageFiles.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final item = _selectedImageFiles.removeAt(oldIndex);
                  _selectedImageFiles.insert(newIndex, item);
                });
              },
              itemBuilder: (context, index) {
                return Container(
                  key: ValueKey(_selectedImageFiles[index].path),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          _selectedImageFiles[index],
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                      if (index == 0)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Cover Photo',
                              style: AppTextStyles.labelSmall.copyWith(
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      // Delete button
                      Positioned(
                        top: 8,
                        right: 8,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedImageFiles.removeAt(index);
                            });
                          },
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(128),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                      // Drag handle
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(128),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(
                            Icons.drag_handle,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],

          // Add photo buttons - FIXED: Now directly call gallery/camera
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickFromGallery, // Direct call to gallery
                  child: Container(
                    height: 100,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.primary,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(26),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.photo_library_outlined,
                            color: AppColors.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Gallery',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: _takePhoto, // Direct call to camera
                  child: Container(
                    height: 100,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.border,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.textHint.withAlpha(26),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt_outlined,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Camera',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Text(
            'Tip: Drag photos to reorder. First photo will be the cover.',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textHint,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Where is your property?',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'Search for an address or tap the map to adjust the pin.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),

          // Location picker with autocomplete and map
          LocationPickerWidget(
            addressController: _addressController,
            cityController: _cityController,
            stateController: _stateController,
            onLocationSelected: (lat, lng) {
              setState(() {
                _latitude = lat;
                _longitude = lng;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Property details',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 24),

          // Title
          AppTextField(
            label: 'Property Title',
            hint: 'e.g. Spacious 3 Bedroom Flat',
            controller: _titleController,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 20),

          // Property Type
          Text(
            'Property Type',
            style: AppTextStyles.labelMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTypeChip('Flat', 'flat'),
              _buildTypeChip('Duplex', 'duplex'),
              _buildTypeChip('Self Contain', 'selfContain'),
              _buildTypeChip('Bungalow', 'bungalow'),
              _buildTypeChip('Room', 'room'),
              _buildTypeChip('Shop', 'shop'),
              _buildTypeChip('Office', 'office'),
            ],
          ),
          const SizedBox(height: 24),

          // Bedrooms, Bathrooms, Toilets
          Row(
            children: [
              Expanded(child: _buildCounter('Bedrooms', _bedrooms, (v) => setState(() => _bedrooms = v))),
              const SizedBox(width: 12),
              Expanded(child: _buildCounter('Bathrooms', _bathrooms, (v) => setState(() => _bathrooms = v))),
              const SizedBox(width: 12),
              Expanded(child: _buildCounter('Toilets', _toilets, (v) => setState(() => _toilets = v))),
            ],
          ),
          const SizedBox(height: 24),

          // Description
          AppTextField(
            label: 'Description',
            hint: 'Describe your property, its features, and what makes it special...',
            controller: _descriptionController,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 24),

          // Amenities
          Text(
            'Amenities',
            style: AppTextStyles.labelMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _amenitiesList.map((amenity) {
              final isSelected = _selectedAmenities.contains(amenity);
              return FilterChip(
                label: Text(amenity),
                selected: isSelected,
                onSelected: (_) {
                  setState(() {
                    if (isSelected) {
                      _selectedAmenities.remove(amenity);
                    } else {
                      _selectedAmenities.add(amenity);
                    }
                  });
                },
                backgroundColor: AppColors.surface,
                selectedColor: AppColors.primary.withAlpha(26),
                checkmarkColor: AppColors.primary,
                labelStyle: AppTextStyles.labelMedium.copyWith(
                  color: isSelected ? AppColors.primary : AppColors.textSecondary,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: isSelected ? AppColors.primary : AppColors.border,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),

          // House Rules
          Text(
            'House Rules (Optional)',
            style: AppTextStyles.labelMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _rulesList.map((rule) {
              final isSelected = _selectedRules.contains(rule);
              return FilterChip(
                label: Text(rule),
                selected: isSelected,
                onSelected: (_) {
                  setState(() {
                    if (isSelected) {
                      _selectedRules.remove(rule);
                    } else {
                      _selectedRules.add(rule);
                    }
                  });
                },
                backgroundColor: AppColors.surface,
                selectedColor: AppColors.warning.withAlpha(26),
                checkmarkColor: AppColors.warning,
                labelStyle: AppTextStyles.labelMedium.copyWith(
                  color: isSelected ? AppColors.warning : AppColors.textSecondary,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: isSelected ? AppColors.warning : AppColors.border,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildTypeChip(String label, String value) {
    final isSelected = _propertyType == value;
    return GestureDetector(
      onTap: () => setState(() => _propertyType = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: AppTextStyles.labelMedium.copyWith(
            color: isSelected ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildCounter(String label, int value, Function(int) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () {
                  if (value > 0) onChanged(value - 1);
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.remove, size: 18),
                ),
              ),
              Text(
                '$value',
                style: AppTextStyles.labelLarge,
              ),
              GestureDetector(
                onTap: () => onChanged(value + 1),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(
                    Icons.add,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPricingStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set your price',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'Be transparent with your pricing. Tenants love clarity.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),

          // Rent amount with comma formatting
          Text(
            'Rent Amount (NGN)',
            style: AppTextStyles.labelMedium,
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: TextField(
              controller: _rentController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                ThousandsSeparatorInputFormatter(),
              ],
              style: AppTextStyles.h4.copyWith(color: AppColors.primary),
              decoration: InputDecoration(
                hintText: '0',
                hintStyle: AppTextStyles.h4.copyWith(color: AppColors.textHint),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 8),
                  child: Text(
                    '₦',
                    style: AppTextStyles.h4.copyWith(color: AppColors.primary),
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Rent period
          Text(
            'Rent Period',
            style: AppTextStyles.labelMedium,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildPeriodChip('Per Year', 'yearly'),
              const SizedBox(width: 12),
              _buildPeriodChip('Per Month', 'monthly'),
            ],
          ),
          const SizedBox(height: 32),

          // Inspection handling section
          _buildInspectionHandlerSection(),

          const SizedBox(height: 24),

          // Inspection availability section
          _buildInspectionAvailabilitySection(),

          const SizedBox(height: 24),

          // Platform fee info
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.successLight.withAlpha(128),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.success.withAlpha(77)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  color: AppColors.success,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Free to list! ClearRent only charges when rent is paid through the platform.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectionHandlerSection() {
    return Container(
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
            'Who handles property inspections?',
            style: AppTextStyles.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'When tenants show interest, who will conduct property viewings?',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),

          // Self option
          GestureDetector(
            onTap: () => setState(() => _inspectionHandler = 'self'),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _inspectionHandler == 'self'
                    ? AppColors.primary.withAlpha(13)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _inspectionHandler == 'self'
                      ? AppColors.primary
                      : AppColors.border,
                  width: _inspectionHandler == 'self' ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _inspectionHandler == 'self'
                          ? AppColors.primary.withAlpha(26)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.person,
                      color: _inspectionHandler == 'self'
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'I\'ll handle it myself',
                          style: AppTextStyles.labelLarge.copyWith(
                            color: _inspectionHandler == 'self'
                                ? AppColors.primary
                                : AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'You\'ll be notified when tenants want to view',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'FREE',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_inspectionHandler == 'self') ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.check_circle,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Agent option
          GestureDetector(
            onTap: () => setState(() => _inspectionHandler = 'agent'),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _inspectionHandler == 'agent'
                    ? AppColors.primary.withAlpha(13)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _inspectionHandler == 'agent'
                      ? AppColors.primary
                      : AppColors.border,
                  width: _inspectionHandler == 'agent' ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _inspectionHandler == 'agent'
                          ? AppColors.primary.withAlpha(26)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.support_agent,
                      color: _inspectionHandler == 'agent'
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Assign a verified agent',
                          style: AppTextStyles.labelLarge.copyWith(
                            color: _inspectionHandler == 'agent'
                                ? AppColors.primary
                                : AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Agent handles viewings on your behalf',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.info.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'PAID',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.info,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_inspectionHandler == 'agent') ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.check_circle,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Info about agent fees
          if (_inspectionHandler == 'agent') ...[
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
                    size: 18,
                    color: AppColors.info,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Agent inspection fees are calculated based on distance. You\'ll select an agent after listing your property.',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.info,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInspectionAvailabilitySection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                'Inspection Availability',
                style: AppTextStyles.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Set when you\'re available for property inspections',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),

          // Available days
          Text('Available Days', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _weekDays.map((day) {
              final isSelected = _availableDays.contains(day);
              return GestureDetector(
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      _availableDays.remove(day);
                    } else {
                      _availableDays.add(day);
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.background,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  child: Text(
                    day.substring(0, 3), // Mon, Tue, etc.
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isSelected ? AppColors.primary : AppColors.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),

          // Available time slots
          Text('Preferred Time Slots', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          ...(_timeSlotOptions.map((slot) {
            final isSelected = _availableTimeSlots.contains(slot['id']);
            return GestureDetector(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _availableTimeSlots.remove(slot['id']);
                  } else {
                    _availableTimeSlots.add(slot['id']!);
                  }
                });
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary.withAlpha(13) : AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.border,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: isSelected ? AppColors.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isSelected ? AppColors.primary : AppColors.border,
                          width: 2,
                        ),
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, size: 14, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(slot['label']!, style: AppTextStyles.labelMedium),
                          Text(
                            slot['time']!,
                            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList()),

          // Tip
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.infoLight.withAlpha(128),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.lightbulb_outline, size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tenants will only be able to request inspections during these times',
                    style: AppTextStyles.caption.copyWith(color: AppColors.info),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodChip(String label, String value) {
    final isSelected = _rentPeriod == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _rentPeriod = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.border,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: AppTextStyles.labelMedium.copyWith(
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewStep() {
    final rent = _parseRentAmount();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview your listing',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'Review everything before publishing.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),

          // Cover image
          if (_selectedImageFiles.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                _selectedImageFiles.first,
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),

          const SizedBox(height: 16),

          // Title and price
          Text(
            _titleController.text.isNotEmpty ? _titleController.text : 'Property Title',
            style: AppTextStyles.h3,
          ),
          const SizedBox(height: 8),
          Text(
            '₦${_formatAmount(rent)}/${_rentPeriod == 'yearly' ? 'year' : 'month'}',
            style: AppTextStyles.h4.copyWith(color: AppColors.primary),
          ),
          const SizedBox(height: 8),

          // Location
          Row(
            children: [
              const Icon(Icons.location_on, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${_addressController.text}, ${_cityController.text}, ${_stateController.text}',
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Details summary
          _buildPreviewSection('Property Type', _propertyType.toUpperCase()),
          _buildPreviewSection('Bedrooms', '$_bedrooms'),
          _buildPreviewSection('Bathrooms', '$_bathrooms'),
          _buildPreviewSection('Toilets', '$_toilets'),
          _buildPreviewSection(
            'Inspections',
            _inspectionHandler == 'self' ? 'Handled by you' : 'Assigned agent',
          ),

          // Inspection availability
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(13),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.primary.withAlpha(51)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.calendar_month, size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text('Inspection Availability', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Days: ${_availableDays.map((d) => d.substring(0, 3)).join(", ")}',
                  style: AppTextStyles.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Times: ${_availableTimeSlots.map((s) => _timeSlotOptions.firstWhere((t) => t["id"] == s)["label"]).join(", ")}',
                  style: AppTextStyles.bodySmall,
                ),
              ],
            ),
          ),

          if (_selectedAmenities.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Amenities', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _selectedAmenities.map((a) => Chip(
                label: Text(a, style: AppTextStyles.caption),
                backgroundColor: AppColors.primaryLight.withAlpha(26),
              )).toList(),
            ),
          ],

          const SizedBox(height: 24),

          // Fee info
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
                Text('Pricing Summary', style: AppTextStyles.labelLarge),
                const SizedBox(height: 16),
                _buildFeeRow('Rent Amount', rent),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'ClearRent Fee',
                      style: AppTextStyles.bodyMedium,
                    ),
                    Text(
                      'Charged when rent is paid',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                if (_inspectionHandler == 'agent') ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Agent Inspection Fee',
                        style: AppTextStyles.bodyMedium,
                      ),
                      Text(
                        'Based on distance',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildPreviewSection(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
          Text(value, style: AppTextStyles.labelLarge),
        ],
      ),
    );
  }

  Widget _buildFeeRow(String label, double amount, {bool isTotal = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: isTotal ? AppTextStyles.labelLarge : AppTextStyles.bodyMedium,
        ),
        Text(
          '₦${_formatAmount(amount)}',
          style: isTotal
              ? AppTextStyles.h4.copyWith(color: AppColors.primary)
              : AppTextStyles.labelLarge,
        ),
      ],
    );
  }

  String _formatAmount(double amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(2)}M';
    }
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) {
        result.add(',');
      }
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  Widget _buildBottomButtons() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).padding.bottom + 16,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(13),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _previousStep,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  'Back',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          if (_currentStep > 0) const SizedBox(width: 12),
          Expanded(
            flex: 1,
            child: AppButton(
              text: _currentStep == _totalSteps - 1 ? 'Publish Property' : 'Continue',
              onPressed: _currentStep == _totalSteps - 1 ? _publishProperty : _nextStep,
              isLoading: _isPublishing,
            ),
          ),
        ],
      ),
    );
  }
}