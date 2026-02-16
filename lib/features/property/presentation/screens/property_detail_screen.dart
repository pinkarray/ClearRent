import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../chat/presentation/widgets/share_property_sheet.dart';
import '../../../../services/property_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/verification_service.dart';
import '../../../tenant/presentation/widgets/request_inspection_sheet.dart';

class PropertyDetailScreen extends StatefulWidget {
  final PropertyModel property;

  const PropertyDetailScreen({super.key, required this.property});

  @override
  State<PropertyDetailScreen> createState() => _PropertyDetailScreenState();
}

class _PropertyDetailScreenState extends State<PropertyDetailScreen> {
  int _currentImageIndex = 0;
  bool _isSaved = false;
  final PageController _imageController = PageController();

  // Services
  late final PropertyService _propertyService;
  late final AuthService _authService;
  late final ConversationService _conversationService;
  late final VerificationService _verificationService;

  // User info
  String? _currentUserId;
  String? _currentUserType;
  bool _isOwner = false;
  bool _isLoading = true;

  bool _hasExistingRequest = false;
  bool _isCheckingRequest = true;

  // Verification status
  bool _isCurrentUserVerified = false;
  bool _isLandlordVerified = false;
  bool _isCheckingVerification = true;

  @override
  void initState() {
    super.initState();
    _propertyService = PropertyService();
    _authService = AuthService();
    _conversationService = ConversationService();
    _verificationService = VerificationService();
    _determineUserContext();
    _checkExistingRequest();
    _checkVerificationStatus();
  }

  @override
  void dispose() {
    _imageController.dispose();
    super.dispose();
  }

  /// Determine if current user is the owner (landlord) or a tenant
  Future<void> _determineUserContext() async {
    try {
      debugPrint('🏠 Property landlordId: ${widget.property.landlordId}');
      debugPrint('🏠 Property ID: ${widget.property.id}');

      final user = _authService.currentUser;

      if (user != null) {
        _currentUserId = user.uid;
        debugPrint('👤 Current user ID: $_currentUserId');

        final profile = await _authService.getUserProfile();
        _currentUserType = profile?['accountType'] ?? 'tenant';
        debugPrint('👤 Account type: $_currentUserType');

        _isOwner = widget.property.landlordId == _currentUserId;

        debugPrint(
          '🔍 Comparing: "${widget.property.landlordId}" == "$_currentUserId"',
        );
        debugPrint('✅ IsOwner: $_isOwner');
      } else {
        debugPrint('❌ No user logged in! _authService.currentUser is null');
      }

      if (mounted) {
        setState(() => _isLoading = false);
      }

      if (!_isOwner && _currentUserType == 'tenant') {
        _trackView();
      }
    } catch (e) {
      debugPrint('❌ Error determining user context: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Check verification status for both current user and landlord
  Future<void> _checkVerificationStatus() async {
    try {
      // Check current user's verification using the existing method (no parameter)
      final currentUserStatus = await _verificationService.getVerificationStatus();
      _isCurrentUserVerified = currentUserStatus.status == VerificationStatus.verified;

      // Check landlord's verification directly from Firestore
      final landlordDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.property.landlordId)
          .get();
      
      if (landlordDoc.exists) {
        final landlordData = landlordDoc.data();
        final landlordVerificationStatus = landlordData?['verificationStatus'] ?? 'none';
        _isLandlordVerified = landlordVerificationStatus == 'verified';
      }

      debugPrint('✅ Current user verified: $_isCurrentUserVerified');
      debugPrint('✅ Landlord verified: $_isLandlordVerified');
    } catch (e) {
      debugPrint('❌ Error checking verification: $e');
    }

    if (mounted) {
      setState(() => _isCheckingVerification = false);
    }
  }

  /// Track when a tenant views this property
  Future<void> _trackView() async {
    try {
      await _propertyService.trackPropertyView(
        propertyId: widget.property.id,
        landlordId: widget.property.landlordId,
        propertyTitle: widget.property.title,
      );
    } catch (e) {
      debugPrint('❌ Failed to track view: $e');
    }
  }

  Future<void> _checkExistingRequest() async {
    final inspectionService = InspectionService();
    final hasRequest = await inspectionService.hasPendingRequest(
      widget.property.id,
    );
    if (mounted) {
      setState(() {
        _hasExistingRequest = hasRequest;
        _isCheckingRequest = false;
      });
    }
  }

  void _toggleSave() {
    setState(() => _isSaved = !_isSaved);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isSaved ? 'Property saved!' : 'Property removed from saved',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _shareProperty() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder:
          (context) => SharePropertySheet(
            property: widget.property,
            conversations: const [],
            currentUserId: _currentUserId ?? '',
            onSendInApp: (conversation) {
              // Handle in-app sharing
            },
          ),
    );
  }

  // ============ VERIFICATION CHECK HELPERS ============

  /// Show verification required dialog
  void _showVerificationRequired({
    required bool currentUserNeedsVerification,
    required String action, // 'message' or 'inspection'
  }) {
    String title;
    String message;
    String? actionButtonText;
    VoidCallback? onAction;

    if (currentUserNeedsVerification) {
      title = 'Verification Required';
      message = action == 'message'
          ? 'You need to complete verification before you can message landlords.'
          : 'You need to complete verification before you can request property inspections.';
      actionButtonText = 'Get Verified';
      onAction = () {
        Navigator.pop(context);
        if (_currentUserType == 'tenant') {
          context.push('/tenant/verification');
        } else if (_currentUserType == 'landlord') {
          context.push('/landlord/verification');
        } else if (_currentUserType == 'agent') {
          context.push('/agent/verification');
        }
      };
    } else {
      // Landlord not verified - this shouldn't happen as we filter properties
      // but handle gracefully
      title = 'Property Unavailable';
      message = 'This property listing is currently unavailable. The landlord needs to complete verification.';
      actionButtonText = 'OK';
      onAction = () => Navigator.pop(context);
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.verified_user_outlined, color: AppColors.warning, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: AppTextStyles.h4)),
          ],
        ),
        content: Text(
          message,
          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          if (currentUserNeedsVerification)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Later', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ElevatedButton(
            onPressed: onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(actionButtonText!),
          ),
        ],
      ),
    );
  }

  // ============ TENANT ACTIONS ============

  void _contactLandlord() {
    // Check verification status first
    if (!_isCurrentUserVerified) {
      _showVerificationRequired(
        currentUserNeedsVerification: true,
        action: 'message',
      );
      return;
    }

    if (!_isLandlordVerified) {
      _showVerificationRequired(
        currentUserNeedsVerification: false,
        action: 'message',
      );
      return;
    }

    // Both verified - proceed with contact sheet
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => _ContactSheet(
            property: widget.property,
            currentUserId: _currentUserId ?? '',
            currentUserName: 'Tenant',
            conversationService: _conversationService,
            onStartChat: (conversation) {
              context.push(
                '/chat',
                extra: {
                  'conversationId': conversation.id,
                  'currentUserId': _currentUserId,
                },
              );
            },
          ),
    );
  }

  void _requestInspection() {
    // Check verification status first
    if (!_isCurrentUserVerified) {
      _showVerificationRequired(
        currentUserNeedsVerification: true,
        action: 'inspection',
      );
      return;
    }

    if (!_isLandlordVerified) {
      _showVerificationRequired(
        currentUserNeedsVerification: false,
        action: 'inspection',
      );
      return;
    }

    // Both verified - proceed with inspection request
    () async {
      final result = await RequestInspectionSheet.show(
        context,
        widget.property,
      );
      if (result == true && mounted) {
        _checkExistingRequest();
      }
    }();
  }

  // ============ LANDLORD ACTIONS ============

  void _editProperty() {
    context.push('/landlord/edit-property', extra: widget.property);
  }

  Future<void> _toggleAvailability() async {
    final newStatus = !widget.property.isAvailable;

    try {
      await _propertyService.updateAvailability(widget.property.id, newStatus);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newStatus
                ? 'Property marked as available'
                : 'Property marked as occupied',
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );

      context.pop(true);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update: $e'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _deleteProperty() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Property'),
            content: Text(
              'Are you sure you want to delete "${widget.property.title}"? This action cannot be undone.',
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Delete', style: TextStyle(color: AppColors.error)),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await _propertyService.deleteProperty(widget.property.id);

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Property deleted'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );

        context.pop(true);
      } catch (e) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete: $e'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  void _viewPropertyStats() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _PropertyStatsSheet(property: widget.property),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    final property = widget.property;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _buildImageCarousel(property)),

                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _isOwner
                              ? _buildOwnerPriceRow(property)
                              : _buildTenantPriceRow(property),

                          const SizedBox(height: 16),

                          Text(property.title, style: AppTextStyles.h3),

                          const SizedBox(height: 8),

                          Row(
                            children: [
                              const Icon(
                                Icons.location_on,
                                size: 18,
                                color: AppColors.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${property.address}, ${property.city}, ${property.state}',
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          _buildFeaturesRow(property),

                          const SizedBox(height: 24),

                          if (_isOwner) ...[
                            _buildOwnerStatsCard(property),
                            const SizedBox(height: 24),
                          ],

                          if (!_isOwner) ...[
                            _buildLandlordCard(property),
                            const SizedBox(height: 24),
                            
                            // Verification status banner for tenant
                            if (!_isCheckingVerification && !_isCurrentUserVerified)
                              _buildVerificationBanner(),
                            
                            if (!_isCheckingVerification && !_isCurrentUserVerified)
                              const SizedBox(height: 24),
                            
                            // Inspection fee section (for agent-handled properties)
                            if (property.inspectionHandler == 'agent' && property.assignedAgentId != null)
                              _buildInspectionFeeCard(property),
                            
                            if (property.inspectionHandler == 'agent' && property.assignedAgentId != null)
                              const SizedBox(height: 24),
                            
                            _buildFeeBreakdown(property),
                            const SizedBox(height: 24),
                          ],

                          _buildSection(
                            title: 'Description',
                            child: Text(
                              property.description,
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: AppColors.textSecondary,
                                height: 1.6,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          if (property.amenities.isNotEmpty)
                            _buildSection(
                              title: 'Amenities',
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    property.amenities.map((amenity) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryLight
                                              .withAlpha(26),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _getAmenityIcon(amenity),
                                              size: 16,
                                              color: AppColors.primary,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              amenity,
                                              style: AppTextStyles.labelMedium
                                                  .copyWith(
                                                    color: AppColors.primary,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                              ),
                            ),

                          if (property.amenities.isNotEmpty)
                            const SizedBox(height: 24),

                          if (property.rules.isNotEmpty)
                            _buildSection(
                              title: 'House Rules',
                              child: Column(
                                children:
                                    property.rules.map((rule) {
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.info_outline,
                                              size: 18,
                                              color: AppColors.warning,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                rule,
                                                style: AppTextStyles.bodyMedium,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                              ),
                            ),

                          const SizedBox(height: 100),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomSheet:
            _isOwner ? _buildOwnerBottomBar() : _buildTenantBottomBar(),
      ),
    );
  }

  /// Banner prompting tenant to get verified
  Widget _buildVerificationBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(51),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.verified_user_outlined, color: AppColors.warning, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Verification Required',
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning),
                ),
                const SizedBox(height: 2),
                Text(
                  'Complete verification to message landlords and request inspections',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => context.push('/tenant/verification'),
            style: TextButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }

  Widget _buildImageCarousel(PropertyModel property) {
    return Stack(
      children: [
        SizedBox(
          height: 300,
          child:
              property.images.isEmpty
                  ? Container(
                    color: AppColors.background,
                    child: const Center(
                      child: Icon(
                        Icons.image_not_supported,
                        size: 50,
                        color: AppColors.textHint,
                      ),
                    ),
                  )
                  : PageView.builder(
                    controller: _imageController,
                    itemCount: property.images.length,
                    onPageChanged:
                        (index) => setState(() => _currentImageIndex = index),
                    itemBuilder: (context, index) {
                      return CachedNetworkImage(
                        imageUrl: property.images[index],
                        fit: BoxFit.cover,
                        placeholder:
                            (context, url) => Container(
                              color: AppColors.background,
                              child: const Center(
                                child: CircularProgressIndicator(
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                        errorWidget:
                            (context, url, error) => Container(
                              color: AppColors.background,
                              child: const Icon(
                                Icons.image_not_supported,
                                size: 50,
                                color: AppColors.textHint,
                              ),
                            ),
                      );
                    },
                  ),
        ),

        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 100,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withAlpha(128), Colors.transparent],
              ),
            ),
          ),
        ),

        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          left: 16,
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 8),
                ],
              ),
              child: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            ),
          ),
        ),

        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          right: 16,
          child:
              _isOwner
                  ? _buildOwnerMoreButton()
                  : GestureDetector(
                    onTap: _shareProperty,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(26),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.share_outlined,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
        ),

        if (property.images.length > 1)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(property.images.length, (index) {
                return Container(
                  width: index == _currentImageIndex ? 24 : 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color:
                        index == _currentImageIndex
                            ? Colors.white
                            : Colors.white.withAlpha(128),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),

        Positioned(
          bottom: 16,
          left: 16,
          child:
              _isOwner
                  ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color:
                          property.isAvailable
                              ? AppColors.success
                              : AppColors.warning,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      property.isAvailable ? 'Available' : 'Occupied',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  )
                  : property.isVerified
                  ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.verified,
                          size: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          AppStrings.verified,
                          style: AppTextStyles.labelMedium.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  )
                  : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildOwnerMoreButton() {
    return PopupMenuButton<String>(
      onSelected: (value) {
        switch (value) {
          case 'edit':
            _editProperty();
            break;
          case 'toggle':
            _toggleAvailability();
            break;
          case 'stats':
            _viewPropertyStats();
            break;
          case 'share':
            _shareProperty();
            break;
          case 'delete':
            _deleteProperty();
            break;
        }
      },
      itemBuilder:
          (context) => [
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Edit Property'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'toggle',
              child: Row(
                children: [
                  Icon(
                    widget.property.isAvailable
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    widget.property.isAvailable
                        ? 'Mark as Occupied'
                        : 'Mark as Available',
                  ),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'stats',
              child: Row(
                children: [
                  Icon(Icons.analytics_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('View Stats'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'share',
              child: Row(
                children: [
                  Icon(Icons.share_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Share'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete_outline, size: 20, color: AppColors.error),
                  SizedBox(width: 12),
                  Text('Delete', style: TextStyle(color: AppColors.error)),
                ],
              ),
            ),
          ],
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 8),
          ],
        ),
        child: const Icon(Icons.more_vert, color: AppColors.textPrimary),
      ),
    );
  }

  // ============ OWNER-SPECIFIC WIDGETS ============

  Widget _buildOwnerPriceRow(PropertyModel property) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          property.formattedRent,
          style: AppTextStyles.h2.copyWith(color: AppColors.primary),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            property.rentPeriod,
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color:
                property.isAvailable
                    ? AppColors.success.withAlpha(26)
                    : AppColors.warning.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            property.isAvailable ? 'Available' : 'Occupied',
            style: AppTextStyles.labelMedium.copyWith(
              color:
                  property.isAvailable ? AppColors.success : AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOwnerStatsCard(PropertyModel property) {
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
              const Icon(
                Icons.analytics_outlined,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text('Property Performance', style: AppTextStyles.labelLarge),
              const Spacer(),
              TextButton(
                onPressed: _viewPropertyStats,
                child: Text(
                  'See Details',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatItem(
                  icon: Icons.visibility_outlined,
                  value: '${property.viewCount}',
                  label: 'Views',
                  color: AppColors.info,
                ),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.chat_bubble_outline,
                  value: '${property.inquiryCount}',
                  label: 'Inquiries',
                  color: AppColors.warning,
                ),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.favorite_outline,
                  value: '${property.savedCount}',
                  label: 'Saved',
                  color: AppColors.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOwnerBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.of(context).padding.bottom + 12,
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
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _toggleAvailability,
              icon: Icon(
                widget.property.isAvailable
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
              ),
              label: Text(
                widget.property.isAvailable
                    ? 'Mark Occupied'
                    : 'Mark Available',
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AppButton(
              text: 'Edit Property',
              onPressed: _editProperty,
              height: 50,
            ),
          ),
        ],
      ),
    );
  }

  // ============ TENANT-SPECIFIC WIDGETS ============

  Widget _buildTenantPriceRow(PropertyModel property) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          property.formattedRent,
          style: AppTextStyles.h2.copyWith(color: AppColors.primary),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            property.rentPeriod,
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: _toggleSave,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color:
                  _isSaved
                      ? AppColors.error.withAlpha(26)
                      : AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isSaved ? AppColors.error : AppColors.border,
              ),
            ),
            child: Icon(
              _isSaved ? Icons.favorite : Icons.favorite_border,
              color: _isSaved ? AppColors.error : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLandlordCard(PropertyModel property) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          // Avatar with verification indicator
          Stack(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight.withAlpha(51),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    property.landlordName?.isNotEmpty == true
                        ? property.landlordName!.substring(0, 1).toUpperCase()
                        : 'L',
                    style: AppTextStyles.h4.copyWith(color: AppColors.primary),
                  ),
                ),
              ),
              // Verification badge
              if (_isLandlordVerified)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.surface, width: 2),
                    ),
                    child: const Icon(
                      Icons.check,
                      size: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      property.hasAgent
                          ? 'Listed via Agent'
                          : 'Direct Landlord',
                      style: AppTextStyles.caption,
                    ),
                    if (_isLandlordVerified) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.verified,
                        size: 14,
                        color: AppColors.primary,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  property.landlordName ?? 'Landlord',
                  style: AppTextStyles.labelLarge,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _callLandlord(property),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.phone_outlined,
                color: AppColors.primary,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _callLandlord(PropertyModel property) {
    final phone = property.landlordPhone;
    if (phone != null && phone.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Calling $phone...'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Phone number not available. Try sending a message instead.',
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  /// Inspection fee card for agent-handled properties
  Widget _buildInspectionFeeCard(PropertyModel property) {
    // Calculate estimated fee (minimum fee since we don't have exact distance)
    final feeBreakdown = InspectionPricing.calculateFee(distanceKm: 0);
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(51)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.directions_walk,
                  size: 20,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Property Inspection',
                      style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Handled by verified agent',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              // Agent badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.verified, size: 12, color: AppColors.success),
                    const SizedBox(width: 4),
                    Text(
                      'Verified',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Fee breakdown
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildInspectionFeeRow('Agent Service Fee', feeBreakdown.agentServiceFee),
                const SizedBox(height: 8),
                _buildInspectionFeeRow('Transport Fee', feeBreakdown.transportFee, note: 'varies by distance'),
                const SizedBox(height: 8),
                _buildInspectionFeeRow('Platform Fee', feeBreakdown.clearrentFee),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(height: 1),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Estimated Total',
                      style: AppTextStyles.labelMedium.copyWith(color: AppColors.textPrimary),
                    ),
                    Text(
                      'From ${InspectionPricing.formatNaira(feeBreakdown.totalFee)}',
                      style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 12),
          
          // Info note
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.infoLight.withAlpha(128),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 14, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pay upfront to schedule inspection. Full refund if the landlord or agent declines.',
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

  Widget _buildInspectionFeeRow(String label, double amount, {String? note}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              Text(
                label,
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
              ),
              if (note != null) ...[
                const SizedBox(width: 4),
                Text(
                  '($note)',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textHint,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
        Text(
          InspectionPricing.formatNaira(amount),
          style: AppTextStyles.labelMedium,
        ),
      ],
    );
  }

  Widget _buildFeeBreakdown(PropertyModel property) {
    final rent = property.rent;
    final agentFee =
        property.hasAgent && property.agentFeePaidBy == 'tenant'
            ? rent * property.agentFee / 100
            : 0.0;
    final total = rent + agentFee;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.infoLight.withAlpha(128),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.info.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.receipt_long_outlined,
                size: 20,
                color: AppColors.info,
              ),
              const SizedBox(width: 8),
              Text(
                AppStrings.feeBreakdown,
                style: AppTextStyles.labelLarge.copyWith(color: AppColors.info),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _FeeRow(label: AppStrings.rentToLandlord, amount: rent),
          if (agentFee > 0) ...[
            const SizedBox(height: 8),
            _FeeRow(
              label: '${AppStrings.agentFee} (${property.formattedAgentFee})',
              amount: agentFee,
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),
          _FeeRow(label: 'Total First Payment', amount: total, isTotal: true),
          if (agentFee > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Agent fee is one-time (first year only)',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTenantBottomBar() {
    return _buildActionButtons();
  }

  void _startConversation() {
    _contactLandlord();
  }

  Widget _buildActionButtons() {
    return Container(
      padding: const EdgeInsets.all(20),
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
      child: SafeArea(
        child: Row(
          children: [
            // Message button
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _startConversation(),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Message'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Request Inspection button
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed:
                    _isCheckingRequest || _hasExistingRequest
                        ? null
                        : () => _requestInspection(),
                icon: Icon(
                  _hasExistingRequest
                      ? Icons.check_circle
                      : Icons.event_available,
                ),
                label: Text(
                  _hasExistingRequest ? 'Request Sent' : 'Request Inspection',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _hasExistingRequest
                          ? AppColors.success
                          : AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      _hasExistingRequest
                          ? AppColors.success.withAlpha(179)
                          : AppColors.textHint,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============ SHARED WIDGETS ============

  Widget _buildFeaturesRow(PropertyModel property) {
    final hasFeatures =
        property.bedrooms > 0 || property.bathrooms > 0 || property.toilets > 0;
    if (!hasFeatures) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          if (property.bedrooms > 0)
            _FeatureItem(
              icon: Icons.bed_outlined,
              value: '${property.bedrooms}',
              label: 'Bedrooms',
            ),
          if (property.bathrooms > 0)
            _FeatureItem(
              icon: Icons.bathtub_outlined,
              value: '${property.bathrooms}',
              label: 'Bathrooms',
            ),
          if (property.toilets > 0)
            _FeatureItem(
              icon: Icons.wc_outlined,
              value: '${property.toilets}',
              label: 'Toilets',
            ),
        ],
      ),
    );
  }

  Widget _buildSection({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTextStyles.h4),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  IconData _getAmenityIcon(String amenity) {
    final lower = amenity.toLowerCase();
    if (lower.contains('power') || lower.contains('electricity')) {
      return Icons.bolt;
    }
    if (lower.contains('water')) return Icons.water_drop;
    if (lower.contains('security')) return Icons.security;
    if (lower.contains('parking')) return Icons.local_parking;
    if (lower.contains('pool') || lower.contains('swimming')) return Icons.pool;
    if (lower.contains('gym')) return Icons.fitness_center;
    if (lower.contains('garden')) return Icons.grass;
    if (lower.contains('cctv')) return Icons.videocam;
    if (lower.contains('kitchen')) return Icons.kitchen;
    if (lower.contains('smart')) return Icons.smart_toy;
    if (lower.contains('tiled') || lower.contains('floor')) {
      return Icons.grid_on;
    }
    if (lower.contains('meter')) return Icons.electric_meter;
    if (lower.contains('bq')) return Icons.house;
    return Icons.check_circle_outline;
  }
}

// ============ HELPER WIDGETS ============

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _FeatureItem({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 24, color: AppColors.primary),
        const SizedBox(height: 8),
        Text(value, style: AppTextStyles.h4),
        const SizedBox(height: 2),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _StatItem({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(height: 8),
        Text(value, style: AppTextStyles.h4),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }
}

class _FeeRow extends StatelessWidget {
  final String label;
  final double amount;
  final bool isTotal;

  const _FeeRow({
    required this.label,
    required this.amount,
    this.isTotal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: isTotal ? AppTextStyles.labelLarge : AppTextStyles.bodyMedium,
        ),
        Text(
          'NGN ${_formatAmount(amount)}',
          style:
              isTotal
                  ? AppTextStyles.h4.copyWith(color: AppColors.primary)
                  : AppTextStyles.labelLarge,
        ),
      ],
    );
  }

  String _formatAmount(double amount) {
    if (amount >= 1000000) return '${(amount / 1000000).toStringAsFixed(2)}M';
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }
}

// ============ BOTTOM SHEETS ============

class _ContactSheet extends StatelessWidget {
  final PropertyModel property;
  final String currentUserId;
  final String currentUserName;
  final ConversationService conversationService;
  final Function(ConversationData) onStartChat;

  const _ContactSheet({
    required this.property,
    required this.currentUserId,
    required this.currentUserName,
    required this.conversationService,
    required this.onStartChat,
  });

  Future<void> _startOrOpenChat(BuildContext context) async {
    Navigator.pop(context);

    try {
      final conversation = await conversationService.getOrCreateConversation(
        propertyId: property.id,
        propertyTitle: property.title,
        propertyImage: property.images.isNotEmpty ? property.images.first : '',
        landlordId: property.landlordId,
        landlordName: property.landlordName ?? 'Landlord',
        tenantId: currentUserId,
        tenantName: currentUserName,
      );

      if (conversation != null) {
        onStartChat(conversation);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Failed to start chat. Please try again.'),
              backgroundColor: AppColors.error,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error starting chat: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start chat: $e'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  void _callLandlord(BuildContext context) {
    Navigator.pop(context);
    final phone = property.landlordPhone;
    if (phone != null && phone.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Calling $phone...'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Phone number not available. Try sending a message instead.',
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
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
          const SizedBox(height: 24),
          Text(
            'Contact ${property.hasAgent ? 'Agent' : 'Landlord'}',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 24),
          _ContactOption(
            icon: Icons.chat_bubble_outline,
            title: 'Send a Message',
            subtitle: 'Chat directly in the app',
            onTap: () => _startOrOpenChat(context),
          ),
          const SizedBox(height: 12),
          _ContactOption(
            icon: Icons.phone_outlined,
            title: 'Call ${property.landlordName ?? 'Landlord'}',
            subtitle: property.landlordPhone ?? 'Phone not available',
            onTap: () => _callLandlord(context),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

class _ContactOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ContactOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.primary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.caption),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textHint),
          ],
        ),
      ),
    );
  }
}

class _PropertyStatsSheet extends StatelessWidget {
  final PropertyModel property;

  const _PropertyStatsSheet({required this.property});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
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
          const SizedBox(height: 24),
          Text('Property Statistics', style: AppTextStyles.h4),
          const SizedBox(height: 24),

          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.visibility_outlined,
                  value: '${property.viewCount}',
                  label: 'Total Views',
                  color: AppColors.info,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.chat_bubble_outline,
                  value: '${property.inquiryCount}',
                  label: 'Inquiries',
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.favorite_outline,
                  value: '${property.savedCount}',
                  label: 'Saved',
                  color: AppColors.error,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.share_outlined,
                  value: '0',
                  label: 'Shared',
                  color: AppColors.primary,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Listed on',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      property.createdAt != null
                          ? '${property.createdAt!.day}/${property.createdAt!.month}/${property.createdAt!.year}'
                          : 'N/A',
                      style: AppTextStyles.labelLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Status',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            property.isAvailable
                                ? AppColors.success.withAlpha(26)
                                : AppColors.warning.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        property.isAvailable ? 'Available' : 'Occupied',
                        style: AppTextStyles.labelSmall.copyWith(
                          color:
                              property.isAvailable
                                  ? AppColors.success
                                  : AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: color),
          const SizedBox(height: 8),
          Text(value, style: AppTextStyles.h3),
          Text(label, style: AppTextStyles.caption),
        ],
      ),
    );
  }
}