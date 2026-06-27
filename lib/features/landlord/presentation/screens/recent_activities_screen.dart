import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/activity_model.dart';
import '../../../../services/activity_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/conversation_service.dart';

class RecentActivitiesScreen extends StatefulWidget {
  const RecentActivitiesScreen({super.key});

  @override
  State<RecentActivitiesScreen> createState() => _RecentActivitiesScreenState();
}

class _RecentActivitiesScreenState extends State<RecentActivitiesScreen> {
  final ActivityService _activityService = ActivityService();
  final AuthService _authService = AuthService();
  final PropertyService _propertyService = PropertyService();
  final ConversationService _conversationService = ConversationService();

  List<ActivityModel> _activities = [];
  List<Map<String, dynamic>> _announcements = [];
  bool _isLoading = true;
  bool _isLoadingAnnouncements = true;
  bool _showAllAnnouncements = false;
  static const int _announcementsPreviewCount = 2;

  @override
  void initState() {
    super.initState();
    _loadActivities();
    _loadAnnouncements();
  }

  Future<void> _loadActivities() async {
    try {
      final activities = await _activityService.getAllActivities();
      if (mounted) {
        setState(() {
          _activities = activities;
          _isLoading = false;
        });
      }
      _activityService.markAllAsRead();
    } catch (e) {
      debugPrint('❌ Error loading activities: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadAnnouncements() async {
    try {
      final userId = _authService.currentUserId;
      if (userId == null) {
        if (mounted) setState(() => _isLoadingAnnouncements = false);
        return;
      }

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final accountType = userDoc.data()?['accountType'] ?? '';

      final snap = await FirebaseFirestore.instance
          .collection('announcements')
          .orderBy('createdAt', descending: true)
          .get();

      final filtered = snap.docs.where((doc) {
        final data = doc.data();
        final targetType = data['targetType'] ?? 'all';
        final targetIds = List<String>.from(data['targetIds'] ?? []);
        return targetType == 'all' ||
            targetType == accountType ||
            targetIds.contains(userId);
      }).map((doc) => {'id': doc.id, ...doc.data()}).toList();

      if (mounted) {
        setState(() {
          _announcements = filtered;
          _isLoadingAnnouncements = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading announcements: $e');
      if (mounted) setState(() => _isLoadingAnnouncements = false);
    }
  }

  Future<void> _onActivityTap(ActivityModel activity) async {
    await _activityService.markAsRead(activity.id);
    if (!mounted) return;

    if (activity.type == ActivityType.issueReported ||
        activity.type == ActivityType.issueDisputed ||
        activity.type == ActivityType.issueConfirmed) {
      context.push('/landlord/issues');
      return;
    }

    // Inspection activities — go to inspections screen
    if (activity.type == ActivityType.inspectionRequest ||
        activity.type == ActivityType.inspectionApproved ||
        activity.type == ActivityType.inspectionDeclined ||
        activity.type == ActivityType.inspectionCompleted ||
        activity.type == ActivityType.inspectionRated ||
        activity.type == ActivityType.payoutReceived) {
      context.push('/landlord/inspections');
      return;
    }

    // Property views and inquiries — show viewer info sheet (same as home screen)
    if ((activity.type == ActivityType.propertyViewed ||
            activity.type == ActivityType.inquiry) &&
        activity.actorId != null) {
      _showViewerSheet(activity);
      return;
    }

    if (activity.propertyId != null) {
      final property =
          await _propertyService.getProperty(activity.propertyId!);
      if (property != null && mounted) {
        context.push('/property-detail', extra: property);
      }
    }
  }

  void _showViewerSheet(ActivityModel activity) {
    final currentUserId = _authService.currentUserId ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ViewerInfoSheet(
        activity: activity,
        landlordId: currentUserId,
        conversationService: _conversationService,
        propertyService: _propertyService,
      ),
    );
  }

  Future<void> _refresh() async {
    await Future.wait([_loadActivities(), _loadAnnouncements()]);
  }

  bool get _isEverythingEmpty =>
      !_isLoading &&
      !_isLoadingAnnouncements &&
      _activities.isEmpty &&
      _announcements.isEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Notifications', style: AppTextStyles.h4),
        centerTitle: true,
        actions: [
          if (_activities.isNotEmpty)
            TextButton(
              onPressed: () async {
                await _activityService.markAllAsRead();
                setState(() {
                  _activities =
                      _activities.map((a) => a.copyWith(isRead: true)).toList();
                });
              },
              child: Text(
                'Mark all read',
                style: AppTextStyles.labelMedium
                    .copyWith(color: AppColors.primary),
              ),
            ),
        ],
      ),
      body: (_isLoading || _isLoadingAnnouncements)
          ? Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : _isEverythingEmpty
              ? const GuidanceEmptyState(
                  icon: Icons.notifications_none_outlined,
                  title: 'No notifications yet',
                  subtitle:
                      'Announcements from ClearRent and activity from your '
                      'properties will appear here.',
                )
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.primary,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Announcements ──────────────────────────────────────────
          if (_announcements.isNotEmpty) ...[
            _SectionHeader(
                title: 'Announcements', count: _announcements.length),
            const SizedBox(height: 12),
            ...(_showAllAnnouncements
                    ? _announcements
                    : _announcements.take(_announcementsPreviewCount).toList())
                .map((a) => _AnnouncementCard(data: a)),
            if (_announcements.length > _announcementsPreviewCount) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(
                    () => _showAllAnnouncements = !_showAllAnnouncements),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _showAllAnnouncements
                            ? 'Show less'
                            : 'View ${_announcements.length - _announcementsPreviewCount} more',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.primary),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _showAllAnnouncements ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.keyboard_arrow_down,
                            size: 18, color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
          ],

          // ── Activity ───────────────────────────────────────────────
          if (_activities.isNotEmpty) ...[
            _SectionHeader(
                title: 'Recent Activity', count: _activities.length),
            const SizedBox(height: 12),
            ...() {
              final grouped = <String, List<ActivityModel>>{};
              for (final activity in _activities) {
                final key = _getDateKey(activity.createdAt);
                grouped.putIfAbsent(key, () => []);
                grouped[key]!.add(activity);
              }
              return grouped.entries.expand((entry) => [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8, top: 4),
                      child: Text(
                        entry.key,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textHint),
                      ),
                    ),
                    ...entry.value.map((activity) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ActivityCard(
                            activity: activity,
                            onTap: () => _onActivityTap(activity),
                          ),
                        )),
                  ]);
            }(),
          ],
        ],
      ),
    );
  }

  String _getDateKey(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final activityDate = DateTime(date.year, date.month, date.day);

    if (activityDate == today) return 'Today';
    if (activityDate == yesterday) return 'Yesterday';
    if (now.difference(date).inDays < 7) return _weekdayName(date.weekday);
    return '${date.day}/${date.month}/${date.year}';
  }

  String _weekdayName(int weekday) {
    const names = [
      '', 'Monday', 'Tuesday', 'Wednesday',
      'Thursday', 'Friday', 'Saturday', 'Sunday'
    ];
    return names[weekday];
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _SectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: AppTextStyles.labelMedium
              .copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(20),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Announcement Card — collapsible ─────────────────────────────────────────

class _AnnouncementCard extends StatefulWidget {
  final Map<String, dynamic> data;

  const _AnnouncementCard({required this.data});

  @override
  State<_AnnouncementCard> createState() => _AnnouncementCardState();
}

class _AnnouncementCardState extends State<_AnnouncementCard> {
  bool _expanded = false;

  Color _color(String type) {
    switch (type) {
      case 'warning': return AppColors.warning;
      case 'success': return AppColors.success;
      case 'alert':   return AppColors.error;
      default:        return AppColors.info;
    }
  }

  IconData _icon(String type) {
    switch (type) {
      case 'warning': return Icons.warning_amber_rounded;
      case 'success': return Icons.check_circle_outline;
      case 'alert':   return Icons.notification_important_outlined;
      default:        return Icons.info_outline;
    }
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1)  return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    if (diff.inDays < 7)     return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final type = (widget.data['type'] ?? 'info') as String;
    final color = _color(type);
    final ts = widget.data['createdAt'];
    final date = ts is Timestamp ? ts.toDate() : null;
    final body = (widget.data['body'] ?? '') as String;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(_expanded ? 20 : 12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(_expanded ? 60 : 35)),
        ),
        child: Column(
          children: [
            // Header — always visible
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color.withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(_icon(type), color: color, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (widget.data['title'] ?? '') as String,
                          style: AppTextStyles.labelMedium,
                        ),
                        if (date != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            _timeAgo(date),
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.textHint),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
            ),

            // Body — only when expanded
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _expanded && body.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Divider(height: 1, color: color.withAlpha(40)),
                          const SizedBox(height: 10),
                          Text(
                            body,
                            style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.textSecondary,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Activity Card ────────────────────────────────────────────────────────────

class _ActivityCard extends StatelessWidget {
  final ActivityModel activity;
  final VoidCallback onTap;

  const _ActivityCard({required this.activity, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: activity.isRead
              ? AppColors.surface
              : AppColors.primaryLight.withAlpha(26),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: activity.isRead
                ? AppColors.border
                : AppColors.primary.withAlpha(77),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _getColor().withAlpha(26),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_getIcon(), color: _getColor(), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          activity.title,
                          style: AppTextStyles.labelLarge.copyWith(
                            fontWeight: activity.isRead
                                ? FontWeight.w500
                                : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!activity.isRead)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    activity.subtitle,
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  activity.timeAgo,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint),
                ),
                const SizedBox(height: 4),
                Icon(Icons.chevron_right,
                    color: AppColors.textHint, size: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIcon() {
    switch (activity.type) {
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

  Color _getColor() {
    switch (activity.type) {
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
}

// ─── Viewer Info Sheet (matches landlord home screen behavior) ────────────────

class _ViewerInfoSheet extends StatefulWidget {
  final ActivityModel activity;
  final String landlordId;
  final ConversationService conversationService;
  final PropertyService propertyService;

  const _ViewerInfoSheet({
    required this.activity,
    required this.landlordId,
    required this.conversationService,
    required this.propertyService,
  });

  @override
  State<_ViewerInfoSheet> createState() => _ViewerInfoSheetState();
}

class _ViewerInfoSheetState extends State<_ViewerInfoSheet> {
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
        landlordName: 'You',
        tenantId: widget.activity.actorId!,
        tenantName: widget.activity.actorName ?? 'Tenant',
      );
      if (!mounted) return;
      Navigator.pop(context);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': property.title,
          'propertyImage':
              property.images.isNotEmpty ? property.images.first : null,
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isMessaging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20, 20, 20, MediaQuery.of(context).padding.bottom + 20,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: _isLoadingProfile
          ? SizedBox(
              height: 120,
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: AppColors.primary.withAlpha(26),
                      child: Text(
                        (widget.activity.actorName ?? 'U')[0].toUpperCase(),
                        style: AppTextStyles.h4
                            .copyWith(color: AppColors.primary),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.activity.actorName ?? 'Unknown',
                            style: AppTextStyles.labelLarge,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (_isVerified)
                                Row(children: [
                                  Icon(Icons.verified,
                                      size: 14, color: AppColors.success),
                                  const SizedBox(width: 4),
                                  Text('Verified',
                                      style: AppTextStyles.caption
                                          .copyWith(color: AppColors.success)),
                                ])
                              else
                                Text('Not verified',
                                    style: AppTextStyles.caption
                                        .copyWith(color: AppColors.textHint)),
                              const SizedBox(width: 8),
                              Text('•',
                                  style: AppTextStyles.caption
                                      .copyWith(color: AppColors.textHint)),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  widget.activity.subtitle,
                                  style: AppTextStyles.caption
                                      .copyWith(color: AppColors.textSecondary),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // Tenant details from profile
                if (_viewerProfile != null) ...[
                  const SizedBox(height: 16),
                  _buildProfileDetails(),
                ],

                const SizedBox(height: 20),

                // Message button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isMessaging ? null : _startConversation,
                    icon: _isMessaging
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.chat_bubble_outline),
                    label: Text(_isMessaging
                        ? 'Opening chat...'
                        : 'Message ${widget.activity.actorName ?? "Tenant"}'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildProfileDetails() {
    final p = _viewerProfile!;
    final occupation = p['occupation'] as String?;
    final employer = p['employer'] as String?;
    final workMode = p['workMode'] as String?;
    final workplaceArea = p['workplaceArea'] as String?;
    final budgetMin = (p['budgetMin'] as num?)?.toDouble();
    final budgetMax = (p['budgetMax'] as num?)?.toDouble();
    final preferredAreas = (p['preferredAreas'] as List?)?.cast<String>();

    final hasDetails =
        occupation != null || employer != null || budgetMin != null;
    if (!hasDetails) return const SizedBox.shrink();

    String? workModeLabel;
    if (workMode != null) {
      switch (workMode) {
        case 'remote':
          workModeLabel = 'Works remotely';
        case 'commute':
          workModeLabel = 'Commutes to work';
        case 'hybrid':
          workModeLabel = 'Hybrid (home & office)';
        default:
          workModeLabel = workMode;
      }
    }

    String? budgetLabel;
    if (budgetMin != null || budgetMax != null) {
      final min = budgetMin != null ? '₦${_fmtAmt(budgetMin)}' : '';
      final max = budgetMax != null ? '₦${_fmtAmt(budgetMax)}' : '';
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
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tenant Profile',
              style: AppTextStyles.labelMedium
                  .copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 10),
          if (occupation != null)
            _infoRow(Icons.work_outline, 'Occupation', occupation),
          if (employer != null && employer.isNotEmpty)
            _infoRow(Icons.business_outlined, 'Employer', employer),
          if (workModeLabel != null)
            _infoRow(
                Icons.laptop_mac_outlined, 'Work Style', workModeLabel),
          if (workplaceArea != null && workplaceArea.isNotEmpty)
            _infoRow(
                Icons.location_on_outlined, 'Workplace', workplaceArea),
          if (budgetLabel != null)
            _infoRow(Icons.account_balance_wallet_outlined, 'Budget',
                budgetLabel),
          if (preferredAreas != null && preferredAreas.isNotEmpty)
            _infoRow(Icons.map_outlined, 'Preferred Areas',
                preferredAreas.join(', ')),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint)),
                const SizedBox(height: 2),
                Text(value, style: AppTextStyles.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtAmt(double amount) {
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