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

class AddPropertyScreen extends StatefulWidget {
  const AddPropertyScreen({super.key});

  @override
  State<AddPropertyScreen> createState() => _AddPropertyScreenState();
}

class _AddPropertyScreenState extends State<AddPropertyScreen> {
  final PageController _pageController = PageController();
  final PropertyService _propertyService = PropertyService();
  final ImagePicker _imagePicker = ImagePicker();
  
  int _currentStep = 0;
  final int _totalSteps = 5;
  bool _isPublishing = false;

  final List<File> _selectedImageFiles = [];
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _rentController = TextEditingController();
  final _agentFeeController = TextEditingController();

  double? _latitude;
  double? _longitude;

  String _propertyType = 'flat';
  int _bedrooms = 1;
  int _bathrooms = 1;
  int _toilets = 1;
  String _rentPeriod = 'yearly';
  bool _hasAgent = false;
  String _agentFeePaidBy = 'tenant';
  final List<String> _selectedAmenities = [];
  final List<String> _selectedRules = [];

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
  void dispose() {
    _pageController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    _rentController.dispose();
    _agentFeeController.dispose();
    super.dispose();
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
        if (_hasAgent && _agentFeeController.text.isEmpty) {
          _showError('Please enter the agent fee percentage');
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
      _showUploadProgress('Uploading images...');
      
      final imageUrls = await _propertyService.uploadImages(_selectedImageFiles);
      
      if (!mounted) return;
      
      if (imageUrls.isEmpty) {
        Navigator.pop(context); // Close progress dialog
        _showError('Failed to upload images. Please try again.');
        setState(() => _isPublishing = false);
        return;
      }

      // Step 2: Create property in Firestore
      _updateUploadProgress('Saving property...');

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
        latitude: _latitude,      // ADD THIS
        longitude: _longitude,    // ADD THIS
        rent: double.tryParse(_rentController.text) ?? 0.0,
        rentFrequency: _rentPeriod,
        agentFee: _hasAgent ? (double.tryParse(_agentFeeController.text) ?? 0.0) : 0.0,
        agentFeePaidBy: _agentFeePaidBy,
        amenities: _selectedAmenities,
        rules: _selectedRules,
      );

      if (!mounted) return;

      Navigator.pop(context); // Close progress dialog

      if (propertyId == null) {
        _showError('Failed to save property. Please try again.');
        setState(() => _isPublishing = false);
        return;
      }

      // Success!
      _showSuccessDialog();
    } catch (e) {
      Navigator.pop(context); // Close progress dialog
      debugPrint('❌ Publish error: $e');
      _showError('Something went wrong. Please try again.');
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
              'Your property is now live and visible to tenants.',
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

  Future<void> _pickImages() async {
    try {
      final List<XFile> images = await _imagePicker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (images.isNotEmpty) {
        setState(() {
          for (final image in images) {
            _selectedImageFiles.add(File(image.path));
          }
        });
      }
    } catch (e) {
      debugPrint('❌ Image picker error: $e');
      _showError('Failed to pick images');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _selectedImageFiles.add(File(image.path));
        });
      }
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      _showError('Failed to take photo');
    }
  }

  @override
  Widget build(BuildContext context) {
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

          // Add photo buttons
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickImages,
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
                  onTap: _takePhoto,
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

          // Rent amount
          AppTextField(
            label: 'Rent Amount (NGN)',
            hint: 'e.g. 500000',
            controller: _rentController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
          const SizedBox(height: 24),

          // Agent toggle
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Using an Agent?',
                            style: AppTextStyles.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Enable if an agent is handling this property',
                            style: AppTextStyles.caption,
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _hasAgent,
                      onChanged: (v) => setState(() => _hasAgent = v),
                      activeColor: AppColors.primary,
                    ),
                  ],
                ),

                if (_hasAgent) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 16),

                  AppTextField(
                    label: 'Agent Fee (%)',
                    hint: 'e.g. 10',
                    controller: _agentFeeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(height: 16),

                  Text(
                    'Who pays the agent fee?',
                    style: AppTextStyles.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _agentFeePaidBy = 'tenant'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: _agentFeePaidBy == 'tenant'
                                  ? AppColors.primary.withAlpha(26)
                                  : AppColors.background,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _agentFeePaidBy == 'tenant'
                                    ? AppColors.primary
                                    : AppColors.border,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'Tenant',
                                style: AppTextStyles.labelMedium.copyWith(
                                  color: _agentFeePaidBy == 'tenant'
                                      ? AppColors.primary
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _agentFeePaidBy = 'landlord'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: _agentFeePaidBy == 'landlord'
                                  ? AppColors.primary.withAlpha(26)
                                  : AppColors.background,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _agentFeePaidBy == 'landlord'
                                    ? AppColors.primary
                                    : AppColors.border,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'Landlord',
                                style: AppTextStyles.labelMedium.copyWith(
                                  color: _agentFeePaidBy == 'landlord'
                                      ? AppColors.primary
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Platform fee info - UPDATED
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
    final rent = double.tryParse(_rentController.text) ?? 0.0;
    final agentFee = _hasAgent ? (double.tryParse(_agentFeeController.text) ?? 0.0) : 0.0;
    final agentAmount = _hasAgent && _agentFeePaidBy == 'tenant' ? rent * agentFee / 100 : 0.0;
    final total = rent + agentAmount;

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
            'NGN ${_formatAmount(rent)}/${_rentPeriod == 'yearly' ? 'year' : 'month'}',
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

          // Fee breakdown
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
                Text('Fee Breakdown (Tenant View)', style: AppTextStyles.labelLarge),
                const SizedBox(height: 16),
                _buildFeeRow('Rent to Landlord', rent),
                if (_hasAgent && _agentFeePaidBy == 'tenant') ...[
                  const SizedBox(height: 8),
                  _buildFeeRow('Agent Fee ($agentFee%)', agentAmount),
                ],
                const Divider(height: 24),
                _buildFeeRow('Total First Payment', total, isTotal: true),
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
          'NGN ${_formatAmount(amount)}',
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