import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/inspection_service.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../chat/presentation/widgets/messages_tab.dart';
import '../widgets/agent_assigned_properties_tab.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../../../../shared/widgets/user_avatar.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/widgets/announcements_banner.dart';
import 'agent_discover_properties_screen.dart';

class AgentHomeScreen extends StatefulWidget {
  const AgentHomeScreen({super.key});

  @override
  State<AgentHomeScreen> createState() => _AgentHomeScreenState();
}

class _AgentHomeScreenState extends State<AgentHomeScreen> {
  final AuthService _authService = AuthService();
  final VerificationService _verificationService = VerificationService();
  final InspectionService _inspectionService = InspectionService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Map<String, dynamic>? _userProfile;
  bool _isLoading = true;
  VerificationData? _verificationData;
  bool _verifLoading = true;

  // Live stream subscriptions
  StreamSubscription? _profileSubscription;
  StreamSubscription? _unreadCountSubscription;

  // Bottom nav
  int _currentNavIndex = 0;
  DateTime? _lastBackPressed;

  String? _profileImageUrl;
  File? _localProfileImage;
  bool _isUploadingImage = false;

  // Unread count
  int _unreadCount = 0;

  // Assigned properties count
  int _assignedPropertiesCount = 0;

  @override
  void initState() {
    super.initState();
    _startProfileStream();
    _loadVerificationData();
    _startUnreadCountStream();
    _loadAssignedPropertiesCount();
  }

  void _startProfileStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      setState(() => _isLoading = false);
      return;
    }
    _profileSubscription = _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data()!;
      setState(() {
        _userProfile = data;
        _profileImageUrl = data['profileImageUrl'];
        _isLoading = false;
      });
    }, onError: (e) {
      debugPrint('❌ Profile stream error: $e');
      if (mounted) setState(() => _isLoading = false);
    });
  }

  void _startUnreadCountStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    _unreadCountSubscription = _firestore
        .collection('conversations')
        .where('participants', arrayContains: uid)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      int total = 0;
      for (final doc in snapshot.docs) {
        final counts = doc.data()['unreadCounts'] as Map<String, dynamic>? ?? {};
        total += (counts[uid] as num? ?? 0).toInt();
      }
      setState(() => _unreadCount = total);
    }, onError: (e) {
      debugPrint('❌ Unread count stream error: $e');
    });
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _unreadCountSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadVerificationData() async {
    setState(() => _verifLoading = true);
    final data = await _verificationService.getVerificationStatus();
    if (mounted) {
      setState(() {
        _verificationData = data;
        _verifLoading = false;
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
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
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
                  const SizedBox(height: 20),
                  Text('Profile Photo', style: AppTextStyles.h4),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildImageSourceOption(
                        icon: Icons.camera_alt_rounded,
                        label: 'Camera',
                        onTap: () => Navigator.pop(ctx, ImageSource.camera),
                      ),
                      _buildImageSourceOption(
                        icon: Icons.photo_library_rounded,
                        label: 'Gallery',
                        onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                      ),
                      if (_profileImageUrl != null)
                        _buildImageSourceOption(
                          icon: Icons.delete_outline,
                          label: 'Remove',
                          onTap: () => Navigator.pop(ctx, null),
                          color: AppColors.error,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
    );

    if (source == null && _profileImageUrl != null) {
      setState(() => _isUploadingImage = true);
      final removed = await _authService.removeProfileImage();
      if (mounted && removed) {
        setState(() {
          _profileImageUrl = null;
          _localProfileImage = null;
          _isUploadingImage = false;
        });
      } else {
        setState(() => _isUploadingImage = false);
      }
      return;
    }

    if (source == null) return;

    try {
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;

      final file = File(image.path);
      setState(() {
        _localProfileImage = file;
        _isUploadingImage = true;
      });

      final url = await _authService.uploadProfileImage(file);
      if (mounted) {
        setState(() {
          if (url != null) {
            _profileImageUrl = url;
            _localProfileImage = null;
          }
          _isUploadingImage = false;
        });
        if (url != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Profile photo updated!'),
              backgroundColor: AppColors.success,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error picking profile image: $e');
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  // Named differently to avoid conflict with existing _buildActionButton
  Widget _buildImageSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: (color ?? AppColors.primary).withAlpha(26),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color ?? AppColors.primary, size: 32),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: AppTextStyles.labelMedium.copyWith(
              color: color ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAssignedPropertiesCount() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      final snapshot =
          await _firestore
              .collection('properties')
              .where('assignedAgentId', isEqualTo: userId)
              .count()
              .get();

      if (mounted) {
        setState(() {
          _assignedPropertiesCount = snapshot.count ?? 0;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading assigned properties count: $e');
    }
  }

  bool get _isVerified =>
      (_verificationData?.status == VerificationStatus.verified) ||
      (_userProfile?['isVerified'] == true);
  String get _accountType => _userProfile?['accountType'] ?? 'agent';
  String get _userName => _userProfile?['fullName'] ?? 'Agent';
  String get _baseLocation => _userProfile?['baseLocation'] ?? 'Not set';
  bool get _hasBankDetails {
    final bankDetails = _userProfile?['bankDetails'] as Map<String, dynamic>?;
    return bankDetails != null &&
        (bankDetails['bankName'] ?? '').toString().isNotEmpty &&
        (bankDetails['accountNumber'] ?? '').toString().isNotEmpty;
  }
  List<String> get _serviceAreas =>
      List<String>.from(_userProfile?['serviceAreas'] ?? []);
  double get _rating => (_userProfile?['rating'] ?? 0.0).toDouble();
  int get _totalInspections => _userProfile?['totalInspections'] ?? 0;

  Future<bool> _onWillPop() async {
    if (_currentNavIndex != 0) {
      setState(() => _currentNavIndex = 0);
      return false;
    }
    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Press back again to exit'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body:
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _currentNavIndex == 0
                ? SafeArea(child: _buildHomeTab())
                : _currentNavIndex == 1
                ? const SafeArea(child: AgentDiscoverPropertiesScreen())
                : _currentNavIndex == 2
                ? SafeArea(child: _buildPropertiesTab())
                : _currentNavIndex == 3
                ? SafeArea(child: _buildMessagesTab())
                : _buildProfileTab(),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  // ============ HOME TAB ============
  Widget _buildHomeTab() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader()),
        if (!_isVerified || _accountType != 'agent')
          SliverToBoxAdapter(child: _buildVerificationBanner()),
        if (!_hasBankDetails && !_isLoading && _isVerified)
          SliverToBoxAdapter(child: _buildBankDetailsBanner()),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: AnnouncementsBanner(
              userId: _auth.currentUser?.uid ?? '',
              accountType: 'agent',
              notificationsRoute: '/agent/activities',
            ),
          ),
        ),
        SliverToBoxAdapter(child: _buildStatsSection()),
        SliverToBoxAdapter(child: _buildTodaysInspectionsSection()),
        SliverToBoxAdapter(child: _buildPaymentConfirmationSection()),
        SliverToBoxAdapter(child: _buildQuickActions()),
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            'Assigned Properties',
            onSeeAll: () => setState(() => _currentNavIndex = 2),
          ),
        ),
        SliverToBoxAdapter(child: _buildAssignedPropertiesSection()),
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            'Inspection Requests',
            onSeeAll: () => context.push('/agent/inspections'),
          ),
        ),
        SliverToBoxAdapter(child: _buildInspectionRequestsSection()),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          UserAvatar(
            name: _userName,
            imageUrl: _profileImageUrl,
            imageFile: _localProfileImage,
            size: 50,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome back,',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _userName.split(' ').first,
                        style: AppTextStyles.h3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_isVerified) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.verified,
                        color: AppColors.primary,
                        size: 20,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => context.push('/agent/activities'),
            icon: Stack(
              children: [
                const Icon(Icons.notifications_outlined),
                if (_unreadCount > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _currentNavIndex = 4),
            icon: const Icon(Icons.menu),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationBanner() {
    if (_accountType != 'agent') {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                Icons.person_add_alt_1_outlined,
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
                    'Not registered as an agent',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Register as an agent to receive inspections and assignments.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => context.push('/account-type'),
              child: const Text('Register'),
            ),
          ],
        ),
      );
    }

    if (_verifLoading) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: const Center(
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final status = _verificationData?.status ?? VerificationStatus.none;

    if (status == VerificationStatus.verified) {
      return const SizedBox.shrink();
    }

    String title, subtitle;
    IconData icon;

    if (status == VerificationStatus.pending) {
      title = 'Verification Pending';
      subtitle =
          'Your documents are under review. You will be able to receive assignments once verified.';
      icon = Icons.pending_actions;
    } else {
      title = 'Complete Verification';
      subtitle = 'Verify your identity to start receiving assignments.';
      icon = Icons.verified_user_outlined;
    }

    return GestureDetector(
      onTap:
          () => context
              .push('/agent/verification')
              .then((_) => _loadVerificationData()),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
              child: Icon(icon, color: AppColors.warning, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: AppTextStyles.bodySmall.copyWith(
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
    );
  }

  Widget _buildBankDetailsBanner() {
    return GestureDetector(
      onTap: () => context.push('/agent/bank-details'),
      child: Container(
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
            Text('Required to receive inspection payouts',
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.warning.withAlpha(204))),
          ])),
          Icon(Icons.chevron_right, color: AppColors.warning),
        ]),
      ),
    );
  }

  Widget _buildStatsSection() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: _buildStatCard(
              icon: Icons.location_on_outlined,
              label: 'Base',
              value: _baseLocation,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              icon: Icons.star_outline,
              label: 'Rating',
              value: _rating > 0 ? _rating.toStringAsFixed(1) : 'N/A',
              color: AppColors.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              icon: Icons.check_circle_outline,
              label: 'Inspections',
              value: _totalInspections.toString(),
              color: AppColors.success,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: AppTextStyles.h4.copyWith(color: color),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildActionButton(
                  icon: Icons.explore_outlined,
                  label: 'Discover',
                  onTap: () => setState(() => _currentNavIndex = 1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionButton(
                  icon: Icons.people_outline,
                  label: 'Find Tenants',
                  onTap: () => setState(() => _currentNavIndex = 1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionButton(
                  icon: Icons.map_outlined,
                  label: 'Service Areas',
                  onTap: () => context.push('/agent/service-areas'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionButton(
                  icon: Icons.schedule_outlined,
                  label: 'Availability',
                  onTap: () => context.push('/agent/availability'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildActionButton(
                  icon: Icons.account_balance_outlined,
                  label: 'Bank Details',
                  onTap: () => context.push('/agent/bank-details'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionButton(
                  icon: Icons.history,
                  label: 'History',
                  onTap:
                      () => context.push(
                        '/agent/inspections',
                        extra: {'initialTab': 1},
                      ),
                ),
              ),
              const SizedBox(width: 12),
              // Spacers to keep uniform sizing
              const Expanded(child: SizedBox()),
              const SizedBox(width: 12),
              const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary, size: 24),
            const SizedBox(height: 8),
            Text(
              label,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {VoidCallback? onSeeAll}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: AppTextStyles.h4),
          if (onSeeAll != null)
            GestureDetector(
              onTap: onSeeAll,
              child: Text(
                'See all',
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAssignedPropertiesSection() {
    if (!_isVerified) {
      return _buildEmptyState(
        icon: Icons.home_work_outlined,
        title: 'No Assignments Yet',
        subtitle:
            'Complete verification to start receiving property assignments from landlords.',
      );
    }

    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return _buildEmptyState(
        icon: Icons.home_work_outlined,
        title: 'No Assigned Properties',
        subtitle:
            'When landlords assign you to their properties, they\'ll appear here.',
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream:
          _firestore
              .collection('properties')
              .where('assignedAgentId', isEqualTo: userId)
              .limit(3)
              .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }

        if (snapshot.hasError) {
          debugPrint('❌ Error loading assigned properties: ${snapshot.error}');
          return _buildEmptyState(
            icon: Icons.error_outline,
            title: 'Error Loading Properties',
            subtitle: 'Please try again later.',
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return _buildEmptyState(
            icon: Icons.home_work_outlined,
            title: 'No Assigned Properties',
            subtitle:
                'When landlords assign you to their properties, they\'ll appear here.',
          );
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children:
                docs.asMap().entries.map((entry) {
                  final index = entry.key;
                  final doc = entry.value;
                  final data = doc.data() as Map<String, dynamic>;

                  return Column(
                    children: [
                      _buildPropertyPreviewItem(data, doc.id),
                      if (index < docs.length - 1)
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                  );
                }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildPropertyPreviewItem(
    Map<String, dynamic> data,
    String propertyId,
  ) {
    final title = data['title'] ?? 'Untitled Property';
    final address = '${data['address'] ?? ''}, ${data['city'] ?? ''}';
    final landlordName = data['landlordName'] ?? 'Landlord';
    final images = List<String>.from(data['images'] ?? []);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/agent/property/$propertyId'),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Property image
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    images.isNotEmpty
                        ? Image.network(
                          images.first,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          errorBuilder:
                              (_, __, ___) => Container(
                                width: 60,
                                height: 60,
                                color: AppColors.background,
                                child: Icon(
                                  Icons.home,
                                  color: AppColors.textHint,
                                ),
                              ),
                        )
                        : Container(
                          width: 60,
                          height: 60,
                          color: AppColors.background,
                          child: Icon(
                            Icons.home,
                            color: AppColors.textHint,
                          ),
                        ),
              ),
              const SizedBox(width: 12),
              // Property info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      address,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'By $landlordName',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: AppColors.textHint,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTodaysInspectionsSection() {
    if (!_isVerified) return const SizedBox.shrink();

    return StreamBuilder<List<InspectionRequest>>(
      stream: _inspectionService.getAgentRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        final all = snapshot.data ?? [];
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        final todaysInspections =
            all.where((r) {
                final requestDay = DateTime(
                  r.requestedDate.year,
                  r.requestedDate.month,
                  r.requestedDate.day,
                );
                return r.isApproved && requestDay.isAtSameMomentAs(today);
              }).toList()
              ..sort(
                (a, b) => a.requestedTimeSlot.compareTo(b.requestedTimeSlot),
              );

        if (todaysInspections.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(26),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.today,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('Today\'s Inspections', style: AppTextStyles.h4),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${todaysInspections.length}',
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ...todaysInspections.map(
              (r) => Container(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary, width: 1.5),
                ),
                child: InkWell(
                  onTap: () => context.push('/agent/inspections'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Status row
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.today,
                                  size: 12,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'TODAY',
                                  style: AppTextStyles.caption.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (r.tenantArrived && !r.handlerArrived)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.warning.withAlpha(26),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.person_pin_circle,
                                    size: 12,
                                    color: AppColors.warning,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Tenant Waiting!',
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.warning,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (r.bothArrived)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.success.withAlpha(26),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.handshake,
                                    size: 12,
                                    color: AppColors.success,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Both Arrived',
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.success,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Property + time
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child:
                                r.propertyImage.isNotEmpty
                                    ? Image.network(
                                      r.propertyImage,
                                      width: 50,
                                      height: 50,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (_, __, ___) => Container(
                                            width: 50,
                                            height: 50,
                                            color: AppColors.background,
                                            child: Icon(
                                              Icons.home,
                                              color: AppColors.textHint,
                                            ),
                                          ),
                                    )
                                    : Container(
                                      width: 50,
                                      height: 50,
                                      color: AppColors.background,
                                      child: Icon(
                                        Icons.home,
                                        color: AppColors.textHint,
                                      ),
                                    ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.propertyTitle,
                                  style: AppTextStyles.labelMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.access_time,
                                      size: 12,
                                      color: AppColors.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      r.requestedTimeDisplay,
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.person_outline,
                                      size: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Tenant: ${r.tenantName}',
                                      style: AppTextStyles.caption.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: AppColors.textHint,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // âœ… FIXED: Now queries Firestore for actual inspection requests
  Widget _buildInspectionRequestsSection() {
    if (!_isVerified) {
      return _buildEmptyState(
        icon: Icons.event_note_outlined,
        title: 'No Inspection Requests',
        subtitle: 'Complete verification to receive inspection requests.',
      );
    }

    return StreamBuilder<List<InspectionRequest>>(
      stream: _inspectionService.getAgentPendingRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }

        if (snapshot.hasError) {
          debugPrint('❌ Error loading inspection requests: ${snapshot.error}');
          return _buildEmptyState(
            icon: Icons.error_outline,
            title: 'Error Loading Requests',
            subtitle: 'Please try again later.',
          );
        }

        final requests = snapshot.data ?? [];

        if (requests.isEmpty) {
          return _buildEmptyState(
            icon: Icons.event_note_outlined,
            title: 'No Pending Requests',
            subtitle: 'When tenants request inspections, they\'ll appear here.',
          );
        }

        // Show max 3 requests on home screen
        final displayRequests = requests.take(3).toList();

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children:
                displayRequests.asMap().entries.map((entry) {
                  final index = entry.key;
                  final request = entry.value;

                  return Column(
                    children: [
                      _buildInspectionRequestItem(request),
                      if (index < displayRequests.length - 1)
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                  );
                }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildInspectionRequestItem(InspectionRequest request) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/agent/inspections'),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Property image
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    request.propertyImage.isNotEmpty
                        ? Image.network(
                          request.propertyImage,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          errorBuilder:
                              (_, __, ___) => Container(
                                width: 60,
                                height: 60,
                                color: AppColors.background,
                                child: Icon(
                                  Icons.home,
                                  color: AppColors.textHint,
                                ),
                              ),
                        )
                        : Container(
                          width: 60,
                          height: 60,
                          color: AppColors.background,
                          child: Icon(
                            Icons.home,
                            color: AppColors.textHint,
                          ),
                        ),
              ),
              const SizedBox(width: 12),
              // Request info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Property title with pending badge
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            request.propertyTitle,
                            style: AppTextStyles.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withAlpha(26),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Pending',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.warning,
                              fontWeight: FontWeight.w600,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Tenant name
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            request.tenantName,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Date on one line
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: 12,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            request.formattedDate,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.primary,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Time on separate line
                    Row(
                      children: [
                        Icon(
                          Icons.access_time,
                          size: 12,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            request.requestedTimeDisplay,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.primary,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: AppColors.textHint,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentConfirmationSection() {
    if (!_isVerified) return const SizedBox.shrink();

    return StreamBuilder<List<InspectionRequest>>(
      stream: _inspectionService.getAgentPendingConfirmations(),
      builder: (context, snapshot) {
        final requests = snapshot.data ?? [];
        if (requests.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(26),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.payments,
                      size: 18,
                      color: AppColors.success,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('Confirm Payment', style: AppTextStyles.h4),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${requests.length}',
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ...requests.map(
              (r) => _PaymentConfirmCard(
                request: r,
                inspectionService: _inspectionService,
                onConfirmed: () {
                  // Optionally refresh profile to update earnings display
                  // Profile stream auto-updates
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: AppColors.textSecondary.withAlpha(128)),
          const SizedBox(height: 16),
          Text(
            title,
            style: AppTextStyles.labelLarge.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ============ PROPERTIES TAB ============
  Widget _buildPropertiesTab() {
    return AgentAssignedPropertiesTab(isVerified: _isVerified);
  }

  // ============ MESSAGES TAB ============
  Widget _buildMessagesTab() {
    return const MessagesTabReal(
      emptyTitle: 'No messages yet',
      emptySubtitle:
          'Conversations with landlords and\ntenants will appear here',
    );
  }

  // ============ PROFILE TAB ============
  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // Header with gradient
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary,
                  AppColors.primary.withAlpha(204),
                  AppColors.primaryLight,
                ],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Profile',
                          style: AppTextStyles.h3.copyWith(color: Colors.white),
                        ),
                        GestureDetector(
                          onTap: () => context.push('/settings'),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(51),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.settings_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    UserAvatarProfile(
                      name: _userName,
                      imageUrl: _profileImageUrl,
                      imageFile: _localProfileImage,
                      size: 90,
                      showEditBadge: true,
                      isLoading: _isLoading || _isUploadingImage,
                      onTap: _pickProfileImage,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _userName,
                      style: AppTextStyles.h3.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color:
                            _isVerified
                                ? Colors.white.withAlpha(51)
                                : AppColors.warning.withAlpha(77),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isVerified ? Icons.verified : Icons.pending,
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _isVerified
                                ? 'Verified Agent'
                                : 'Pending Verification',
                            style: AppTextStyles.labelSmall.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Stats card
          Transform.translate(
            offset: const Offset(0, -30),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(13),
                      blurRadius: 20,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _ProfileStat(
                        icon: Icons.location_on_outlined,
                        value: _baseLocation,
                        label: 'Base Location',
                        color: AppColors.primary,
                      ),
                    ),
                    Container(width: 1, height: 40, color: AppColors.border),
                    Expanded(
                      child: _ProfileStat(
                        icon: Icons.star_outline,
                        value: _rating > 0 ? _rating.toStringAsFixed(1) : 'N/A',
                        label: 'Rating',
                        color: AppColors.warning,
                      ),
                    ),
                    Container(width: 1, height: 40, color: AppColors.border),
                    Expanded(
                      child: _ProfileStat(
                        icon: Icons.check_circle_outline,
                        value: '$_totalInspections',
                        label: 'Inspections',
                        color: AppColors.success,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Menu sections
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProfileSection(
                  title: 'Account',
                  items: [
                    _ProfileMenuItem(
                      icon: Icons.person_outline,
                      title: 'Edit Profile',
                      subtitle: 'Update your personal information',
                      onTap: () => context.push('/edit-profile'),
                    ),
                    _ProfileMenuItem(
                      icon: Icons.map_outlined,
                      title: 'Service Areas',
                      subtitle: '${_serviceAreas.length} areas selected',
                      onTap: () => context.push('/agent/service-areas'),
                    ),
                    _ProfileMenuItem(
                      icon: Icons.account_balance_outlined,
                      title: 'Bank Details',
                      subtitle: 'Manage your payout account',
                      onTap: () => context.push('/agent/bank-details'),
                    ),
                    _ProfileMenuItem(
                      icon: Icons.verified_user_outlined,
                      title: 'Verification',
                      subtitle: _isVerified ? 'Verified' : 'Tap to verify',
                      onTap:
                          () => context
                              .push('/agent/verification')
                              .then((_) => _loadVerificationData()),
                      trailing:
                          _isVerified
                              ? Icon(
                                Icons.check_circle,
                                color: AppColors.success,
                                size: 20,
                              )
                              : Icon(
                                Icons.chevron_right,
                                color: AppColors.textHint,
                                size: 20,
                              ),
                    ),
                    _ProfileMenuItem(
                      icon: Icons.event_note_outlined,
                      title: 'My Inspections',
                      subtitle: 'View and manage inspections',
                      onTap: () => context.push('/agent/inspections'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _ProfileSection(
                  title: 'Support',
                  items: [
                    _ProfileMenuItem(
                      icon: Icons.help_outline,
                      title: 'Help & Support',
                      subtitle: 'FAQs and contact us',
                      onTap: () => context.push('/help-support'),
                    ),
                    _ProfileMenuItem(
                      icon: Icons.info_outline,
                      title: 'About ClearRent',
                      subtitle: 'Version 1.0.0',
                      onTap: () => context.push('/about'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Sign Out button
                GestureDetector(
                  onTap: () => _showLogoutConfirmation(),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.error.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.error.withAlpha(77)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.logout, color: AppColors.error),
                        const SizedBox(width: 8),
                        Text(
                          'Sign Out',
                          style: AppTextStyles.labelLarge.copyWith(
                            color: AppColors.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showLogoutConfirmation() {
    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Sign Out'),
            content: const Text('Are you sure you want to sign out?'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await _authService.signOut();
                  if (mounted) {
                    context.go('/login');
                  }
                },
                child: Text(
                  'Sign Out',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ],
          ),
    );
  }

  // ============ BOTTOM NAV ============
  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(13),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
                label: 'Home',
                isActive: _currentNavIndex == 0,
                onTap: () => setState(() => _currentNavIndex = 0),
              ),
              _NavItem(
                icon: Icons.explore_outlined,
                activeIcon: Icons.explore,
                label: 'Discover',
                isActive: _currentNavIndex == 1,
                onTap: () => setState(() => _currentNavIndex = 1),
              ),
              _NavItem(
                icon: Icons.home_work_outlined,
                activeIcon: Icons.home_work,
                label: 'Properties',
                isActive: _currentNavIndex == 2,
                onTap: () => setState(() => _currentNavIndex = 2),
                badge:
                    _assignedPropertiesCount > 0
                        ? '$_assignedPropertiesCount'
                        : null,
              ),
              _NavItem(
                icon: Icons.chat_outlined,
                activeIcon: Icons.chat,
                label: 'Messages',
                isActive: _currentNavIndex == 3,
                onTap: () {
                  setState(() {
                    _currentNavIndex = 3;
                  });
                },
                badge: _unreadCount > 0 ? '$_unreadCount' : null,
              ),
              _NavItem(
                icon: Icons.person_outline,
                activeIcon: Icons.person,
                label: 'Profile',
                isActive: _currentNavIndex == 4,
                onTap: () => setState(() => _currentNavIndex = 4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============ HELPER WIDGETS ============

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final String? badge;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                isActive ? activeIcon : icon,
                color: isActive ? AppColors.primary : AppColors.textSecondary,
              ),
              if (badge != null)
                Positioned(
                  right: -8,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: isActive ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _ProfileStat({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(
          value,
          style: AppTextStyles.labelMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(fontSize: 10),
          maxLines: 1,
        ),
      ],
    );
  }
}

class _ProfileSection extends StatelessWidget {
  final String title;
  final List<Widget> items;

  const _ProfileSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTextStyles.labelLarge.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children:
                items.asMap().entries.map((e) {
                  return Column(
                    children: [
                      e.value,
                      if (e.key < items.length - 1)
                        Divider(height: 1, indent: 56, color: AppColors.border),
                    ],
                  );
                }).toList(),
          ),
        ),
      ],
    );
  }
}

class _ProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const _ProfileMenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppColors.textPrimary, size: 20),
            ),
            const SizedBox(width: 12),
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
            trailing ??
                Icon(
                  Icons.chevron_right,
                  color: AppColors.textHint,
                  size: 20,
                ),
          ],
        ),
      ),
    );
  }
}

class _PaymentConfirmCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  final VoidCallback? onConfirmed;

  const _PaymentConfirmCard({
    required this.request,
    required this.inspectionService,
    this.onConfirmed,
  });

  @override
  State<_PaymentConfirmCard> createState() => _PaymentConfirmCardState();
}

class _PaymentConfirmCardState extends State<_PaymentConfirmCard> {
  bool _isConfirming = false;

  Future<void> _confirmReceived() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Confirm Payment Received'),
            content: Text(
              'Have you received ${InspectionPricing.formatNaira(widget.request.agentEarnings)} '
              'for the inspection at ${widget.request.propertyTitle}?',
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Not Yet',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Yes, Received'),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    setState(() => _isConfirming = true);
    final ok = await widget.inspectionService.confirmPaymentReceived(
      widget.request.id,
    );
    if (!mounted) return;
    setState(() => _isConfirming = false);

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Payment confirmed! Thank you. âœ“'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      widget.onConfirmed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
                      Icons.payments,
                      size: 12,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'PAYMENT SENT',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                InspectionPricing.formatNaira(r.agentEarnings),
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.success,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            r.propertyTitle,
            style: AppTextStyles.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            'Please confirm if you have received this payment.',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isConfirming ? null : _confirmReceived,
              icon:
                  _isConfirming
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                      : const Icon(Icons.check_circle, size: 18),
              label: Text(
                _isConfirming ? 'Confirming...' : 'Yes, I Received Payment',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
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
  }
}