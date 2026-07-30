import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../widgets/clearrent_location_picker.dart';
import '../../../../shared/widgets/area_dropdown.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../services/property_service.dart';
import '../../../../services/building_service.dart';
import '../../../../shared/models/building_model.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/paystack_service.dart';
import '../../../../services/pricing_service.dart';
import '../../../../services/agent_service.dart';
import '../../../../services/property_draft_service.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/screens/paystack_checkout_screen.dart';

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

class _AddPropertyScreenState extends State<AddPropertyScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final PageController _pageController = PageController();
  final ScrollController _pricingScrollController = ScrollController();
  final ScrollController _detailsScrollController = ScrollController();
  final GlobalKey _agentSectionKey = GlobalKey();
  final PropertyService _propertyService = PropertyService();
  final VerificationService _verificationService = VerificationService();
  final ImagePicker _imagePicker = ImagePicker();

  int _currentStep = 0;
  final int _totalSteps = 5;
  bool _isPublishing = false;
  bool _isCheckingVerification = true;
  bool _isRestoringDraft = false;
  Timer? _draftSaveTimer;

  // Listing fee state. Read from the remote schedule (config/pricing) so the
  // price can change without a Play Store release; PricingService falls back to
  // the compiled-in value when config is unreachable. The server charges from
  // the same document, so displaying a stale number would bill a different one.
  int get _listingFeeAmount => PricingService().current.listing.round();
  bool _requiresListingFee = false;
  String? _listingFeePaymentReference;

  final List<File> _selectedImageFiles = [];
  File? _selectedVideoFile;
  VideoPlayerController? _videoPreviewController;
  bool _isValidatingVideo = false;

  // Ceiling type
  String? _ceilingType;

  // Recurring dues
  final Map<String, TextEditingController> _duesControllers = {};
  final Map<String, bool> _duesEnabled = {};
  final Map<String, String> _duesFrequency = {};
  final List<Map<String, String>> _customDues =
      []; // [{name: '', controllerId: 'custom_0'}]
  int _customDueCounter = 0;

  static const List<Map<String, String>> _predefinedDues = [
    {'id': 'security', 'name': 'Security/CDA', 'icon': 'security'},
    {'id': 'psb', 'name': 'PSB/Community', 'icon': 'groups'},
    {'id': 'waste', 'name': 'Waste Management', 'icon': 'delete'},
    {'id': 'light', 'name': 'Light/NEPA', 'icon': 'bolt'},
    {'id': 'water', 'name': 'Water', 'icon': 'water_drop'},
    {
      'id': 'estate',
      'name': 'Estate Maintenance',
      'icon': 'home_repair_service',
    },
  ];

  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _rentController = TextEditingController();
  final _agentFeeController = TextEditingController();
  final _cautionDepositController = TextEditingController();

  // Controllers for landlord's own location (when they don't live in the property)
  final _landlordAddressController = TextEditingController();
  final _landlordCityController = TextEditingController();
  final _landlordStateController = TextEditingController();

  double? _latitude;
  double? _longitude;

  String _propertyType = '';
  int _bedrooms = 1;
  int _bathrooms = 1;
  int _toilets = 1;
  int _livingRooms = 1;
  int _guestRooms = 0;
  int _kitchens = 1;
  int _maxTenants = 1;
  String _rentPeriod = 'yearly';
  final List<String> _selectedAmenities = [];
  final List<String> _selectedRules = [];

  bool _titleManuallyEdited = false;
  bool _descriptionManuallyEdited = false;

  // New inspection handling model
  String _inspectionHandler = 'self'; // 'self' or 'agent'
  bool _landlordLivesInProperty = false;
  bool _includeAgentFee = false; // Agent fee is optional
  // Whether the caution deposit comes back to the tenant at move-out. Defaults
  // true because that is what the listing copy has always promised.
  bool _cautionDepositRefundable = true;

  // Selected agent (required when _inspectionHandler == 'agent')
  String? _selectedAgentId;
  String? _selectedAgentName;

  // ── Occupancy info ──
  final bool _landlordLivesOnPremises = false;

  bool _hasCaretaker = false;
  bool _caretakerLivesOnPremises = false;

  // Landlord's residence location (if they live elsewhere)
  double? _landlordBaseLatitude;
  double? _landlordBaseLongitude;
  String? _landlordBaseArea; // Selected from AreaDropdown

  // Inspection availability
  final List<String> _availableDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];
  final List<String> _availableTimeSlots = ['morning', 'afternoon'];

  // Ownership document
  File? _ownershipDocFile;
  String? _ownershipDocType; // 'c_of_o' | 'deed' | 'other'

  // Building / compound grouping. When [_isInBuilding] the unit inherits a
  // building's shared ownership doc instead of uploading its own:
  //   - join existing → [_selectedBuildingId] set, [_creatingNewBuilding] false
  //   - create new    → [_creatingNewBuilding] true, name/address + the
  //     ownership-doc picker above feed BuildingService.createBuilding
  final BuildingService _buildingService = BuildingService();
  // Cached so the form's frequent setState()s don't recreate this stream and
  // flash the building picker.
  late final Stream<List<BuildingModel>> _landlordBuildingsStream =
      _buildingService.streamLandlordBuildings();
  bool _isInBuilding = false;
  bool _creatingNewBuilding = false;
  String? _selectedBuildingId;
  final TextEditingController _buildingNameController = TextEditingController();
  final TextEditingController _buildingAddressController =
      TextEditingController();

  final List<String> _weekDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  final List<Map<String, String>> _timeSlotOptions = [
    {'id': 'morning', 'label': 'Morning', 'time': '9:00 AM - 12:00 PM'},
    {'id': 'afternoon', 'label': 'Afternoon', 'time': '12:00 PM - 3:00 PM'},
    {
      'id': 'late_afternoon',
      'label': 'Late Afternoon',
      'time': '3:00 PM - 6:00 PM',
    },
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
    // Listen to price field changes for real-time total preview
    _rentController.addListener(_onPriceFieldChanged);
    _agentFeeController.addListener(_onPriceFieldChanged);
    _cautionDepositController.addListener(_onPriceFieldChanged);
    // Initialize dues controllers
    for (final due in _predefinedDues) {
      _duesControllers[due['id']!] = TextEditingController();
      _duesEnabled[due['id']!] = false;
      _duesFrequency[due['id']!] = 'yearly';
    }
    _checkForDraft();
  }

  void _onPriceFieldChanged() {
    // Trigger rebuild so the total package preview updates in real-time
    if (mounted) setState(() {});
    _saveDraftDebounced();
  }

  /// Check if a draft exists and offer to restore it
  Future<void> _checkForDraft() async {
    final draft = await PropertyDraftService.loadDraft();
    if (draft != null && mounted) {
      _showDraftFoundDialog(draft);
    }
  }

  void _showDraftFoundDialog(Map<String, dynamic> draft) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
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
                  child: Icon(
                    Icons.restore,
                    size: 40,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Resume Draft?',
                  style: AppTextStyles.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'You have an unfinished property listing. Would you like to continue where you left off?',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    text: 'Continue Editing',
                    onPressed: () {
                      Navigator.pop(context);
                      _restoreDraft(draft);
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await PropertyDraftService.clearDraft();
                  },
                  child: Text(
                    'Start Fresh',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  /// Serialize the current form state into a map
  Map<String, dynamic> _collectFormState() {
    return {
      'step': _currentStep,
      'propertyType': _propertyType,
      'bedrooms': _bedrooms,
      'bathrooms': _bathrooms,
      'toilets': _toilets,
      'livingRooms': _livingRooms,
      'guestRooms': _guestRooms,
      'kitchens': _kitchens,
      'maxTenants': _maxTenants,
      'rentPeriod': _rentPeriod,
      'title': _titleController.text,
      'description': _descriptionController.text,
      'titleManuallyEdited': _titleManuallyEdited,
      'descriptionManuallyEdited': _descriptionManuallyEdited,
      'rent': _rentController.text,
      'agentFee': _agentFeeController.text,
      'cautionDeposit': _cautionDepositController.text,
      'cautionDepositRefundable': _cautionDepositRefundable,
      'includeAgentFee': _includeAgentFee,
      'address': _addressController.text,
      'city': _cityController.text,
      'state': _stateController.text,
      'latitude': _latitude,
      'longitude': _longitude,
      'amenities': _selectedAmenities,
      'rules': _selectedRules,
      'inspectionHandler': _inspectionHandler,
      'landlordLivesInProperty': _landlordLivesInProperty,
      'landlordBaseArea': _landlordBaseArea,
      'landlordCity': _landlordCityController.text,
      'selectedAgentId': _selectedAgentId,
      'selectedAgentName': _selectedAgentName,
      'availableDays': _availableDays,
      'availableTimeSlots': _availableTimeSlots,
      'hasCaretaker': _hasCaretaker,
      'caretakerLivesOnPremises': _caretakerLivesOnPremises,
      'ownershipDocType': _ownershipDocType,
      'ceilingType': _ceilingType,
      // Building / compound grouping
      'isInBuilding': _isInBuilding,
      'creatingNewBuilding': _creatingNewBuilding,
      'selectedBuildingId': _selectedBuildingId,
      'buildingName': _buildingNameController.text,
      'buildingAddress': _buildingAddressController.text,
      // Image paths (not the File objects)
      'imagePaths': _selectedImageFiles.map((f) => f.path).toList(),
      // Save timestamp so we can show "Draft from X minutes ago"
      'savedAt': DateTime.now().toIso8601String(),
    };
  }

  /// Restore form state from a draft map
  void _restoreDraft(Map<String, dynamic> draft) {
    setState(() => _isRestoringDraft = true);

    try {
      // Text controllers
      _titleController.text = draft['title'] ?? '';
      _descriptionController.text = draft['description'] ?? '';
      _rentController.text = draft['rent'] ?? '';
      _agentFeeController.text = draft['agentFee'] ?? '';
      _cautionDepositController.text = draft['cautionDeposit'] ?? '';
      _cautionDepositRefundable = draft['cautionDepositRefundable'] ?? true;
      _addressController.text = draft['address'] ?? '';
      _cityController.text = draft['city'] ?? '';
      _stateController.text = draft['state'] ?? '';
      _landlordCityController.text = draft['landlordCity'] ?? '';

      // Booleans and values
      _propertyType = draft['propertyType'] ?? '';
      _bedrooms = draft['bedrooms'] ?? 1;
      _bathrooms = draft['bathrooms'] ?? 1;
      _toilets = draft['toilets'] ?? 1;
      _livingRooms = draft['livingRooms'] ?? 1;
      _guestRooms = draft['guestRooms'] ?? 0;
      _kitchens = draft['kitchens'] ?? 1;
      _maxTenants = draft['maxTenants'] ?? 1;
      _rentPeriod = 'yearly';
      _titleManuallyEdited = draft['titleManuallyEdited'] ?? false;
      _descriptionManuallyEdited = draft['descriptionManuallyEdited'] ?? false;
      _includeAgentFee = draft['includeAgentFee'] ?? false;
      _inspectionHandler = draft['inspectionHandler'] ?? 'self';
      _landlordLivesInProperty = draft['landlordLivesInProperty'] ?? false;
      _landlordBaseArea = draft['landlordBaseArea'];
      _selectedAgentId = draft['selectedAgentId'];
      _selectedAgentName = draft['selectedAgentName'];

      _hasCaretaker = draft['hasCaretaker'] ?? false;
      _caretakerLivesOnPremises = draft['caretakerLivesOnPremises'] ?? false;
      _ownershipDocType = draft['ownershipDocType'];
      _ceilingType = draft['ceilingType'] as String?;
      _latitude = draft['latitude'] as double?;
      _longitude = draft['longitude'] as double?;

      // Building / compound grouping
      _isInBuilding = draft['isInBuilding'] ?? false;
      _creatingNewBuilding = draft['creatingNewBuilding'] ?? false;
      _selectedBuildingId = draft['selectedBuildingId'] as String?;
      _buildingNameController.text = draft['buildingName'] ?? '';
      _buildingAddressController.text = draft['buildingAddress'] ?? '';

      // Lists
      _selectedAmenities.clear();
      _selectedAmenities.addAll(List<String>.from(draft['amenities'] ?? []));
      _selectedRules.clear();
      _selectedRules.addAll(List<String>.from(draft['rules'] ?? []));
      _availableDays.clear();
      _availableDays.addAll(
        List<String>.from(
          draft['availableDays'] ??
              [
                'Monday',
                'Tuesday',
                'Wednesday',
                'Thursday',
                'Friday',
                'Saturday',
              ],
        ),
      );
      _availableTimeSlots.clear();
      _availableTimeSlots.addAll(
        List<String>.from(
          draft['availableTimeSlots'] ?? ['morning', 'afternoon'],
        ),
      );

      // Image file paths — only restore if files still exist
      final imagePaths = List<String>.from(draft['imagePaths'] ?? []);
      _selectedImageFiles.clear();
      for (final path in imagePaths) {
        final file = File(path);
        if (file.existsSync()) {
          _selectedImageFiles.add(file);
        }
      }

      // Jump to the saved step
      final savedStep = draft['step'] ?? 0;
      _currentStep = savedStep;
      // Use jumpToPage (not animateToPage) since we're in initState flow
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _pageController.jumpToPage(savedStep);
        }
      });
    } catch (e) {
      debugPrint('❌ Error restoring draft: $e');
    }

    setState(() => _isRestoringDraft = false);
  }

  /// Save draft with debounce (called on field changes)
  void _saveDraftDebounced() {
    if (_isRestoringDraft) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(seconds: 2), () {
      PropertyDraftService.saveDraft(_collectFormState());
    });
  }

  /// Save draft immediately (called on step changes)
  void _saveDraftNow() {
    if (_isRestoringDraft) return;
    _draftSaveTimer?.cancel();
    PropertyDraftService.saveDraft(_collectFormState());
  }

  /// Check if landlord is verified before allowing property listing,
  /// and whether they need to pay the ₦10,000 subsequent listing fee.
  Future<void> _checkVerificationStatus() async {
    try {
      final data = await _verificationService.getVerificationStatus();

      if (!mounted) return;

      final isVerified =
          data.status == VerificationStatus.verified || data.isVerified;
      if (!isVerified) {
        _showVerificationRequiredDialog(data.status);
      } else {
        // Verified — check how many properties they've listed
        final count = await _propertyService.getLandlordPropertyCount();
        if (!mounted) return;
        setState(() {
          _requiresListingFee = count > 0; // first listing is free
          _isCheckingVerification = false;
        });
        if (_requiresListingFee) {
          _showListingFeeDialog();
        }
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
        message =
            'You need to verify your identity before listing properties. This helps build trust with tenants and protects everyone on the platform.';
        buttonText = 'Get Verified';
        icon = Icons.verified_user_outlined;
        color = AppColors.primary;
        break;
      case VerificationStatus.pending:
        title = 'Verification Pending';
        message =
            'Your verification is being reviewed. You\'ll be able to list properties once approved. This usually takes 24-48 hours.';
        buttonText = 'Got it';
        icon = Icons.schedule;
        color = AppColors.warning;
        break;
      case VerificationStatus.rejected:
        title = 'Verification Failed';
        message =
            'Your verification was not approved. Please review the feedback and submit again to start listing properties.';
        buttonText = 'Try Again';
        icon = Icons.error_outline;
        color = AppColors.error;
        break;
      case VerificationStatus.expired:
        title = 'Verification Expired';
        message =
            'Your annual verification has expired. Renew it to continue listing properties.';
        buttonText = 'Renew Now';
        icon = Icons.autorenew;
        color = AppColors.warning;
        break;
      case VerificationStatus.verified:
        setState(() => _isCheckingVerification = false);
        return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
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
                Text(
                  title,
                  style: AppTextStyles.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
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
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
    );
  }

  void _showListingFeeDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
                  child: Icon(
                    Icons.receipt_long_outlined,
                    size: 40,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Listing Fee Required',
                  style: AppTextStyles.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your first listing is free. Each additional property listing requires a ₦10,000 fee. Payment will be collected securely via Paystack when you publish.',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // Fee display
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(13),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary.withAlpha(51)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.payment, size: 24, color: AppColors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Listing Fee',
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '₦10,000',
                              style: AppTextStyles.h3.copyWith(
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.lock_outline,
                        size: 18,
                        color: AppColors.success,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(13),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.success.withAlpha(51)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 16,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Secured by Paystack. Pay with card or bank transfer.',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    text: 'Continue to Listing',
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    context.pop();
                  },
                  child: Text(
                    'Cancel',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  @override
  void dispose() {
    _rentController.removeListener(_onPriceFieldChanged);
    _agentFeeController.removeListener(_onPriceFieldChanged);
    _cautionDepositController.removeListener(_onPriceFieldChanged);
    _pageController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    _rentController.dispose();
    _agentFeeController.dispose();
    _cautionDepositController.dispose();
    _landlordAddressController.dispose();
    _landlordCityController.dispose();
    _landlordStateController.dispose();
    _descriptionController.dispose();
    _videoPreviewController?.dispose();
    for (final controller in _duesControllers.values) {
      controller.dispose();
    }
    _pricingScrollController.dispose();
    _detailsScrollController.dispose();
    _buildingNameController.dispose();
    _buildingAddressController.dispose();
    _draftSaveTimer?.cancel();
    super.dispose();
  }

  /// Auto-generate title from property type + bedrooms
  void _updateAutoTitle() {
    if (_titleManuallyEdited) return;
    if (_propertyType.isEmpty) return;

    final typeLabels = {
      'flat': 'Flat',
      'duplex': 'Duplex',
      'selfContain': 'Self Contain',
      'bungalow': 'Bungalow',
      'room': 'Room',
      'shop': 'Shop',
      'office': 'Office',
    };

    final label = typeLabels[_propertyType] ?? 'Property';

    // Shop/Office don't need bedroom count
    if (_propertyType == 'shop' || _propertyType == 'office') {
      _titleController.text = label;
    } else {
      _titleController.text = '$_bedrooms Bedroom $label';
    }
  }

  /// Auto-generate description from property type, bedrooms & amenities
  void _updateAutoDescription() {
    if (_descriptionManuallyEdited) return;
    if (_propertyType.isEmpty) return;

    final typeLabels = {
      'flat': 'flat',
      'duplex': 'duplex',
      'selfContain': 'self contain',
      'bungalow': 'bungalow',
      'room': 'room',
      'shop': 'shop',
      'office': 'office space',
    };

    final label = typeLabels[_propertyType] ?? 'property';
    final buffer = StringBuffer();

    if (_propertyType == 'shop' || _propertyType == 'office') {
      buffer.write('Well-maintained $label');
    } else {
      buffer.write('$_bedrooms bedroom $label');
      if (_bathrooms > 0) {
        buffer.write(' with $_bathrooms bathroom${_bathrooms > 1 ? 's' : ''}');
      }
    }

    if (_selectedAmenities.isNotEmpty) {
      buffer.write('. Features include ');
      if (_selectedAmenities.length == 1) {
        buffer.write(_selectedAmenities.first);
      } else {
        final last = _selectedAmenities.last;
        final rest = _selectedAmenities.sublist(
          0,
          _selectedAmenities.length - 1,
        );
        buffer.write('${rest.join(', ')} and $last');
      }
    }

    buffer.write('.');
    _descriptionController.text = buffer.toString();
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
      _saveDraftNow();
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _saveDraftNow();
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
        if (_includeAgentFee) {
          if (_agentFeeController.text.isEmpty) {
            _showError('Please enter the agent fee');
            return false;
          }
          if (_parseAmountFromController(_agentFeeController) <= 0) {
            _showError('Please enter a valid agent fee amount');
            return false;
          }
        }
        if (_cautionDepositController.text.isEmpty) {
          _showError('Please enter the caution deposit');
          return false;
        }
        if (_parseAmountFromController(_cautionDepositController) <= 0) {
          _showError('Please enter a valid caution deposit amount');
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
        if (_inspectionHandler == 'agent' && _selectedAgentId == null) {
          _showError('Please select an agent to handle inspections');
          return false;
        }
        // Grouping-aware ownership validation.
        if (_isInBuilding && !_creatingNewBuilding) {
          // Joining an existing building — inherits its doc, none required here.
          if (_selectedBuildingId == null) {
            _showError(
              'Please select the building this unit belongs to, or create a new one.',
            );
            return false;
          }
        } else {
          // Standalone OR creating a new building — a document is required.
          if (_creatingNewBuilding &&
              _buildingNameController.text.trim().isEmpty) {
            _showError('Please enter a name for the new building.');
            return false;
          }
          if (_ownershipDocFile == null) {
            _showError(
              _creatingNewBuilding
                  ? 'Please upload the building\'s proof of ownership document.'
                  : 'Please upload your proof of ownership document. This is required for all listings.',
            );
            return false;
          }
          if (_ownershipDocType == null) {
            _showError('Please select the document type (C of O, Deed, etc.)');
            return false;
          }
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showExitConfirmation() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Discard listing?'),
            content: const Text(
              'You\'ll lose all the information you\'ve entered.',
            ),
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

      final imageUrls = await _propertyService.uploadImages(
        _selectedImageFiles,
      );

      if (!mounted) return;

      debugPrint('📸 Uploaded ${imageUrls.length} images');

      if (imageUrls.isEmpty) {
        Navigator.pop(context); // Close progress dialog
        _showError('Failed to upload images. Please try again.');
        setState(() => _isPublishing = false);
        return;
      }

      // Step 1b: Upload video to Cloudinary if provided
      String? videoUrl;
      if (_selectedVideoFile != null) {
        _updateUploadProgress('Uploading video tour...');
        videoUrl = await _propertyService.uploadVideo(_selectedVideoFile!);
        if (videoUrl == null) {
          debugPrint('⚠️ Video upload failed, continuing without video');
        }
      }

      if (!mounted) return;

      // Step 2: Ownership document / building grouping.
      //   - standalone        → doc stays on the property
      //   - new building       → doc goes onto the building; property inherits
      //   - join existing      → no doc; property inherits the building's
      String? ownershipDocUrl; // per-property doc (standalone only)
      String? buildingId; // set when this unit belongs to a building
      final bool joiningExisting = _isInBuilding && !_creatingNewBuilding;

      if (_ownershipDocFile != null) {
        _updateUploadProgress('Uploading ownership document...');
        // Private Firebase Storage (not Cloudinary) — a C of O is title-level
        // PII. uploadedUrl holds a storage PATH, streamed to admins via an
        // authenticated route.
        final uploadedUrl =
            await _propertyService.uploadOwnershipDoc(_ownershipDocFile!);

        if (_creatingNewBuilding) {
          _updateUploadProgress('Creating building...');
          final buildingAddress =
              _buildingAddressController.text.trim().isNotEmpty
                  ? _buildingAddressController.text.trim()
                  : _addressController.text.trim();
          buildingId = await _buildingService.createBuilding(
            name: _buildingNameController.text.trim(),
            address: buildingAddress,
            ownershipDocUrl: uploadedUrl,
            ownershipDocType: _ownershipDocType,
          );
          if (buildingId == null) {
            if (mounted) {
              Navigator.pop(context); // Close progress dialog
              _showError('Failed to create the building. Please try again.');
            }
            setState(() => _isPublishing = false);
            return;
          }
        } else {
          ownershipDocUrl = uploadedUrl;
        }
      } else if (joiningExisting) {
        buildingId = _selectedBuildingId;
      }

      if (!mounted) return;

      // Step 2b: Upload payment proof if this is a paid listing
      if (_requiresListingFee) {
        final paymentResult = await PaystackCheckoutScreen.launch(
          context: context,
          amount: _listingFeeAmount.toDouble(),
          type: PaystackService.typeListing,
          metadata: {'description': 'Listing fee for additional property'},
        );

        if (paymentResult == null || !paymentResult.success) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Listing fee payment is required to publish your property.',
                ),
                backgroundColor: AppColors.error,
              ),
            );
          }
          setState(() => _isPublishing = false);
          return;
        }

        _listingFeePaymentReference = paymentResult.reference;

        // Record payment
        await PaystackService().recordPayment(
          reference: paymentResult.reference,
          type: PaystackService.typeListing,
          amount: paymentResult.amountPaid ?? _listingFeeAmount.toDouble(),
          status: 'completed',
        );
      }

      if (!mounted) return;

      // Step 3: Create property in Firestore
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

      // ── Pre-calculate inspection fee ──
      final propertyCity = _cityController.text.trim();
      final propertyCluster = InspectionPricing.getClusterForArea(propertyCity);
      InspectionFeeBreakdown? preCalcFee;

      if (_inspectionHandler == 'agent' &&
          _selectedAgentId != null &&
          propertyCluster != null) {
        // Agent-handled: fetch agent's base location from Firestore
        try {
          final agentDoc =
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(_selectedAgentId)
                  .get();
          if (agentDoc.exists) {
            final agentData = agentDoc.data()!;
            final agentBase = agentData['baseLocation'] as String? ?? '';
            final agentCluster = InspectionPricing.getClusterForArea(agentBase);
            if (agentCluster != null) {
              preCalcFee = InspectionPricing.calculateFee(
                agentCluster: agentCluster,
                propertyCluster: propertyCluster,
                propertyArea: propertyCity,
              );
            }
          }
        } catch (e) {
          debugPrint('⚠️ Could not pre-calculate agent fee: $e');
        }
      } else if (_inspectionHandler == 'self' && propertyCluster != null) {
        // Self-handled
        if (_landlordLivesInProperty) {
          preCalcFee = InspectionPricing.calculateSelfHandledFee(
            landlordLivesInProperty: true,
            propertyCluster: propertyCluster,
          );
        } else {
          // Use landlord's selected base location
          final landlordCity = _landlordCityController.text.trim();
          final landlordCluster = InspectionPricing.getClusterForArea(
            landlordCity,
          );
          preCalcFee = InspectionPricing.calculateSelfHandledFee(
            landlordLivesInProperty: false,
            landlordCluster: landlordCluster,
            propertyCluster: propertyCluster,
            propertyArea: propertyCity,
          );
        }
      }

      debugPrint('   - Pre-calc fee: ${preCalcFee?.totalFee ?? "null"}');

      final propertyId = await _propertyService.createProperty(
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        propertyType: _propertyType,
        bedrooms: _bedrooms,
        bathrooms: _bathrooms,
        toilets: _toilets,
        livingRooms: _livingRooms,
        guestRooms: _guestRooms,
        kitchens: _kitchens,
        imageUrls: imageUrls,
        address: _addressController.text.trim(),
        city: _cityController.text.trim(),
        state: _stateController.text.trim(),
        latitude: _latitude,
        longitude: _longitude,
        rent: rentAmount,
        rentFrequency: _rentPeriod,
        agentFee:
            _includeAgentFee
                ? _parseAmountFromController(_agentFeeController)
                : 0,
        cautionDeposit: _parseAmountFromController(_cautionDepositController),
        cautionDepositRefundable: _cautionDepositRefundable,
        amenities: _selectedAmenities,
        rules: _selectedRules,
        inspectionHandler: _inspectionHandler,
        inspectionDays: _availableDays,
        inspectionTimeSlots: _availableTimeSlots,
        landlordLivesInProperty: _landlordLivesInProperty,
        landlordBaseLatitude: _landlordBaseLatitude,
        landlordBaseLongitude: _landlordBaseLongitude,
        maxTenants: _maxTenants,
        landlordLivesOnPremises: _landlordLivesOnPremises,
        hasCaretaker: _hasCaretaker,
        caretakerLivesOnPremises: _caretakerLivesOnPremises,
        ownershipDocUrl: ownershipDocUrl,
        ownershipDocType: buildingId != null ? null : _ownershipDocType,
        buildingId: buildingId,
        listingFeePaymentReference: _listingFeePaymentReference,
        assignedAgentId:
            _inspectionHandler == 'agent' ? _selectedAgentId : null,
        assignedAgentName:
            _inspectionHandler == 'agent' ? _selectedAgentName : null,
        inspectionFeeTotal: preCalcFee?.totalFee,
        inspectionTransportFee: preCalcFee?.transportFee,
        inspectionServiceFee:
            preCalcFee?.agentServiceFee != 0
                ? preCalcFee?.agentServiceFee
                : preCalcFee?.tenantServiceCharge,
        inspectionAgentCluster: preCalcFee?.agentCluster,
        inspectionPropertyCluster: preCalcFee?.propertyCluster,
        videoUrl: videoUrl,
        ceilingType: _ceilingType,
        recurringDues: _collectRecurringDues(),
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

      // ── ALL properties start hidden until admin reviews ──
      // Admin verifies that ownership docs match the landlord.
      // This prevents verified users from listing properties they don't own.
      final bool hasDoc = _ownershipDocFile != null;
      final Map<String, dynamic> reviewFields = {
        'isAvailable': false, // Hidden until admin approves
      };
      // Grouped units keep the 'inherited' status set by createProperty — don't
      // overwrite it. Standalone listings reflect their own doc upload state.
      if (buildingId == null) {
        reviewFields['ownershipDocStatus'] =
            hasDoc ? 'pending' : 'not_uploaded';
      }

      // If listing fee was also required, flag that too
      if (_requiresListingFee) {
        reviewFields['listingFeeStatus'] = 'paid';
      }

      await _propertyService.updateProperty(propertyId, reviewFields);
      debugPrint(
        '⏳ Property marked as pending admin review (doc: ${hasDoc ? "uploaded" : "not uploaded"}, fee: ${_requiresListingFee ? "pending" : "n/a"})',
      );

      // Track activity — already handled inside PropertyService.createProperty()

      // Clear the draft since we published successfully
      await PropertyDraftService.clearDraft();

      // Always show the pending review dialog. A grouped unit counts as having
      // a doc (it inherits the building's), so the dialog won't nag to upload.
      _showPendingReviewDialog(
        hasDoc: hasDoc || buildingId != null,
        requiresListingFee: _requiresListingFee,
      );
    } catch (e, stackTrace) {
      if (mounted) {
        Navigator.pop(context); // Close progress dialog
      }
      debugPrint('❌ Publish error: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      _showError('Something went wrong: ${e.toString()}');
      if (mounted) {
        setState(() => _isPublishing = false);
      }
    }
  }

  void _showUploadProgress(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.primary),
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
    if (mounted) {
      Navigator.pop(context);
      _showUploadProgress(message);
    }
  }

  void _showPendingReviewDialog({
    required bool hasDoc,
    required bool requiresListingFee,
  }) {
    String message;
    if (!hasDoc) {
      message =
          'Your property has been saved but is not yet visible to tenants. '
          'Please upload your ownership document (C of O, Deed of Assignment, etc.) '
          'so our team can verify it. Your listing will go live once approved.';
    } else if (requiresListingFee) {
      message =
          'Your property has been saved but is not yet visible to tenants. '
          'Our team will verify your ownership document and listing fee payment. '
          'Your listing will go live once both are approved.';
    } else {
      message =
          'Your property has been saved but is not yet visible to tenants. '
          'Our team will review your ownership document to verify it matches your identity. '
          'This usually takes less than 24 hours.';
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color:
                        hasDoc
                            ? AppColors.primary.withAlpha(26)
                            : AppColors.warning.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    hasDoc
                        ? Icons.hourglass_top_rounded
                        : Icons.description_outlined,
                    size: 40,
                    color: hasDoc ? AppColors.primary : AppColors.warning,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  hasDoc ? 'Pending Review' : 'Document Needed',
                  style: AppTextStyles.h3,
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.info.withAlpha(50)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 18,
                        color: AppColors.info,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'This protects tenants from fraudulent listings and builds trust in your property.',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.info,
                          ),
                        ),
                      ),
                    ],
                  ),
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

  Future<void> _pickFromGallery() async {
    try {
      final List<XFile> mediaFiles = await _imagePicker.pickMultipleMedia();

      if (mediaFiles.isEmpty) return;

      for (final media in mediaFiles) {
        final path = media.path.toLowerCase();
        final isVideo =
            path.endsWith('.mp4') ||
            path.endsWith('.mov') ||
            path.endsWith('.avi') ||
            path.endsWith('.3gp') ||
            path.endsWith('.mkv');

        if (isVideo) {
          await _handleVideoSelected(File(media.path));
        } else {
          // Image — temp-file workaround for Samsung/cloud-backed images
          final bytes = await media.readAsBytes();
          final tempDir = Directory.systemTemp;
          final tempFile = File(
            '${tempDir.path}/clearrent_${DateTime.now().millisecondsSinceEpoch}_${_selectedImageFiles.length}.jpg',
          );
          await tempFile.writeAsBytes(bytes);

          setState(() {
            _selectedImageFiles.add(tempFile);
          });
          _saveDraftDebounced();
        }
      }
    } catch (e) {
      debugPrint('❌ Gallery pick error: $e');
      _showError('Failed to pick media. Please try again.');
    }
  }

  Future<void> _takePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
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
                  const SizedBox(height: 16),
                  Text('Camera', style: AppTextStyles.h4),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(26),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.photo_camera_outlined,
                        color: AppColors.primary,
                      ),
                    ),
                    title: Text('Take Photo', style: AppTextStyles.labelLarge),
                    subtitle: Text(
                      'Capture a photo of your property',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    onTap: () => Navigator.pop(context, 'photo'),
                  ),
                  ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(26),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.videocam_outlined,
                        color: AppColors.info,
                      ),
                    ),
                    title: Text(
                      'Record Video',
                      style: AppTextStyles.labelLarge,
                    ),
                    subtitle: Text(
                      'Record a 1–3 minute video tour',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    onTap: () => Navigator.pop(context, 'video'),
                  ),
                ],
              ),
            ),
          ),
    );

    if (choice == null) return;

    try {
      if (choice == 'photo') {
        final XFile? image = await _imagePicker.pickImage(
          source: ImageSource.camera,
        );
        if (image != null) {
          final bytes = await image.readAsBytes();
          final tempDir = Directory.systemTemp;
          final tempFile = File(
            '${tempDir.path}/clearrent_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          await tempFile.writeAsBytes(bytes);
          setState(() {
            _selectedImageFiles.add(tempFile);
          });
          _saveDraftDebounced();
        }
      } else {
        final XFile? video = await _imagePicker.pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(minutes: 3),
        );
        if (video != null) {
          await _handleVideoSelected(File(video.path));
        }
      }
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      _showError('Failed to capture. Please try again.');
    }
  }

  /// Validate and store a selected video file (2–5 min duration limit)
  Future<void> _handleVideoSelected(File videoFile) async {
    if (_selectedVideoFile != null) {
      _showError(
        'Only one video per property. Remove the current video first.',
      );
      return;
    }

    setState(() => _isValidatingVideo = true);
    _saveDraftDebounced();

    try {
      // Check file size first (50MB max)
      final fileSizeBytes = await videoFile.length();
      final fileSizeMB = fileSizeBytes / (1024 * 1024);

      if (fileSizeMB > 50) {
        _showError(
          'Video is too large (${fileSizeMB.toStringAsFixed(1)}MB). '
          'Maximum is 50MB. Try recording at a lower quality or trimming the video.',
        );
        setState(() => _isValidatingVideo = false);
        _saveDraftDebounced();
        return;
      }

      // Check duration
      final controller = VideoPlayerController.file(videoFile);
      await controller.initialize();
      final duration = controller.value.duration;
      await controller.dispose();

      if (duration.inSeconds < 60) {
        _showError(
          'Video is too short (${duration.inSeconds}s). Minimum is 1 minute.',
        );
        setState(() => _isValidatingVideo = false);
        return;
      }

      if (duration.inSeconds > 180) {
        _showError(
          'Video is too long (${duration.inMinutes}m ${duration.inSeconds % 60}s). Maximum is 3 minutes.',
        );
        setState(() => _isValidatingVideo = false);
        return;
      }

      // Initialize preview controller
      _videoPreviewController?.dispose();
      _videoPreviewController = VideoPlayerController.file(videoFile);
      await _videoPreviewController!.initialize();
      _videoPreviewController!.setLooping(false);
      _videoPreviewController!.setVolume(0);

      setState(() {
        _selectedVideoFile = videoFile;
        _isValidatingVideo = false;
      });
    } catch (e) {
      debugPrint('❌ Video validation error: $e');
      _showError('Could not process this video. Please try another one.');
      setState(() => _isValidatingVideo = false);
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  /// Collect all enabled dues into a list of maps for Firestore
  List<Map<String, dynamic>> _collectRecurringDues() {
    final List<Map<String, dynamic>> dues = [];

    // Predefined dues
    for (final due in _predefinedDues) {
      final id = due['id']!;
      if (_duesEnabled[id] == true) {
        final amount = _parseAmountFromController(_duesControllers[id]!);
        if (amount > 0) {
          dues.add({
            'id': id,
            'name': due['name'],
            'amount': amount,
            'frequency': _duesFrequency[id] ?? 'yearly',
          });
        }
      }
    }

    // Custom dues
    for (final custom in _customDues) {
      final controllerId = custom['controllerId']!;
      final name = custom['name'] ?? '';
      if (name.isNotEmpty && _duesControllers[controllerId] != null) {
        final amount = _parseAmountFromController(
          _duesControllers[controllerId]!,
        );
        if (amount > 0) {
          dues.add({
            'id': controllerId,
            'name': name,
            'amount': amount,
            'frequency': _duesFrequency[controllerId] ?? 'yearly',
          });
        }
      }
    }

    return dues;
  }

  /// Calculate total annual dues for the preview
  double _totalDuesYearly() {
    double total = 0;
    final dues = _collectRecurringDues();
    for (final due in dues) {
      final amount = (due['amount'] as num?)?.toDouble() ?? 0;
      final freq = due['frequency'] as String? ?? 'yearly';
      total += freq == 'monthly' ? amount * 12 : amount;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    // Show loading while checking verification
    if (_isCheckingVerification) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.close, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: Text('Add Property', style: AppTextStyles.h4),
          centerTitle: true,
        ),
        body: Center(
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
            icon: Icon(Icons.close, color: AppColors.textPrimary),
            onPressed: _showExitConfirmation,
          ),
          title: Text('Add Property', style: AppTextStyles.h4),
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
                  margin: EdgeInsets.only(
                    right: index < _totalSteps - 1 ? 8 : 0,
                  ),
                  height: 4,
                  decoration: BoxDecoration(
                    color:
                        isCompleted || isCurrent
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
        return 'Photos & Video';
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
          Text('Add photos of your property', style: AppTextStyles.h4),
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

          // Add photo buttons — both styled equally (no pre-selected look)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickFromGallery,
                  child: Container(
                    height: 100,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border, width: 1.5),
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
                          child: Icon(
                            Icons.photo_library_outlined,
                            color: AppColors.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Gallery',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.textPrimary,
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
                      border: Border.all(color: AppColors.border, width: 1.5),
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
                          child: Icon(
                            Icons.camera_alt_outlined,
                            color: AppColors.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Camera',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.textPrimary,
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

          // ── Video Tour Section ──
          const SizedBox(height: 32),
          Row(
            children: [
              Icon(Icons.videocam_outlined, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Text('Video Tour', style: AppTextStyles.labelLarge),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(26),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Optional',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.info,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Add a 1–3 minute walkthrough video (max 50MB). Properties with video get more inquiries.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),

          if (_isValidatingVideo)
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Checking video...',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_selectedVideoFile != null &&
              _videoPreviewController != null &&
              _videoPreviewController!.value.isInitialized) ...[
            // Video preview
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: _videoPreviewController!.value.aspectRatio,
                    child: VideoPlayer(_videoPreviewController!),
                  ),
                ),
                // Play badge
                Positioned.fill(
                  child: Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(128),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
                // Duration badge
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(160),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _formatDuration(_videoPreviewController!.value.duration),
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                // Remove button
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () {
                      _videoPreviewController?.dispose();
                      _videoPreviewController = null;
                      setState(() => _selectedVideoFile = null);
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
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Video added! Tenants will see a muted preview when they view your listing.',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.success,
                fontStyle: FontStyle.italic,
              ),
            ),
          ] else
            // No video yet — show hint
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.border,
                  style: BorderStyle.solid,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: AppColors.textHint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Use the Gallery or Camera button above to add a video tour.',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
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

  Widget _buildLocationStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Where is your property?', style: AppTextStyles.h4),
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
            onUnknownAreaDetected: (rawName, lat, lng) async {
              // Log to admin so the area can be added to the dropdown in future
              try {
                await FirebaseFirestore.instance
                    .collection('admin_requests')
                    .add({
                      'type': 'unknown_area',
                      'rawName': rawName,
                      'lat': lat,
                      'lng': lng,
                      'source': 'add_property',
                      'status': 'pending',
                      'createdAt': FieldValue.serverTimestamp(),
                    });
              } catch (e) {
                debugPrint('Failed to log unknown area: $e');
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsStep() {
    return SingleChildScrollView(
      controller: _detailsScrollController,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Property details', style: AppTextStyles.h4),
          const SizedBox(height: 24),

          // Title
          AppTextField(
            label: 'Property Title',
            hint: 'e.g. Spacious 3 Bedroom Flat',
            controller: _titleController,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => _titleManuallyEdited = true,
          ),
          const SizedBox(height: 20),

          // Property Type
          Text('Property Type', style: AppTextStyles.labelMedium),
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
              Expanded(
                child: _buildCounter(
                  'Bedrooms',
                  _bedrooms,
                  (v) => setState(() {
                    _bedrooms = v;
                    _updateAutoTitle();
                    _updateAutoDescription();
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCounter(
                  'Bathrooms',
                  _bathrooms,
                  (v) => setState(() {
                    _bathrooms = v;
                    _updateAutoDescription();
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCounter(
                  'Toilets',
                  _toilets,
                  (v) => setState(() => _toilets = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Second row: Living Room, Guest Room, Kitchen
          Row(
            children: [
              Expanded(
                child: _buildCounter(
                  'Living Room',
                  _livingRooms,
                  (v) => setState(() => _livingRooms = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCounter(
                  'Guest Room',
                  _guestRooms,
                  (v) => setState(() => _guestRooms = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCounter(
                  'Kitchen',
                  _kitchens,
                  (v) => setState(() => _kitchens = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Model A: one unit = one rent = one tenancy. A property is let to a
          // single household (its bedroom count captures size) — it is not
          // sub-let as separate per-tenant rents — so maxTenants is fixed at 1.
          // A building with multiple lettable units is listed as one property
          // per unit. (No picker; _maxTenants stays 1.)

          // ── Ceiling Type ──
          Text('Ceiling Type', style: AppTextStyles.labelMedium),
          const SizedBox(height: 4),
          Text(
            'What type of ceiling does the property have?',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildCeilingChip('False Ceiling (POP)', 'false_ceiling'),
              _buildCeilingChip('PVC', 'pvc'),
              _buildCeilingChip('Concrete', 'concrete'),
              _buildCeilingChip('Asbestos', 'asbestos'),
              _buildCeilingChip('None', 'none'),
            ],
          ),

          const SizedBox(height: 24),

          // ── Occupancy & Living Situation ──
          Text('Living Situation', style: AppTextStyles.labelMedium),
          const SizedBox(height: 4),
          Text(
            'Help tenants understand who they\'ll be sharing the compound with.',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),

          // Existing tenant — handled post-publish via the property page's
          // link flow, not a raw counter. A number can't represent a real,
          // consented tenancy (no tenantId, no lease, no acceptance), and a
          // phantom count desyncs occupancy + the rent lock. Occupancy now
          // only rises when a real tenancy_link is confirmed by the tenant.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.info.withAlpha(50)),
            ),
            child: Row(
              children: [
                Icon(Icons.group_outlined, size: 20, color: AppColors.info),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Already have a tenant living here?',
                        style: AppTextStyles.labelMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'You can link them after publishing — open this property '
                        'and send a link request. They confirm it, and the '
                        'property is marked occupied.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Has caretaker?
          _buildYesNoTile(
            icon: Icons.manage_accounts_outlined,
            title: 'Do you have a caretaker?',
            value: _hasCaretaker,
            onChanged:
                (v) => setState(() {
                  _hasCaretaker = v;
                  if (!v) _caretakerLivesOnPremises = false;
                }),
          ),

          // Caretaker lives on premises (conditional)
          if (_hasCaretaker) ...[
            const SizedBox(height: 12),
            _buildYesNoTile(
              icon: Icons.home_work_outlined,
              title: 'Does the caretaker live on the property?',
              value: _caretakerLivesOnPremises,
              onChanged: (v) => setState(() => _caretakerLivesOnPremises = v),
              indent: true,
            ),
          ],

          // Description
          AppTextField(
            label: 'Description',
            hint:
                'Describe your property, its features, and what makes it special...',
            controller: _descriptionController,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => _descriptionManuallyEdited = true,
          ),
          const SizedBox(height: 24),

          // Amenities
          Text('Amenities', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                _amenitiesList.map((amenity) {
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
                        _updateAutoDescription();
                      });
                    },
                    backgroundColor: AppColors.surface,
                    selectedColor: AppColors.primary.withAlpha(26),
                    checkmarkColor: AppColors.primary,
                    labelStyle: AppTextStyles.labelMedium.copyWith(
                      color:
                          isSelected
                              ? AppColors.primary
                              : AppColors.textSecondary,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color:
                            isSelected ? AppColors.primary : AppColors.border,
                      ),
                    ),
                  );
                }).toList(),
          ),
          const SizedBox(height: 24),

          // House Rules
          Text('House Rules (Optional)', style: AppTextStyles.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                _rulesList.map((rule) {
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
                      color:
                          isSelected
                              ? AppColors.warning
                              : AppColors.textSecondary,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color:
                            isSelected ? AppColors.warning : AppColors.border,
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

  Widget _buildYesNoTile({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool indent = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: indent ? AppColors.background : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: value ? AppColors.primary.withAlpha(80) : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          if (indent) const SizedBox(width: 8),
          Icon(
            icon,
            size: 20,
            color: value ? AppColors.primary : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: AppTextStyles.labelMedium)),
          Row(
            children: [
              _buildToggleOption('No', !value, () => onChanged(false)),
              const SizedBox(width: 6),
              _buildToggleOption('Yes', value, () => onChanged(true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleOption(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: selected ? Colors.white : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildTypeChip(String label, String value) {
    final isSelected = _propertyType == value;
    return GestureDetector(
      onTap:
          () => setState(() {
            _propertyType = value;
            _updateAutoTitle();
            _updateAutoDescription();
          }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
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

  Widget _buildCeilingChip(String label, String value) {
    final isSelected = _ceilingType == value;
    return GestureDetector(
      onTap:
          () => setState(() {
            _ceilingType =
                isSelected ? null : value; // Toggle off if already selected
          }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
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

  Widget _buildCounter(
    String label,
    int value,
    Function(int) onChanged, {
    int max = 20,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.caption),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
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
              Expanded(
                child: Text(
                  '$value',
                  style: AppTextStyles.labelLarge,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (value < max) onChanged(value + 1);
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color:
                        value < max
                            ? AppColors.primary.withAlpha(26)
                            : AppColors.background,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.add,
                    size: 18,
                    color: value < max ? AppColors.primary : AppColors.textHint,
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
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: SingleChildScrollView(
        controller: _pricingScrollController,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set your price', style: AppTextStyles.h4),
            const SizedBox(height: 8),
            Text(
              'Set the total package — rent, agent fee, and caution deposit. Tenants see the full breakdown upfront.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),

            // Rent amount with comma formatting
            Text('Rent Amount (₦)', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            _buildNairaInput(
              controller: _rentController,
              hintText: 'e.g. 800,000',
            ),
            const SizedBox(height: 20),

            // Rent period — yearly only at launch (monthly is v2; Lagos law caps
            // yearly advance rent at one year, which the lifecycle relies on).
            Text('Rent Period', style: AppTextStyles.labelMedium),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primary),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.calendar_today_outlined,
                    size: 16,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Per Year',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Monthly coming soon',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Agent fee toggle (optional)
            _buildYesNoTile(
              icon: Icons.person_outline,
              title: 'Include an agent fee?',
              value: _includeAgentFee,
              onChanged:
                  (v) => setState(() {
                    _includeAgentFee = v;
                    if (v) {
                      // An agent fee only makes sense if an agent is assigned to
                      // close the tenant — so turning it on forces agent-handled
                      // inspection and reveals the agent picker below.
                      _inspectionHandler = 'agent';
                    } else {
                      // No fee → no agent to pay → revert to self-handled and
                      // clear any selected agent.
                      _agentFeeController.clear();
                      _inspectionHandler = 'self';
                      _selectedAgentId = null;
                      _selectedAgentName = null;
                    }
                  }),
            ),
            if (!_includeAgentFee) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  'Agents are optional on ClearRent. Only set a fee if you want an agent involved.',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],

            if (_includeAgentFee) ...[
              const SizedBox(height: 16),
              Text('Agent Fee (₦)', style: AppTextStyles.labelMedium),
              const SizedBox(height: 4),
              Text(
                'The flat amount the agent collects from the tenant.',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              _buildNairaInput(
                controller: _agentFeeController,
                hintText: 'e.g. 200,000',
              ),
            ],
            const SizedBox(height: 24),

            // Caution / Damages deposit
            Text('Caution Deposit (₦)', style: AppTextStyles.labelMedium),
            const SizedBox(height: 4),
            Text(
              'Deposit held against damage to the property.',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            _buildNairaInput(
              controller: _cautionDepositController,
              hintText: 'e.g. 150,000',
            ),
            const SizedBox(height: 12),
            // Refundability is stated up front so the tenant knows before they
            // pay whether this money comes back, and the move-out handover is
            // measured against this promise.
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Refundable at move-out',
                          style: AppTextStyles.labelMedium),
                      const SizedBox(height: 2),
                      Text(
                        _cautionDepositRefundable
                            ? 'Returned in full if the tenant leaves the '
                                'property in good condition.'
                            : 'Tenants will be told this deposit is NOT '
                                'refundable.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _cautionDepositRefundable,
                  onChanged: (v) =>
                      setState(() => _cautionDepositRefundable = v),
                  activeColor: AppColors.primary,
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ── Recurring Dues Section ──
            Row(
              children: [
                Text('Recurring Dues', style: AppTextStyles.h4),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(26),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Optional',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.info,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Does this property have any recurring charges? Toggle the ones that apply and enter the amount.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),

            // Predefined dues
            ..._predefinedDues.map((due) {
              final id = due['id']!;
              final isEnabled = _duesEnabled[id] ?? false;
              return _buildDueTile(
                id: id,
                name: due['name']!,
                icon: _dueIcon(due['icon']!),
                isEnabled: isEnabled,
                onToggle: (v) => setState(() => _duesEnabled[id] = v),
              );
            }),

            // Custom dues
            ..._customDues.map((custom) => _buildCustomDueTile(custom)),

            const SizedBox(height: 8),

            // Add custom due button
            GestureDetector(
              onTap: _addCustomDue,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.border,
                    style: BorderStyle.solid,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 18, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Add other due',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Total Package preview ──
            _buildTotalPackagePreview(),
            const SizedBox(height: 32),

            // ── Building / compound grouping ──
            _buildBuildingGroupingSection(),

            const SizedBox(height: 24),

            // ── Proof of ownership (conditional on grouping choice) ──
            _buildOwnershipDocStep(),

            const SizedBox(height: 32),

            // Landlord residence question
            _buildLandlordResidenceSection(),

            const SizedBox(height: 24),

            // Inspection handling section
            KeyedSubtree(
              key: _agentSectionKey,
              child: _buildInspectionHandlerSection(),
            ),

            const SizedBox(height: 24),

            // Agreement-readiness heads-up. Closing a deal on ClearRent requires
            // a signed tenancy agreement, so remind the landlord to have one
            // ready before a tenant reaches the finalize step.
            _buildAgreementReadinessNote(),

            const SizedBox(height: 24),

            // Inspection availability section
            _buildInspectionAvailabilitySection(),

            const SizedBox(height: 24),

            // Platform fee info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    _requiresListingFee
                        ? AppColors.warning.withAlpha(26)
                        : AppColors.successLight.withAlpha(128),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      _requiresListingFee
                          ? AppColors.warning.withAlpha(77)
                          : AppColors.success.withAlpha(77),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _requiresListingFee
                        ? Icons.info_outline
                        : Icons.check_circle_outline,
                    color:
                        _requiresListingFee
                            ? AppColors.warning
                            : AppColors.success,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _requiresListingFee
                          ? 'This listing requires a ₦10,000 fee. Your property will go live after admin verifies it.'
                          : 'Your first listing is free!',
                      style: AppTextStyles.bodySmall.copyWith(
                        color:
                            _requiresListingFee
                                ? AppColors.warning
                                : AppColors.success,
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

  /// Reusable Naira input field with comma formatting
  Widget _buildNairaInput({
    required TextEditingController controller,
    String hintText = '0',
  }) {
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
          ThousandsSeparatorInputFormatter(),
        ],
        style: AppTextStyles.h4.copyWith(color: AppColors.primary),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: AppTextStyles.h4.copyWith(color: AppColors.textHint),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Text(
              '₦',
              style: AppTextStyles.h4.copyWith(color: AppColors.primary),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 0,
            minHeight: 0,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }

  IconData _dueIcon(String iconName) {
    switch (iconName) {
      case 'security':
        return Icons.security;
      case 'groups':
        return Icons.groups_outlined;
      case 'delete':
        return Icons.delete_outline;
      case 'bolt':
        return Icons.bolt;
      case 'water_drop':
        return Icons.water_drop_outlined;
      case 'home_repair_service':
        return Icons.home_repair_service_outlined;
      default:
        return Icons.receipt_outlined;
    }
  }

  Widget _buildDueTile({
    required String id,
    required String name,
    required IconData icon,
    required bool isEnabled,
    required ValueChanged<bool> onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isEnabled ? AppColors.primary.withAlpha(8) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                isEnabled ? AppColors.primary.withAlpha(60) : AppColors.border,
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isEnabled ? AppColors.primary : AppColors.textHint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    style: AppTextStyles.labelMedium.copyWith(
                      color:
                          isEnabled
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                    ),
                  ),
                ),
                Switch(
                  value: isEnabled,
                  onChanged: onToggle,
                  activeColor: AppColors.primary,
                ),
              ],
            ),
            if (isEnabled) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  // Amount field
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 44,
                      child: _buildNairaInput(
                        controller: _duesControllers[id]!,
                        hintText: 'Amount',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Frequency toggle
                  Expanded(
                    flex: 2,
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap:
                                  () => setState(
                                    () => _duesFrequency[id] = 'yearly',
                                  ),
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color:
                                      _duesFrequency[id] == 'yearly'
                                          ? AppColors.primary
                                          : Colors.transparent,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  '/yr',
                                  style: AppTextStyles.labelSmall.copyWith(
                                    color:
                                        _duesFrequency[id] == 'yearly'
                                            ? Colors.white
                                            : AppColors.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap:
                                  () => setState(
                                    () => _duesFrequency[id] = 'monthly',
                                  ),
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color:
                                      _duesFrequency[id] == 'monthly'
                                          ? AppColors.primary
                                          : Colors.transparent,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  '/mo',
                                  style: AppTextStyles.labelSmall.copyWith(
                                    color:
                                        _duesFrequency[id] == 'monthly'
                                            ? Colors.white
                                            : AppColors.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCustomDueTile(Map<String, String> custom) {
    final controllerId = custom['controllerId']!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(60)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_outlined,
                  size: 20,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    custom['name']?.isNotEmpty == true
                        ? custom['name']!
                        : 'Custom Due',
                    style: AppTextStyles.labelMedium,
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    _duesControllers[controllerId]?.dispose();
                    _duesControllers.remove(controllerId);
                    _duesFrequency.remove(controllerId);
                    setState(() {
                      _customDues.removeWhere(
                        (c) => c['controllerId'] == controllerId,
                      );
                    });
                  },
                  child: Icon(Icons.close, size: 18, color: AppColors.error),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Name field
            SizedBox(
              height: 44,
              child: TextField(
                textCapitalization: TextCapitalization.words,
                onChanged: (v) {
                  final index = _customDues.indexWhere(
                    (c) => c['controllerId'] == controllerId,
                  );
                  if (index >= 0) {
                    setState(() => _customDues[index]['name'] = v);
                  }
                },
                style: AppTextStyles.labelMedium,
                decoration: InputDecoration(
                  hintText: 'Due name (e.g. Gate Pass)',
                  hintStyle: AppTextStyles.caption.copyWith(
                    color: AppColors.textHint,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: SizedBox(
                    height: 44,
                    child: _buildNairaInput(
                      controller: _duesControllers[controllerId]!,
                      hintText: 'Amount',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap:
                                () => setState(
                                  () => _duesFrequency[controllerId] = 'yearly',
                                ),
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color:
                                    _duesFrequency[controllerId] == 'yearly'
                                        ? AppColors.primary
                                        : Colors.transparent,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                '/yr',
                                style: AppTextStyles.labelSmall.copyWith(
                                  color:
                                      _duesFrequency[controllerId] == 'yearly'
                                          ? Colors.white
                                          : AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap:
                                () => setState(
                                  () =>
                                      _duesFrequency[controllerId] = 'monthly',
                                ),
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color:
                                    _duesFrequency[controllerId] == 'monthly'
                                        ? AppColors.primary
                                        : Colors.transparent,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                '/mo',
                                style: AppTextStyles.labelSmall.copyWith(
                                  color:
                                      _duesFrequency[controllerId] == 'monthly'
                                          ? Colors.white
                                          : AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _addCustomDue() {
    final controllerId = 'custom_$_customDueCounter';
    _duesControllers[controllerId] = TextEditingController();
    _duesFrequency[controllerId] = 'yearly';
    setState(() {
      _customDues.add({'name': '', 'controllerId': controllerId});
      _customDueCounter++;
    });
  }

  /// Live Total Package breakdown shown in the pricing step
  Widget _buildTotalPackagePreview() {
    final rent = _parseAmountFromController(_rentController);
    final agentFee = _parseAmountFromController(_agentFeeController);
    final cautionDeposit = _parseAmountFromController(
      _cautionDepositController,
    );
    final totalPackage = rent + agentFee + cautionDeposit;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Total Package Preview',
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildPackageRow('Rent', rent),
          if (agentFee > 0) ...[
            const SizedBox(height: 8),
            _buildPackageRow('Agent Fee', agentFee),
          ],
          const SizedBox(height: 8),
          _buildPackageRow('Caution Deposit', cautionDeposit),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total Package', style: AppTextStyles.labelLarge),
              Text(
                '₦${_formatAmount(totalPackage)}',
                style: AppTextStyles.h4.copyWith(
                  color: AppColors.primary,
                  fontFamily: 'Roboto',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'After the first year, renewal is just ₦${_formatAmount(rent)}${_rentPeriod == 'yearly' ? '/year' : '/month'}',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
          // Recurring dues summary
          if (_totalDuesYearly() > 0) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.repeat, size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Text(
                  'Recurring Dues',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.info,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._collectRecurringDues().map((due) {
              final amount = (due['amount'] as num?)?.toDouble() ?? 0;
              final freq = due['frequency'] as String? ?? 'yearly';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      due['name'] as String,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      '₦${_formatAmount(amount)}/${freq == 'monthly' ? 'mo' : 'yr'}',
                      style: AppTextStyles.labelSmall.copyWith(
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total Dues', style: AppTextStyles.labelMedium),
                Text(
                  '₦${_formatAmount(_totalDuesYearly())}/yr',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.info,
                    fontFamily: 'Roboto',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPackageRow(String label, double amount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTextStyles.bodyMedium),
        Text(
          '₦${_formatAmount(amount)}',
          style: AppTextStyles.labelLarge.copyWith(fontFamily: 'Roboto'),
        ),
      ],
    );
  }

  double _parseAmountFromController(TextEditingController controller) {
    final cleanedText = controller.text.replaceAll(',', '');
    return double.tryParse(cleanedText) ?? 0;
  }

  // ── Building / compound grouping ──────────────────────────────────────────
  // Lets the landlord mark this listing as one unit in a building/compound they
  // own. Units in the same building share ONE ownership document (verified once
  // for all), so a grouped unit skips its own doc upload.
  Widget _buildBuildingGroupingSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Property Grouping', style: AppTextStyles.h4),
      const SizedBox(height: 4),
      Text(
        'Is this a standalone listing, or one unit in a building/compound you '
        'own? Units in the same building share one ownership document.',
        style: AppTextStyles.caption
            .copyWith(color: AppColors.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: _buildGroupingChoiceCard(
            label: 'Standalone',
            subtitle: 'One unit, its own document',
            icon: Icons.home_outlined,
            selected: !_isInBuilding,
            onTap: () => setState(() {
              _isInBuilding = false;
              _creatingNewBuilding = false;
              _selectedBuildingId = null;
            }),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildGroupingChoiceCard(
            label: 'In a building',
            subtitle: 'Shares one document',
            icon: Icons.apartment_outlined,
            selected: _isInBuilding,
            onTap: () => setState(() => _isInBuilding = true),
          ),
        ),
      ]),
      if (_isInBuilding) ...[
        const SizedBox(height: 16),
        _buildBuildingPicker(),
      ],
    ]);
  }

  Widget _buildGroupingChoiceCard({
    required String label,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon,
              color: selected ? AppColors.primary : AppColors.textSecondary,
              size: 22),
          const SizedBox(height: 8),
          Text(label,
              style: AppTextStyles.labelMedium.copyWith(
                color: selected ? AppColors.primary : AppColors.textPrimary,
              )),
          const SizedBox(height: 2),
          Text(subtitle,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  // Picker shown when "In a building" is chosen: the landlord's existing
  // buildings (join one) plus a "create new building" option.
  Widget _buildBuildingPicker() {
    return StreamBuilder<List<BuildingModel>>(
      stream: _landlordBuildingsStream,
      builder: (context, snap) {
        final buildings = snap.data ?? const <BuildingModel>[];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ...buildings.map(_buildExistingBuildingTile),
          _buildCreateBuildingTile(),
          if (_creatingNewBuilding) ...[
            const SizedBox(height: 12),
            AppTextField(
              label: 'Building / compound name',
              hint: 'e.g. Olu Compound, 12 Allen Ave',
              controller: _buildingNameController,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            AppTextField(
              label: 'Building address',
              hint: 'Defaults to this unit\'s address — edit if different',
              controller: _buildingAddressController,
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ]);
      },
    );
  }

  Widget _buildExistingBuildingTile(BuildingModel b) {
    final selected = !_creatingNewBuilding && _selectedBuildingId == b.id;
    final verified = b.isDocVerified;
    return GestureDetector(
      onTap: () => setState(() {
        _creatingNewBuilding = false;
        _selectedBuildingId = b.id;
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.name, style: AppTextStyles.labelMedium,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              if (b.address.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(b.address,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (verified ? AppColors.success : AppColors.warning)
                  .withAlpha(26),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              verified ? 'Doc verified' : 'Doc pending',
              style: AppTextStyles.caption.copyWith(
                color: verified ? AppColors.success : AppColors.warning,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildCreateBuildingTile() {
    final selected = _creatingNewBuilding;
    return GestureDetector(
      onTap: () => setState(() {
        _creatingNewBuilding = true;
        _selectedBuildingId = null;
        // A compound shares the unit's street address — prefill it so the
        // landlord doesn't retype what they already entered (still editable).
        if (_buildingAddressController.text.trim().isEmpty) {
          _buildingAddressController.text = _addressController.text.trim();
        }
      }),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(Icons.add_circle_outline,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 12),
          Text('Create a new building',
              style: AppTextStyles.labelMedium.copyWith(
                color: selected ? AppColors.primary : AppColors.textPrimary,
              )),
        ]),
      ),
    );
  }

  // The proof-of-ownership step. Standalone listings and new buildings upload a
  // document here; a unit joining an existing building inherits that building's
  // document, so no upload is shown.
  Widget _buildOwnershipDocStep() {
    final joiningExisting = _isInBuilding && !_creatingNewBuilding;
    if (joiningExisting) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.info.withAlpha(13),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.info.withAlpha(60)),
        ),
        child: Row(children: [
          Icon(Icons.verified_user_outlined, color: AppColors.info, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _selectedBuildingId == null
                  ? 'Select a building above. This unit will inherit the '
                      'building\'s ownership document.'
                  : 'This unit inherits the selected building\'s ownership '
                      'document — no separate upload needed.',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary, height: 1.5),
            ),
          ),
        ]),
      );
    }

    final title = _creatingNewBuilding
        ? 'Building\'s Proof of Ownership'
        : 'Proof of Ownership';
    final desc = _creatingNewBuilding
        ? 'Upload the C of O / title document for this building. It is verified '
            'once and covers every unit you list under it.'
        : 'Upload a C of O, Deed of Assignment, or any title document. Your '
            'listing will be reviewed by our team before going live.';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(title, style: AppTextStyles.h4),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.error.withAlpha(26),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('Required',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.error,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              )),
        ),
      ]),
      const SizedBox(height: 4),
      Text(desc,
          style: AppTextStyles.caption
              .copyWith(color: AppColors.textSecondary, height: 1.5)),
      const SizedBox(height: 12),
      _buildOwnershipDocSection(),
    ]);
  }

  Widget _buildOwnershipDocSection() {
    final hasDoc = _ownershipDocFile != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasDoc ? AppColors.success.withAlpha(80) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Doc type chips
          Text('Document Type', style: AppTextStyles.labelMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              _DocTypeChip(
                label: 'C of O',
                value: 'c_of_o',
                selected: _ownershipDocType == 'c_of_o',
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _ownershipDocType = 'c_of_o');
                },
              ),
              _DocTypeChip(
                label: 'Deed of Assignment',
                value: 'deed',
                selected: _ownershipDocType == 'deed',
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _ownershipDocType = 'deed');
                },
              ),
              _DocTypeChip(
                label: 'Other',
                value: 'other',
                selected: _ownershipDocType == 'other',
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _ownershipDocType = 'other');
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (hasDoc) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.success.withAlpha(50)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_outlined,
                    color: AppColors.success,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Document selected',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.success,
                          ),
                        ),
                        Text(
                          _ownershipDocFile!.path.split('/').last,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _pickOwnershipDoc,
                    child: Text(
                      'Change',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            GestureDetector(
              onTap: _pickOwnershipDoc,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.upload_file_outlined,
                      size: 32,
                      color: AppColors.textHint,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap to upload document or photo',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'C of O, Deed of Assignment, or other title document',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickOwnershipDoc() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
      if (image != null) {
        setState(() => _ownershipDocFile = File(image.path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not pick document'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Widget _buildLandlordResidenceSection() {
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
            'Do you live in this property?',
            style: AppTextStyles.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'This helps tenants know if the landlord is a co-resident and affects inspection fee calculation.',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _landlordLivesInProperty = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color:
                          _landlordLivesInProperty
                              ? AppColors.primary.withAlpha(13)
                              : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            _landlordLivesInProperty
                                ? AppColors.primary
                                : AppColors.border,
                        width: _landlordLivesInProperty ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.home,
                          color:
                              _landlordLivesInProperty
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Yes, I live here',
                          style: AppTextStyles.labelSmall.copyWith(
                            color:
                                _landlordLivesInProperty
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
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
                  onTap: () => setState(() => _landlordLivesInProperty = false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color:
                          !_landlordLivesInProperty
                              ? AppColors.primary.withAlpha(13)
                              : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            !_landlordLivesInProperty
                                ? AppColors.primary
                                : AppColors.border,
                        width: !_landlordLivesInProperty ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.other_houses_outlined,
                          color:
                              !_landlordLivesInProperty
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'No, I live elsewhere',
                          style: AppTextStyles.labelSmall.copyWith(
                            color:
                                !_landlordLivesInProperty
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Show AreaDropdown if landlord doesn't live in property
          if (!_landlordLivesInProperty) ...[
            const SizedBox(height: 16),
            AreaDropdown(
              label: 'Where do you live?',
              helperText:
                  'We\'ll use this to calculate inspection fees based on travel distance.',
              hint: 'Select your area',
              selectedArea: _landlordBaseArea,
              onSelected: (area) {
                setState(() {
                  _landlordBaseArea = area;
                  _landlordCityController.text = area;
                });
              },
            ),
            if (_landlordBaseArea != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(13),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.success.withAlpha(50)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Inspection fees will be calculated based on distance from $_landlordBaseArea to your property.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// Show agent picker bottom sheet
  Future<void> _showAgentPicker() async {
    // Load agents
    final agentService = AgentService();
    List<AgentModel> agents = [];
    bool isLoading = true;
    bool showingAll = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setSheetState) {
              // Load agents on first build
              if (isLoading) {
                () async {
                  final city = _cityController.text.trim();
                  List<AgentModel> result;
                  if (city.isNotEmpty) {
                    result = await agentService.getAgentsByArea(city);
                    if (result.isEmpty) {
                      result = await agentService.getVerifiedAgents();
                      showingAll = true;
                    }
                  } else {
                    result = await agentService.getVerifiedAgents();
                    showingAll = true;
                  }
                  if (ctx.mounted) {
                    setSheetState(() {
                      agents = result;
                      isLoading = false;
                    });
                  }
                }();
              }

              return DraggableScrollableSheet(
                initialChildSize: 0.7,
                minChildSize: 0.4,
                maxChildSize: 0.92,
                expand: false,
                builder:
                    (_, scrollController) => Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                      ),
                      child: Column(
                        children: [
                          // Handle
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 8),
                            child: Center(
                              child: Container(
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: AppColors.border,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                            child: Row(
                              children: [
                                Text(
                                  'Select an Agent',
                                  style: AppTextStyles.h4,
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: Icon(
                                    Icons.close,
                                    color: AppColors.textSecondary,
                                  ),
                                  onPressed: () => Navigator.pop(ctx),
                                ),
                              ],
                            ),
                          ),
                          if (showingAll && !isLoading)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                              child: Text(
                                'No agents found in ${_cityController.text.trim()}. Showing all verified agents.',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.warning,
                                ),
                              ),
                            ),

                          if (isLoading)
                            Expanded(
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: AppColors.primary,
                                ),
                              ),
                            )
                          else if (agents.isEmpty)
                            Expanded(
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.person_off,
                                      size: 48,
                                      color: AppColors.textHint,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No verified agents available yet',
                                      style: AppTextStyles.bodyMedium.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'You can handle inspections yourself for now',
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.textHint,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Expanded(
                              child: ListView.separated(
                                controller: scrollController,
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  8,
                                  20,
                                  20,
                                ),
                                itemCount: agents.length,
                                separatorBuilder:
                                    (_, __) => const SizedBox(height: 10),
                                itemBuilder: (_, index) {
                                  final agent = agents[index];
                                  final isSelected =
                                      _selectedAgentId == agent.id;
                                  return GestureDetector(
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      FocusManager.instance.primaryFocus
                                          ?.unfocus();
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (!mounted) return;
                                            setState(() {
                                              _selectedAgentId = agent.id;
                                              _selectedAgentName =
                                                  agent.fullName;
                                            });
                                          });
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color:
                                            isSelected
                                                ? AppColors.primary.withAlpha(
                                                  13,
                                                )
                                                : AppColors.background,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color:
                                              isSelected
                                                  ? AppColors.primary
                                                  : AppColors.border,
                                          width: isSelected ? 2 : 1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 22,
                                            backgroundColor: AppColors.primary
                                                .withAlpha(26),
                                            child: Text(
                                              (agent.fullName.isNotEmpty
                                                      ? agent.fullName[0]
                                                      : '?')
                                                  .toUpperCase(),
                                              style: AppTextStyles.h4.copyWith(
                                                color: AppColors.primary,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  agent.fullName,
                                                  style:
                                                      AppTextStyles.labelLarge,
                                                ),
                                                if (agent
                                                    .baseLocation
                                                    .isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    agent.baseLocation,
                                                    style: AppTextStyles.caption
                                                        .copyWith(
                                                          color:
                                                              AppColors
                                                                  .textSecondary,
                                                        ),
                                                  ),
                                                ],
                                                if (agent.totalRatings > 0) ...[
                                                  const SizedBox(height: 4),
                                                  Row(
                                                    children: [
                                                      Icon(
                                                        Icons.star,
                                                        size: 14,
                                                        color:
                                                            AppColors.warning,
                                                      ),
                                                      const SizedBox(width: 2),
                                                      Text(
                                                        agent.ratingDisplay,
                                                        style: AppTextStyles
                                                            .caption
                                                            .copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                      ),
                                                      Text(
                                                        ' (${agent.totalInspections} inspections)',
                                                        style: AppTextStyles
                                                            .caption
                                                            .copyWith(
                                                              color:
                                                                  AppColors
                                                                      .textHint,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          if (isSelected)
                                            Icon(
                                              Icons.check_circle,
                                              color: AppColors.primary,
                                              size: 24,
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
              );
            },
          ),
    );
  }

  Widget _buildAgreementReadinessNote() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.description_outlined,
              size: 18,
              color: AppColors.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Have your tenancy agreement ready',
                  style: AppTextStyles.labelMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'You\'ll need a signed tenancy agreement to close a deal '
                  'with a tenant. Prepare it now so you can upload it when a '
                  'tenant is ready to finalize.',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
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
            onTap:
                () => setState(() {
                  _inspectionHandler = 'self';
                  _selectedAgentId = null;
                  _selectedAgentName = null;
                  // Self-handled means no agent to pay → turn off any agent fee
                  // so the two controls can't contradict each other.
                  _includeAgentFee = false;
                  _agentFeeController.clear();
                }),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    _inspectionHandler == 'self'
                        ? AppColors.primary.withAlpha(13)
                        : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      _inspectionHandler == 'self'
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
                      color:
                          _inspectionHandler == 'self'
                              ? AppColors.primary.withAlpha(26)
                              : AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.person,
                      color:
                          _inspectionHandler == 'self'
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
                            color:
                                _inspectionHandler == 'self'
                                    ? AppColors.primary
                                    : AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'You\'ll conduct viewings. Tenants pay a booking fee.',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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
                  if (_inspectionHandler == 'self') ...[
                    const SizedBox(width: 8),
                    Icon(
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
                color:
                    _inspectionHandler == 'agent'
                        ? AppColors.primary.withAlpha(13)
                        : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      _inspectionHandler == 'agent'
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
                      color:
                          _inspectionHandler == 'agent'
                              ? AppColors.primary.withAlpha(26)
                              : AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.support_agent,
                      color:
                          _inspectionHandler == 'agent'
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
                            color:
                                _inspectionHandler == 'agent'
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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
                    Icon(
                      Icons.check_circle,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Agent selection (required when agent is chosen)
          if (_inspectionHandler == 'agent') ...[
            const SizedBox(height: 16),

            // Selected agent display or pick button
            if (_selectedAgentId != null) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.success.withAlpha(80)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.success.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.person_pin,
                        color: AppColors.success,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedAgentName ?? 'Agent Selected',
                            style: AppTextStyles.labelLarge.copyWith(
                              color: AppColors.success,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Will handle all property inspections',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _showAgentPicker,
                      child: Text(
                        'Change',
                        style: AppTextStyles.labelSmall.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              GestureDetector(
                onTap: _showAgentPicker,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withAlpha(13),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.warning.withAlpha(80),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.warning.withAlpha(26),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.person_add,
                          color: AppColors.warning,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Select an Agent',
                              style: AppTextStyles.labelLarge.copyWith(
                                color: AppColors.warning,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Required — choose a verified agent for inspections',
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: AppColors.warning),
                    ],
                  ),
                ),
              ),
            ],

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
                  Icon(Icons.info_outline, size: 18, color: AppColors.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tenants pay a flat ₦10,000 inspection fee. Transport to and from the property is arranged directly between the tenant and the agent.',
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
              Icon(Icons.calendar_month, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Text('Inspection Availability', style: AppTextStyles.labelLarge),
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
            children:
                _weekDays.map((day) {
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color:
                            isSelected
                                ? AppColors.primary.withAlpha(26)
                                : AppColors.background,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color:
                              isSelected ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Text(
                        day.substring(0, 3), // Mon, Tue, etc.
                        style: AppTextStyles.labelMedium.copyWith(
                          color:
                              isSelected
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
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
                  color:
                      isSelected
                          ? AppColors.primary.withAlpha(13)
                          : AppColors.background,
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
                        color:
                            isSelected ? AppColors.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color:
                              isSelected ? AppColors.primary : AppColors.border,
                          width: 2,
                        ),
                      ),
                      child:
                          isSelected
                              ? const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.white,
                              )
                              : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            slot['label']!,
                            style: AppTextStyles.labelMedium,
                          ),
                          Text(
                            slot['time']!,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
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
                Icon(Icons.lightbulb_outline, size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tenants will only be able to request inspections during these times',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.info,
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

  Widget _buildPreviewStep() {
    final rent = _parseRentAmount();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preview your listing', style: AppTextStyles.h4),
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
            _titleController.text.isNotEmpty
                ? _titleController.text
                : 'Property Title',
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
              Icon(Icons.location_on, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${_addressController.text}, ${_cityController.text}, ${_stateController.text}',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
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
          if (_livingRooms > 0)
            _buildPreviewSection('Living Rooms', '$_livingRooms'),
          if (_guestRooms > 0)
            _buildPreviewSection('Guest Rooms', '$_guestRooms'),
          if (_kitchens > 0) _buildPreviewSection('Kitchens', '$_kitchens'),
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
                    Icon(
                      Icons.calendar_month,
                      size: 16,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Inspection Availability',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
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
              children:
                  _selectedAmenities
                      .map(
                        (a) => Chip(
                          label: Text(a, style: AppTextStyles.caption),
                          backgroundColor: AppColors.primaryLight.withAlpha(26),
                        ),
                      )
                      .toList(),
            ),
          ],

          const SizedBox(height: 24),

          // Fee info — Total Package breakdown
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
                  'Total Package Breakdown',
                  style: AppTextStyles.labelLarge,
                ),
                const SizedBox(height: 16),
                _buildFeeRow('Rent', rent),
                if (_includeAgentFee &&
                    _parseAmountFromController(_agentFeeController) > 0) ...[
                  const SizedBox(height: 8),
                  _buildFeeRow(
                    'Agent Fee',
                    _parseAmountFromController(_agentFeeController),
                  ),
                ],
                const SizedBox(height: 8),
                _buildFeeRow(
                  'Caution Deposit',
                  _parseAmountFromController(_cautionDepositController),
                ),
                // Recurring dues in preview
                if (_totalDuesYearly() > 0) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.repeat, size: 14, color: AppColors.info),
                      const SizedBox(width: 6),
                      Text(
                        'Recurring Dues',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.info,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ..._collectRecurringDues().map((due) {
                    final amount = (due['amount'] as num?)?.toDouble() ?? 0;
                    final freq = due['frequency'] as String? ?? 'yearly';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '  ${due['name']}',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          Text(
                            '₦${_formatAmount(amount)}/${freq == 'monthly' ? 'mo' : 'yr'}',
                            style: AppTextStyles.caption.copyWith(
                              fontFamily: 'Roboto',
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(),
                ),
                _buildFeeRow(
                  'Total Package',
                  rent +
                      (_includeAgentFee
                          ? _parseAmountFromController(_agentFeeController)
                          : 0) +
                      _parseAmountFromController(_cautionDepositController),
                  isTotal: true,
                ),
                const SizedBox(height: 12),
                Text(
                  'Renewal after first year: ₦${_formatAmount(rent)}/${_rentPeriod == 'yearly' ? 'year' : 'month'}',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Tenant Inspection Fee',
                      style: AppTextStyles.bodyMedium,
                    ),
                    Text(
                      '₦10,000 flat',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
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
          Text(
            label,
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
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
          style:
              isTotal
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
                  side: BorderSide(color: AppColors.border),
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
              text:
                  _currentStep == _totalSteps - 1
                      ? 'Publish Property'
                      : 'Continue',
              onPressed:
                  _currentStep == _totalSteps - 1
                      ? _publishProperty
                      : _nextStep,
              isLoading: _isPublishing,
            ),
          ),
        ],
      ),
    );
  }
}

class _DocTypeChip extends StatelessWidget {
  final String label, value;
  final bool selected;
  final VoidCallback onTap;

  const _DocTypeChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withAlpha(26) : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: selected ? AppColors.primary : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
