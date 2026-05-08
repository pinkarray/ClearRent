import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/models/tenancy_link_model.dart';
import '../../../property/presentation/widgets/property_card.dart';
import '../../../chat/presentation/widgets/messages_tab.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/saved_properties_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/tenancy_link_service.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/widgets/connectivity_wrapper.dart';
import '../../../../shared/widgets/user_avatar.dart';
import '../../../../shared/widgets/verification_badge.dart';
import '../../../../shared/widgets/notification_bell.dart';
import '../widgets/tenant_rental_dashboard.dart';
import '../../../../shared/widgets/announcements_banner.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';

const List<Map<String, String>> propertyTypes = [
  {'label': 'All', 'value': 'all'},
  {'label': 'Flat', 'value': 'flat'},
  {'label': 'Duplex', 'value': 'duplex'},
  {'label': 'Bungalow', 'value': 'bungalow'},
  {'label': 'Self Contain', 'value': 'self_contain'},
  {'label': 'Room & Parlour', 'value': 'room_and_parlour'},
  {'label': 'Studio', 'value': 'studio'},
  {'label': 'Mansion', 'value': 'mansion'},
];

const List<String> lagosAreas = [
  'All Areas',
  'Ikeja', 'Victoria Island', 'Lekki', 'Ajah', 'Surulere',
  'Yaba', 'Maryland', 'Magodo', 'GRA Ikeja', 'Gbagada',
  'Ikoyi', 'Oniru', 'Ikorodu', 'Badagry', 'Epe',
  'Ojota', 'Ketu', 'Mile 12', 'Agege', 'Alimosho',
  'Isolo', 'Mushin', 'Oshodi', 'Apapa', 'Ajegunle',
];

class TenantHomeScreen extends StatefulWidget {
  const TenantHomeScreen({super.key});

  @override
  State<TenantHomeScreen> createState() => _TenantHomeScreenState();
}

class _TenantHomeScreenState extends State<TenantHomeScreen> {
  final TextEditingController _searchController = TextEditingController();

  // Services
  late final AuthService _authService;
  late final SavedPropertiesService _savedService;
  late final ConversationService _conversationService;
  late final PropertyService _propertyService;
  late final ActiveRentalService _activeRentalService;
  late final TenancyLinkService _tenancyLinkService;
  // Saved properties
  Set<String> _savedProperties = {};
  bool _isLoadingSaved = true;

  // Unread messages
  int _unreadCount = 0;

  int _currentNavIndex = 0;
  String _selectedType = 'all';
  String _selectedArea = 'All Areas';

  // Properties
  List<PropertyModel> _realProperties = [];
  List<PropertyModel> _allProperties = [];
  List<PropertyModel> _filteredProperties = [];
  bool _isLoadingProperties = true;

  // Active rental (paid/contract-based)
  ActiveRental? _activeRental;
  bool _isLoadingRental = true;
  bool _browsingFromDashboard = false; // true when user tapped "browse" from rental dashboard
  bool _browsingFromLinkedDashboard = false; // true when verified linked tenant taps browse

  // Live rent from property (overrides stale link snapshot)
  double? _livePropertyRent;
  String? _livePropertyRentFrequency;

  DateTime? _lastBackPressed;

  // User data
  String _userName = '';
  String? _profileImageUrl;
  File? _localProfileImage;
  bool _isUploadingImage = false;
  bool _isLoadingProfile = true;

  VerificationStatus _verificationStatus = VerificationStatus.none;
  bool _hasBankDetails = false;

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _savedService = SavedPropertiesService();
    _conversationService = ConversationService();
    _propertyService = PropertyService();
    _activeRentalService = ActiveRentalService();
    _tenancyLinkService = TenancyLinkService();
    _loadUserProfile();
    _loadSavedProperties();
    _loadUnreadCount();
    _loadProperties();
    _loadActiveRental();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── DATA LOADING ──────────────────────────────────────────────────────────

  Future<void> _loadVerificationStatus() => _loadUserProfile();

  Future<void> _loadUserProfile() async {
    try {
      final profile = await _authService.getUserProfile();
      if (profile != null && mounted) {
        // Parse verification status directly from Firestore — same field admin sets
        final status = profile['verificationStatus'] as String? ?? 'none';
        final isVerified = profile['isVerified'] == true;
        VerificationStatus verStatus;
        if (status == 'verified' || isVerified) {
          verStatus = VerificationStatus.verified;
        } else if (status == 'pending') {
          verStatus = VerificationStatus.pending;
        } else if (status == 'rejected') {
          verStatus = VerificationStatus.rejected;
        } else {
          verStatus = VerificationStatus.none;
        }
        setState(() {
          _userName = profile['fullName'] ?? 'Tenant';
          _profileImageUrl = profile['profileImageUrl'];
          _verificationStatus = verStatus;
          _isLoadingProfile = false;
          // Track bank details
          final bankDetails = profile['bankDetails'] as Map<String, dynamic>?;
          _hasBankDetails = bankDetails != null &&
              (bankDetails['bankName'] ?? '').toString().isNotEmpty &&
              (bankDetails['accountNumber'] ?? '').toString().isNotEmpty;
        });
      } else {
        if (mounted) setState(() { _userName = 'Tenant'; _isLoadingProfile = false; });
      }
    } catch (e) {
      debugPrint('❌ Error loading profile: $e');
      if (mounted) setState(() { _userName = 'Tenant'; _isLoadingProfile = false; });
    }
  }

  Future<void> _loadSavedProperties() async {
    try {
      final savedIds = await _savedService.getSavedPropertyIds();
      if (mounted) setState(() { _savedProperties = savedIds; _isLoadingSaved = false; });
    } catch (e) {
      debugPrint('❌ Error loading saved: $e');
      if (mounted) setState(() => _isLoadingSaved = false);
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await _conversationService.getTotalUnreadCount();
      if (mounted) setState(() => _unreadCount = count);
    } catch (e) {
      debugPrint('❌ Error loading unread: $e');
    }
  }

  Future<void> _loadProperties() async {
    setState(() => _isLoadingProperties = true);
    try {
      final realProps = await _propertyService.getAvailableProperties();
      if (mounted) {
        setState(() {
          _realProperties = realProps;
          final seenIds = <String>{};
          _allProperties = _realProperties
              .where((p) => seenIds.add(p.id))
              .where((p) => p.isAvailable || p.hasAvailableSpots)
              .toList();
          _isLoadingProperties = false;
        });
        _filterProperties();
      }
    } catch (e) {
      debugPrint('❌ Error loading properties: $e');
      if (mounted) {
        setState(() { _allProperties = []; _isLoadingProperties = false; });
        _filterProperties();
      }
    }
  }

  Future<void> _loadActiveRental() async {
    try {
      final rental = await _activeRentalService.getTenantActiveRental();
      if (mounted) setState(() { _activeRental = rental; _isLoadingRental = false; });
    } catch (e) {
      debugPrint('❌ Error loading rental: $e');
      if (mounted) setState(() => _isLoadingRental = false);
    }
  }

  /// Fetches live rent from Firestore property document.
  /// Called once we know the activeLink's propertyId.
  Future<void> _loadLiveRent(String propertyId) async {
    if (propertyId.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('properties')
          .doc(propertyId)
          .get();
      if (!mounted) return;
      final data = doc.data();
      if (data != null) {
        setState(() {
          _livePropertyRent = (data['rent'] as num?)?.toDouble();
          _livePropertyRentFrequency = data['rentFrequency'] as String?;
        });
      }
    } catch (e) {
      debugPrint('⚠️ Could not load live rent: $e');
    }
  }

  Future<void> _refreshData() async {
    await Future.wait([
      _loadProperties(),
      _loadSavedProperties(),
      _loadUnreadCount(),
      _loadActiveRental(),
    ]);
  }

  // ── PROFILE IMAGE ─────────────────────────────────────────────────────────

  Future<void> _pickProfileImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              Text('Profile Photo', style: AppTextStyles.h4),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _buildSourceOption(icon: Icons.camera_alt_rounded, label: 'Camera', onTap: () => Navigator.pop(ctx, ImageSource.camera)),
                _buildSourceOption(icon: Icons.photo_library_rounded, label: 'Gallery', onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
                if (_profileImageUrl != null)
                  _buildSourceOption(icon: Icons.delete_outline, label: 'Remove', onTap: () => Navigator.pop(ctx, null), color: AppColors.error),
              ]),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );

    // Remove photo
    if (source == null && _profileImageUrl != null) {
      setState(() => _isUploadingImage = true);
      final removed = await _authService.removeProfileImage();
      if (mounted && removed) {
        setState(() { _profileImageUrl = null; _localProfileImage = null; _isUploadingImage = false; });
      } else {
        if (mounted) setState(() => _isUploadingImage = false);
      }
      return;
    }

    if (source == null) return;

    try {
      final XFile? image = await picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 85);
      if (image == null) return;
      final file = File(image.path);
      setState(() { _localProfileImage = file; _isUploadingImage = true; });

      final url = await _authService.uploadProfileImage(file);
      if (mounted) {
        setState(() {
          if (url != null) { _profileImageUrl = url; _localProfileImage = null; }
          _isUploadingImage = false;
        });
        if (url != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Profile photo updated!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      }
    } catch (e) {
      debugPrint('❌ Error picking profile image: $e');
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Widget _buildSourceOption({required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: (color ?? AppColors.primary).withAlpha(26), borderRadius: BorderRadius.circular(16)),
          child: Icon(icon, color: color ?? AppColors.primary, size: 32),
        ),
        const SizedBox(height: 8),
        Text(label, style: AppTextStyles.labelMedium.copyWith(color: color ?? AppColors.textPrimary)),
      ]),
    );
  }

  // ── NAVIGATION ────────────────────────────────────────────────────────────

  Future<bool> _onWillPop() async {
    if (_currentNavIndex != 0) {
      setState(() => _currentNavIndex = 0);
      return false;
    }
    final now = DateTime.now();
    if (_lastBackPressed == null || now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Press back again to exit'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return false;
    }
    return true;
  }

  void _filterProperties() {
    setState(() {
      _filteredProperties = _allProperties.where((property) {
        if (_selectedType != 'all' && property.propertyType != _selectedType) return false;
        if (_selectedArea != 'All Areas' && property.city != _selectedArea) return false;
        if (_searchController.text.isNotEmpty) {
          final query = _searchController.text.toLowerCase();
          return property.title.toLowerCase().contains(query) ||
              property.city.toLowerCase().contains(query) ||
              property.address.toLowerCase().contains(query);
        }
        return true;
      }).toList();
    });
  }

  Future<void> _toggleSave(String propertyId) async {
    final wasSaved = _savedProperties.contains(propertyId);
    setState(() { wasSaved ? _savedProperties.remove(propertyId) : _savedProperties.add(propertyId); });
    final success = wasSaved
        ? await _savedService.unsaveProperty(propertyId)
        : await _savedService.saveProperty(propertyId);
    if (!success && mounted) {
      setState(() { wasSaved ? _savedProperties.add(propertyId) : _savedProperties.remove(propertyId); });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Failed to update saved properties'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  void _openPropertyDetail(PropertyModel property) => context.push('/property-detail', extra: property);

  String get _firstName => _userName.split(' ').first;

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) SystemNavigator.pop();
      },
      child: ConnectivityWrapper(
        child: StreamBuilder<TenancyLinkModel?>(
          stream: _tenancyLinkService.tenantActiveLinkStream(),
          builder: (context, activeLinkSnap) {
            final activeLink = activeLinkSnap.data;
            // Load live rent from property whenever the link changes
            if (activeLink != null && _livePropertyRent == null) {
              _loadLiveRent(activeLink.propertyId);
            }
            return StreamBuilder<List<TenancyLinkModel>>(
              stream: _tenancyLinkService.tenantPendingLinksStream(),
              builder: (context, pendingSnap) {
                final pendingLinks = pendingSnap.data ?? [];
                final isVerified = _verificationStatus == VerificationStatus.verified;
                final isLinkedUnverified = activeLink != null && !isVerified;
                final isLinkedVerified = activeLink != null && isVerified;
                return Scaffold(
                  backgroundColor: AppColors.background,
                  body: _buildCurrentTab(activeLink, pendingLinks, isLinkedUnverified, isLinkedVerified),
                  bottomNavigationBar: _buildBottomNav(isLinkedUnverified, isLinkedVerified),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildCurrentTab(
    TenancyLinkModel? activeLink,
    List<TenancyLinkModel> pendingLinks,
    bool isLinkedUnverified,
    bool isLinkedVerified,
  ) {
    // ── Loading guard: don't route until profile (verification status) is known ──
    // Without this, _verificationStatus starts as 'none' and verified linked tenants
    // incorrectly fall to Tier 2 or Tier 3 on first build.
    if (_isLoadingProfile) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }

    // ── TIER 1: Verified linked tenant — tenancy dashboard ───────────────
    // Note: TenantRentalDashboard requires an ActiveRental (post-inspection flow).
    // Linked tenants use their own dashboard built from TenancyLinkModel.
    if (isLinkedVerified && activeLink != null) {
      switch (_currentNavIndex) {
        case 0:
          // When browsing, show home tab (browse mode) instead of linked dashboard
          if (_browsingFromLinkedDashboard) {
            return SafeArea(child: _buildHomeTab(pendingLinks));
          }
          return SafeArea(child: _buildLinkedVerifiedDashboard(activeLink, pendingLinks));
        case 1: return SafeArea(child: _buildSavedTab());
        case 2: return SafeArea(child: _buildMessagesTab());
        case 3: return _buildProfileTab();
        default: return SafeArea(child: _buildLinkedVerifiedDashboard(activeLink, pendingLinks));
      }
    }

    // ── TIER 2: Unverified linked tenant — limited access ─────────────────
    if (isLinkedUnverified && activeLink != null) {
      switch (_currentNavIndex) {
        case 0: return SafeArea(child: _buildLinkedUnverifiedHome(activeLink, pendingLinks));
        case 1: return _buildLinkedUnverifiedProfile();
        default: return SafeArea(child: _buildLinkedUnverifiedHome(activeLink, pendingLinks));
      }
    }

    // ── TIER 3: Unlinked tenant — browse mode (with active rental if any) ─
    if (!_isLoadingRental && _activeRental != null && !_browsingFromDashboard) {
      if (_currentNavIndex == 0) {
        return SafeArea(
          child: TenantRentalDashboard(
            rental: _activeRental!,
            userName: _userName,
            userInitial: _userName.isNotEmpty ? _userName[0].toUpperCase() : 'T',
            isLoadingProfile: _isLoadingProfile,
            onBrowseProperties: () => setState(() => _browsingFromDashboard = true),
          ),
        );
      }
    }
    switch (_currentNavIndex) {
      case 0: return SafeArea(child: _buildHomeTab(pendingLinks));
      case 1: return SafeArea(child: _buildSavedTab());
      case 2: return SafeArea(child: _buildMessagesTab());
      case 3: return _buildProfileTab();
      default: return SafeArea(child: _buildHomeTab(pendingLinks));
    }
  }

  // ── TIER 2: UNVERIFIED LINKED TENANT HOME ───────────────────────────────
  // Limited dashboard: see rent info + landlord call + verification CTA

  Widget _buildLinkedUnverifiedHome(TenancyLinkModel link, List<TenancyLinkModel> pendingLinks) {
    final daysLeft = link.daysUntilDue;
    final isUrgent = daysLeft <= 3;
    final isDue = daysLeft == 0;
    return CustomScrollView(
      slivers: [
        _buildLinkedAppBar(
          title: 'My Tenancy',
          subtitle: link.propertyCity,
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Rent due card
              _buildRentDueCard(link, daysLeft, isUrgent, isDue),
              const SizedBox(height: 16),

              // Property info
              _buildLinkedPropertyCard(link),
              const SizedBox(height: 16),

              // Landlord call (no in-app message for unverified)
              _buildLandlordContactCard(link, canMessage: false),
              const SizedBox(height: 20),

              // Pending link requests
              if (pendingLinks.isNotEmpty) ...[
                _buildPendingLinksSection(pendingLinks),
                const SizedBox(height: 20),
              ],

              // ── Unlock full access CTA ────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primary, AppColors.primary.withAlpha(200)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(40),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.lock_open_outlined, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text('Unlock Full Access', style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                    "You're currently a linked tenant. Pay ₦5,000 to get verified and unlock:",
                    style: AppTextStyles.bodySmall.copyWith(color: Colors.white.withAlpha(220), height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  ...const [
                    _AccessFeature('Report maintenance issues', Icons.report_problem_outlined),
                    _AccessFeature('View & manage your lease', Icons.description_outlined),
                    _AccessFeature('In-app messaging with landlord', Icons.chat_outlined),
                    _AccessFeature('Browse & save other properties', Icons.search_outlined),
                    _AccessFeature('Request inspections', Icons.event_available_outlined),
                  ].map((f) => Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Icon(f.icon, color: Color(0x33FFFFFF), size: 16),
                      SizedBox(width: 8),
                      Text(f.label, style: TextStyle(color: Color(0xDCFFFFFF), fontSize: 12)),
                    ]),
                  )),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => context.push('/tenant/verification').then((_) => _loadVerificationStatus()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text('Get Verified — ₦5,000', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary)),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 40),
            ]),
          ),
        ),
      ],
    );
  }

  // ── TIER 1: VERIFIED LINKED TENANT DASHBOARD ────────────────────────────
  // Full linked dashboard — report issues, lease details, messaging, browse

  Widget _buildLinkedVerifiedDashboard(TenancyLinkModel link, List<TenancyLinkModel> pendingLinks) {
    final daysLeft = link.daysUntilDue;
    final isUrgent = daysLeft <= 3;
    final isDue = daysLeft == 0;
    return CustomScrollView(
      slivers: [
        _buildLinkedAppBar(title: 'My Tenancy', subtitle: link.propertyCity),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Rent due card
              _buildRentDueCard(link, daysLeft, isUrgent, isDue),
              const SizedBox(height: 16),

              // Property info
              _buildLinkedPropertyCard(link),
              const SizedBox(height: 16),

              // Landlord contact with messaging
              _buildLandlordContactCard(link, canMessage: true),
              const SizedBox(height: 16),

              // Pending fix confirmations
              _buildLinkedPendingConfirmations(link),

              // Active issues summary (open + in_progress)
              _buildActiveIssuesCard(link),

              // Quick actions — verified tenant only
              Row(children: [
                Expanded(
                  child: _LinkedActionCard(
                    icon: Icons.description_outlined,
                    label: 'Lease Details',
                    color: AppColors.info,
                    onTap: () => _showLinkedLeaseDetails(link),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LinkedActionCard(
                    icon: Icons.report_problem_outlined,
                    label: 'Report Issue',
                    color: AppColors.warning,
                    onTap: () => context.push('/tenant/report-issue', extra: {
                      'propertyId': link.propertyId,
                      'propertyTitle': link.propertyTitle,
                      'tenantId': link.tenantId,
                      'tenantName': link.tenantName,
                      'landlordId': link.landlordId,
                      'landlordName': link.landlordName,
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LinkedActionCard(
                    icon: Icons.payment_outlined,
                    label: 'Payments',
                    color: AppColors.success,
                    onTap: () => context.push('/tenant/payment-history'),
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // Pending link requests
              if (pendingLinks.isNotEmpty) ...[
                _buildPendingLinksSection(pendingLinks),
                const SizedBox(height: 16),
              ],

              // Browse more (future tenancy)
              GestureDetector(
                onTap: () => setState(() => _browsingFromLinkedDashboard = true),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                      child: Icon(Icons.search_outlined, color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Browse Properties', style: AppTextStyles.labelMedium),
                      Text('Looking ahead? Find your next home.', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                    ])),
                    Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary),
                  ]),
                ),
              ),
              const SizedBox(height: 40),
            ]),
          ),
        ),
      ],
    );
  }

  // Streams pending_confirmation issues for linked tenants — same accountability
  // loop as the inspection-path tenant dashboard.
  Widget _buildLinkedPendingConfirmations(TenancyLinkModel link) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('issues')
          .where('tenantId', isEqualTo: link.tenantId)
          .where('propertyId', isEqualTo: link.propertyId)
          .where('status', isEqualTo: 'pending_confirmation')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }
        final docs = snapshot.data!.docs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                    color: AppColors.info, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                'Fix${docs.length > 1 ? 'es' : ''} to Confirm (${docs.length})',
                style: AppTextStyles.labelLarge,
              ),
            ]),
            const SizedBox(height: 10),
            ...docs.map((doc) => _LinkedPendingConfirmationCard(
                  issueId: doc.id,
                  data: doc.data() as Map<String, dynamic>,
                )),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  /// Active issues card — shows open + in_progress issues for THIS property.
  /// Only visible while the tenancy link is confirmed/active.
  /// Scoped to propertyId so switching properties shows the right data.
  Widget _buildActiveIssuesCard(TenancyLinkModel link) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('issues')
          .where('tenantId', isEqualTo: link.tenantId)
          .where('propertyId', isEqualTo: link.propertyId)
          .where('status', whereIn: ['open', 'in_progress'])
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];

        return GestureDetector(
          onTap: () => context.push('/tenant/issue-history'),
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: docs.isNotEmpty
                    ? AppColors.warning.withAlpha(100)
                    : AppColors.border,
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: docs.isEmpty
                        ? AppColors.success.withAlpha(26)
                        : AppColors.warning.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    docs.isEmpty
                        ? Icons.check_circle_outline
                        : Icons.report_problem_outlined,
                    color: docs.isEmpty ? AppColors.success : AppColors.warning,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      docs.isEmpty ? 'No Active Issues' : 'Active Issues',
                      style: AppTextStyles.labelMedium,
                    ),
                    Text(
                      docs.isEmpty
                          ? 'All clear at this property'
                          : '${docs.length} issue${docs.length > 1 ? 's' : ''} open or in progress',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ]),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('History',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.primary)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_ios,
                      size: 12, color: AppColors.primary),
                ]),
              ]),

              // Issue rows — up to 3
              if (docs.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ...docs.take(3).map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final status = (d['status'] as String?) ?? 'open';
                  final category = (d['category'] as String?) ?? 'general';
                  final title = (d['title'] as String?)?.trim().isNotEmpty == true
                      ? d['title'] as String
                      : category;
                  final statusColor =
                      status == 'in_progress' ? AppColors.warning : AppColors.error;
                  final statusLabel =
                      status == 'in_progress' ? 'In Progress' : 'Open';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Container(
                        width: 6, height: 6,
                        margin: const EdgeInsets.only(right: 8, top: 1),
                        decoration: BoxDecoration(
                            color: statusColor, shape: BoxShape.circle),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          style: AppTextStyles.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(statusLabel,
                          style: AppTextStyles.caption.copyWith(
                              color: statusColor, fontWeight: FontWeight.w600)),
                    ]),
                  );
                }),
                if (docs.length > 3)
                  Text('+${docs.length - 3} more — tap to view all',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
              ],
            ]),
          ),
        );
      },
    );
  }

  // Shows a single bottom sheet with key tenancy info for linked tenants.
  // LeaseDetailsScreen requires ActiveRental (inspection-path only) so linked
  // tenants get a purpose-built summary sheet instead.
  void _showLinkedLeaseDetails(TenancyLinkModel link) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final nextDue = link.nextDueDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),

            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: AppColors.info.withAlpha(26), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.description_outlined, color: AppColors.info, size: 20),
              ),
              const SizedBox(width: 12),
              Text('Tenancy Details', style: AppTextStyles.h4),
            ]),
            const SizedBox(height: 24),

            _LeaseDetailRow(label: 'Property', value: link.propertyTitle),
            const SizedBox(height: 12),
            _LeaseDetailRow(label: 'Address', value: link.propertyAddress),
            const SizedBox(height: 12),
            _LeaseDetailRow(label: 'Landlord', value: link.landlordName),
            const SizedBox(height: 12),
            _LeaseDetailRow(
              label: 'Rent',
              value: '${link.formattedRentAmount} ${link.rentPeriodLabel}',
            ),
            const SizedBox(height: 12),
            _LeaseDetailRow(
              label: 'Next Due',
              value: '${months[nextDue.month - 1]} ${nextDue.day}, ${nextDue.year}',
            ),
            const SizedBox(height: 12),
            _LeaseDetailRow(
              label: 'Linked Since',
              value: link.acceptedAt != null
                  ? '${months[link.acceptedAt!.month - 1]} ${link.acceptedAt!.day}, ${link.acceptedAt!.year}'
                  : 'N/A',
            ),

            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.info.withAlpha(40)),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your tenancy was set up directly by your landlord through ClearRent.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary, height: 1.5),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

    // ── TIER 2: UNVERIFIED LINKED TENANT PROFILE ─────────────────────────────
  // Mini profile: edit info, verify, help — no saved/inspections/browse

  Widget _buildLinkedUnverifiedProfile() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(children: [
        // Header
        Container(
          width: double.infinity,
          color: AppColors.surface,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Profile', style: AppTextStyles.h3),
                  GestureDetector(
                    onTap: () => context.push('/settings'),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
                      child: Icon(Icons.settings_outlined, color: AppColors.textPrimary, size: 20),
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
                Row(children: [
                  UserAvatar(
                    name: _userName,
                    imageUrl: _profileImageUrl,
                    imageFile: _localProfileImage,
                    size: 72,
                    showEditBadge: !_isLoadingProfile && !_isUploadingImage,
                    onTap: _pickProfileImage,
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _isLoadingProfile
                        ? Container(width: 90, height: 20, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(4)))
                        : Text(_userName, style: AppTextStyles.h4),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withAlpha(26),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.link, size: 12, color: AppColors.warning),
                        const SizedBox(width: 4),
                        Text('Linked Tenant', style: AppTextStyles.labelSmall.copyWith(color: AppColors.warning)),
                      ]),
                    ),
                  ])),
                  GestureDetector(
                    onTap: () => context.push('/edit-profile'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(border: Border.all(color: AppColors.primary), borderRadius: BorderRadius.circular(8)),
                      child: Text('Edit', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),

        // Verification upgrade card
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: GestureDetector(
            onTap: () => context.push('/tenant/verification').then((_) => _loadVerificationStatus()),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.primary.withAlpha(60)),
              ),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), shape: BoxShape.circle),
                  child: Icon(Icons.verified_user_outlined, color: AppColors.primary, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Get Verified', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary)),
                  const SizedBox(height: 2),
                  Text('Pay ₦5,000 to unlock full platform access', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ])),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(8)),
                  child: Text('Start', style: AppTextStyles.labelSmall.copyWith(color: Colors.white)),
                ),
              ]),
            ),
          ),
        ),

        // Menu items
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _TenantProfileSection(title: 'My Account', items: [
              _TenantProfileMenuItem(
                icon: Icons.person_outline,
                title: 'Edit Profile',
                subtitle: 'Update your name and photo',
                onTap: () => context.push('/edit-profile'),
              ),
              _TenantProfileMenuItem(
                icon: Icons.payment_outlined,
                title: 'Payment History',
                subtitle: 'View your payment records',
                onTap: () => context.push('/tenant/payment-history'),
              ),
            ]),
            const SizedBox(height: 20),
            _TenantProfileSection(title: 'Support', items: [
              _TenantProfileMenuItem(icon: Icons.help_outline, title: 'Help & Support', subtitle: 'FAQs and contact us', onTap: () => context.push('/help-support')),
              _TenantProfileMenuItem(icon: Icons.info_outline, title: 'About ClearRent', subtitle: 'Version 1.0.0', onTap: () => context.push('/about')),
            ]),
            const SizedBox(height: 32),
            Center(child: Column(children: [
              Text('ClearRent', style: AppTextStyles.labelLarge.copyWith(color: AppColors.textHint)),
              const SizedBox(height: 4),
              Text('Rent Without Regret', style: AppTextStyles.caption.copyWith(color: AppColors.textHint, fontStyle: FontStyle.italic)),
            ])),
            const SizedBox(height: 20),
          ]),
        ),
      ]),
    );
  }

  // ── SHARED APP BAR (reused across linked dashboard variants) ─────────────

  SliverAppBar _buildLinkedAppBar({required String title, required String subtitle}) {
    return SliverAppBar(
      expandedHeight: 0,
      floating: true,
      backgroundColor: AppColors.surface,
      elevation: 0,
      automaticallyImplyLeading: false,
      title: Row(children: [
        GestureDetector(
          onTap: _pickProfileImage,
          child: Stack(children: [
            UserAvatar(imageUrl: _profileImageUrl, imageFile: _localProfileImage, name: _userName, size: 36),
            if (_isUploadingImage)
              Positioned.fill(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: AppTextStyles.labelLarge),
            Text(subtitle, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          ],
        )),
        VerificationBadge(status: _verificationStatus),
      ]),
    );
  }

    // ── SHARED LINKED TENANT WIDGETS ──────────────────────────────────────────

  Widget _buildRentDueCard(TenancyLinkModel link, int daysLeft, bool isUrgent, bool isDue) {
    // Use live rent from property if available, fall back to snapshotted value in link
    final rentAmount = _livePropertyRent ?? link.rentAmount;
    final rentFrequency = _livePropertyRentFrequency ?? link.rentFrequency;

    String formattedRent;
    if (rentAmount >= 1000000) {
      formattedRent = '₦${(rentAmount / 1000000).toStringAsFixed(1)}M';
    } else if (rentAmount >= 1000) {
      formattedRent = '₦${(rentAmount / 1000).toStringAsFixed(0)}K';
    } else {
      formattedRent = '₦${rentAmount.toStringAsFixed(0)}';
    }
    final periodLabel = rentFrequency == 'yearly' ? 'per year' : 'per month';
    final Color cardColor;
    const Color textColor = Colors.white;
    final String dueLabel;
    final IconData dueIcon;

    if (isDue) {
      cardColor = AppColors.error;
      dueLabel = 'Rent is due TODAY';
      dueIcon = Icons.warning_rounded;
    } else if (isUrgent) {
      cardColor = AppColors.warning;
      dueLabel = 'Due in $daysLeft day${daysLeft != 1 ? 's' : ''}';
      dueIcon = Icons.schedule;
    } else {
      cardColor = AppColors.primary;
      dueLabel = 'Due in $daysLeft days';
      dueIcon = Icons.calendar_today_outlined;
    }

    final nextDue = link.nextDueDate;
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(dueIcon, color: textColor.withAlpha(200), size: 18),
          const SizedBox(width: 6),
          Text(dueLabel, style: AppTextStyles.labelMedium.copyWith(color: textColor.withAlpha(200))),
        ]),
        const SizedBox(height: 8),
        Text(formattedRent, style: AppTextStyles.h2.copyWith(color: textColor)),
        const SizedBox(height: 2),
        Text(
          '$periodLabel  •  due ${_ordinal(link.rentDueDay)} of each month',
          style: AppTextStyles.caption.copyWith(color: textColor.withAlpha(180)),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.white.withAlpha(30), borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.event, size: 16, color: textColor),
            const SizedBox(width: 6),
            Text(
              'Next: ${months[nextDue.month - 1]} ${nextDue.day}, ${nextDue.year}',
              style: AppTextStyles.labelMedium.copyWith(color: textColor),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildLinkedPropertyCard(TenancyLinkModel link) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.home_outlined, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(link.propertyTitle, style: AppTextStyles.labelLarge),
            const SizedBox(height: 2),
            Text(link.propertyAddress, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
          ])),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: AppColors.success.withAlpha(20), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.verified_outlined, size: 14, color: AppColors.success),
            const SizedBox(width: 5),
            Text('Verified Tenancy', style: AppTextStyles.caption.copyWith(color: AppColors.success, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildLandlordContactCard(TenancyLinkModel link, {bool canMessage = true}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Your Landlord', style: AppTextStyles.labelLarge),
        const SizedBox(height: 12),
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), shape: BoxShape.circle),
            child: Center(child: Text(
              link.landlordName.isNotEmpty ? link.landlordName[0].toUpperCase() : 'L',
              style: AppTextStyles.h4.copyWith(color: AppColors.primary),
            )),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(link.landlordName, style: AppTextStyles.labelMedium),
            if (link.landlordPhone.isNotEmpty)
              Text(link.landlordPhone, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          ])),
          if (link.landlordPhone.isNotEmpty) ...[
            GestureDetector(
              onTap: () => _callLandlord(link.landlordPhone),
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: AppColors.success.withAlpha(20), shape: BoxShape.circle),
                child: Icon(Icons.phone_outlined, size: 20, color: AppColors.success),
              ),
            ),
            if (canMessage) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _openLandlordChat(link),
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), shape: BoxShape.circle),
                  child: Icon(Icons.chat_outlined, size: 20, color: AppColors.primary),
                ),
              ),
            ],
          ],
        ]),
        if (!canMessage && link.landlordPhone.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.lock_outline, size: 13, color: AppColors.textHint),
            const SizedBox(width: 5),
            Text('In-app messaging unlocks after verification', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
          ]),
        ],
      ]),
    );
  }

    // ── PENDING LINK REQUESTS ─────────────────────────────────────────────────

  Widget _buildPendingLinksSection(List<TenancyLinkModel> links) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: AppColors.warning, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('Link Request${links.length > 1 ? 's' : ''} (${links.length})', style: AppTextStyles.labelLarge),
        ]),
        const SizedBox(height: 10),
        ...links.map((link) => _buildPendingLinkCard(link)),
      ],
    );
  }

  Widget _buildPendingLinkCard(TenancyLinkModel link) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withAlpha(80)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: AppColors.warning.withAlpha(20), shape: BoxShape.circle),
            child: Center(child: Text(
              link.landlordName.isNotEmpty ? link.landlordName[0].toUpperCase() : 'L',
              style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning),
            )),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(link.landlordName, style: AppTextStyles.labelMedium),
            Text('wants to link you to their property', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          ])),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(link.propertyTitle, style: AppTextStyles.labelMedium),
            const SizedBox(height: 2),
            Text(link.propertyAddress, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            Row(children: [
              Text(_livePropertyRent != null ? (_livePropertyRent! >= 1000000 ? '₦${(_livePropertyRent! / 1000000).toStringAsFixed(1)}M' : _livePropertyRent! >= 1000 ? '₦${(_livePropertyRent! / 1000).toStringAsFixed(0)}K' : '₦${_livePropertyRent!.toStringAsFixed(0)}') : link.formattedRentAmount, style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
              Text('  ${_livePropertyRentFrequency != null ? (_livePropertyRentFrequency == 'yearly' ? 'per year' : 'per month') : link.rentPeriodLabel}', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              const Spacer(),
              Icon(Icons.calendar_today_outlined, size: 13, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text('Due ${_ordinal(link.rentDueDay)} each month', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _rejectLink(link),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('Decline', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: () => _acceptLink(link),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('Accept', style: AppTextStyles.labelMedium),
            ),
          ),
        ]),
      ]),
    );
  }

  // ── HOME TAB (unlinked browse mode) ───────────────────────────────────────

  Widget _buildHomeTab(List<TenancyLinkModel> pendingLinks) {
    return RefreshIndicator(
      onRefresh: _refreshData,
      color: AppColors.primary,
      child: Column(children: [
        _buildHeader(),
        // Announcements banner
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: AnnouncementsBanner(
            userId: _authService.currentUserId ?? '',
            accountType: 'tenant',
            notificationsRoute: '/notifications',
          ),
        ),
        // Back to dashboard banner when browsing from rental dashboard
        if (_browsingFromDashboard && _activeRental != null)
          GestureDetector(
            onTap: () => setState(() => _browsingFromDashboard = false),
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withAlpha(60)),
              ),
              child: Row(children: [
                Icon(Icons.arrow_back, size: 16, color: AppColors.success),
                const SizedBox(width: 8),
                Text('Back to my rental dashboard', style: AppTextStyles.labelMedium.copyWith(color: AppColors.success)),
              ]),
            ),
          ),
        // Back to tenancy banner when linked tenant is browsing
        if (_browsingFromLinkedDashboard)
          GestureDetector(
            onTap: () => setState(() => _browsingFromLinkedDashboard = false),
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withAlpha(60)),
              ),
              child: Row(children: [
                Icon(Icons.arrow_back, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Text('Back to my tenancy', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
              ]),
            ),
          ),
        // Pending link requests banner — replaces the old route-based banner
        if (pendingLinks.isNotEmpty)
          _buildPendingLinksBanner(pendingLinks),
        if (_verificationStatus != VerificationStatus.verified)
          _buildVerificationPrompt(),
        if (!_hasBankDetails && !_isLoadingProfile && _verificationStatus == VerificationStatus.verified)
          _buildBankDetailsBanner(),
        _buildSearchBar(),
        _buildFilters(),
        Expanded(
          child: _isLoadingProperties
              ? Center(child: CircularProgressIndicator(color: AppColors.primary))
              : _filteredProperties.isEmpty
                  ? _buildEmptyState()
                  : _buildPropertyList(),
        ),
      ]),
    );
  }

  /// Compact banner shown above property list when there are pending link requests
  Widget _buildPendingLinksBanner(List<TenancyLinkModel> links) {
    final count = links.length;
    return GestureDetector(
      onTap: () => context.push('/tenant/tenancy-requests'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(13),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(77)),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), shape: BoxShape.circle),
            child: Icon(Icons.home_outlined, size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '$count tenancy request${count > 1 ? 's' : ''} pending',
              style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
            ),
            const SizedBox(height: 2),
            Text(
              'A landlord wants to link you to their property',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ])),
          Icon(Icons.chevron_right, color: AppColors.primary, size: 20),
        ]),
      ),
    );
  }

  Widget _buildVerificationPrompt() {
    String title = '';
    String subtitle = '';
    IconData icon = Icons.verified_user_outlined;
    Color color = AppColors.primary;
    Color bgColor = AppColors.primaryLight.withAlpha(26);
    switch (_verificationStatus) {
      case VerificationStatus.none:
        title = 'Get Verified';
        subtitle = 'Verified tenants are preferred by landlords';
        icon = Icons.verified_user_outlined;
        color = AppColors.primary;
        bgColor = AppColors.primaryLight.withAlpha(26);
        break;
      case VerificationStatus.pending:
        title = 'Verification Pending';
        subtitle = 'We\'re reviewing your documents';
        icon = Icons.schedule;
        color = AppColors.warning;
        bgColor = AppColors.warningLight;
        break;
      case VerificationStatus.rejected:
        title = 'Verification Failed';
        subtitle = 'Tap to see why and try again';
        icon = Icons.error_outline;
        color = AppColors.error;
        bgColor = AppColors.error.withAlpha(26);
        break;
      case VerificationStatus.verified:
        return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => context.push('/tenant/verification').then((_) => _loadVerificationStatus()),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withAlpha(77))),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: color.withAlpha(26), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppTextStyles.labelLarge.copyWith(color: color)),
            const SizedBox(height: 2),
            Text(subtitle, style: AppTextStyles.bodySmall.copyWith(color: color.withAlpha(204))),
          ])),
          Icon(Icons.chevron_right, color: color),
        ]),
      ),
    );
  }

  Widget _buildBankDetailsBanner() {
    return GestureDetector(
      onTap: () => context.push('/tenant/bank-details').then((_) => _loadUserProfile()),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.warning.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.warning.withAlpha(77)),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(26),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.account_balance_wallet_outlined, color: AppColors.warning, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Add Bank Details', style: AppTextStyles.labelLarge.copyWith(color: AppColors.warning)),
            const SizedBox(height: 2),
            Text('Required for receiving refunds and deposits',
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.warning.withAlpha(204))),
          ])),
          Icon(Icons.chevron_right, color: AppColors.warning),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _isLoadingProfile
              ? Container(width: 120, height: 16, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(4)))
              : Text('Hello, $_firstName ', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(
            _activeRental != null ? 'Browse more properties' : 'Find your perfect space',
            style: AppTextStyles.h3,
          ),
        ])),
        NotificationBell(userId: _authService.currentUserId ?? ''),
      ]),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Container(
        height: 52,
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: TextField(
          controller: _searchController,
          onChanged: (_) => _filterProperties(),
          decoration: InputDecoration(
            hintText: AppStrings.searchProperties,
            hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
            prefixIcon: Icon(Icons.search, color: AppColors.textHint),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(icon: Icon(Icons.clear, color: AppColors.textHint), onPressed: () { _searchController.clear(); _filterProperties(); })
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Column(children: [
      SizedBox(
        height: 40,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: propertyTypes.length,
          itemBuilder: (context, index) {
            final type = propertyTypes[index];
            final isSelected = _selectedType == type['value'];
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(type['label']!),
                selected: isSelected,
                onSelected: (_) { setState(() => _selectedType = type['value']!); _filterProperties(); },
                backgroundColor: AppColors.surface,
                selectedColor: AppColors.primary.withAlpha(26),
                checkmarkColor: AppColors.primary,
                labelStyle: AppTextStyles.labelMedium.copyWith(color: isSelected ? AppColors.primary : AppColors.textSecondary),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border)),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
              child: DropdownButton<String>(
                underline: const SizedBox.shrink(),
                value: _selectedArea,
                isExpanded: true,
                icon: const Icon(Icons.keyboard_arrow_down),
                style: AppTextStyles.bodyMedium,
                items: lagosAreas.map((area) => DropdownMenuItem(value: area, child: Text(area))).toList(),
                onChanged: (value) { if (value != null) { setState(() => _selectedArea = value); _filterProperties(); } },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            height: 44, width: 44,
            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.tune, color: Colors.white, size: 20),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          Text('${_filteredProperties.length} properties found', style: AppTextStyles.bodySmall),
          if (_realProperties.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppColors.success.withAlpha(26), borderRadius: BorderRadius.circular(10)),
              child: Text('${_realProperties.length} verified', style: AppTextStyles.caption.copyWith(color: AppColors.success)),
            ),
          ],
          const Spacer(),
          Text('Sort by: ', style: AppTextStyles.bodySmall),
          Text('Newest', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
          Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.primary),
        ]),
      ),
      const SizedBox(height: 12),
    ]);
  }

  Widget _buildPropertyList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: _filteredProperties.length,
      itemBuilder: (context, index) {
        final property = _filteredProperties[index];
        final isReal = _realProperties.any((p) => p.id == property.id);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Stack(children: [
            PropertyCard(
              property: property,
              isSaved: _savedProperties.contains(property.id),
              onTap: () => _openPropertyDetail(property),
              onSave: () => _toggleSave(property.id),
            ),
            if (isReal)
              Positioned(
                top: 12, left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.success, borderRadius: BorderRadius.circular(6)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.verified, size: 12, color: Colors.white),
                    const SizedBox(width: 4),
                    Text('Verified', style: AppTextStyles.labelSmall.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.search_off, size: 64, color: AppColors.textHint),
      const SizedBox(height: 16),
      Text(AppStrings.noProperties, style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary)),
      const SizedBox(height: 8),
      Text('Try adjusting your filters', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint)),
    ]));
  }

  // ── SAVED TAB ─────────────────────────────────────────────────────────────

  Widget _buildSavedTab() {
    final allPropsMap = {for (var p in _allProperties) p.id: p};
    final savedList = _savedProperties.where((id) => allPropsMap.containsKey(id)).map((id) => allPropsMap[id]!).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Text('Saved Properties', style: AppTextStyles.h2),
          const Spacer(),
          if (!_isLoadingSaved && savedList.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), borderRadius: BorderRadius.circular(12)),
              child: Text('${savedList.length}', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
            ),
        ]),
      ),
      Expanded(
        child: _isLoadingSaved
            ? Center(child: CircularProgressIndicator(color: AppColors.primary))
            : savedList.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: AppColors.error.withAlpha(26), shape: BoxShape.circle),
                        child: Icon(Icons.favorite_outline, size: 48, color: AppColors.error)),
                    const SizedBox(height: 20),
                    Text('No saved properties yet', style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary)),
                    const SizedBox(height: 8),
                    Text('Tap the heart icon on any property\nto save it for later',
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint), textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: () => setState(() => _currentNavIndex = 0),
                      icon: const Icon(Icons.search),
                      label: const Text('Browse Properties'),
                      style: TextButton.styleFrom(foregroundColor: AppColors.primary),
                    ),
                  ]))
                : RefreshIndicator(
                    onRefresh: _loadSavedProperties,
                    color: AppColors.primary,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      itemCount: savedList.length,
                      itemBuilder: (context, index) {
                        final property = savedList[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: PropertyCard(
                            property: property, isSaved: true,
                            onTap: () => _openPropertyDetail(property),
                            onSave: () => _toggleSave(property.id),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    ]);
  }

  // ── MESSAGES TAB ──────────────────────────────────────────────────────────

  Widget _buildMessagesTab() {
    return const MessagesTabReal(
      emptyTitle: 'No messages yet',
      emptySubtitle: 'Your conversations with landlords\nwill appear here',
    );
  }

  // ── PROFILE TAB ───────────────────────────────────────────────────────────

  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(children: [
        Container(
          width: double.infinity,
          color: AppColors.surface,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Profile', style: AppTextStyles.h3),
                  GestureDetector(
                    onTap: () => context.push('/settings'),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
                      child: Icon(Icons.settings_outlined, color: AppColors.textPrimary, size: 20),
                    ),
                  ),
                ]),
                const SizedBox(height: 30),
                Row(children: [
                  UserAvatar(
                    name: _userName,
                    imageUrl: _profileImageUrl,
                    imageFile: _localProfileImage,
                    size: 80,
                    showEditBadge: !_isLoadingProfile && !_isUploadingImage,
                    onTap: _pickProfileImage,
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _isLoadingProfile
                        ? Container(width: 100, height: 24, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(4)))
                        : Text(_userName, style: AppTextStyles.h3),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), borderRadius: BorderRadius.circular(6)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.person, size: 14, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text('Tenant', style: AppTextStyles.labelSmall.copyWith(color: AppColors.primary)),
                      ]),
                    ),
                  ])),
                  GestureDetector(
                    onTap: () => context.push('/edit-profile'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(border: Border.all(color: AppColors.primary), borderRadius: BorderRadius.circular(8)),
                      child: Text('Edit', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Expanded(child: _TenantStatCard(icon: Icons.favorite_outline, value: _isLoadingSaved ? '...' : '${_savedProperties.length}', label: 'Saved', color: AppColors.error)),
            const SizedBox(width: 12),
            Expanded(child: _TenantStatCard(icon: Icons.home_outlined, value: _activeRental != null ? '1' : '0', label: 'Rentals', color: AppColors.primary)),
            const SizedBox(width: 12),
            Expanded(child: _TenantStatCard(icon: Icons.chat_bubble_outline, value: '$_unreadCount', label: 'Unread', color: AppColors.info)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _TenantProfileSection(title: 'Activity', items: [
              _TenantProfileMenuItem(icon: Icons.event_note_outlined, title: 'My Inspections', subtitle: 'Track your inspection requests', onTap: () => context.push('/tenant/inspections')),
              _TenantProfileMenuItem(icon: Icons.report_problem_outlined, title: 'My Issues', subtitle: 'Issues you\'ve reported across all properties', onTap: () => context.push('/tenant/issue-history')),
              _TenantProfileMenuItem(icon: Icons.favorite_outline, title: 'Saved Properties', subtitle: '${_savedProperties.length} properties saved', onTap: () => setState(() => _currentNavIndex = 1)),
              _TenantProfileMenuItem(icon: Icons.verified_user_outlined, title: 'Verification', subtitle: 'Verify your identity', onTap: () => context.push('/tenant/verification')),
              _TenantProfileMenuItem(icon: Icons.history, title: 'My Rentals', subtitle: 'View your rental history', onTap: () => context.push('/tenant/my-rentals')),
              _TenantProfileMenuItem(icon: Icons.payment_outlined, title: 'Payment History', subtitle: 'View all your payments', onTap: () => context.push('/tenant/payment-history')),
              _TenantProfileMenuItem(icon: Icons.description_outlined, title: 'Documents', subtitle: 'Rental agreements and receipts', onTap: () => context.push('/tenant/documents')),
            ]),
            const SizedBox(height: 20),
            _TenantProfileSection(title: 'Support', items: [
              _TenantProfileMenuItem(icon: Icons.help_outline, title: 'Help & Support', subtitle: 'FAQs and contact us', onTap: () => context.push('/help-support')),
              _TenantProfileMenuItem(icon: Icons.info_outline, title: 'About ClearRent', subtitle: 'Version 1.0.0', onTap: () => context.push('/about')),
            ]),
            const SizedBox(height: 32),
            Center(child: Column(children: [
              Text('ClearRent', style: AppTextStyles.labelLarge.copyWith(color: AppColors.textHint)),
              const SizedBox(height: 4),
              Text('Rent Without Regret', style: AppTextStyles.caption.copyWith(color: AppColors.textHint, fontStyle: FontStyle.italic)),
            ])),
            const SizedBox(height: 20),
          ]),
        ),
      ]),
    );
  }

  // ── BOTTOM NAV ────────────────────────────────────────────────────────────

  Widget _buildBottomNav(bool isLinkedUnverified, bool isLinkedVerified) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(13), blurRadius: 10, offset: const Offset(0, -5))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            // ── Unverified linked: Home + Profile only
            if (isLinkedUnverified) ...[
              _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home',
                  isActive: _currentNavIndex == 0, onTap: () => setState(() => _currentNavIndex = 0)),
              _NavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profile',
                  isActive: _currentNavIndex == 1, onTap: () => setState(() => _currentNavIndex = 1)),
            ]
            // ── Verified linked or unlinked: full 4 tabs
            else ...[
              _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home',
                  isActive: _currentNavIndex == 0, onTap: () => setState(() => _currentNavIndex = 0)),
              _NavItem(
                icon: Icons.favorite_outline, activeIcon: Icons.favorite, label: 'Saved',
                isActive: _currentNavIndex == 1, onTap: () => setState(() => _currentNavIndex = 1),
                badge: _savedProperties.isNotEmpty ? '${_savedProperties.length}' : null,
              ),
              _NavItem(
                icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble, label: 'Messages',
                isActive: _currentNavIndex == 2,
                onTap: () { setState(() { _currentNavIndex = 2; _loadUnreadCount(); }); },
                badge: _unreadCount > 0 ? '$_unreadCount' : null,
              ),
              _NavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profile',
                  isActive: _currentNavIndex == 3, onTap: () => setState(() => _currentNavIndex = 3)),
            ],
          ]),
        ),
      ),
    );
  }

  // ── LINK ACTIONS ──────────────────────────────────────────────────────────

  Future<void> _acceptLink(TenancyLinkModel link) async {
    final success = await _tenancyLinkService.acceptLink(link.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success ? 'You\'re now linked to ${link.propertyTitle}!' : 'Failed to accept. Please try again.'),
        backgroundColor: success ? AppColors.success : AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Future<void> _rejectLink(TenancyLinkModel link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Decline Request'),
        content: Text('Decline the link request from ${link.landlordName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Decline', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (confirmed == true) await _tenancyLinkService.rejectLink(link.id);
  }

  /// Opens or creates a direct conversation between the linked tenant and their landlord.
  Future<void> _openLandlordChat(TenancyLinkModel link) async {
    if (link.landlordId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Landlord information not available'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    // Show loading indicator
    final scaffold = ScaffoldMessenger.of(context);
    setState(() {}); // trigger any loading state if needed

    try {
      // Fetch fresh landlord name from Firestore so display is always correct
      String landlordName = link.landlordName;
      String tenantName = _userName.isNotEmpty ? _userName : 'Tenant';
      try {
        final landlordDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(link.landlordId)
            .get();
        if (landlordDoc.exists) {
          landlordName = landlordDoc.data()?['fullName'] ?? link.landlordName;
        }
      } catch (_) {} // fallback to link value on network error

      final conv = await _conversationService.getOrCreateConversation(
        propertyId: link.propertyId,
        propertyTitle: link.propertyTitle,
        propertyImage: '',
        landlordId: link.landlordId,
        landlordName: landlordName,
        tenantId: link.tenantId,
        tenantName: tenantName,
      );

      if (!mounted) return;

      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': link.propertyTitle,
          'propertyImage': null,
        });
      } else {
        scaffold.showSnackBar(SnackBar(
          content: const Text('Could not open chat. Both parties must be verified.'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      debugPrint('❌ Error opening landlord chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to open chat. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  Future<void> _callLandlord(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  // ── HELPERS ───────────────────────────────────────────────────────────────

  String _ordinal(int n) {
    if (n >= 11 && n <= 13) return '${n}th';
    switch (n % 10) {
      case 1: return '${n}st';
      case 2: return '${n}nd';
      case 3: return '${n}rd';
      default: return '${n}th';
    }
  }
}

// ── SHARED WIDGETS ────────────────────────────────────────────────────────────

// ── Helper data class for access feature list ────────────────────────────────

class _LinkedActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _LinkedActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ]),
      ),
    );
  }
}

class _AccessFeature {
  final String label;
  final IconData icon;
  const _AccessFeature(this.label, this.icon);
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final String? badge;

  const _NavItem({
    required this.icon, required this.activeIcon, required this.label,
    required this.isActive, required this.onTap, this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(clipBehavior: Clip.none, children: [
            Icon(isActive ? activeIcon : icon, color: isActive ? AppColors.primary : AppColors.textHint, size: 24),
            if (badge != null)
              Positioned(right: -8, top: -4, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              )),
          ]),
          const SizedBox(height: 4),
          Text(label, style: AppTextStyles.labelSmall.copyWith(
            color: isActive ? AppColors.primary : AppColors.textHint,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          )),
        ]),
      ),
    );
  }
}

class _TenantStatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _TenantStatCard({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: Column(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withAlpha(26), shape: BoxShape.circle), child: Icon(icon, color: color, size: 20)),
        const SizedBox(height: 8),
        Text(value, style: AppTextStyles.h4),
        const SizedBox(height: 2),
        Text(label, style: AppTextStyles.caption),
      ]),
    );
  }
}

class _TenantProfileSection extends StatelessWidget {
  final String title;
  final List<Widget> items;

  const _TenantProfileSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(left: 4, bottom: 10), child: Text(title, style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary))),
      Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: Column(
          children: items.asMap().entries.map((entry) {
            return Column(children: [entry.value, if (entry.key < items.length - 1) const Divider(height: 1, indent: 52)]);
          }).toList(),
        ),
      ),
    ]);
  }
}

class _TenantProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _TenantProfileMenuItem({required this.icon, required this.title, this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Container(width: 36, height: 36, decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: AppColors.textSecondary, size: 20)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppTextStyles.labelLarge),
            if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppTextStyles.caption)],
          ])),
          Icon(Icons.chevron_right, color: AppColors.textHint, size: 20),
        ]),
      ),
    );
  }
}

// Simple label/value row used in the linked lease details bottom sheet
class _LeaseDetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _LeaseDetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: AppTextStyles.labelMedium,
          ),
        ),
      ],
    );
  }
}
/// Confirmation card for linked tenants — identical accountability loop
/// to the inspection-path version in tenant_rental_dashboard.dart
class _LinkedPendingConfirmationCard extends StatefulWidget {
  final String issueId;
  final Map<String, dynamic> data;

  const _LinkedPendingConfirmationCard({
    required this.issueId,
    required this.data,
  });

  @override
  State<_LinkedPendingConfirmationCard> createState() =>
      _LinkedPendingConfirmationCardState();
}

class _LinkedPendingConfirmationCardState
    extends State<_LinkedPendingConfirmationCard> {
  bool _isActing = false;

  String get _title => widget.data['title'] ?? 'Issue';
  String get _category => widget.data['category'] ?? 'other';

  Future<void> _confirm() async {
    setState(() => _isActing = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
        'tenantConfirmedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
        await FirebaseFirestore.instance.collection('activities').add({
          'landlordId': landlordId,
          'type': 'issue_confirmed',
          'title': 'Fix Confirmed ✓',
          'message':
              '${widget.data['tenantName'] ?? 'Your tenant'} confirmed the $_category issue has been resolved.',
          'propertyId': widget.data['propertyId'],
          'issueId': widget.issueId,
          'actorId': widget.data['tenantId'],
          'actorName': widget.data['tenantName'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('❌ Error confirming fix: $e');
      if (mounted) setState(() => _isActing = false);
    }
  }

  Future<void> _dispute() async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('What\'s still wrong?'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Describe what hasn\'t been fixed yet...',
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(ctx, reasonController.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Submit Dispute',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) return;
    setState(() => _isActing = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': 'in_progress',
        'disputeReason': reason,
        'disputedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
        await FirebaseFirestore.instance.collection('activities').add({
          'landlordId': landlordId,
          'type': 'issue_disputed',
          'title': 'Fix Disputed',
          'message':
              '${widget.data['tenantName'] ?? 'Your tenant'} says the $_category issue is not fully resolved: "$reason"',
          'propertyId': widget.data['propertyId'],
          'issueId': widget.issueId,
          'actorId': widget.data['tenantId'],
          'actorName': widget.data['tenantName'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('❌ Error disputing fix: $e');
      if (mounted) setState(() => _isActing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.info.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.build_outlined,
                  size: 16, color: AppColors.info),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title,
                    style: AppTextStyles.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text('Your landlord says this is fixed',
                    style:
                        AppTextStyles.caption.copyWith(color: AppColors.info)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isActing ? null : _dispute,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text('Still Broken',
                    style: TextStyle(color: AppColors.error, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _isActing ? null : _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _isActing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Confirmed Fixed',
                        style: TextStyle(fontSize: 13)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}