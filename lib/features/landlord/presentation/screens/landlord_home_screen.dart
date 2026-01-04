import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/models/activity_model.dart';
import '../../../messaging/presentation/widgets/messages_tab_real.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/activity_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/widgets/verification_badge.dart';

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
  String _userInitial = '';
  bool _isLoadingProfile = true;
  VerificationStatus _verificationStatus = VerificationStatus.none;

  // Properties - now from Firestore
  List<PropertyModel> _myProperties = [];
  bool _isLoadingProperties = true;

  // Activities - now from Firestore
  List<ActivityModel> _recentActivities = [];
  bool _isLoadingActivities = true;

  // Unread message count
  int _unreadCount = 0;

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
    _loadUserProfile();
    _loadVerificationStatus();
    _loadProperties();
    _loadActivities();
    _loadUnreadCount();
  }

  Future<void> _loadUserProfile() async {
    try {
      final profile = await _authService.getUserProfile();
      if (profile != null && mounted) {
        setState(() {
          _userName = profile['fullName'] ?? 'Landlord';
          _userInitial = _userName.isNotEmpty ? _userName[0].toUpperCase() : 'L';
          _isLoadingProfile = false;
        });
      } else {
        setState(() {
          _userName = 'Landlord';
          _userInitial = 'L';
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      setState(() {
        _userName = 'Landlord';
        _userInitial = 'L';
        _isLoadingProfile = false;
      });
    }
  }

  Future<void> _loadVerificationStatus() async {
    try {
      final data = await _verificationService.getVerificationStatus();
      if (mounted) {
        setState(() => _verificationStatus = data.status);
      }
    } catch (e) {
      debugPrint('❌ Error loading verification: $e');
    }
  }

  Future<void> _loadProperties() async {
    try {
      final properties = await _propertyService.getLandlordProperties();
      if (mounted) {
        setState(() {
          _myProperties = properties;
          _isLoadingProperties = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading properties: $e');
      setState(() => _isLoadingProperties = false);
    }
  }

  Future<void> _loadActivities() async {
    try {
      final activities = await _activityService.getRecentActivities(limit: 10);
      if (mounted) {
        setState(() {
          _recentActivities = activities;
          _isLoadingActivities = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading activities: $e');
      setState(() => _isLoadingActivities = false);
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await _conversationService.getTotalUnreadCount();
      if (mounted) {
        setState(() => _unreadCount = count);
      }
    } catch (e) {
      debugPrint('❌ Error loading unread count: $e');
    }
  }

  Future<void> _refreshData() async {
    await Future.wait([
      _loadProperties(),
      _loadActivities(),
      _loadUnreadCount(),
    ]);
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
                          : Text('Hello, $_firstName 👋', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 4),
                      Text('Dashboard', style: AppTextStyles.h2),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _currentNavIndex = 3),
                  child: Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(color: AppColors.primaryLight.withAlpha(51), shape: BoxShape.circle),
                    child: Center(
                      child: _isLoadingProfile
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                          : Text(_userInitial, style: AppTextStyles.h4.copyWith(color: AppColors.primary)),
                    ),
                  ),
                ),
              ],
            ),

            // Verification prompt
            if (_verificationStatus != VerificationStatus.verified) ...[
              const SizedBox(height: 16),
              _buildVerificationPrompt(),
            ],

            const SizedBox(height: 24),

            // Stats cards
            Row(children: [
              Expanded(child: _StatCard(
                icon: Icons.home_outlined, 
                label: 'Properties', 
                value: _isLoadingProperties ? '...' : '${_myProperties.length}', 
                color: AppColors.primary,
              )),
              const SizedBox(width: 12),
              Expanded(child: _StatCard(
                icon: Icons.visibility_outlined, 
                label: 'Total Views', 
                value: _isLoadingActivities ? '...' : '$_totalViews', 
                color: AppColors.info,
              )),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _StatCard(
                icon: Icons.chat_bubble_outline, 
                label: 'Inquiries', 
                value: _isLoadingActivities ? '...' : '$_totalInquiries', 
                color: AppColors.warning,
              )),
              const SizedBox(width: 12),
              Expanded(child: _StatCard(
                icon: Icons.account_balance_wallet_outlined, 
                label: 'Earnings', 
                value: _totalEarnings > 0 ? 'NGN ${(_totalEarnings / 1000000).toStringAsFixed(1)}M' : 'NGN 0', 
                color: AppColors.success,
              )),
            ]),

            const SizedBox(height: 32),

            // Recent Activity section
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Recent Activity', style: AppTextStyles.h4),
              TextButton(
                onPressed: () => context.push('/landlord/activities'),
                child: Text('See all', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
              ),
            ]),
            const SizedBox(height: 12),

            // Activities - Real data
            _buildActivitiesSection(),

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

            const SizedBox(height: 80),
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
        child: const Center(
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

    // Show only first 3 activities on dashboard
    final displayActivities = _recentActivities.take(3).toList();

    return Column(
      children: displayActivities.map((activity) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GestureDetector(
          onTap: () => _onActivityTap(activity),
          child: _ActivityItem(
            icon: _getActivityIcon(activity.type),
            title: activity.title,
            subtitle: activity.subtitle,
            time: activity.timeAgo,
            color: _getActivityColor(activity.type),
            isUnread: !activity.isRead,
          ),
        ),
      )).toList(),
    );
  }

  Future<void> _onActivityTap(ActivityModel activity) async {
    // Mark as read
    await _activityService.markAsRead(activity.id);
    
    // Refresh activities to update UI
    _loadActivities();

    if (!mounted) return;

    // Navigate to property if available
    if (activity.propertyId != null) {
      final property = await _propertyService.getProperty(activity.propertyId!);
      if (property != null && mounted) {
        context.push('/property-detail', extra: property);
      }
    }
  }

  IconData _getActivityIcon(ActivityType type) {
    switch (type) {
      case ActivityType.propertyAdded:
        return Icons.home_outlined;
      case ActivityType.propertyViewed:
        return Icons.visibility_outlined;
      case ActivityType.inquiry:
        return Icons.chat_bubble_outline;
      case ActivityType.payment:
        return Icons.payments_outlined;
    }
  }

  Color _getActivityColor(ActivityType type) {
    switch (type) {
      case ActivityType.propertyAdded:
        return AppColors.primary;
      case ActivityType.propertyViewed:
        return AppColors.info;
      case ActivityType.inquiry:
        return AppColors.warning;
      case ActivityType.payment:
        return AppColors.success;
    }
  }

  Widget _buildPropertiesPreview() {
    if (_isLoadingProperties) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (_myProperties.isEmpty) {
      return Container(
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
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _myProperties.isEmpty
                ? _buildEmptyProperties()
                : RefreshIndicator(
                    onRefresh: _loadProperties,
                    color: AppColors.primary,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
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
      _loadProperties();
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
    _loadProperties();
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
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 100, 
        height: 100, 
        decoration: BoxDecoration(color: AppColors.primaryLight.withAlpha(26), shape: BoxShape.circle), 
        child: const Icon(Icons.home_outlined, size: 50, color: AppColors.primary),
      ),
      const SizedBox(height: 24),
      Text('No properties yet', style: AppTextStyles.h4),
      const SizedBox(height: 8),
      Text('Add your first property to start\nreceiving tenant inquiries', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary), textAlign: TextAlign.center),
    ]));
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
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Profile', style: AppTextStyles.h3.copyWith(color: Colors.white)),
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
                Container(
                  width: 90, height: 90,
                  decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 20, offset: const Offset(0, 10))]),
                  child: Center(child: _isLoadingProfile ? const CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2) : Text(_userInitial, style: AppTextStyles.h2.copyWith(color: AppColors.primary))),
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
                Expanded(child: _ProfileStat(icon: Icons.star_outline, value: '4.8', label: 'Rating', color: AppColors.warning)),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _ProfileSection(title: 'Account', items: [
              _ProfileMenuItem(icon: Icons.person_outline, title: 'Edit Profile', subtitle: 'Update your personal information', onTap: () => context.push('/edit-profile')),
              _ProfileMenuItem(
                icon: Icons.account_balance_outlined,
                title: 'Bank Details',
                subtitle: 'Manage your payout account',
                onTap: () => context.push('/landlord/bank-details'),
              ),
              _ProfileMenuItem(icon: Icons.security_outlined, title: 'Verification', subtitle: _getVerificationSubtitle(), trailing: VerificationBadge(status: _verificationStatus, showLabel: true), onTap: () => context.push('/landlord/verification').then((_) => _loadVerificationStatus())),
            ]),
            const SizedBox(height: 24),
            _ProfileSection(title: 'Finances', items: [
              _ProfileMenuItem(icon: Icons.account_balance_wallet_outlined, title: 'Earnings & Transactions', subtitle: _totalEarnings > 0 ? 'NGN ${(_totalEarnings / 1000000).toStringAsFixed(1)}M total' : 'View your earnings and payment history', onTap: () => context.push('/landlord/earnings')),
            ]),
            const SizedBox(height: 24),
            _ProfileSection(title: 'Preferences', items: [
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
            // Only show Admin section for your account
            if (_authService.currentUser?.uid == 'hEKsYuKKdzLlPD0QWOP2CvAxYlq2') ...[
              const SizedBox(height: 24),
              _ProfileSection(title: 'Admin', items: [
                _ProfileMenuItem(icon: Icons.admin_panel_settings_outlined, title: 'Review Verifications', subtitle: 'Approve or reject landlord verifications', onTap: () => context.push('/admin/verifications')),
              ]),
            ],
            const SizedBox(height: 16),
            Center(child: Text('Member since November 2024', style: AppTextStyles.caption.copyWith(color: AppColors.textHint))),
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
                  _loadUnreadCount();
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

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color color;
  const _StatCard({required this.icon, required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withAlpha(26), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color, size: 20)),
        const SizedBox(height: 12),
        Text(value, style: AppTextStyles.h3),
        const SizedBox(height: 4),
        Text(label, style: AppTextStyles.caption),
      ]),
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
                  decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
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
            child: Image.network(
              property.images.isNotEmpty ? property.images.first : 'https://via.placeholder.com/100', 
              width: 80, height: 80, fit: BoxFit.cover,
              errorBuilder: (c, e, s) => Container(width: 80, height: 80, color: AppColors.background, child: const Icon(Icons.image_not_supported, color: AppColors.textHint)),
            ),
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
            icon: const Icon(Icons.more_vert, color: AppColors.textSecondary, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v == 'delete' && onDelete != null) {
                onDelete!();
              } else if (v == 'toggle' && onToggleStatus != null) {
                onToggleStatus!();
              }
            },
            itemBuilder: (c) => [
              const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_outlined, size: 20), SizedBox(width: 8), Text('Edit')])),
              PopupMenuItem(value: 'toggle', child: Row(children: [Icon(property.isAvailable ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20), SizedBox(width: 8), Text(property.isAvailable ? 'Mark Occupied' : 'Mark Available')])),
              const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 20, color: AppColors.error), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.error))])),
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
          trailing ?? const Icon(Icons.chevron_right, color: AppColors.textHint, size: 20),
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