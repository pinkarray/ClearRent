import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/utils/document_file_picker.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../shared/widgets/description_prompts.dart';
import '../../../../services/property_service.dart';

/// Custom formatter that adds commas to numbers as you type
class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    
    if (digitsOnly.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

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

class EditPropertyScreen extends StatefulWidget {
  final PropertyModel property;

  const EditPropertyScreen({
    super.key,
    required this.property,
  });

  @override
  State<EditPropertyScreen> createState() => _EditPropertyScreenState();
}

class _EditPropertyScreenState extends State<EditPropertyScreen> {
  final PropertyService _propertyService = PropertyService();
  final ImagePicker _imagePicker = ImagePicker();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  bool _isSaving = false;
  bool _hasChanges = false;

  // Existing images (URLs from Cloudinary)
  late List<String> _existingImageUrls;
  // New images to upload (local files)
  final List<File> _newImageFiles = [];
  // Images marked for deletion
  final List<String> _imagesToDelete = [];

  // Ownership document
  String? _ownershipDocUrl;       // existing Cloudinary URL
  File? _newOwnershipDocFile;     // newly picked file (image or PDF)
  String? _ownershipDocType;      // 'c_of_o' | 'deed' | 'other'
  bool _isUploadingDoc = false;

  // Form controllers
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  final FocusNode _descriptionFocusNode = FocusNode();
  late final TextEditingController _rentController;
  late final TextEditingController _agentFeeController;
  late final TextEditingController _cautionDepositController;
  late final TextEditingController _addressController;
  late final TextEditingController _cityController;
  late final TextEditingController _stateController;

  // Property details
  late String _propertyType;
  late int _bedrooms;
  late int _bathrooms;
  late int _toilets;
  late int _livingRooms;
  late int _guestRooms;
  late int _kitchens;
  late String _rentPeriod;
  late List<String> _selectedAmenities;
  late List<String> _selectedRules;
  late bool _isAvailable;
  late String _inspectionHandler;
  late bool _includeAgentFee; // Agent fee is optional
  // Whether the deposit comes back at move-out. Locked while a tenant is
  // sitting, same as the amount — the promise can't change mid-tenancy.
  late bool _cautionDepositRefundable;
  final List<String> _ceilingTypes = [];

  // Agent assignment
  String? _assignedAgentId;
  String? _assignedAgentName;
  bool _isLoadingAgent = false;

  // Inspection availability
  late List<String> _availableDays;
  late List<String> _availableTimeSlots;

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
    _initializeFromProperty();
  }

  void _initializeFromProperty() {
    final p = widget.property;
    
    _existingImageUrls = List.from(p.images);
    
    _titleController = TextEditingController(text: p.title);
    _descriptionController = TextEditingController(text: p.description);
    // FIX: Format rent as plain number with commas, not abbreviated (e.g., "3,500,000" not "3.5M")
    _rentController = TextEditingController(text: _formatRentForInput(p.rent));
    _agentFeeController = TextEditingController(text: _formatRentForInput(p.agentFee));
    _cautionDepositController = TextEditingController(text: _formatRentForInput(p.cautionDeposit));
    // Exact street address lives in the gated subdoc — loaded in
    // _loadFreshPropertyData(). Start empty to avoid showing a stale value.
    _addressController = TextEditingController(text: p.address);
    _cityController = TextEditingController(text: p.city);
    _stateController = TextEditingController(text: p.state);
    
    _propertyType = p.propertyType;
    _bedrooms = p.bedrooms;
    _bathrooms = p.bathrooms;
    _toilets = p.toilets;
    _livingRooms = p.livingRooms;
    _guestRooms = p.guestRooms;
    _kitchens = p.kitchens;
    _rentPeriod = p.rentFrequency;
    _selectedAmenities = List.from(p.amenities);
    _selectedRules = List.from(p.rules);
    _isAvailable = p.isAvailable;
    _inspectionHandler = p.inspectionHandler;
    _includeAgentFee = p.agentFee > 0; // Derive from existing data
    _cautionDepositRefundable = p.cautionDepositRefundable;
    
    // Initialize inspection availability
    _availableDays = List.from(p.inspectionDays);
    _availableTimeSlots = List.from(p.inspectionTimeSlots);

    // Initialize ownership document
    _ownershipDocUrl = p.ownershipDocUrl;
    _ownershipDocType = p.ownershipDocType;
    _ceilingTypes
      ..clear()
      ..addAll(p.ceilingTypes);

    // Listen for changes
    _titleController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);
    _rentController.addListener(_onFieldChanged);
    _agentFeeController.addListener(_onFieldChanged);
    _cautionDepositController.addListener(_onFieldChanged);
    _addressController.addListener(_onFieldChanged);
    _cityController.addListener(_onFieldChanged);
    _stateController.addListener(_onFieldChanged);
    
    // Load fresh property data from Firestore to get current agent assignment
    _loadFreshPropertyData();
  }

  /// Load fresh property data from Firestore to get current agent assignment
  Future<void> _loadFreshPropertyData() async {
    try {
      final doc = await _firestore.collection('properties').doc(widget.property.id).get();
      if (doc.exists && mounted) {
        final data = doc.data()!;
        setState(() {
          _assignedAgentId = data['assignedAgentId'];
          _inspectionHandler = data['inspectionHandler'] ?? 'self';
        });
        
        if (_assignedAgentId != null) {
          _loadAgentInfo();
        }
      }

      // Load the exact street address from the gated subdoc (the owner is
      // entitled) so the field prefills with the real address for editing.
      final loc = await _propertyService.getExactLocation(widget.property.id);
      if (mounted && loc != null && loc.address.isNotEmpty) {
        _addressController.text = loc.address;
        // Loading the stored value isn't a user edit — don't flag unsaved.
        setState(() => _hasChanges = false);
      }
    } catch (e) {
      debugPrint('❌ Error loading fresh property data: $e');
      // Fallback to widget.property data
      _assignedAgentId = widget.property.assignedAgentId;
      if (_assignedAgentId != null) {
        _loadAgentInfo();
      }
    }
  }

  /// Format rent as plain number with commas for the input field
  /// e.g., 3500000 -> "3,500,000"
  String _formatRentForInput(double rent) {
    final intValue = rent.toInt();
    final chars = intValue.toString().split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) {
        result.add(',');
      }
      result.add(chars[i]);
    }
    return result.reversed.join('');
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

  Future<void> _loadAgentInfo() async {
    if (_assignedAgentId == null) return;
    
    setState(() => _isLoadingAgent = true);
    
    try {
      final doc = await _firestore.collection('users').doc(_assignedAgentId).get();
      if (doc.exists && mounted) {
        setState(() {
          _assignedAgentName = doc.data()?['fullName'] ?? 'Unknown Agent';
          _isLoadingAgent = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading agent info: $e');
      if (mounted) {
        setState(() => _isLoadingAgent = false);
      }
    }
  }

  void _onFieldChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _descriptionFocusNode.dispose();
    _rentController.dispose();
    _agentFeeController.dispose();
    _cautionDepositController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    super.dispose();
  }

  double _parseRentAmount() {
    final cleanedText = _rentController.text.replaceAll(',', '');
    return double.tryParse(cleanedText) ?? 0.0;
  }

  double _parseAmountFromController(TextEditingController controller) {
    final cleanedText = controller.text.replaceAll(',', '');
    return double.tryParse(cleanedText) ?? 0.0;
  }

  Future<void> _pickFromGallery() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _newImageFiles.add(File(image.path));
          _hasChanges = true;
        });
      }
    } catch (e) {
      _showError('Failed to pick image. Please try again.');
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
          _newImageFiles.add(File(image.path));
          _hasChanges = true;
        });
      }
    } catch (e) {
      _showError('Failed to take photo. Please try again.');
    }
  }

  void _removeExistingImage(String url) {
    setState(() {
      _existingImageUrls.remove(url);
      _imagesToDelete.add(url);
      _hasChanges = true;
    });
  }

  void _removeNewImage(int index) {
    setState(() {
      _newImageFiles.removeAt(index);
      _hasChanges = true;
    });
  }

  Future<void> _selectAgent() async {
    final result = await context.push<bool>(
      '/landlord/select-agent',
      extra: {
        'propertyId': widget.property.id,
        'propertyCity': _cityController.text.trim(),
      },
    );

    if (result == true && mounted) {
      // Refresh property to get updated agent info from Firestore
      try {
        final doc = await _firestore.collection('properties').doc(widget.property.id).get();
        if (doc.exists && mounted) {
          final data = doc.data()!;
          setState(() {
            _assignedAgentId = data['assignedAgentId'];
            _assignedAgentName = data['assignedAgentName'];
            // Don't set _hasChanges = true here since it's already saved to Firestore
          });
          
          // If we got the name directly, no need to load again
          if (_assignedAgentName == null && _assignedAgentId != null) {
            _loadAgentInfo();
          }
        }
      } catch (e) {
        debugPrint('❌ Error refreshing property after agent selection: $e');
      }
    }
  }

  Future<void> _removeAgent() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Agent?'),
        content: const Text('This agent will no longer handle inspections for this property. You\'ll need to handle inspections yourself or assign a new agent.'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _assignedAgentId = null;
        _assignedAgentName = null;
        _hasChanges = true;
      });
    }
  }

  bool _validateForm() {
    if (_existingImageUrls.isEmpty && _newImageFiles.isEmpty) {
      _showError('Please add at least one photo');
      return false;
    }
    if (_titleController.text.trim().isEmpty) {
      _showError('Please enter a title');
      return false;
    }
    if (_descriptionController.text.trim().isEmpty) {
      _showError('Please enter a description');
      return false;
    }
    if (_addressController.text.trim().isEmpty) {
      _showError('Please enter the address');
      return false;
    }
    if (_cityController.text.trim().isEmpty) {
      _showError('Please enter the city');
      return false;
    }
    if (_stateController.text.trim().isEmpty) {
      _showError('Please enter the state');
      return false;
    }
    if (_parseRentAmount() <= 0) {
      _showError('Please enter a valid rent amount');
      return false;
    }
    if (_includeAgentFee && _parseAmountFromController(_agentFeeController) <= 0) {
      _showError('Please enter a valid agent fee amount');
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
    // Validate agent assignment if agent handler is selected
    if (_inspectionHandler == 'agent' && _assignedAgentId == null) {
      _showError('Please select an agent to handle inspections');
      return false;
    }
    // An admin approved a specific FILE as a specific type. Relabelling it
    // without uploading the matching document would make the record lie about
    // what was actually reviewed, so firestore.rules rejects that write —
    // catch it here and say why, instead of letting the save fail silently and
    // snap back to the old label.
    if (_ownershipDocType != widget.property.ownershipDocType &&
        _isDocApproved &&
        _newOwnershipDocFile == null) {
      _showError(
        'Your ${_docTypeLabel(widget.property.ownershipDocType)} was already '
        'approved. To change the document type, upload the '
        '${_docTypeLabel(_ownershipDocType)} itself — it will go back for '
        'review.',
      );
      return false;
    }
    return true;
  }

  /// This listing is a unit inside a building. The building holds the single
  /// ownership document an admin reviews; the unit owns none of its own. A
  /// per-unit doc type could only ever agree with the building's redundantly or
  /// contradict it misleadingly — which is exactly what happened in production —
  /// so the whole doc section is hidden and never written for a grouped unit.
  bool get _isGrouped => widget.property.buildingId != null;

  /// The admin has already reviewed and approved the document on file. Grouped
  /// units inherit their building's status, so this only governs standalone
  /// listings — the same scope the save path uses.
  bool get _isDocApproved =>
      widget.property.ownershipDocStatus == 'verified' && !_isGrouped;

  /// Human label for a stored ownership-doc type value.
  String _docTypeLabel(String? type) {
    switch (type) {
      case 'c_of_o':
        return 'C of O';
      case 'deed':
        return 'Deed of Assignment';
      case 'other':
        return 'other document';
      default:
        return 'document';
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _saveChanges() async {
    if (!_validateForm()) return;
    final hasActiveTenants = (widget.property.currentTenantsCount ?? 0) > 0;

    setState(() => _isSaving = true);

    try {
      // Upload new images if any
      List<String> allImageUrls = List.from(_existingImageUrls);
      
      if (_newImageFiles.isNotEmpty) {
        _showProgress('Uploading new images...');
        final newUrls = await _propertyService.uploadImages(_newImageFiles);
        if (mounted) Navigator.pop(context); // Close progress
        
        if (newUrls.isEmpty && _newImageFiles.isNotEmpty) {
          _showError('Failed to upload some images');
          setState(() => _isSaving = false);
          return;
        }
        allImageUrls.addAll(newUrls);
      }

      // Upload ownership document if a new one was picked
      String? finalDocUrl = _ownershipDocUrl;
      if (_newOwnershipDocFile != null) {
        setState(() => _isUploadingDoc = true);
        try {
          // Private Storage (not Cloudinary) — C of O is sensitive PII.
          final path =
              await _propertyService.uploadOwnershipDoc(_newOwnershipDocFile!);
          if (path != null) finalDocUrl = path;
        } catch (e) {
          debugPrint('⚠️ Doc upload failed: $e');
        }
        if (mounted) setState(() => _isUploadingDoc = false);
      }

      // Prepare updates
      final updates = <String, dynamic>{
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'propertyType': _propertyType,
        'bedrooms': _bedrooms,
        'bathrooms': _bathrooms,
        'toilets': _toilets,
        'livingRooms': _livingRooms,
        'guestRooms': _guestRooms,
        'kitchens': _kitchens,
        'images': allImageUrls,
        // Only write the address when non-empty, so a failed subdoc load can
        // never blank out the stored address. Routed to the gated subdoc by
        // PropertyService.updateProperty.
        if (_addressController.text.trim().isNotEmpty)
          'address': _addressController.text.trim(),
        'city': _cityController.text.trim(),
        'state': _stateController.text.trim(),
        if (!hasActiveTenants) ...{
          'rent': _parseRentAmount(),
          'rentFrequency': _rentPeriod,
          'agentFee': _includeAgentFee ? _parseAmountFromController(_agentFeeController) : 0,
          'cautionDeposit': _parseAmountFromController(_cautionDepositController),
          'cautionDepositRefundable': _cautionDepositRefundable,
        },
        'amenities': _selectedAmenities,
        'ceilingTypes': _ceilingTypes,
        'rules': _selectedRules,
        'isAvailable': _isAvailable,
        'inspectionHandler': _inspectionHandler,
        'inspectionDays': _availableDays,
        'inspectionTimeSlots': _availableTimeSlots,
        // A grouped unit owns no document — the building's is the reviewed
        // artifact, and firestore.rules now rejects any doc field on a unit.
        if (!_isGrouped && finalDocUrl != null) 'ownershipDocUrl': finalDocUrl,
        if (!_isGrouped && _ownershipDocType != null)
          'ownershipDocType': _ownershipDocType,
      };

      // A changed ownership doc must go back through admin review — never keep
      // the old 'verified' status over a document the admin didn't approve.
      // This covers RE-LABELLING too, not just re-uploading: admin approves a
      // file as 'c_of_o' and the owner silently switches it to 'other'/'deed',
      // and the verification now vouches for something it never reviewed. The
      // matching firestore.rules guard rejects the write outright, so this must
      // stay in step or a legitimate relabel fails with a permission error.
      // Standalone listings only; grouped units inherit their building's status.
      final docChanged = _newOwnershipDocFile != null ||
          _ownershipDocType != widget.property.ownershipDocType;
      if (docChanged && !_isGrouped) {
        updates['ownershipDocStatus'] = 'pending';
        updates['isAvailable'] = false;
      }

      // Handle agent assignment changes
      if (_inspectionHandler == 'self') {
        // Clear agent if switching to self
        updates['assignedAgentId'] = null;
        updates['assignedAgentName'] = null;
        updates['assignedAgentPhone'] = null;
      } else if (_assignedAgentId == null && widget.property.assignedAgentId != null) {
        // Agent was removed
        updates['assignedAgentId'] = null;
        updates['assignedAgentName'] = null;
        updates['assignedAgentPhone'] = null;
      }
      // Note: If a new agent was assigned via the selection screen, it's already saved

      // Guard: don't strand a tenant mid-inspection. If the agent currently
      // handling this property is being removed or swapped out while they have
      // a pending or scheduled inspection here, block the change — mirrors the
      // agent's own self-unassign guard (agentHasActiveInspectionOnProperty).
      // Query by propertyId only and filter in code, to avoid a composite index.
      final currentAgentId = widget.property.assignedAgentId;
      final removingAgent = currentAgentId != null &&
          (_inspectionHandler == 'self' || _assignedAgentId != currentAgentId);
      if (removingAgent) {
        const activeStatuses = [
          'pending',
          'pendingVerification',
          'pendingPayment',
          'approved',
        ];
        final snap = await _firestore
            .collection('inspection_requests')
            .where('propertyId', isEqualTo: widget.property.id)
            .get();
        final hasActive = snap.docs.any((d) {
          final data = d.data();
          return data['agentId'] == currentAgentId &&
              activeStatuses.contains(data['status']);
        });
        if (hasActive) {
          if (!mounted) return;
          _showError(
            'This agent has a pending or scheduled inspection on this property. '
            'Wait for it to be completed or declined before changing the '
            'handler — otherwise the tenant would be left without a handler.',
          );
          return;
        }
      }

      _showProgress('Saving changes...');

      final success = await _propertyService.updateProperty(
        widget.property.id,
        updates,
      );

      if (!mounted) return;
      Navigator.pop(context); // Close progress

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Property updated successfully!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        context.pop(true); // Return true to indicate refresh needed
      } else {
        _showError('Failed to save changes. Please try again.');
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      _showError('Something went wrong: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showProgress(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            Text(message, style: AppTextStyles.bodyMedium),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  void _showDiscardConfirmation() {
    if (!_hasChanges) {
      context.pop();
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved changes. Are you sure you want to discard them?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Keep editing', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.pop();
            },
            child: Text('Discard', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showDiscardConfirmation();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.close, color: AppColors.textPrimary),
            onPressed: _showDiscardConfirmation,
          ),
          title: Text('Edit Property', style: AppTextStyles.h4),
          centerTitle: true,
          actions: [
            if (_hasChanges)
              TextButton(
                onPressed: _isSaving ? null : _saveChanges,
                child: Text(
                  'Save',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: _isSaving ? AppColors.textHint : AppColors.primary,
                  ),
                ),
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Availability toggle at top
              _buildAvailabilityToggle(),
              const SizedBox(height: 24),

              // Photos section
              _buildSectionTitle('Photos'),
              const SizedBox(height: 12),
              _buildPhotosSection(),
              const SizedBox(height: 24),

              // Ownership document
              _buildSectionTitle('Ownership Document'),
              const SizedBox(height: 4),
              Text(
                _isGrouped
                    ? 'This unit is part of a building. One ownership document is held and verified for the whole building, so there is nothing to upload here.'
                    : 'Upload a Certificate of Occupancy, Deed of Assignment, or other proof of ownership. This gives tenants confidence and earns your listing a verified badge.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 12),
              if (!_isGrouped) _buildOwnershipDocSection(),
              const SizedBox(height: 24),

              // Basic info
              _buildSectionTitle('Basic Information'),
              const SizedBox(height: 12),
              _buildBasicInfoSection(),
              const SizedBox(height: 24),

              // Location
              _buildSectionTitle('Location'),
              const SizedBox(height: 12),
              _buildLocationSection(),
              const SizedBox(height: 24),

              // Pricing
              _buildSectionTitle('Pricing'),
              const SizedBox(height: 12),
              _buildPricingSection(),
              const SizedBox(height: 24),

              // Inspection settings
              _buildSectionTitle('Inspection Settings'),
              const SizedBox(height: 12),
              _buildInspectionSection(),
              const SizedBox(height: 24),

              // Amenities
              _buildSectionTitle('Amenities'),
              const SizedBox(height: 12),
              _buildAmenitiesSection(),
              const SizedBox(height: 24),

              // Ceiling Type
              _buildSectionTitle('Ceiling Type'),
              const SizedBox(height: 4),
              Text(
                'What type of ceiling does the property have?',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildCeilingChip('POP', 'pop'),
                  _buildCeilingChip('PVC', 'pvc'),
                  _buildCeilingChip('Concrete', 'concrete'),
                  _buildCeilingChip('Asbestos', 'asbestos'),
                  _buildCeilingChip('Slate', 'slate'),
                  _buildCeilingChip('None', 'none'),
                ],
              ),
              const SizedBox(height: 24),

              // House rules
              _buildSectionTitle('House Rules'),
              const SizedBox(height: 12),
              _buildRulesSection(),
              const SizedBox(height: 100),
            ],
          ),
        ),
        bottomSheet: _buildBottomBar(),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(title, style: AppTextStyles.h4);
  }

  Widget _buildAvailabilityToggle() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isAvailable ? AppColors.success.withAlpha(26) : AppColors.warning.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isAvailable ? AppColors.success : AppColors.warning,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _isAvailable ? Icons.visibility : Icons.visibility_off,
            color: _isAvailable ? AppColors.success : AppColors.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isAvailable ? 'Property is Available' : 'Property is Occupied',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: _isAvailable ? AppColors.success : AppColors.warning,
                  ),
                ),
                Text(
                  _isAvailable 
                      ? 'Visible to tenants searching for properties'
                      : 'Hidden from search results',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Switch(
            value: _isAvailable,
            onChanged: (value) {
              setState(() {
                _isAvailable = value;
                _hasChanges = true;
              });
            },
            activeThumbColor: AppColors.success,
          ),
        ],
      ),
    );
  }

  Widget _buildPhotosSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Existing images
        if (_existingImageUrls.isNotEmpty) ...[
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _existingImageUrls.length,
              itemBuilder: (context, index) {
                final url = _existingImageUrls[index];
                return Container(
                  width: 120,
                  margin: EdgeInsets.only(right: index < _existingImageUrls.length - 1 ? 12 : 0),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: url,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: AppColors.surface,
                            child: Center(
                              child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: AppColors.surface,
                            child: Icon(Icons.image_not_supported, color: AppColors.textHint),
                          ),
                        ),
                      ),
                      if (index == 0)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Cover',
                              style: AppTextStyles.labelSmall.copyWith(color: Colors.white, fontSize: 10),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _removeExistingImage(url),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(128),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],

        // New images
        if (_newImageFiles.isNotEmpty) ...[
          Text('New Photos', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _newImageFiles.length,
              itemBuilder: (context, index) {
                return Container(
                  width: 120,
                  margin: EdgeInsets.only(right: index < _newImageFiles.length - 1 ? 12 : 0),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          _newImageFiles[index],
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _removeNewImage(index),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(128),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Add photo buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Gallery'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: AppColors.primary),
                  foregroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _takePhoto,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: const Text('Camera'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: AppColors.border),
                  foregroundColor: AppColors.textSecondary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBasicInfoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextField(
          label: 'Property Title',
          hint: 'e.g. Spacious 3 Bedroom Flat',
          controller: _titleController,
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 16),

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
            // Hidden alongside add-property until the commercial branch exists.
          ],
        ),
        const SizedBox(height: 16),

        // Counters
        Row(
          children: [
            Expanded(child: _buildCounter('Bedrooms', _bedrooms, (v) {
              setState(() { _bedrooms = v; _hasChanges = true; });
            })),
            const SizedBox(width: 12),
            Expanded(child: _buildCounter('Bathrooms', _bathrooms, (v) {
              setState(() { _bathrooms = v; _hasChanges = true; });
            })),
            const SizedBox(width: 12),
            Expanded(child: _buildCounter('Toilets', _toilets, (v) {
              setState(() { _toilets = v; _hasChanges = true; });
            })),
          ],
        ),
        const SizedBox(height: 12),

        // Second row: Living Room, Guest Room, Kitchen
        Row(
          children: [
            Expanded(child: _buildCounter('Living Room', _livingRooms, (v) {
              setState(() { _livingRooms = v; _hasChanges = true; });
            })),
            const SizedBox(width: 12),
            Expanded(child: _buildCounter('Guest Room', _guestRooms, (v) {
              setState(() { _guestRooms = v; _hasChanges = true; });
            })),
            const SizedBox(width: 12),
            Expanded(child: _buildCounter('Kitchen', _kitchens, (v) {
              setState(() { _kitchens = v; _hasChanges = true; });
            })),
          ],
        ),
        const SizedBox(height: 16),

        AppTextField(
          label: 'Description',
          hint: 'Describe your property...',
          controller: _descriptionController,
          focusNode: _descriptionFocusNode,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
        ),
        DescriptionPrompts(
          controller: _descriptionController,
          focusNode: _descriptionFocusNode,
          onInserted: () => setState(() => _hasChanges = true),
        ),
      ],
    );
  }

  Widget _buildTypeChip(String label, String value) {
    final isSelected = _propertyType == value;
    return GestureDetector(
      onTap: () {
        setState(() { _propertyType = value; _hasChanges = true; });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withAlpha(26) : AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () { if (value > 0) onChanged(value - 1); },
                child: Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.remove, size: 18),
                ),
              ),
              Text('$value', style: AppTextStyles.labelLarge),
              GestureDetector(
                onTap: () => onChanged(value + 1),
                child: Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.add, size: 18, color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLocationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextField(
          label: 'Address',
          hint: 'Street address',
          controller: _addressController,
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 8),
        // Address note — changing it updates the map pin for tenants
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.info.withAlpha(13),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.info.withAlpha(50)),
          ),
          child: Row(children: [
            Icon(Icons.info_outline, size: 14, color: AppColors.info),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your exact address is hidden from tenants until their inspection is approved. Only edit this to correct a typo — not to move the property to a different place.',
                style: AppTextStyles.caption.copyWith(color: AppColors.info, height: 1.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: AppTextField(
                label: 'City',
                hint: 'City',
                controller: _cityController,
                textCapitalization: TextCapitalization.words,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppTextField(
                label: 'State',
                hint: 'State',
                controller: _stateController,
                textCapitalization: TextCapitalization.words,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPricingSection() {
    final hasActiveTenants = (widget.property.currentTenantsCount ?? 0) > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Rent Amount (₦)', style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),

        if (hasActiveTenants) ...[
          // Locked rent display — active tenants present
          _buildLockedAmountDisplay('₦${_rentController.text}', _rentPeriod == 'yearly' ? 'Per Year' : 'Per Month'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(13),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withAlpha(50)),
            ),
            child: Row(children: [
              Icon(Icons.warning_amber_outlined, size: 14, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pricing cannot be changed while you have active tenants. To propose changes, use the Rent Review feature.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.warning, height: 1.5),
                ),
              ),
            ]),
          ),
        ] else ...[
          // Editable rent field — no active tenants
          _buildNairaInput(controller: _rentController),
        ],
        const SizedBox(height: 16),

        Text('Rent Period', style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        // Frequency is no longer switchable — yearly only at launch (monthly is
        // v2). Existing monthly properties keep their stored value (shown as-is,
        // not rewritten); new ones are always yearly.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.calendar_today_outlined,
                  size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(
                _rentPeriod == 'yearly' ? 'Per Year' : 'Per Month',
                style: AppTextStyles.labelMedium,
              ),
              const Spacer(),
              if (_rentPeriod == 'yearly')
                Text(
                  'Monthly coming soon',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Agent Fee (optional toggle)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _includeAgentFee ? AppColors.primary.withAlpha(80) : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.person_outline,
                size: 20,
                color: _includeAgentFee ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Include an agent fee?', style: AppTextStyles.labelMedium),
                    if (!_includeAgentFee)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Agents are optional on ClearRent',
                          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
              Switch(
                value: _includeAgentFee,
                activeThumbColor: AppColors.primary,
                onChanged: hasActiveTenants ? null : (v) {
                  setState(() {
                    _includeAgentFee = v;
                    if (v) {
                      // Agent fee requires an assigned agent to earn it →
                      // force agent-handled inspection.
                      _inspectionHandler = 'agent';
                    } else {
                      _agentFeeController.clear();
                      _inspectionHandler = 'self';
                      _assignedAgentId = null;
                      _assignedAgentName = null;
                    }
                    _hasChanges = true;
                  });
                },
              ),
            ],
          ),
        ),
        if (_includeAgentFee) ...[
          const SizedBox(height: 16),
          Text('Agent Fee (₦)', style: AppTextStyles.labelMedium),
          const SizedBox(height: 4),
          Text(
            'Flat amount collected by the agent, paid by the tenant.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          if (hasActiveTenants)
            _buildLockedAmountDisplay('₦${_agentFeeController.text}', 'Agent Fee')
          else
            _buildNairaInput(controller: _agentFeeController),
        ],
        const SizedBox(height: 24),

        // Caution Deposit
        Text('Caution Deposit (₦)', style: AppTextStyles.labelMedium),
        const SizedBox(height: 4),
        Text(
          'Deposit held against damage to the property.',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        if (hasActiveTenants)
          _buildLockedAmountDisplay('₦${_cautionDepositController.text}', 'Caution Deposit')
        else
          _buildNairaInput(controller: _cautionDepositController),
        const SizedBox(height: 12),
        // Refundability is part of the deal the tenant accepted, so it is
        // frozen while the unit is occupied, exactly like the amount.
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Refundable at move-out',
                    style: AppTextStyles.labelMedium),
                const SizedBox(height: 2),
                Text(
                  _cautionDepositRefundable
                      ? 'Returned in full if the tenant leaves the property '
                          'in good condition.'
                      : 'Tenants are told this deposit is NOT refundable.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Switch(
            value: _cautionDepositRefundable,
            onChanged: hasActiveTenants
                ? null
                : (v) => setState(() => _cautionDepositRefundable = v),
            activeThumbColor: AppColors.primary,
          ),
        ]),

        // Total Package preview
        if (!hasActiveTenants) ...[
          const SizedBox(height: 24),
          _buildTotalPackagePreview(),
        ],
      ],
    );
  }

  /// Reusable Naira input field with comma formatting
  Widget _buildNairaInput({required TextEditingController controller}) {
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
          hintText: '0',
          hintStyle: AppTextStyles.h4.copyWith(color: AppColors.textHint),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Text('₦', style: AppTextStyles.h4.copyWith(color: AppColors.primary)),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }

  /// Locked amount display when tenants are active
  Widget _buildLockedAmountDisplay(String amount, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Icon(Icons.lock_outline, size: 20, color: AppColors.textHint),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            amount,
            style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary),
          ),
          Text(
            subtitle,
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
          ),
        ]),
      ]),
    );
  }

  /// Live Total Package breakdown
  Widget _buildTotalPackagePreview() {
    final rent = _parseRentAmount();
    final agentFee = _includeAgentFee ? _parseAmountFromController(_agentFeeController) : 0.0;
    final cautionDeposit = _parseAmountFromController(_cautionDepositController);
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
              Icon(Icons.receipt_long_outlined, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                'Total Package Preview',
                style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
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

  Widget _buildInspectionSection() {
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
          // Who handles inspections
          Text('Who handles inspections?', style: AppTextStyles.labelLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() { 
                      _inspectionHandler = 'self'; 
                      // Self-handled → no agent fee (keeps fee/handler consistent).
                      _includeAgentFee = false;
                      _agentFeeController.clear();
                      _hasChanges = true; 
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _inspectionHandler == 'self' ? AppColors.primary.withAlpha(26) : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _inspectionHandler == 'self' ? AppColors.primary : AppColors.border,
                        width: _inspectionHandler == 'self' ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.person,
                          color: _inspectionHandler == 'self' ? AppColors.primary : AppColors.textSecondary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Myself',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: _inspectionHandler == 'self' ? AppColors.primary : AppColors.textSecondary,
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
                  onTap: () {
                    setState(() { 
                      _inspectionHandler = 'agent'; 
                      _hasChanges = true; 
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _inspectionHandler == 'agent' ? AppColors.primary.withAlpha(26) : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _inspectionHandler == 'agent' ? AppColors.primary : AppColors.border,
                        width: _inspectionHandler == 'agent' ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.support_agent,
                          color: _inspectionHandler == 'agent' ? AppColors.primary : AppColors.textSecondary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Agent',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: _inspectionHandler == 'agent' ? AppColors.primary : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Agent assignment section (only shown when 'agent' is selected)
          if (_inspectionHandler == 'agent') ...[
            const SizedBox(height: 16),
            _buildAgentAssignmentSection(),
          ],

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 16),

          // Available days
          Text('Available Days', style: AppTextStyles.labelLarge),
          const SizedBox(height: 4),
          Text(
            _inspectionHandler == 'self' 
                ? 'Select days when you\'re available for inspections'
                : 'Select days when inspections are allowed',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
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
                    _hasChanges = true;
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
          Text('Available Time Slots', style: AppTextStyles.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Select preferred inspection times',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
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
                  _hasChanges = true;
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
        ],
      ),
    );
  }

  /// NEW: Agent assignment section
  Widget _buildAgentAssignmentSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.support_agent,
                color: _assignedAgentId != null ? AppColors.success : AppColors.warning,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Assigned Agent',
                style: AppTextStyles.labelMedium.copyWith(
                  color: _assignedAgentId != null ? AppColors.success : AppColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          if (_isLoadingAgent)
            Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
              ),
            )
          else if (_assignedAgentId != null && _assignedAgentName != null)
            // Show assigned agent
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      _assignedAgentName![0].toUpperCase(),
                      style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_assignedAgentName!, style: AppTextStyles.labelLarge),
                      Row(
                        children: [
                          Icon(Icons.verified, size: 14, color: AppColors.success),
                          const SizedBox(width: 4),
                          Text(
                            'Verified Agent',
                            style: AppTextStyles.caption.copyWith(color: AppColors.success),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Change / Remove buttons
                IconButton(
                  onPressed: _selectAgent,
                  icon: Icon(Icons.swap_horiz, color: AppColors.primary),
                  tooltip: 'Change Agent',
                ),
                IconButton(
                  onPressed: _removeAgent,
                  icon: Icon(Icons.close, color: AppColors.error.withAlpha(179)),
                  tooltip: 'Remove Agent',
                ),
              ],
            )
          else
            // No agent assigned - show select button
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withAlpha(13),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.warning.withAlpha(77)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: AppColors.warning, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'No agent assigned. Select an agent to handle inspections for this property.',
                          style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _selectAgent,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Select Agent'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: BorderSide(color: AppColors.primary),
                      foregroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildOwnershipDocSection() {
    final hasDoc = _ownershipDocUrl != null || _newOwnershipDocFile != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasDoc ? AppColors.success.withAlpha(80) : AppColors.border,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Doc type selector
        Text('Document Type', style: AppTextStyles.labelMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            _DocTypeChip(label: 'C of O', value: 'c_of_o', selected: _ownershipDocType == 'c_of_o', onTap: () => setState(() { _ownershipDocType = 'c_of_o'; _hasChanges = true; })),
            _DocTypeChip(label: 'Deed of Assignment', value: 'deed', selected: _ownershipDocType == 'deed', onTap: () => setState(() { _ownershipDocType = 'deed'; _hasChanges = true; })),
            _DocTypeChip(label: 'Other', value: 'other', selected: _ownershipDocType == 'other', onTap: () => setState(() { _ownershipDocType = 'other'; _hasChanges = true; })),
          ],
        ),

        // Once approved, the label is tied to the file the admin actually
        // reviewed — say so up front rather than failing on save.
        if (_isDocApproved) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.info.withAlpha(60)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.lock_outline, size: 15, color: AppColors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Approved as '
                  '${_docTypeLabel(widget.property.ownershipDocType)}. '
                  'To change the type you must upload the matching document — '
                  'it goes back for review and your listing is offline until '
                  'approved.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 16),

        if (hasDoc) ...[
          // Show current doc state
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(13),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.success.withAlpha(50)),
            ),
            child: Row(children: [
              Icon(Icons.verified_outlined, color: AppColors.success, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    _newOwnershipDocFile != null ? 'New document selected' : 'Document on file',
                    style: AppTextStyles.labelMedium.copyWith(color: AppColors.success),
                  ),
                  if (_newOwnershipDocFile != null)
                    Text(
                      _newOwnershipDocFile!.path.split('/').last,
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      'Tap replace to upload a new version',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
                    ),
                ]),
              ),
              TextButton(
                onPressed: _pickOwnershipDoc,
                child: Text('Replace', style: AppTextStyles.labelSmall.copyWith(color: AppColors.primary)),
              ),
            ]),
          ),
        ] else ...[
          // Upload prompt
          GestureDetector(
            onTap: _pickOwnershipDoc,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border, style: BorderStyle.solid),
              ),
              child: Column(children: [
                Icon(Icons.upload_file_outlined, size: 32, color: AppColors.textHint),
                const SizedBox(height: 8),
                Text('Upload document or photo', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text('JPG, PNG or PDF • Max 10MB', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
              ]),
            ),
          ),
        ],

        if (_isUploadingDoc) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(color: AppColors.primary),
        ],
      ]),
    );
  }

  Future<void> _pickOwnershipDoc() async {
    try {
      // PDF or image — a title document is rarely one page, and re-uploading
      // here is exactly what a landlord does after a rejection for an
      // unreadable or incomplete document.
      final file = await DocumentFilePicker.pick(
        context,
        hint: 'A C of O or deed runs to several pages — upload it as one PDF.',
      );
      if (file != null) {
        setState(() {
          _newOwnershipDocFile = file;
          _hasChanges = true;
        });
      }
    } catch (e) {
      _showError('Could not pick document. Please try again.');
    }
  }

  Widget _buildAmenitiesSection() {
    return Wrap(
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
              _hasChanges = true;
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
            side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border),
          ),
        );
      }).toList(),
    );
  }

  /// Ceilings are multi-select, but "None" can't coexist with a real ceiling —
  /// picking one clears the other.
  void _toggleCeilingType(String value) {
    if (_ceilingTypes.contains(value)) {
      _ceilingTypes.remove(value);
      return;
    }
    if (value == 'none') {
      _ceilingTypes.clear();
    } else {
      _ceilingTypes.remove('none');
    }
    _ceilingTypes.add(value);
  }

  Widget _buildCeilingChip(String label, String value) {
    final isSelected = _ceilingTypes.contains(value);
    return GestureDetector(
      onTap: () => setState(() {
        _toggleCeilingType(value);
        _hasChanges = true;
      }),
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

  Widget _buildRulesSection() {
    return Wrap(
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
              _hasChanges = true;
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
            side: BorderSide(color: isSelected ? AppColors.warning : AppColors.border),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
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
      child: AppButton(
        text: 'Save Changes',
        onPressed: _hasChanges ? _saveChanges : null,
        isLoading: _isSaving,
      ),
    );
  }
}

class _DocTypeChip extends StatelessWidget {
  final String label;
  final String value;
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