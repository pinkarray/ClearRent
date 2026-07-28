import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/models/activity_model.dart';
import '../../../../shared/widgets/announcements_banner.dart';
import '../../../chat/presentation/widgets/messages_tab.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/activity_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/tenancy_link_model.dart';
import '../../../../shared/widgets/notification_bell.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../shared/widgets/connectivity_wrapper.dart';
import '../../../../shared/widgets/verification_badge.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../../../../shared/widgets/user_avatar.dart';

class LandlordHomeScreen extends StatefulWidget {
  const LandlordHomeScreen({super.key});

  @override
  State<LandlordHomeScreen> createState() => _LandlordHomeScreenState();
}

class _LandlordHomeScreenState extends State<LandlordHomeScreen> {
  int _currentNavIndex = 0;
  DateTime? _lastBackPressed;
  
  // Services
  late final AuthService _authService;
  late final VerificationService _verificationService;
  late final PropertyService _propertyService;
  late final ActivityService _activityService;
  late final ConversationService _conversationService;
  
  // User data
  String _userName = '';
  bool _isLoadingProfile = true;
  String? _profileImageUrl;
  File? _localProfileImage;   
  bool _isUploadingImage = false;
  VerificationStatus _verificationStatus = VerificationStatus.none;
  double _landlordRating = 0.0;
  int _totalRatings = 0;

  // Live stream subscriptions
  StreamSubscription? _profileSubscription;
  StreamSubscription? _propertiesSubscription;
  StreamSubscription? _activitiesSubscription;
  StreamSubscription? _rentalsSubscription;
  StreamSubscription? _linkedTenantsSubscription;
  StreamSubscription? _unreadCountSubscription;

  // Properties - now from Firestore
  List<PropertyModel> _myProperties = [];
  bool _isLoadingProperties = true;

  // Activities - now from Firestore
  List<ActivityModel> _recentActivities = [];
  bool _isLoadingActivities = true;

  // Unread message count
  int _unreadCount = 0;
  List<ActiveRental> _activeRentals = [];
  bool _isLoadingRentals = true;

  // Linked tenants
  List<TenancyLinkModel> _linkedTenants = [];
  bool _isLoadingLinkedTenants = true;

  // Stats (will be real later)
  int get _totalViews => _recentActivities
      .where((a) => a.type == ActivityType.propertyViewed)
      .length;
  int get _totalInquiries => _recentActivities
      .where((a) => a.type == ActivityType.inquiry)
      .length;
  double get _totalEarnings => 0; // Will come from payments later

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _verificationService = VerificationService();
    _propertyService = PropertyService();
    _activityService = ActivityService();
    _conversationService = ConversationService();
    _startProfileStream();
    _startPropertiesStream();
    _startActivitiesStream();
    _startRentalsStream();
    _startLinkedTenantsStream();
    _startUnreadCountStream();
  }

  void _startProfileStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() { _userName = 'Landlord'; _isLoadingProfile = false; });
      return;
    }
    _profileSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data()!;
      // Parse verification status directly from profile doc
      final statusStr = data['verificationStatus'] as String? ?? 'none';
      final isVerifiedFlag = data['isVerified'] == true;
      VerificationStatus vStatus;
      switch (statusStr) {
        case 'verified':  vStatus = VerificationStatus.verified;  break;
        case 'pending':   vStatus = VerificationStatus.pending;   break;
        case 'rejected':  vStatus = VerificationStatus.rejected;  break;
        case 'expired':   vStatus = VerificationStatus.expired;   break;
        default:          vStatus = VerificationStatus.none;
      }
      if (isVerifiedFlag) vStatus = VerificationStatus.verified;
      setState(() {
        _userName = data['fullName'] ?? 'Landlord';
        _profileImageUrl = data['profileImageUrl'];
        _landlordRating = (data['rating'] ?? 0.0).toDouble();
        _totalRatings = (data['totalRatings'] ?? 0) as int;
        _verificationStatus = vStatus;
        _isLoadingProfile = false;
      });
    }, onError: (e) {
      debugPrint('❌ Profile stream error: $e');
      if (mounted) setState(() { _userName = 'Landlord'; _isLoadingProfile = false; });
    });
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              Text('Profile Photo', style: AppTextStyles.h4),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _buildSourceOption(
                  icon: Icons.camera_alt_rounded, label: 'Camera',
                  onTap: () => Navigator.pop(ctx, ImageSource.camera),
                ),
                _buildSourceOption(
                  icon: Icons.photo_library_rounded, label: 'Gallery',
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
                if (_profileImageUrl != null)
                  _buildSourceOption(
                    icon: Icons.delete_outline, label: 'Remove',
                    onTap: () => Navigator.pop(ctx, null), // null = remove
                    color: AppColors.error,
                  ),
              ]),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );

    // source is null if user tapped Remove or dismissed
    if (source == null && _profileImageUrl != null) {
      // Remove photo
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
      // Show local preview immediately
      setState(() {
        _localProfileImage = file;
        _isUploadingImage = true;
      });

      // Upload in background
      final url = await _authService.uploadProfileImage(file);
      if (mounted) {
        setState(() {
          if (url != null) {
            _profileImageUrl = url;
            _localProfileImage = null; // clear local file, use URL now
          }
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
      debugPrint('âŒ Error picking profile image: $e');
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Widget _buildSourceOption({required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: (color ?? AppColors.primary).withAlpha(26),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: color ?? AppColors.primary, size: 32),
        ),
        const SizedBox(height: 8),
        Text(label, style: AppTextStyles.labelMedium.copyWith(
          color: color ?? AppColors.textPrimary)),
      ]),
    );
  }

  Future<void> _loadVerificationStatus() async {
    try {
      final data = await _verificationService.getVerificationStatus();
      if (mounted) {
        setState(() => _verificationStatus = data.status);
      }
    } catch (e) {
      debugPrint('âŒ Error loading verification: $e');
    }
  }

  void _startPropertiesStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) { setState(() => _isLoadingProperties = false); return; }
    _propertiesSubscription = FirebaseFirestore.instance
        .collection('properties')
        .where('landlordId', isEqualTo: uid)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final properties = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        // Convert Timestamps to ISO strings for PropertyModel.fromJson
        for (final key in ['createdAt', 'updatedAt']) {
          if (data[key] is Timestamp) {
            data[key] = (data[key] as Timestamp).toDate().toIso8601String();
          }
        }
        return PropertyModel.fromJson(data);
      }).toList();
      setState(() {
        _myProperties = properties;
        _isLoadingProperties = false;
      });
    }, onError: (e) {
      debugPrint('❌ Properties stream error: $e');
      if (mounted) setState(() => _isLoadingProperties = false);
    });
  }

  void _startActivitiesStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) { setState(() => _isLoadingActivities = false); return; }

    // Use ActivityService stream which queries by 'landlordId' —
    // this picks up property views, inquiries, AND inspection activities.
    _activitiesSubscription = _activityService.activitiesStream(limit: 20)
        .listen((activities) {
      if (!mounted) return;

      // Only show activities from the last 3 days on the dashboard
      final cutoff = DateTime.now().subtract(const Duration(days: 3));
      final recent = activities
          .where((a) => a.createdAt.isAfter(cutoff))
          .toList();

      setState(() {
        _recentActivities = recent;
        _isLoadingActivities = false;
      });
    }, onError: (e) {
      debugPrint('❌ Activities stream error: $e');
      if (mounted) setState(() => _isLoadingActivities = false);
    });
  }

  void _startUnreadCountStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _unreadCountSubscription = FirebaseFirestore.instance
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

  void _startRentalsStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) { setState(() => _isLoadingRentals = false); return; }
    _rentalsSubscription = FirebaseFirestore.instance
        .collection('active_rentals')
        .where('landlordId', isEqualTo: uid)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final rentals = snapshot.docs
          .map((doc) => ActiveRental.fromFirestore(doc.data(), doc.id))
          .toList()
          .where((r) => r.isActive || r.isExpiringSoon)
          .toList();
      setState(() {
        _activeRentals = rentals;
        _isLoadingRentals = false;
      });
    }, onError: (e) {
      debugPrint('❌ Rentals stream error: $e');
      if (mounted) setState(() => _isLoadingRentals = false);
    });
  }

  void _startLinkedTenantsStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) { setState(() => _isLoadingLinkedTenants = false); return; }
    _linkedTenantsSubscription = FirebaseFirestore.instance
        .collection('tenancy_links')
        .where('landlordId', isEqualTo: uid)
        .where('status', isEqualTo: 'confirmed')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final links = snapshot.docs
          .map((doc) => TenancyLinkModel.fromFirestore(doc.data(), doc.id))
          .toList();
      setState(() {
        _linkedTenants = links;
        _isLoadingLinkedTenants = false;
      });
    }, onError: (e) {
      debugPrint('❌ Linked tenants stream error: $e');
      if (mounted) setState(() => _isLoadingLinkedTenants = false);
    });
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _propertiesSubscription?.cancel();
    _activitiesSubscription?.cancel();
    _rentalsSubscription?.cancel();
    _linkedTenantsSubscription?.cancel();
    _unreadCountSubscription?.cancel();
    super.dispose();
  }

  // Streams auto-update, but pull-to-refresh restarts them cleanly
  Future<void> _refreshData() async {
    _profileSubscription?.cancel();
    _propertiesSubscription?.cancel();
    _activitiesSubscription?.cancel();
    _rentalsSubscription?.cancel();
    _linkedTenantsSubscription?.cancel();
    _unreadCountSubscription?.cancel();
    _startProfileStream();
    _startPropertiesStream();
    _startActivitiesStream();
    _startRentalsStream();
    _startLinkedTenantsStream();
    _startUnreadCountStream();
  }

  String get _firstName {
    final parts = _userName.split(' ');
    return parts.isNotEmpty ? parts.first : _userName;
  }

  Future<bool> _onWillPop() async {
    if (_currentNavIndex != 0) {
      setState(() => _currentNavIndex = 0);
      return false;
    }
    final now = DateTime.now();
    if (_lastBackPressed == null || now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Press back again to exit'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
        if (shouldPop && context.mounted) SystemNavigator.pop();
      },
      child: ConnectivityWrapper(
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: _currentNavIndex == 0
              ? SafeArea(child: _buildHomeTab())
              : _currentNavIndex == 1
                  ? SafeArea(child: _buildPropertiesTab())
                  : _currentNavIndex == 2
                      ? SafeArea(child: _buildMessagesTab())
                      : _buildProfileTab(),
          floatingActionButton: _currentNavIndex <= 1
              ? FloatingActionButton.extended(
                  onPressed: () => context.push('/landlord/add-property').then((_) => _refreshData()),
                  backgroundColor: AppColors.primary,
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: Text('Add Property', style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
                )
              : null,
          bottomNavigationBar: _buildBottomNav(),
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    return RefreshIndicator(
      onRefresh: _refreshData,
      color: AppColors.primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _isLoadingProfile
                          ? Container(width: 150, height: 16, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(4)))
                          : Text('Hello, $_firstName', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 4),
                      Text('Dashboard', style: AppTextStyles.h2),
                    ],
                  ),
                ),
                NotificationBell(userId: _authService.currentUserId ?? ''),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => setState(() => _currentNavIndex = 3),
                  child: UserAvatar(
                    name: _userName,
                    imageUrl: _profileImageUrl,
                    imageFile: _localProfileImage,
                    size: 48,
                  ),
                ),
              ],
            ),

            // Verification prompt
            if (_verificationStatus != VerificationStatus.verified) ...[
              const SizedBox(height: 16),
              _buildVerificationPrompt(),
            ],
            // Announcements
            AnnouncementsBanner(
              userId: _authService.currentUserId ?? '',
              accountType: 'landlord',
              notificationsRoute: '/notifications',
            ),
            const SizedBox(height: 8),

            const SizedBox(height: 24),

            // Stats dashboard card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Row(children: [
                    _DashStat(
                      icon: Icons.home_outlined,
                      label: 'Properties',
                      value: _isLoadingProperties ? '...' : '${_myProperties.length}',
                      color: AppColors.primary,
                      onTap: () => setState(() => _currentNavIndex = 1),
                    ),
                    _VerticalDivider(),
                    _DashStat(
                      icon: Icons.visibility_outlined,
                      label: 'Total Views',
                      value: _isLoadingActivities ? '...' : '$_totalViews',
                      color: AppColors.info,
                      onTap: () => context.push('/landlord/activities'),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 16),
                  Row(children: [
                    _DashStat(
                      icon: Icons.chat_bubble_outline,
                      label: 'Inquiries',
                      value: _isLoadingActivities ? '...' : '$_totalInquiries',
                      color: AppColors.warning,
                      onTap: () => context.push('/landlord/activities'),
                    ),
                    _VerticalDivider(),
                    _DashStat(
                      icon: Icons.account_balance_wallet_outlined,
                      label: 'Rentals',
                      value: _isLoadingRentals ? '...' : '${_activeRentals.length}',
                      color: AppColors.success,
                      onTap: () => context.push('/landlord/rentals'),
                    ),
                  ]),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Recent Activity — surfaced first so the landlord sees what just
            // happened before scrolling their rentals and linked tenants.
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Recent Activity', style: AppTextStyles.h4),
              TextButton(
                onPressed: () => context.push('/landlord/activities'),
                child: Text('See all', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
              ),
            ]),
            const SizedBox(height: 12),
            _buildActivitiesSection(),

            if (!_isLoadingRentals && _activeRentals.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Active Rentals', style: AppTextStyles.h4),
                  TextButton(
                    onPressed: () => context.push('/landlord/rentals'),
                    child: Text('See all',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.primary)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ..._activeRentals.take(2).map((rental) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildRentalSummaryCard(rental),
                  )),
            ],

            // Linked tenants section — only shown if landlord has confirmed links
            if (!_isLoadingLinkedTenants && _linkedTenants.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    Text('Linked Tenants', style: AppTextStyles.h4),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(26),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_linkedTenants.length}',
                        style: AppTextStyles.labelSmall.copyWith(color: AppColors.info),
                      ),
                    ),
                  ]),
                  TextButton(
                    onPressed: () => context.push('/landlord/rentals'),
                    child: Text('See all',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.primary)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ..._linkedTenants.take(2).map((link) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildLinkedTenantCard(link),
                  )),
            ],

            const SizedBox(height: 32),

            // My Properties section
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('My Properties', style: AppTextStyles.h4),
              TextButton(
                onPressed: () => setState(() => _currentNavIndex = 1), 
                child: Text('See all', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
              ),
            ]),
            const SizedBox(height: 12),

            // Properties - Real data
            _buildPropertiesPreview(),

            // Clears the floating "Add Property" button (~64px) with a small
            // gap; the padding above already adds 20, so 52 → ~72 total.
            const SizedBox(height: 52),
          ],
        ),
      ),
    );
  }

  Widget _buildActivitiesSection() {
    if (_isLoadingActivities) {
      return Container(
        padding: const EdgeInsets.all(40),
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

    if (_recentActivities.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(Icons.notifications_none_outlined, size: 40, color: AppColors.textHint),
            const SizedBox(height: 12),
            Text(
              'No recent activity',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              'When tenants view or inquire about your properties, you\'ll see it here',
              style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Show activities in a scrollable container on dashboard
    final displayActivities = _recentActivities.take(10).toList();

    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: displayActivities.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final activity = displayActivities[index];
          return GestureDetector(
            onTap: () => _onActivityTap(activity),
            child: _ActivityItem(
              icon: _getActivityIcon(activity.type),
              title: activity.title,
              subtitle: activity.subtitle,
              time: activity.timeAgo,
              color: _getActivityColor(activity.type),
              isUnread: !activity.isRead,
            ),
          );
        },
      ),
    );
  }

  Future<void> _onActivityTap(ActivityModel activity) async {
    await _activityService.markAsRead(activity.id);
    
    if (!mounted) return;

    // Issue activities — go straight to the issues screen
    if (activity.type == ActivityType.issueReported ||
        activity.type == ActivityType.issueDisputed ||
        activity.type == ActivityType.issueConfirmed) {
      context.push('/landlord/issues');
      return;
    }

    // Inspection activities — go to landlord inspections screen
    if (activity.type == ActivityType.inspectionRequest ||
        activity.type == ActivityType.inspectionApproved ||
        activity.type == ActivityType.inspectionDeclined ||
        activity.type == ActivityType.inspectionCompleted ||
        activity.type == ActivityType.inspectionRated) {
      context.push('/landlord/inspections');
      return;
    }

    // Payout activities — go to earnings
    if (activity.type == ActivityType.payoutReceived) {
      context.push('/landlord/earnings');
      return;
    }

    // Property views and inquiries — show viewer info sheet
    if ((activity.type == ActivityType.propertyViewed ||
            activity.type == ActivityType.inquiry) &&
        activity.actorId != null) {
      _showViewerSheet(activity);
      return;
    }

    // Payment activities — a tenant paid to rent. The landlord accepts them in
    // Inspections → History (tab 2), which is what the activity subtitle and
    // the matching push payload both say; this used to open the property
    // instead, leaving no route to the accept box. relatedId is the inspection
    // to highlight — rows written before it was stored just land on the tab.
    if (activity.type == ActivityType.payment) {
      context.push('/landlord/inspections', extra: {
        'initialTab': 2,
        if (activity.relatedId != null) 'param_requestId': activity.relatedId,
      });
      return;
    }

    // Fallback — navigate to the property if available
    if (activity.propertyId != null) {
      final property = await _propertyService.getProperty(activity.propertyId!);
      if (!mounted) return;
      if (property != null) {
        context.push('/property-detail', extra: property);
      } else {
        // Never leave the tap unanswered — a missing/unreadable property used
        // to fail silently, which reads as a dead tap.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Could not open that property. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  void _showViewerSheet(ActivityModel activity) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ViewerSheet(
        activity: activity,
        landlordId: _authService.currentUserId ?? '',
        landlordName: _userName,
        conversationService: _conversationService,
        propertyService: _propertyService,
      ),
    );
  }

  IconData _getActivityIcon(ActivityType type) {
    switch (type) {
      case ActivityType.propertyAdded:       return Icons.home_outlined;
      case ActivityType.propertyViewed:      return Icons.visibility_outlined;
      case ActivityType.inquiry:             return Icons.chat_bubble_outline;
      case ActivityType.payment:             return Icons.payments_outlined;
      case ActivityType.issueReported:       return Icons.report_problem_outlined;
      case ActivityType.issueDisputed:       return Icons.warning_amber_outlined;
      case ActivityType.issueConfirmed:      return Icons.check_circle_outline;
      case ActivityType.inspectionRequest:   return Icons.search_outlined;
      case ActivityType.inspectionApproved:  return Icons.event_available_outlined;
      case ActivityType.inspectionDeclined:  return Icons.event_busy_outlined;
      case ActivityType.inspectionCompleted: return Icons.done_all_outlined;
      case ActivityType.inspectionRated:     return Icons.star_outline;
      case ActivityType.payoutReceived:      return Icons.account_balance_wallet_outlined;
    }
  }

  Color _getActivityColor(ActivityType type) {
    switch (type) {
      case ActivityType.propertyAdded:       return AppColors.primary;
      case ActivityType.propertyViewed:      return AppColors.info;
      case ActivityType.inquiry:             return AppColors.warning;
      case ActivityType.payment:             return AppColors.success;
      case ActivityType.issueReported:       return AppColors.error;
      case ActivityType.issueDisputed:       return AppColors.error;
      case ActivityType.issueConfirmed:      return AppColors.success;
      case ActivityType.inspectionRequest:   return AppColors.warning;
      case ActivityType.inspectionApproved:  return AppColors.success;
      case ActivityType.inspectionDeclined:  return AppColors.error;
      case ActivityType.inspectionCompleted: return AppColors.success;
      case ActivityType.inspectionRated:     return AppColors.primary;
      case ActivityType.payoutReceived:      return AppColors.success;
    }
  }

  Widget _buildPropertiesPreview() {
    if (_isLoadingProperties) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(40),
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

    if (_myProperties.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(Icons.home_outlined, size: 40, color: AppColors.textHint),
            const SizedBox(height: 12),
            Text(
              'No properties yet',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap "Add Property" to list your first property',
              style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Show only first 2 properties on dashboard
    final displayProperties = _myProperties.take(2).toList();

    return Column(
      children: displayProperties.map((p) => Padding(
        padding: const EdgeInsets.only(bottom: 12), 
        child: _LandlordPropertyCard(
          property: p, 
          onTap: () => context.push('/property-detail', extra: p),
        ),
      )).toList(),
    );
  }

  Widget _buildRentalSummaryCard(ActiveRental rental) {
    final daysLeft = rental.daysUntilLeaseEnd;
    final isExpiring = daysLeft <= 30 && daysLeft > 0;

    return GestureDetector(
      onTap: () => context.push('/landlord/rentals'),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isExpiring
                ? AppColors.warning.withAlpha(77)
                : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            // Property image
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: rental.propertyImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: rental.propertyImage,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      memCacheWidth: 200,
                      errorWidget: (_, __, ___) => Container(
                        width: 56,
                        height: 56,
                        color: AppColors.background,
                        child: Icon(Icons.home,
                            color: AppColors.textHint, size: 24),
                      ),
                    )
                  : Container(
                      width: 56,
                      height: 56,
                      color: AppColors.background,
                      child: Icon(Icons.home,
                          color: AppColors.textHint, size: 24),
                    ),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rental.propertyTitle,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.person_outline,
                          size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Text(rental.tenantName,
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Status
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isExpiring
                    ? AppColors.warning.withAlpha(26)
                    : AppColors.success.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isExpiring ? '${daysLeft}d left' : 'Active',
                style: AppTextStyles.labelSmall.copyWith(
                  color: isExpiring
                      ? AppColors.warning
                      : AppColors.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkedTenantCard(TenancyLinkModel link) {
    final daysUntilDue = link.daysUntilDue;
    final isDueSoon = daysUntilDue <= 7;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDueSoon
              ? AppColors.warning.withAlpha(77)
              : AppColors.border,
        ),
      ),
      child: Row(children: [
        // Avatar
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.info.withAlpha(26),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              link.tenantName.isNotEmpty ? link.tenantName[0].toUpperCase() : 'T',
              style: AppTextStyles.labelLarge.copyWith(color: AppColors.info),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Info
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                link.tenantName,
                style: AppTextStyles.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Row(children: [
                Icon(Icons.home_outlined, size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    link.propertyTitle,
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Rent due badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isDueSoon
                ? AppColors.warning.withAlpha(26)
                : AppColors.info.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                link.formattedRentAmount,
                style: AppTextStyles.labelSmall.copyWith(
                  color: isDueSoon ? AppColors.warning : AppColors.info,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                isDueSoon ? 'due in ${daysUntilDue}d' : 'linked',
                style: AppTextStyles.caption.copyWith(
                  color: isDueSoon ? AppColors.warning : AppColors.textHint,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildVerificationPrompt() {
    String title, subtitle;
    IconData icon;
    Color color, bgColor;
    switch (_verificationStatus) {
      case VerificationStatus.none:
        title = 'Get Verified';
        subtitle = 'Verified landlords get 3x more inquiries';
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
      case VerificationStatus.expired:
        title = 'Verification Expired';
        subtitle = 'Renew to keep listing & messaging';
        icon = Icons.autorenew;
        color = AppColors.warning;
        bgColor = AppColors.warningLight;
        break;
      case VerificationStatus.verified:
        return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => context.push('/landlord/verification').then((_) => _loadVerificationStatus()),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withAlpha(77)),),
        child: Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withAlpha(26), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color, size: 22)),
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

  Widget _buildPropertiesTab() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.all(20), child: Text('My Properties', style: AppTextStyles.h2)),
      Expanded(
        child: _isLoadingProperties
            ? Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _myProperties.isEmpty
                ? _buildEmptyProperties()
                : RefreshIndicator(
                    onRefresh: _refreshData,
                    color: AppColors.primary,
                    child: ListView.builder(
                      // Bottom clears the floating "Add Property" button; was
                      // 100 (excess dead space at the end of the list).
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 72),
                      itemCount: _myProperties.length,
                      itemBuilder: (context, index) {
                        final property = _myProperties[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16), 
                          child: _LandlordPropertyCard(
                            property: property, 
                            onTap: () => context.push('/property-detail', extra: property), 
                            showActions: true,
                            onDelete: () => _deleteProperty(property),
                            onToggleStatus: () => _togglePropertyStatus(property),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    ]);
  }

  Future<void> _deleteProperty(PropertyModel property) async {
    // Can't delete a property with a sitting/linked tenant — it would strand
    // their dashboard with an orphaned rental/link.
    if (await _propertyService.propertyHasSittingTenant(property.id)) {
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
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Property'),
        content: Text('Are you sure you want to delete "${property.title}"?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _propertyService.deleteProperty(property.id);
      // Stream auto-updates the list
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Property deleted'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _togglePropertyStatus(PropertyModel property) async {
    await _propertyService.updateAvailability(property.id, !property.isAvailable);
    // Stream auto-updates the list
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(property.isAvailable ? 'Property marked as occupied' : 'Property marked as available'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _buildEmptyProperties() {
    return GuidanceEmptyState(
      icon: Icons.home_outlined,
      title: 'No properties yet',
      subtitle: 'Add your first property to start receiving tenant inquiries.',
      actionLabel: 'Add Property',
      actionIcon: Icons.add,
      onAction: () =>
          context.push('/landlord/add-property').then((_) => _refreshData()),
    );
  }

  /// UPDATED: Now uses real Firestore messages
  Widget _buildMessagesTab() {
    return const MessagesTabReal(
      emptyTitle: 'No messages yet',
      emptySubtitle: 'Tenant inquiries will appear here',
    );
  }

  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [AppColors.primary, AppColors.primary.withAlpha(204), AppColors.primaryLight])),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  GestureDetector(
                    onTap: () => context.push('/settings'),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(51),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.settings_outlined, color: Colors.white, size: 20),
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
                UserAvatarProfile(
                  name: _userName,
                  imageUrl: _profileImageUrl,
                  imageFile: _localProfileImage,
                  size: 90,
                  showEditBadge: true,
                  isLoading: _isLoadingProfile || _isUploadingImage,
                  onTap: _pickProfileImage,
                ),
                const SizedBox(height: 16),
                _isLoadingProfile ? Container(width: 120, height: 24, decoration: BoxDecoration(color: Colors.white.withAlpha(77), borderRadius: BorderRadius.circular(4))) : Text(_userName, style: AppTextStyles.h3.copyWith(color: Colors.white)),
                const SizedBox(height: 8),
                VerificationBadgeLarge(status: _verificationStatus, onTap: () => context.push('/landlord/verification').then((_) => _loadVerificationStatus())),
              ]),
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -30),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withAlpha(13), blurRadius: 20, offset: const Offset(0, 5))]),
              child: Row(children: [
                Expanded(child: _ProfileStat(icon: Icons.home_outlined, value: '${_myProperties.length}', label: 'Properties', color: AppColors.primary)),
                Container(width: 1, height: 40, color: AppColors.border),
                Expanded(child: _ProfileStat(icon: Icons.visibility_outlined, value: '$_totalViews', label: 'Total Views', color: AppColors.info)),
                Container(width: 1, height: 40, color: AppColors.border),
                Expanded(child: _ProfileStat(icon: Icons.star_outline, value: _landlordRating > 0 ? _landlordRating.toStringAsFixed(1) : 'N/A', label: 'Rating${_totalRatings > 0 ? ' ($_totalRatings)' : ''}', color: AppColors.warning)),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _ProfileSection(title: 'Account', items: [
              _ProfileMenuItem(icon: Icons.person_outline, title: 'Edit Profile', subtitle: 'Update your personal information', onTap: () => context.push('/edit-profile')),
              _ProfileMenuItem(icon: Icons.security_outlined, title: 'Verification', subtitle: _getVerificationSubtitle(), trailing: VerificationBadge(status: _verificationStatus, showLabel: true), onTap: () => context.push('/landlord/verification').then((_) => _loadVerificationStatus())),
              _ProfileMenuItem(
                icon: Icons.account_balance_outlined,
                title: 'Bank Details',
                subtitle: 'Manage your payout account',
                onTap: () => context.push('/landlord/bank-details'),
              ),
            ]),
            const SizedBox(height: 24),
            _ProfileSection(title: 'Activity', items: [
              _ProfileMenuItem(
                icon: Icons.event_note_outlined,
                title: 'Inspection Requests',
                subtitle: 'Manage property inspections',
                onTap: () => context.push('/landlord/inspections'),
              ),
              _ProfileMenuItem(
                icon: Icons.key_outlined,
                title: 'Active Rentals',
                subtitle: _activeRentals.isNotEmpty
                    ? '${_activeRentals.length} active rental${_activeRentals.length > 1 ? 's' : ''}'
                    : 'Manage your rented properties',
                onTap: () => context.push('/landlord/rentals'),
              ),
              _ProfileMenuItem(
                icon: Icons.description_outlined,
                title: 'Tenancy Agreements',
                subtitle: 'Upload and manage lease agreements',
                onTap: () => context.push('/landlord/agreements'),
              ),
              _ProfileMenuItem(
                icon: Icons.report_problem_outlined,
                title: 'Tenant Issues',
                subtitle: 'View reported maintenance issues',
                onTap: () => context.push('/landlord/issues'),
              ),
              _ProfileMenuItem(icon: Icons.account_balance_wallet_outlined, title: 'Earnings & Transactions', subtitle: _totalEarnings > 0 ? '₦${(_totalEarnings / 1000000).toStringAsFixed(1)}M total' : 'View your earnings and payment history', onTap: () => context.push('/landlord/earnings')),
              _ProfileMenuItem(icon: Icons.receipt_long_outlined, title: 'Payments & Documents', subtitle: 'Receipts and payment history', onTap: () => context.push('/landlord/documents')),
            ]),
            const SizedBox(height: 24),
            _ProfileSection(title: 'Support', items: [
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
            ]),
            const SizedBox(height: 20),
          ]),
        ),
      ]),
    );
  }

  String _getVerificationSubtitle() {
    switch (_verificationStatus) {
      case VerificationStatus.none: return 'Tap to get verified';
      case VerificationStatus.pending: return 'Under review';
      case VerificationStatus.verified: return 'Identity verified';
      case VerificationStatus.rejected: return 'Verification failed - tap to retry';
      case VerificationStatus.expired: return 'Verification expired - tap to renew';
    }
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(color: AppColors.surface, boxShadow: [BoxShadow(color: Colors.black.withAlpha(13), blurRadius: 10, offset: const Offset(0, -5))]),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _NavItem(icon: Icons.dashboard_outlined, activeIcon: Icons.dashboard, label: 'Dashboard', isActive: _currentNavIndex == 0, onTap: () => setState(() => _currentNavIndex = 0)),
            _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Properties', isActive: _currentNavIndex == 1, onTap: () => setState(() => _currentNavIndex = 1)),
            _NavItem(
              icon: Icons.chat_bubble_outline, 
              activeIcon: Icons.chat_bubble, 
              label: 'Messages', 
              isActive: _currentNavIndex == 2, 
              onTap: () {
                setState(() {
                  _currentNavIndex = 2;
                  // Unread count is live via stream — no manual reload needed
                });
              },
              badge: _unreadCount > 0 ? '$_unreadCount' : null,
            ),
            _NavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profile', isActive: _currentNavIndex == 3, onTap: () => setState(() => _currentNavIndex = 3)),
          ]),
        ),
      ),
    );
  }
}

// Compact stat cell used inside the unified dashboard card
class _DashStat extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color color;
  final VoidCallback? onTap;
  const _DashStat({required this.icon, required this.label, required this.value, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: color.withAlpha(26),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: AppTextStyles.h4),
            Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          ]),
          if (onTap != null) ...[
            const Spacer(),
            Icon(Icons.chevron_right, size: 14, color: AppColors.textHint),
          ],
        ]),
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 36, color: AppColors.border, margin: const EdgeInsets.symmetric(horizontal: 12));
  }
}

// Bottom sheet shown when landlord taps a property-viewed or inquiry activity.
// Fetches the viewer's profile from Firestore and shows verification status.
// Message button is only active for verified tenants.
class _ViewerSheet extends StatefulWidget {
  final ActivityModel activity;
  final String landlordId;
  final String landlordName;
  final ConversationService conversationService;
  final PropertyService propertyService;

  const _ViewerSheet({
    required this.activity,
    required this.landlordId,
    required this.landlordName,
    required this.conversationService,
    required this.propertyService,
  });

  @override
  State<_ViewerSheet> createState() => _ViewerSheetState();
}

class _ViewerSheetState extends State<_ViewerSheet> {
  bool _isLoadingProfile = true;
  bool _isMessaging = false;
  Map<String, dynamic>? _viewerProfile;

  @override
  void initState() {
    super.initState();
    _loadViewerProfile();
  }

  Future<void> _loadViewerProfile() async {
    if (widget.activity.actorId == null) {
      setState(() => _isLoadingProfile = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.activity.actorId)
          .get();
      if (mounted) {
        setState(() {
          _viewerProfile = doc.data();
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingProfile = false);
    }
  }

  bool get _isVerified =>
      _viewerProfile?['verificationStatus'] == 'verified';

  Future<void> _startConversation() async {
    if (widget.activity.propertyId == null) return;
    setState(() => _isMessaging = true);
    try {
      final property = await widget.propertyService
          .getProperty(widget.activity.propertyId!);
      if (property == null || !mounted) {
        setState(() => _isMessaging = false);
        return;
      }
      final conv = await widget.conversationService.getOrCreateConversation(
        propertyId: property.id,
        propertyTitle: property.title,
        propertyImage: property.images.isNotEmpty ? property.images.first : '',
        landlordId: widget.landlordId,
        landlordName: widget.landlordName,
        tenantId: widget.activity.actorId!,
        tenantName: widget.activity.actorName ?? 'Tenant',
      );
      if (!mounted) return;
      Navigator.pop(context);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': property.title,
          'propertyImage': property.images.isNotEmpty ? property.images.first : null,
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isMessaging = false);
    }
  }

  Widget _buildTenantDetails() {
    final p = _viewerProfile!;
    final occupation = p['occupation'] as String?;
    final employer = p['employer'] as String?;
    final workMode = p['workMode'] as String?;
    final workplaceArea = p['workplaceArea'] as String?;
    final budgetMin = (p['budgetMin'] as num?)?.toDouble();
    final budgetMax = (p['budgetMax'] as num?)?.toDouble();
    final preferredAreas = (p['preferredAreas'] as List?)?.cast<String>();

    final hasDetails = occupation != null || employer != null ||
        workMode != null || budgetMin != null;

    if (!hasDetails) return const SizedBox.shrink();

    String? workModeLabel;
    if (workMode != null) {
      switch (workMode) {
        case 'remote': workModeLabel = 'Works remotely';
        case 'commute': workModeLabel = 'Commutes to work';
        case 'hybrid': workModeLabel = 'Hybrid (home & office)';
        default: workModeLabel = workMode;
      }
    }

    String? budgetLabel;
    if (budgetMin != null || budgetMax != null) {
      final min = budgetMin != null ? '₦${_formatAmount(budgetMin)}' : '';
      final max = budgetMax != null ? '₦${_formatAmount(budgetMax)}' : '';
      if (min.isNotEmpty && max.isNotEmpty) {
        budgetLabel = '$min – $max / year';
      } else if (max.isNotEmpty) {
        budgetLabel = 'Up to $max / year';
      } else {
        budgetLabel = 'From $min / year';
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tenant Profile', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (occupation != null)
            _detailRow(Icons.work_outline, 'Occupation', occupation),
          if (employer != null && employer.isNotEmpty)
            _detailRow(Icons.business_outlined, 'Employer', employer),
          if (workModeLabel != null)
            _detailRow(Icons.laptop_mac_outlined, 'Work Style', workModeLabel),
          if (workplaceArea != null && workplaceArea.isNotEmpty)
            _detailRow(Icons.location_on_outlined, 'Workplace', workplaceArea),
          if (budgetLabel != null)
            _detailRow(Icons.account_balance_wallet_outlined, 'Budget', budgetLabel),
          if (preferredAreas != null && preferredAreas.isNotEmpty)
            _detailRow(Icons.map_outlined, 'Preferred Areas', preferredAreas.join(', ')),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
                const SizedBox(height: 2),
                Text(value, style: AppTextStyles.bodySmall.copyWith(color: AppColors.textPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  @override
  Widget build(BuildContext context) {
    final isViewed = widget.activity.type == ActivityType.propertyViewed;
    final actorName = widget.activity.actorName ?? 'Unknown Tenant';
    final initial = actorName.isNotEmpty ? actorName[0].toUpperCase() : 'T';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),

          // Avatar + name + badge row
          Row(children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: AppColors.info.withAlpha(26),
              child: Text(initial,
                  style: AppTextStyles.h3.copyWith(color: AppColors.info)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(actorName, style: AppTextStyles.h4),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.info.withAlpha(20),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('Tenant',
                        style: AppTextStyles.labelSmall
                            .copyWith(color: AppColors.info)),
                  ),
                  const SizedBox(width: 8),
                  if (_isLoadingProfile)
                    Container(
                      width: 70, height: 20,
                      decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(10)),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _isVerified
                            ? AppColors.success.withAlpha(20)
                            : AppColors.warning.withAlpha(20),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                          _isVerified
                              ? Icons.verified_outlined
                              : Icons.warning_amber_outlined,
                          size: 12,
                          color: _isVerified
                              ? AppColors.success
                              : AppColors.warning,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _isVerified ? 'Verified' : 'Unverified',
                          style: AppTextStyles.labelSmall.copyWith(
                            color: _isVerified
                                ? AppColors.success
                                : AppColors.warning,
                          ),
                        ),
                      ]),
                    ),
                ]),
              ]),
            ),
          ]),
          const SizedBox(height: 20),

          // Activity context
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(
                isViewed ? Icons.visibility_outlined : Icons.chat_bubble_outline,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isViewed
                      ? 'Viewed "${widget.activity.propertyTitle ?? 'your property'}"'
                      : 'Enquired about "${widget.activity.propertyTitle ?? 'your property'}"',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ),
              Text(
                widget.activity.timeAgo,
                style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // Tenant profile details (if loaded)
          if (!_isLoadingProfile && _viewerProfile != null)
            _buildTenantDetails(),

          const SizedBox(height: 20),

          // Message button — disabled with explanation if unverified
          if (_isLoadingProfile)
            Container(
              height: 50,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(12)),
            )
          else if (_isVerified)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isMessaging ? null : _startConversation,
                icon: _isMessaging
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.chat_outlined, size: 18),
                label: Text(_isMessaging ? 'Opening chat...' : 'Send a Message'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.warning.withAlpha(60)),
              ),
              child: Row(children: [
                Icon(Icons.lock_outline,
                    size: 18, color: AppColors.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Messaging is only available for verified tenants. This tenant hasn\'t completed verification yet.',
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.warning, height: 1.5),
                  ),
                ),
              ]),
            ),
        ],
      ),
      ),
    );
  }
}

class _ActivityItem extends StatelessWidget {
  final IconData icon;
  final String title, subtitle, time;
  final Color color;
  final bool isUnread;
  const _ActivityItem({required this.icon, required this.title, required this.subtitle, required this.time, required this.color, this.isUnread = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUnread ? AppColors.primaryLight.withAlpha(26) : AppColors.surface, 
        borderRadius: BorderRadius.circular(12), 
        border: Border.all(color: isUnread ? AppColors.primary.withAlpha(77) : AppColors.border),
      ),
      child: Row(children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withAlpha(26), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppTextStyles.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (isUnread)
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: AppTextStyles.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        const SizedBox(width: 8),
        Text(time, style: AppTextStyles.caption),
      ]),
    );
  }
}

class _LandlordPropertyCard extends StatelessWidget {
  final PropertyModel property;
  final VoidCallback? onTap;
  final bool showActions;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleStatus;
  const _LandlordPropertyCard({required this.property, this.onTap, this.showActions = false, this.onDelete, this.onToggleStatus});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: property.images.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: property.images.first,
                  width: 80, height: 80, fit: BoxFit.cover,
                  memCacheWidth: 240,
                  errorWidget: (c, e, s) => Container(width: 80, height: 80, color: AppColors.background, child: Icon(Icons.image_not_supported, color: AppColors.textHint)),
                )
              : Container(width: 80, height: 80, color: AppColors.background, child: Icon(Icons.image_not_supported, color: AppColors.textHint)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(property.title, style: AppTextStyles.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text('${property.city}, ${property.state}', style: AppTextStyles.caption),
            const SizedBox(height: 8),
            Row(children: [
              Flexible(child: Text('${property.formattedRent}${property.rentPeriod}', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary), maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(color: property.isAvailable ? AppColors.successLight : AppColors.warningLight, borderRadius: BorderRadius.circular(4)),
                child: Text(property.isAvailable ? 'Available' : 'Occupied', style: AppTextStyles.labelSmall.copyWith(color: property.isAvailable ? AppColors.success : AppColors.warning, fontSize: 10)),
              ),
            ]),
          ])),
          if (showActions) PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: AppColors.textSecondary, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v == 'edit') {
                context.push('/landlord/edit-property/${property.id}');
              } else if (v == 'health') {
                context.push('/landlord/property-health', extra: property);
              } else if (v == 'rent_change') {
                context.push('/landlord/request-rent-change', extra: {
                  'propertyId': property.id,
                  'propertyTitle': property.title,
                  'currentRent': property.rent,
                  'landlordId': property.landlordId,
                  'landlordName': property.landlordName ?? '',
                });
              } else if (v == 'delete' && onDelete != null) {
                onDelete!();
              } else if (v == 'toggle' && onToggleStatus != null) {
                onToggleStatus!();
              }
            },
            itemBuilder: (c) => [
              const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_outlined, size: 20), SizedBox(width: 8), Text('Edit Property')])),
              const PopupMenuItem(value: 'health', child: Row(children: [Icon(Icons.monitor_heart_outlined, size: 20), SizedBox(width: 8), Text('Property Health')])),
              const PopupMenuItem(value: 'rent_change', child: Row(children: [Icon(Icons.price_change_outlined, size: 20), SizedBox(width: 8), Text('Request Rent Change')])),
              PopupMenuItem(value: 'toggle', child: Row(children: [Icon(property.isAvailable ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20), SizedBox(width: 8), Text(property.isAvailable ? 'Mark Occupied' : 'Mark Available')])),
              PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 20, color: AppColors.error), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.error))])),
            ],
          ),
        ]),
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  final IconData icon;
  final String value, label;
  final Color color;
  const _ProfileStat({required this.icon, required this.value, required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(height: 8),
      Text(value, style: AppTextStyles.h4),
      const SizedBox(height: 2),
      Text(label, style: AppTextStyles.caption),
    ]);
  }
}

class _ProfileSection extends StatelessWidget {
  final String title;
  final List<Widget> items;
  const _ProfileSection({required this.title, required this.items});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: AppTextStyles.labelLarge.copyWith(color: AppColors.textSecondary)),
      const SizedBox(height: 12),
      Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: Column(children: items.asMap().entries.map((e) => Column(children: [e.value, if (e.key < items.length - 1) Divider(height: 1, indent: 56, color: AppColors.border)])).toList()),
      ),
    ]);
  }
}

class _ProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  const _ProfileMenuItem({required this.icon, required this.title, required this.subtitle, this.trailing, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: AppColors.textPrimary, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppTextStyles.labelLarge),
            const SizedBox(height: 2),
            Text(subtitle, style: AppTextStyles.caption),
          ])),
          trailing ?? Icon(Icons.chevron_right, color: AppColors.textHint, size: 20),
        ]),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon, activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final String? badge;
  const _NavItem({required this.icon, required this.activeIcon, required this.label, required this.isActive, required this.onTap, this.badge});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(isActive ? activeIcon : icon, color: isActive ? AppColors.primary : AppColors.textHint, size: 24),
              if (badge != null)
                Positioned(
                  right: -8,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                    child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(label, style: AppTextStyles.labelSmall.copyWith(color: isActive ? AppColors.primary : AppColors.textHint, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
        ]),
      ),
    );
  }
}