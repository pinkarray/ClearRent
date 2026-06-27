import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/share_property_sheet_external.dart';
import '../../../../services/property_service.dart';
import '../../../../services/building_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/tenancy_link_service.dart';
import '../../../../shared/models/tenancy_link_model.dart';
import '../../../tenant/presentation/widgets/request_inspection_sheet.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/services.dart';

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

  // Video tour
  VideoPlayerController? _videoController;
  bool _videoInitialized = false;
  final bool _videoMuted = true;
  Duration _videoPosition = Duration.zero;
  static const _previewDuration = Duration(seconds: 60);

  // Services
  late final PropertyService _propertyService;
  late final BuildingService _buildingService;
  late final AuthService _authService;
  late final ConversationService _conversationService;
  late final VerificationService _verificationService;
  late final TenancyLinkService _tenancyLinkService;

  // For a unit grouped under a building, the shared ownership doc lives on the
  // building. Loaded async; null until then (or for standalone listings).
  String? _buildingDocStatus;

  /// Ownership-doc status that actually governs this listing: the building's
  /// shared status when grouped (property.ownershipDocStatus is 'inherited'
  /// then), otherwise the property's own. Defaults to 'pending' while the
  /// building loads so a grouped unit is never wrongly treated as verified.
  String get _effectiveDocStatus => widget.property.buildingId != null
      ? (_buildingDocStatus ?? 'pending')
      : widget.property.ownershipDocStatus;

  // User info
  String? _currentUserId;
  String? _currentUserType;
  bool _isOwner = false;
  bool _isLoading = true;

  bool _hasExistingRequest = false;
  bool _isCheckingRequest = true;
  // Address gate: false = approximate (LGA/city/state), true = exact street.
  bool _addressUnlocked = false;

  // Verification status
  bool _isCurrentUserVerified = false;
  bool _isLandlordVerified = false;
  bool _isCheckingVerification = true;

  bool _landlordAllowsCalls = false;
  String? _landlordPhone;

  // Whether current tenant is already linked to THIS property
  bool _isLinkedToThisProperty = false;

  // True once we confirm the property has a sitting tenant. Rent changes for an
  // occupied unit must go through the admin "Request Rent Change" flow (the
  // sitting tenant is protected); a vacant unit's rent is edited directly on
  // Edit Property, so we hide "Request Rent Change" when vacant.
  bool _hasSittingTenant = false;

  @override
  void initState() {
    super.initState();
    _propertyService = PropertyService();
    _buildingService = BuildingService();
    _authService = AuthService();
    _conversationService = ConversationService();
    _verificationService = VerificationService();
    _tenancyLinkService = TenancyLinkService();
    _determineUserContext();
    _checkExistingRequest();
    _checkVerificationStatus();
    _checkIfLinkedToThisProperty();
    _loadBuildingDocStatus();
    _loadOccupancy();
    _initializeVideo();
  }

  /// Resolve whether this property currently has a sitting tenant (drives
  /// whether "Request Rent Change" is offered — occupied only). Only the
  /// owner sees that menu item, and propertyHasSittingTenant runs an
  /// owner-scoped query, so skip it entirely for non-owner viewers.
  Future<void> _loadOccupancy() async {
    if (widget.property.landlordId != _authService.currentUser?.uid) return;
    final occupied =
        await _propertyService.propertyHasSittingTenant(widget.property.id);
    if (!mounted) return;
    setState(() => _hasSittingTenant = occupied);
  }

  /// Resolve the shared ownership-doc status for a grouped unit by reading its
  /// building. No-op for standalone listings.
  Future<void> _loadBuildingDocStatus() async {
    final buildingId = widget.property.buildingId;
    if (buildingId == null || buildingId.isEmpty) return;
    final building = await _buildingService.getBuilding(buildingId);
    if (!mounted || building == null) return;
    setState(() => _buildingDocStatus = building.ownershipDocStatus);
  }

  @override
  void dispose() {
    _imageController.dispose();
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    super.dispose();
  }

  /// Initialize the video player if property has a video
  Future<void> _initializeVideo() async {
    final videoUrl = widget.property.videoUrl;
    if (videoUrl == null || videoUrl.isEmpty) return;

    try {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
      await _videoController!.initialize();
      _videoController!.setVolume(0); // Start muted
      _videoController!.setLooping(false);
      _videoController!.addListener(_onVideoProgress);

      if (mounted) {
        setState(() => _videoInitialized = true);
        _videoController!.play(); // Autoplay muted
      }
    } catch (e) {
      debugPrint('❌ Video init error: $e');
    }
  }

  /// Pause at 60 seconds for the preview
  void _onVideoProgress() {
    if (_videoController == null) return;
    final position = _videoController!.value.position;

    if (mounted && position != _videoPosition) {
      setState(() => _videoPosition = position);
    }

    // Auto-pause at 60s for the preview
    if (position >= _previewDuration && _videoController!.value.isPlaying) {
      _videoController!.pause();
    }
  }

  /// Open fullscreen video with chewie (full controls, sound)
  void _openFullscreenVideo() {
    if (_videoController == null || !_videoInitialized) return;

    // Reset to beginning for fullscreen viewing
    _videoController!.seekTo(Duration.zero);
    _videoController!.setVolume(1.0);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _FullscreenVideoScreen(
          videoUrl: widget.property.videoUrl!,
        ),
      ),
    );
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
      final currentUserStatus =
          await _verificationService.getVerificationStatus();
      _isCurrentUserVerified =
          currentUserStatus.status == VerificationStatus.verified;

      final landlordDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(widget.property.landlordId)
              .get();

      if (landlordDoc.exists) {
        final landlordData = landlordDoc.data();
        final landlordVerificationStatus =
            landlordData?['verificationStatus'] ?? 'none';
        _isLandlordVerified = landlordVerificationStatus == 'verified';

        // Capture call info at the same time - no extra Firestore read needed
        _landlordAllowsCalls = landlordData?['allowsCalls'] ?? false;
        _landlordPhone = landlordData?['phone'];
      }

      debugPrint('✅ Current user verified: $_isCurrentUserVerified');
      debugPrint('✅ Landlord verified: $_isLandlordVerified');
      debugPrint('✅ Landlord allows calls: $_landlordAllowsCalls');
    } catch (e) {
      debugPrint('❌ Error checking verification: $e');
    }

    if (mounted) {
      setState(() => _isCheckingVerification = false);
    }
  }

  /// Check if the current user is already a confirmed linked tenant on this property
  Future<void> _checkIfLinkedToThisProperty() async {
    try {
      final link = await _tenancyLinkService.getTenantActiveLink();
      if (link != null && link.propertyId == widget.property.id && link.isConfirmed) {
        if (mounted) setState(() => _isLinkedToThisProperty = true);
      }
    } catch (e) {
      debugPrint('❌ Error checking linked status: $e');
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
    // Address gate: exact only when approved/completed AND not passed.
    final approved =
        await inspectionService.hasApprovedInspection(widget.property.id);
    final passed = await inspectionService.hasPassed(widget.property.id);
    if (mounted) {
      setState(() {
        _hasExistingRequest = hasRequest;
        _addressUnlocked = approved && !passed;
        _isCheckingRequest = false;
      });
    }
  }

  void _toggleSave() {
    setState(() => _isSaved = !_isSaved);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isSaved ? 'Property saved!' : 'Property removed from saved',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  void _shareProperty() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SharePropertySheet(
        property: widget.property,
        // Only tenants/agents share *to* the owner. The owner viewing their
        // own listing gets external-share only (no "send to landlord").
        onShareInApp: _isOwner ? null : _shareToOwnerInApp,
      ),
    );
  }

  Future<void> _shareToOwnerInApp() async {
    // Gate: same verification rules as messaging.
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

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    // Resolve current user's display name for the share message.
    final profile = await _authService.getUserProfile();
    final senderName = profile?['fullName'] ?? 'User';
    final senderRole = _currentUserType ?? 'tenant';

    // Get or create the conversation with this property's landlord.
    final conversation = await _conversationService.getOrCreateConversation(
      propertyId: widget.property.id,
      propertyTitle: widget.property.title,
      propertyImage:
          widget.property.images.isNotEmpty ? widget.property.images.first : '',
      landlordId: widget.property.landlordId,
      landlordName: widget.property.landlordName ?? 'Landlord',
      tenantId: _currentUserId ?? '',
      tenantName: senderName,
      agentId: widget.property.assignedAgentId,
      agentName: widget.property.assignedAgentName,
    );

    if (!mounted) return;

    if (conversation == null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Could not start the chat. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    // Send the property as a share card into the conversation.
    final message = await _conversationService.sendPropertyShare(
      conversationId: conversation.id,
      senderName: senderName,
      senderRole: senderRole,
      propertyId: widget.property.id,
      propertyTitle: widget.property.title,
      propertyImage:
          widget.property.images.isNotEmpty ? widget.property.images.first : '',
      propertyRent: widget.property.formattedRent,
    );

    if (!mounted) return;

    if (message == null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Could not share the property. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    // Navigate into the chat.
    router.push('/chat', extra: {
      'conversationId': conversation.id,
      'propertyTitle': widget.property.title,
      'propertyImage':
          widget.property.images.isNotEmpty ? widget.property.images.first : '',
    });
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
      message =
          action == 'message'
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
      message =
          'This property listing is currently unavailable. The landlord needs to complete verification.';
      actionButtonText = 'OK';
      onAction = () => Navigator.pop(context);
    }

    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.verified_user_outlined,
                    color: AppColors.warning,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: AppTextStyles.h4)),
              ],
            ),
            content: Text(
              message,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            actions: [
              if (currentUserNeedsVerification)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Later',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
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
            landlordAllowsCalls: _landlordAllowsCalls,
            landlordPhone: _landlordPhone,
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

    // Block if ownership doc was rejected — landlord must re-submit.
    // For a grouped unit this resolves to the building's shared doc status.
    final docStatus = _effectiveDocStatus;
    if (docStatus == 'rejected') {
      _showDocBlockedDialog(
        title: 'Document Rejected',
        message:
            'The ownership document for this property was rejected by our team. '
            'The landlord must re-upload a valid document before inspections can be booked.',
      );
      return;
    }

    // Block if no doc uploaded yet — landlord must provide it first
    if (docStatus == 'none') {
      _showDocBlockedDialog(
        title: 'Document Required',
        message:
            'The landlord has not yet uploaded an ownership document for this property. '
            'Inspections cannot be booked until ownership is verified.',
      );
      return;
    }

    // Both verified - proceed with inspection request
    _showRequestInspectionSheet();
  }

  void _showDocBlockedDialog({required String title, required String message}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.shield_outlined, color: AppColors.warning, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: AppTextStyles.h4)),
        ]),
        content: Text(
          message,
          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Got it', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<void> _showRequestInspectionSheet() async {
    final result = await RequestInspectionSheet.show(context, widget.property);
    if (result == true && mounted) {
      _checkExistingRequest();
    }
  }

  // ============ LANDLORD ACTIONS ============

  void _editProperty() {
    context.push('/landlord/edit-property', extra: widget.property);
  }

  void _requestRentChange() {
    final property = widget.property;
    context.push('/landlord/request-rent-change', extra: {
      'propertyId': property.id,
      'propertyTitle': property.title,
      'currentRent': property.rent,
      'landlordId': property.landlordId,
      'landlordName': property.landlordName ?? '',
    });
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
    // Can't delete a property with a sitting/linked tenant — it would strand
    // their dashboard with an orphaned rental/link.
    if (await _propertyService.propertyHasSittingTenant(widget.property.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'This property has a sitting or linked tenant and can\'t be deleted. End the tenancy first.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }
    if (!mounted) return;

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
      isScrollControlled: true,
      builder: (context) => _PropertyStatsSheet(property: widget.property),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
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

                  // Video preview (muted autoplay, 60s)
                  if (_videoInitialized && _videoController != null)
                    SliverToBoxAdapter(
                      child: _buildVideoPreview(),
                    ),

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
                              Icon(
                                Icons.location_on,
                                size: 18,
                                color: AppColors.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  (_isOwner || _addressUnlocked)
                                      ? property.exactAddress
                                      : property.approximateAddress,
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

                          if (_isOwner) ...[
                            _buildTenantManagementSection(property),
                            const SizedBox(height: 24),
                          ],

                          if (!_isOwner) ...[
                            _buildLandlordCard(property),
                            const SizedBox(height: 24),

                            // Verification status banner for tenant
                            if (!_isCheckingVerification &&
                                !_isCurrentUserVerified)
                              _buildVerificationBanner(),

                            if (!_isCheckingVerification &&
                                !_isCurrentUserVerified)
                              const SizedBox(height: 24),

                            // Ownership doc status banner — shown when doc is not verified
                            if (_effectiveDocStatus != 'verified')
                              _buildDocStatusBanner(property),

                            if (_effectiveDocStatus != 'verified')
                              const SizedBox(height: 24),

                            // Inspection fee section (for agent-handled properties)
                            if (property.inspectionHandler == 'agent' &&
                                property.assignedAgentId != null)
                              _buildInspectionFeeCard(property),

                            if (property.inspectionHandler == 'agent' &&
                                property.assignedAgentId != null)
                              const SizedBox(height: 24),

                            _buildFeeBreakdown(property),
                            const SizedBox(height: 24),

                            // Occupancy info card — visible to tenants
                            _buildOccupancyInfoCard(property),
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
                                            Icon(
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
            child: Icon(
              Icons.verified_user_outlined,
              color: AppColors.warning,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Verification Required',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.warning,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Complete verification to message landlords and request inspections',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }

  Widget _buildDocStatusBanner(PropertyModel property) {
    final docStatus = _effectiveDocStatus;

    final Color color;
    final IconData icon;
    final String title;
    final String subtitle;

    switch (docStatus) {
      case 'rejected':
        color = AppColors.error;
        icon = Icons.gpp_bad_outlined;
        title = 'Ownership Document Rejected';
        subtitle =
            'The landlord\'s ownership document was rejected. Inspections are '
            'blocked until a valid document is re-uploaded and approved.';
        break;
      case 'pending':
        color = AppColors.warning;
        icon = Icons.hourglass_top_outlined;
        title = 'Document Under Review';
        subtitle =
            'The landlord\'s ownership document is being reviewed by our team. '
            'You can still browse this listing but cannot book an inspection yet.';
        break;
      case 'none':
      default:
        color = AppColors.textSecondary;
        icon = Icons.description_outlined;
        title = 'Document Not Yet Uploaded';
        subtitle =
            'The landlord has not yet uploaded an ownership document. '
            'Inspections will be available once ownership is verified.';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.labelMedium.copyWith(color: color),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
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
                    child: Center(
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
                        // Decode/cache at ~screen width so the gallery stays
                        // resident and doesn't reload on revisit.
                        memCacheWidth: 1080,
                        placeholder:
                            (context, url) => Container(
                              color: AppColors.background,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                        errorWidget:
                            (context, url, error) => Container(
                              color: AppColors.background,
                              child: Icon(
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
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 8),
                ],
              ),
              child: Icon(Icons.arrow_back, color: AppColors.textPrimary),
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
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(26),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: Icon(
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
                            ? AppColors.surface
                            : AppColors.surface.withAlpha(128),
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
          case 'health':
            context.push('/landlord/property-health', extra: widget.property);
            break;
          case 'toggle':
            _toggleAvailability();
            break;
          case 'stats':
            _viewPropertyStats();
            break;
          case 'rent_change':
            _requestRentChange();
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
            const PopupMenuItem(
              value: 'health',
              child: Row(
                children: [
                  Icon(Icons.monitor_heart_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Property Health'),
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
            // Occupied units only — a vacant unit's rent is edited directly on
            // Edit Property (no admin review needed without a sitting tenant).
            if (_hasSittingTenant)
              const PopupMenuItem(
                value: 'rent_change',
                child: Row(
                  children: [
                    Icon(Icons.price_change_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Request Rent Change'),
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
            PopupMenuItem(
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
        child: Icon(Icons.more_vert, color: AppColors.textPrimary),
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
              Icon(
                Icons.analytics_outlined,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text('Property Performance', style: AppTextStyles.labelLarge),
              const Spacer(),
              TextButton(
                onPressed: () => context.push('/landlord/property-health', extra: property),
                child: Text(
                  'View Health',
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

  // ============ TENANT MANAGEMENT (OWNER) ============

  /// Inline warning shown inside the Tenants card when a tenant stream errors.
  /// Keeps the failure visible instead of silently rendering "0 tenants".
  Widget _buildTenantsErrorBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.error.withAlpha(26),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.error.withAlpha(77)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Couldn\'t load tenant data. Occupancy shown may be incomplete — '
              'pull to refresh or try again.',
              style: AppTextStyles.caption.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTenantManagementSection(PropertyModel property) {
    // Outer stream: active rentals for this property (inspection → payment path).
    // landlordId-scoped for the ownership-constrained list rule — this is the
    // owner's tenant-management view, so property.landlordId == the caller's uid.
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('active_rentals')
          .where('landlordId', isEqualTo: property.landlordId)
          .where('propertyId', isEqualTo: property.id)
          .where('status', isEqualTo: 'active')
          .snapshots(),
      builder: (context, rentalSnapshot) {
        if (rentalSnapshot.hasError) {
          AppLogger.e(
            'active_rentals tenants stream failed for ${property.id}',
            error: rentalSnapshot.error,
            name: 'PropertyDetail',
          );
        }
        final rentalDocs = rentalSnapshot.data?.docs ?? [];
        // Collect tenant IDs that came through the rental path
        final rentalTenantIds = rentalDocs
            .map((d) => (d.data() as Map<String, dynamic>)['tenantId'] as String? ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();

        // Inner stream: tenancy links for this property (landlord-link path)
        return StreamBuilder<List<TenancyLinkModel>>(
          stream: _tenancyLinkService.propertyTenantsStream(property.id),
          builder: (context, snapshot) {
            // Surface, don't swallow. A stream error here (e.g. a rules/query
            // regression) previously rendered as "0 tenants" — making the
            // failure invisible. Log it and show an inline banner so occupancy
            // never silently understates reality.
            if (snapshot.hasError) {
              AppLogger.e(
                'propertyTenantsStream failed for ${property.id}',
                error: snapshot.error,
                name: 'PropertyDetail',
              );
            }
            final links = snapshot.data ?? [];
            final confirmed = links.where((l) => l.status == 'confirmed').toList();
            final pending = links.where((l) => l.status == 'pending').toList();

            // Union of both tenant ID sets = all unique occupied slots.
            // Using a Set prevents double-counting if the same tenant somehow
            // appears in both collections.
            final linkedTenantIds = confirmed.map((l) => l.tenantId).toSet();
            final allOccupiedIds = {...rentalTenantIds, ...linkedTenantIds};
            final occupied = allOccupiedIds.length;

            final max = property.maxTenants;
            final isFull = occupied >= max;

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
                  // Degraded-state banner — either tenant source failed to
                  // load, so the occupancy figures below may be incomplete.
                  if (snapshot.hasError || rentalSnapshot.hasError) ...[
                    _buildTenantsErrorBanner(),
                    const SizedBox(height: 12),
                  ],
                  // Header row
                  Row(
                    children: [
                      Icon(
                        Icons.people_outline,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text('Tenants', style: AppTextStyles.labelLarge),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Active rental tenants (read-only — managed by rental flow)
                  if (rentalDocs.isNotEmpty) ...[
                    Text(
                      'Active Rental${rentalDocs.length > 1 ? 's' : ''}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...rentalDocs.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final name = data['tenantName'] as String? ?? 'Tenant';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.success.withAlpha(77)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: AppColors.success.withAlpha(26),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    name.isNotEmpty ? name[0].toUpperCase() : 'T',
                                    style: AppTextStyles.labelMedium.copyWith(
                                      color: AppColors.success,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name, style: AppTextStyles.labelMedium),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Active rental tenant',
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.success.withAlpha(26),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'Active',
                                  style: AppTextStyles.caption.copyWith(
                                    color: AppColors.success,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    if (confirmed.isNotEmpty || pending.isNotEmpty)
                      const SizedBox(height: 8),
                  ],

                  // Pending requests banner
                  if (pending.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withAlpha(26),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.warning.withAlpha(77)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.hourglass_empty,
                            size: 16,
                            color: AppColors.warning,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${pending.length} pending request${pending.length > 1 ? 's' : ''}',
                            style: AppTextStyles.labelSmall.copyWith(
                              color: AppColors.warning,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Confirmed linked tenants list
                  if (confirmed.isNotEmpty) ...[
                    if (rentalDocs.isNotEmpty) ...[
                      Text(
                        'Linked Tenant${confirmed.length > 1 ? 's' : ''}',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    ...confirmed.map((link) => _buildTenantTile(link)),
                  ] else if (rentalDocs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No tenants linked yet. Search for existing tenants to connect them.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),

                  // Pending tenants list
                  if (pending.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Awaiting Response',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...pending.map(
                      (link) => _buildTenantTile(link, isPending: true),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Link tenant button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          isFull ? null : () => _showLinkTenantSheet(property),
                      icon: const Icon(Icons.person_add_outlined, size: 18),
                      label: Text(
                        isFull ? 'Property Full' : 'Link Existing Tenant',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        disabledForegroundColor: AppColors.textHint,
                        side: BorderSide(
                          color: isFull ? AppColors.border : AppColors.primary,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTenantTile(TenancyLinkModel link, {bool isPending = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color:
                isPending ? AppColors.warning.withAlpha(77) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color:
                    isPending
                        ? AppColors.warning.withAlpha(26)
                        : AppColors.primaryLight.withAlpha(51),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  link.tenantName.isNotEmpty
                      ? link.tenantName[0].toUpperCase()
                      : 'T',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: isPending ? AppColors.warning : AppColors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(link.tenantName, style: AppTextStyles.labelMedium),
                  const SizedBox(height: 2),
                  Text(
                    isPending
                        ? 'Waiting for tenant to accept'
                        : 'Linked tenant',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            // Status / remove
            if (isPending)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Pending',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: () => _confirmRemoveTenant(link),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(26),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.person_remove_outlined,
                    size: 16,
                    color: AppColors.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemoveTenant(TenancyLinkModel link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Remove Tenant'),
            content: Text(
              'Remove ${link.tenantName} from this property? They will lose their linked tenant status and would need to pay the verification fee to use ClearRent in future.',
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
                child: Text('Remove', style: TextStyle(color: AppColors.error)),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      final success = await _tenancyLinkService.removeTenant(link.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '${link.tenantName} removed'
                  : 'Failed to remove tenant',
            ),
            backgroundColor: success ? AppColors.success : AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  void _showLinkTenantSheet(PropertyModel property) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (context) => _LinkTenantSheet(
            property: property,
            tenancyLinkService: _tenancyLinkService,
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
                side: BorderSide(color: AppColors.border),
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
                      Icon(
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

          if (_isCheckingVerification)
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
              ),
            )
          else if (_landlordAllowsCalls)
            GestureDetector(
              onTap: () {
                final phone = _landlordPhone;
                if (phone != null && phone.isNotEmpty) {
                  launchUrl(Uri.parse('tel:$phone'));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Phone number not available.'),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  );
                }
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.phone_outlined,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
            )
          else
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(
                Icons.phone_disabled_outlined,
                color: AppColors.textHint,
                size: 20,
              ),
            ),
        ],
      ),
    );
  }

  /// Inspection fee card for agent-handled properties
  Widget _buildInspectionFeeCard(PropertyModel property) {
    // Calculate estimated fee (same-zone minimum since we don't know agent yet)
    final feeBreakdown = InspectionPricing.calculateFee(
      agentCluster: 'maryland_ikeja',
      propertyCluster: 'maryland_ikeja',
    );

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
                child: Icon(
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
                      style: AppTextStyles.labelLarge.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Handled by verified agent',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
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
                    Icon(
                      Icons.verified,
                      size: 12,
                      color: AppColors.success,
                    ),
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Inspection fee',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  InspectionPricing.formatNaira(feeBreakdown.totalFee),
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.primary,
                    fontFamily: 'Roboto',
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Info note: transport advisory + refund policy
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.infoLight.withAlpha(128),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Transport to and from the property is arranged '
                    'directly with the agent. Pay upfront to schedule; '
                    'full refund if the landlord or agent declines.',
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

  Widget _buildFeeBreakdown(PropertyModel property) {
    final rent = property.rent;
    final agentFee = property.agentFee;
    final cautionDeposit = property.cautionDeposit;
    final totalPackage = property.totalPackage;

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
              Icon(
                Icons.receipt_long_outlined,
                size: 20,
                color: AppColors.info,
              ),
              const SizedBox(width: 8),
              Text(
                'Total Package Breakdown',
                style: AppTextStyles.labelLarge.copyWith(color: AppColors.info),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _FeeRow(label: 'Rent', amount: rent),
          if (agentFee > 0) ...[
            const SizedBox(height: 8),
            _FeeRow(label: 'Agent Fee', amount: agentFee),
          ],
          if (cautionDeposit > 0) ...[
            const SizedBox(height: 8),
            _FeeRow(label: 'Caution Deposit', amount: cautionDeposit),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),
          _FeeRow(label: 'Total Package', amount: totalPackage, isTotal: true),
          const SizedBox(height: 8),
          Text(
            'Renewal after first year: ${property.formattedRent}${property.rentPeriod}',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
          if (cautionDeposit > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Caution deposit is refundable when you move out',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          // Recurring dues
          if (property.recurringDues.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.repeat, size: 16, color: AppColors.warning),
                const SizedBox(width: 8),
                Text(
                  'Recurring Dues',
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...property.recurringDues.map((due) {
              final name = due['name'] as String? ?? '';
              final amount = (due['amount'] as num?)?.toDouble() ?? 0;
              final freq = due['frequency'] as String? ?? 'yearly';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(name, style: AppTextStyles.bodyMedium),
                    Text(
                      '₦${_formatDueAmount(amount)}/${freq == 'monthly' ? 'mo' : 'yr'}',
                      style: AppTextStyles.labelMedium.copyWith(fontFamily: 'Roboto'),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Total Dues', style: AppTextStyles.labelMedium),
                  Text(
                    '${property.formattedRecurringDues}/yr',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.warning,
                      fontFamily: 'Roboto',
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

  String _formatDueAmount(double amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(1)}M';
    }
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
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
                  side: BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Request Inspection button — hidden if tenant already lives here
            Expanded(
              flex: 2,
              child: _isLinkedToThisProperty
                  ? ElevatedButton.icon(
                      onPressed: null,
                      icon: Icon(Icons.home),
                      label: Text('You live here'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.success.withAlpha(179),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    )
                  : Builder(builder: (context) {
                      final docStatus = _effectiveDocStatus;
                      final docBlocked = docStatus == 'rejected' ||
                          docStatus == 'none' ||
                          docStatus == 'pending';
                      final Color docColor;
                      if (docStatus == 'rejected') {
                        docColor = AppColors.error;
                      } else if (docStatus == 'pending') {
                        docColor = AppColors.warning;
                      } else {
                        docColor = AppColors.textSecondary;
                      }
                      return ElevatedButton.icon(
                        onPressed: _isCheckingRequest || _hasExistingRequest
                            ? null
                            : () => _requestInspection(),
                        icon: Icon(
                          _hasExistingRequest
                              ? Icons.check_circle
                              : docBlocked
                                  ? Icons.lock_outline
                                  : Icons.event_available,
                        ),
                        label: Text(
                          _hasExistingRequest
                              ? 'Request Sent'
                              : docBlocked
                                  ? 'Inspection Unavailable'
                                  : 'Request Inspection',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _hasExistingRequest
                              ? AppColors.success
                              : docBlocked
                                  ? docColor
                                  : AppColors.primary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: _hasExistingRequest
                              ? AppColors.success.withAlpha(179)
                              : AppColors.textHint,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }

  // ============ SHARED WIDGETS ============

  Widget _buildOccupancyInfoCard(PropertyModel property) {
    // Tenant-facing card. Uses the stored currentTenantsCount, which is
    // recomputed server-side (Cloud Function) from both active_rentals and
    // tenancy_links — so it's authoritative and covers landlord-linked
    // tenants. A browsing tenant no longer lists active_rentals directly
    // (the list rule is now owner-scoped), and never read tenancy_links.
    final storedCount = property.currentTenantsCount ?? 0;
    return _buildOccupancyCard(property, storedCount);
  }

  Widget _buildOccupancyCard(PropertyModel property, int currentCount) {
    // Collect info rows — only show fields that have meaningful data
    final rows = <_OccupancyRow>[];

    // Availability — single-unit listing, so no multi-tenant capacity framing.
    rows.add(_OccupancyRow(
      icon: Icons.chair_outlined,
      label: 'Availability',
      value: currentCount > 0 ? 'Occupied' : 'Available',
      valueColor: currentCount > 0 ? AppColors.error : AppColors.success,
    ));

    // Landlord on premises
    final landlordOnPremises = property.landlordLivesOnPremises ?? false;
    rows.add(_OccupancyRow(
      icon: landlordOnPremises ? Icons.person_pin_circle : Icons.person_pin_circle_outlined,
      label: 'Landlord lives on property',
      value: landlordOnPremises ? 'Yes' : 'No',
      valueColor: null,
    ));

    // Caretaker
    final hasCaretaker = property.hasCaretaker ?? false;
    if (hasCaretaker) {
      final caretakerLives = property.caretakerLivesOnPremises ?? false;
      rows.add(_OccupancyRow(
        icon: Icons.manage_accounts_outlined,
        label: 'Caretaker',
        value: caretakerLives ? 'On-site caretaker' : 'Off-site caretaker',
      ));
    } else {
      rows.add(const _OccupancyRow(
        icon: Icons.manage_accounts_outlined,
        label: 'Caretaker',
        value: 'No caretaker',
      ));
    }

    return _buildSection(
      title: 'Who You\'ll Share With',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: rows.map((row) {
            final isLast = rows.last == row;
            return Column(
              children: [
                Row(
                  children: [
                    Icon(row.icon, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        row.label,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    Text(
                      row.value,
                      style: AppTextStyles.labelMedium.copyWith(
                        color: row.valueColor ?? AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                if (!isLast) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                ],
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

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
      child: Column(
        children: [
          // Primary row: bedrooms, bathrooms, toilets
          Row(
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
          // Secondary row: living room, guest room, kitchen (only if any > 0)
          if (property.livingRooms > 0 || property.guestRooms > 0 || property.kitchens > 0) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                if (property.livingRooms > 0)
                  _FeatureItem(
                    icon: Icons.weekend_outlined,
                    value: '${property.livingRooms}',
                    label: 'Living Room',
                  ),
                if (property.guestRooms > 0)
                  _FeatureItem(
                    icon: Icons.meeting_room_outlined,
                    value: '${property.guestRooms}',
                    label: 'Guest Room',
                  ),
                if (property.kitchens > 0)
                  _FeatureItem(
                    icon: Icons.kitchen_outlined,
                    value: '${property.kitchens}',
                    label: 'Kitchen',
                  ),
              ],
            ),
          ],
          // Ceiling type row
          if (property.ceilingType != null && property.ceilingType!.isNotEmpty && property.ceilingType != 'none') ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.roofing_outlined, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  'Ceiling: ${_ceilingTypeLabel(property.ceilingType!)}',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _ceilingTypeLabel(String type) {
    switch (type) {
      case 'false_ceiling':
        return 'False Ceiling (POP)';
      case 'pvc':
        return 'PVC';
      case 'concrete':
        return 'Concrete';
      case 'asbestos':
        return 'Asbestos';
      case 'none':
        return 'None';
      default:
        return type;
    }
  }

  Widget _buildVideoPreview() {
    final controller = _videoController!;
    final totalDuration = controller.value.duration;
    final previewEnd = totalDuration > _previewDuration ? _previewDuration : totalDuration;
    final progress = previewEnd.inMilliseconds > 0
        ? (_videoPosition.inMilliseconds / previewEnd.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: _openFullscreenVideo,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.videocam_outlined, size: 18, color: Colors.white70),
                  const SizedBox(width: 8),
                  Text(
                    'Video Tour',
                    style: AppTextStyles.labelMedium.copyWith(color: Colors.white),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(26),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _videoMuted ? Icons.volume_off : Icons.volume_up,
                          size: 14,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Tap to expand',
                          style: AppTextStyles.caption.copyWith(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Video
            ClipRRect(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),

            // Progress bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.white.withAlpha(38),
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              ),
            ),

            // Time and play/pause
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Text(
                    '${_formatVideoDuration(_videoPosition)} / ${_formatVideoDuration(previewEnd)}',
                    style: AppTextStyles.caption.copyWith(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                  if (!controller.value.isPlaying && _videoPosition >= _previewDuration)
                    Text(
                      'Tap for full video',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.primary,
                        fontSize: 11,
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: () {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          if (_videoPosition >= _previewDuration) {
                            controller.seekTo(Duration.zero);
                          }
                          controller.play();
                        }
                      },
                      child: Icon(
                        controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 20,
                        color: Colors.white70,
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

  String _formatVideoDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
          '₦${_formatAmount(amount)}',
          style:
              isTotal
                  ? AppTextStyles.h4.copyWith(color: AppColors.primary, fontFamily: 'Roboto')
                  : AppTextStyles.labelLarge.copyWith(fontFamily: 'Roboto'),
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

class _ContactSheet extends StatefulWidget {
  final PropertyModel property;
  final String currentUserId;
  final String currentUserName;
  final ConversationService conversationService;
  final bool landlordAllowsCalls;
  final String? landlordPhone;
  final Function(ConversationData) onStartChat;

  const _ContactSheet({
    required this.property,
    required this.currentUserId,
    required this.currentUserName,
    required this.conversationService,
    required this.landlordAllowsCalls,
    required this.landlordPhone,
    required this.onStartChat,
  });

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  bool _isStartingChat = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _startOrOpenChat() async {
    if (_isStartingChat) return;

    setState(() => _isStartingChat = true);

    try {
      final conversation = await widget.conversationService
          .getOrCreateConversation(
            propertyId: widget.property.id,
            propertyTitle: widget.property.title,
            propertyImage:
                widget.property.images.isNotEmpty
                    ? widget.property.images.first
                    : '',
            landlordId: widget.property.landlordId,
            landlordName: widget.property.landlordName ?? 'Landlord',
            tenantId: widget.currentUserId,
            tenantName: widget.currentUserName,
            agentId: widget.property.assignedAgentId,
            agentName: widget.property.assignedAgentName,
          );

      if (!mounted) return;

      if (conversation != null) {
        // Capture what we need, then pop, then navigate
        final onStartChat = widget.onStartChat;
        Navigator.pop(context);
        onStartChat(conversation);
      } else {
        setState(() => _isStartingChat = false);
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
    } catch (e) {
      debugPrint('❌ Error starting chat: $e');
      if (!mounted) return;
      setState(() => _isStartingChat = false);
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

  void _callLandlord() {
    Navigator.pop(context);
    final phone = widget.landlordPhone;
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
      launchUrl(Uri.parse('tel:$phone'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
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
            'Contact ${widget.property.hasAgent ? 'Agent' : 'Landlord'}',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 24),

          // Message option
          _ContactOption(
            icon: Icons.chat_bubble_outline,
            title: 'Send a Message',
            subtitle: 'Chat directly in the app',
            isLoading: _isStartingChat,
            onTap: _isStartingChat ? null : _startOrOpenChat,
          ),

          const SizedBox(height: 12),

          // Call option - respects landlord's allowsCalls setting
          if (widget.landlordAllowsCalls)
            _ContactOption(
              icon: Icons.phone_outlined,
              title: 'Call ${widget.property.landlordName ?? 'Landlord'}',
              subtitle: widget.landlordPhone ?? 'Phone not available',
              onTap: widget.landlordPhone != null ? _callLandlord : null,
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
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
                      color: AppColors.textHint.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.phone_disabled_outlined,
                      color: AppColors.textHint,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Phone calls not available',
                          style: AppTextStyles.labelLarge.copyWith(
                            color: AppColors.textHint,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'This landlord prefers messages only',
                          style: AppTextStyles.caption,
                        ),
                      ],
                    ),
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

class _ContactOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool isLoading;

  const _ContactOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isLoading = false,
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
              child:
                  isLoading
                      ? Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        ),
                      )
                      : Icon(icon, color: AppColors.primary),
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
            Icon(Icons.chevron_right, color: AppColors.textHint),
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
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.all(24),
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
      ),
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

class _LinkTenantSheet extends StatefulWidget {
  final PropertyModel property;
  final TenancyLinkService tenancyLinkService;

  const _LinkTenantSheet({
    required this.property,
    required this.tenancyLinkService,
  });

  @override
  State<_LinkTenantSheet> createState() => _LinkTenantSheetState();
}

class _LinkTenantSheetState extends State<_LinkTenantSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<TenantSearchResult> _results = [];
  bool _isSearching = false;
  bool _isSending = false;
  String? _sendingUserId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _isSearching = true);
    final results = await widget.tenancyLinkService.searchTenantsByName(query);
    if (mounted) {
      setState(() {
        _results = results;
        _isSearching = false;
      });
    }
  }

  Future<void> _sendRequest(TenantSearchResult tenant) async {
    // First collect rent due day from landlord
    final rentConfig = await _showRentConfigSheet();
    if (rentConfig == null) return; // landlord dismissed without confirming

    setState(() {
      _isSending = true;
      _sendingUserId = tenant.userId;
    });

    final success = await widget.tenancyLinkService.sendLinkRequest(
      propertyId: widget.property.id,
      propertyTitle: widget.property.title,
      propertyAddress: widget.property.address,
      propertyCity: widget.property.city,
      tenantId: tenant.userId,
      tenantName: tenant.fullName,
      rentDueDay: rentConfig['rentDueDay'] as int,
      rentDueMonth: (rentConfig['rentDueMonth'] as int?) ?? 1,
      rentAmount: widget.property.rent,
      rentFrequency: (rentConfig['rentFrequency'] as String?) ?? widget.property.rentFrequency,
      leaseStartDate: rentConfig['leaseStartDate'] as DateTime?,
      leaseEndDate: rentConfig['leaseEndDate'] as DateTime?,
    );

    if (!mounted) return;

    setState(() {
      _isSending = false;
      _sendingUserId = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Request sent to ${tenant.fullName}'
              : 'Could not send request. They may already be linked.',
        ),
        backgroundColor: success ? AppColors.success : AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    if (success) Navigator.pop(context);
  }

  /// Shows a bottom sheet for landlord to pick rent due day.
  /// Returns {'rentDueDay': int} or null if dismissed.
  Future<Map<String, dynamic>?> _showRentConfigSheet() async {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RentConfigSheet(property: widget.property),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            Text('Link Existing Tenant', style: AppTextStyles.h4),
            const SizedBox(height: 4),
            Text(
              'Search for tenants already registered on ClearRent.',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),

            // Search field
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: 'Search by name...',
                prefixIcon: Icon(
                  Icons.search,
                  color: AppColors.textSecondary,
                ),
                suffixIcon:
                    _isSearching
                        ? Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                        )
                        : null,
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: AppColors.primary,
                    width: 2,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Results
            if (_results.isEmpty &&
                !_isSearching &&
                _searchController.text.length >= 2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'No tenants found with that name.',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final tenant = _results[index];
                    final isThisSending =
                        _isSending && _sendingUserId == tenant.userId;
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          // Avatar
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight.withAlpha(51),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                tenant.fullName.isNotEmpty
                                    ? tenant.fullName[0].toUpperCase()
                                    : 'T',
                                style: AppTextStyles.labelMedium.copyWith(
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      tenant.fullName,
                                      style: AppTextStyles.labelMedium,
                                    ),
                                    if (tenant.isVerified) ...[
                                      const SizedBox(width: 4),
                                      Icon(
                                        Icons.verified,
                                        size: 14,
                                        color: AppColors.primary,
                                      ),
                                    ],
                                  ],
                                ),
                                if (!tenant.isVerified)
                                  Text(
                                    'Not yet verified',
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.textHint,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Send button
                          ElevatedButton(
                            onPressed:
                                isThisSending || _isSending
                                    ? null
                                    : () => _sendRequest(tenant),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child:
                                isThisSending
                                    ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                    : const Text('Invite'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// RENT CONFIG SHEET — landlord sets rent due day before sending link request
// ─────────────────────────────────────────────────────────────────────────────

class _RentConfigSheet extends StatefulWidget {
  final PropertyModel property;
  const _RentConfigSheet({required this.property});

  @override
  State<_RentConfigSheet> createState() => _RentConfigSheetState();
}

class _RentConfigSheetState extends State<_RentConfigSheet> {
  // Yearly only at launch (monthly is v2). Fixed — there is no UI to change it.
  final String _frequency = 'yearly';
  int _selectedDay = 1;
  // for yearly: month 1-12
  int _selectedMonth = 1;
  // Lease term is DERIVED from the rent due date — one source of truth, so the
  // landlord can't enter a lease date that contradicts when rent is due. The
  // current period began on the most recent past occurrence of the due
  // month/day and runs one year (Lagos yearly advance-rent cap).
  DateTime get _leaseStart {
    final now = DateTime.now();
    final maxDay = _daysInMonth(_selectedMonth);
    final day = _selectedDay < 1
        ? 1
        : (_selectedDay > maxDay ? maxDay : _selectedDay);
    final thisYear = DateTime(now.year, _selectedMonth, day);
    return thisYear.isAfter(now)
        ? DateTime(now.year - 1, _selectedMonth, day)
        : thisYear;
  }

  DateTime get _leaseEnd => DateTime(
        _leaseStart.year + 1,
        _leaseStart.month,
        _leaseStart.day,
      );

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  String _fmtDate(DateTime d) => '${_months[d.month - 1].substring(0, 3)} ${d.day}, ${d.year}';

  @override
  void initState() {
    super.initState();
    // Yearly only at launch — monthly is v2 (mirrors add-property; the lease
    // lifecycle relies on the Lagos one-year advance-rent cap). _frequency
    // stays 'yearly' regardless of the property's stored value.
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border, borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            const SizedBox(height: 20),

            Text('Configure Rent', style: AppTextStyles.h4),
            const SizedBox(height: 4),
            Text(
              'Set the payment frequency and due date for your tenant.',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),

            // Property summary pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withAlpha(51)),
              ),
              child: Row(children: [
                Icon(Icons.home_outlined, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.property.title,
                    style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  widget.property.formattedRent,
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            // ── Rent frequency — yearly only at launch (monthly is v2; the
            // lease lifecycle relies on the Lagos one-year advance-rent cap).
            // Mirrors the add-property screen. ──
            Text('Rent Frequency', style: AppTextStyles.labelMedium),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primary),
              ),
              child: Row(children: [
                Icon(Icons.calendar_today_outlined, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  'Per Year',
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                ),
                const Spacer(),
                Text(
                  'Monthly coming soon',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            // ── Due date — yearly: pick the month + day rent is due ──
              Text('Which month is rent due each year?', style: AppTextStyles.labelMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(12, (i) {
                  final sel = _selectedMonth == (i + 1);
                  return GestureDetector(
                    onTap: () => setState(() {
                      _selectedMonth = i + 1;
                      final maxDay = _daysInMonth(_selectedMonth);
                      if (_selectedDay > maxDay) _selectedDay = maxDay;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.primary : AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: sel ? AppColors.primary : AppColors.border),
                      ),
                      child: Text(
                        _months[i].substring(0, 3),
                        style: AppTextStyles.labelMedium.copyWith(
                          color: sel ? Colors.white : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 20),
              // Yearly — also pick the day within that month
              Text('Which day of ${_months[_selectedMonth - 1]} is rent due?', style: AppTextStyles.labelMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: () {
                  final maxDay = _daysInMonth(_selectedMonth);
                  final picks = [1, 5, 10, 15, 20, 25, maxDay];
                  return picks.toSet().toList()..sort();
                }().map((day) {
                  final sel = _selectedDay == day;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedDay = day),
                    child: Container(
                      width: 56,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.primary : AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: sel ? AppColors.primary : AppColors.border),
                      ),
                      child: Center(
                        child: Text(
                          _ordinal(day),
                          style: AppTextStyles.labelMedium.copyWith(
                            color: sel ? Colors.white : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Text('Other:', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                const SizedBox(width: 10),
                SizedBox(
                  width: 72,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.labelLarge,
                    maxLength: 2,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        if (newValue.text.isEmpty) return newValue;
                        final n = int.tryParse(newValue.text);
                        final maxDay = _daysInMonth(_selectedMonth);
                        if (n == null || n < 1 || n > maxDay) return oldValue;
                        return newValue;
                      }),
                    ],
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '1–${_daysInMonth(_selectedMonth)}',
                      hintStyle: AppTextStyles.caption.copyWith(color: AppColors.textHint),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      filled: true,
                      fillColor: AppColors.background,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.primary, width: 2)),
                    ),
                    onChanged: (val) {
                      final n = int.tryParse(val);
                      final maxDay = _daysInMonth(_selectedMonth);
                      if (n != null && n >= 1 && n <= maxDay) setState(() => _selectedDay = n);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Text('of ${_months[_selectedMonth - 1]}', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
              ]),
              const SizedBox(height: 6),
              Text(
                'Tenant will be reminded when ${_months[_selectedMonth - 1]} ${_ordinal(_selectedDay)} approaches.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),

            const SizedBox(height: 24),

            // ── Lease term (auto-derived from the rent due date) ──────────
            Text('Lease Term', style: AppTextStyles.labelMedium),
            const SizedBox(height: 4),
            Text(
              'Set automatically from the rent due date above — the current '
              'year runs to the next due date (Lagos law caps yearly rent in '
              'advance at one year).',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(children: [
                Icon(Icons.event_outlined, size: 18, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Starts', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
                      Text(_fmtDate(_leaseStart), style: AppTextStyles.labelMedium),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward, size: 16, color: AppColors.textHint),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Ends', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
                    Text(_fmtDate(_leaseEnd), style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
                  ],
                ),
              ]),
            ),

            const SizedBox(height: 24),

            // Confirm button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context, {
                    'rentDueDay': _selectedDay,
                    'rentDueMonth': _frequency == 'yearly' ? _selectedMonth : null,
                    'rentFrequency': _frequency,
                    'leaseStartDate': _leaseStart,
                    'leaseEndDate': _leaseEnd,
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'Confirm  •  Due ${_ordinal(_selectedDay)} ${_months[_selectedMonth - 1]} yearly',
                  style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
                ),
              ),
            ),

              SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
            ],
          ),
        ),
      ),
    );
  }

  String _ordinal(int n) {
    if (n >= 11 && n <= 13) return '${n}th';
    switch (n % 10) {
      case 1: return '${n}st';
      case 2: return '${n}nd';
      case 3: return '${n}rd';
      default: return '${n}th';
    }
  }

  int _daysInMonth(int month) {
    switch (month) {
      case 1: case 3: case 5: case 7: case 8: case 10: case 12:
        return 31;
      case 4: case 6: case 9: case 11:
        return 30;
      case 2:
        final year = DateTime.now().year;
        final isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        return isLeap ? 29 : 28;
      default:
        return 28;
    }
  }
}

class _OccupancyRow {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _OccupancyRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });
}

/// Fullscreen video player with chewie controls
class _FullscreenVideoScreen extends StatefulWidget {
  final String videoUrl;

  const _FullscreenVideoScreen({required this.videoUrl});

  @override
  State<_FullscreenVideoScreen> createState() => _FullscreenVideoScreenState();
}

class _FullscreenVideoScreenState extends State<_FullscreenVideoScreen> {
  late VideoPlayerController _controller;
  ChewieController? _chewieController;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    await _controller.initialize();

    _chewieController = ChewieController(
      videoPlayerController: _controller,
      autoPlay: true,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
      showControlsOnInitialize: true,
      materialProgressColors: ChewieProgressColors(
        playedColor: AppColors.primary,
        handleColor: AppColors.primary,
        backgroundColor: Colors.white24,
        bufferedColor: Colors.white38,
      ),
    );

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Video Tour', style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : Center(
              child: Chewie(controller: _chewieController!),
            ),
    );
  }
}