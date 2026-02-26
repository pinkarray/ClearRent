import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/activity_model.dart';
import '../../../../services/activity_service.dart';
import '../../../../services/property_service.dart';

class RecentActivitiesScreen extends StatefulWidget {
  const RecentActivitiesScreen({super.key});

  @override
  State<RecentActivitiesScreen> createState() => _RecentActivitiesScreenState();
}

class _RecentActivitiesScreenState extends State<RecentActivitiesScreen> {
  final ActivityService _activityService = ActivityService();
  final PropertyService _propertyService = PropertyService();
  
  List<ActivityModel> _activities = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadActivities();
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
      // Mark all as read when viewing
      _activityService.markAllAsRead();
    } catch (e) {
      debugPrint('❌ Error loading activities: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onActivityTap(ActivityModel activity) async {
    await _activityService.markAsRead(activity.id);
    if (!mounted) return;

    // Issue activities — go to issues screen so landlord can act
    if (activity.type == ActivityType.issueReported ||
        activity.type == ActivityType.issueDisputed ||
        activity.type == ActivityType.issueConfirmed) {
      context.push('/landlord/issues');
      return;
    }

    // All other types — navigate to the property detail
    if (activity.propertyId != null) {
      final property = await _propertyService.getProperty(activity.propertyId!);
      if (property != null && mounted) {
        context.push('/property-detail', extra: property);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Recent Activity', style: AppTextStyles.h4),
        centerTitle: true,
        actions: [
          if (_activities.isNotEmpty)
            TextButton(
              onPressed: () async {
                await _activityService.markAllAsRead();
                setState(() {
                  _activities = _activities.map((a) => a.copyWith(isRead: true)).toList();
                });
              },
              child: Text(
                'Mark all read',
                style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _activities.isEmpty
              ? _buildEmptyState()
              : _buildActivityList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications_none_outlined,
              size: 50,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No activity yet',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'When tenants view or inquire about\nyour properties, you\'ll see it here',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActivityList() {
    // Group activities by date
    final groupedActivities = <String, List<ActivityModel>>{};
    
    for (final activity in _activities) {
      final dateKey = _getDateKey(activity.createdAt);
      groupedActivities.putIfAbsent(dateKey, () => []);
      groupedActivities[dateKey]!.add(activity);
    }

    return RefreshIndicator(
      onRefresh: _loadActivities,
      color: AppColors.primary,
      child: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: groupedActivities.length,
        itemBuilder: (context, index) {
          final dateKey = groupedActivities.keys.elementAt(index);
          final activities = groupedActivities[dateKey]!;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (index > 0) const SizedBox(height: 24),
              
              // Date header
              Text(
                dateKey,
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),

              // Activities for this date
              ...activities.map((activity) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ActivityCard(
                  activity: activity,
                  onTap: () => _onActivityTap(activity),
                ),
              )),
            ],
          );
        },
      ),
    );
  }

  String _getDateKey(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final activityDate = DateTime(date.year, date.month, date.day);

    if (activityDate == today) {
      return 'Today';
    } else if (activityDate == yesterday) {
      return 'Yesterday';
    } else if (now.difference(date).inDays < 7) {
      return _getWeekdayName(date.weekday);
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String _getWeekdayName(int weekday) {
    switch (weekday) {
      case 1: return 'Monday';
      case 2: return 'Tuesday';
      case 3: return 'Wednesday';
      case 4: return 'Thursday';
      case 5: return 'Friday';
      case 6: return 'Saturday';
      case 7: return 'Sunday';
      default: return '';
    }
  }
}

class _ActivityCard extends StatelessWidget {
  final ActivityModel activity;
  final VoidCallback onTap;

  const _ActivityCard({
    required this.activity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: activity.isRead ? AppColors.surface : AppColors.primaryLight.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: activity.isRead ? AppColors.border : AppColors.primary.withAlpha(77),
          ),
        ),
        child: Row(
          children: [
            // Icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _getColor().withAlpha(26),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _getIcon(),
                color: _getColor(),
                size: 22,
              ),
            ),
            const SizedBox(width: 12),

            // Content
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
                            fontWeight: activity.isRead ? FontWeight.w500 : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!activity.isRead)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    activity.subtitle,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),

            // Time
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  activity.timeAgo,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textHint,
                  ),
                ),
                const SizedBox(height: 4),
                Icon(
                  Icons.chevron_right,
                  color: AppColors.textHint,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIcon() {
    switch (activity.type) {
      case ActivityType.propertyAdded:   return Icons.home_outlined;
      case ActivityType.propertyViewed:  return Icons.visibility_outlined;
      case ActivityType.inquiry:         return Icons.chat_bubble_outline;
      case ActivityType.payment:         return Icons.payments_outlined;
      case ActivityType.issueReported:   return Icons.report_problem_outlined;
      case ActivityType.issueDisputed:   return Icons.warning_amber_outlined;
      case ActivityType.issueConfirmed:  return Icons.check_circle_outline;
    }
  }

  Color _getColor() {
    switch (activity.type) {
      case ActivityType.propertyAdded:   return AppColors.primary;
      case ActivityType.propertyViewed:  return AppColors.info;
      case ActivityType.inquiry:         return AppColors.warning;
      case ActivityType.payment:         return AppColors.success;
      case ActivityType.issueReported:   return AppColors.error;
      case ActivityType.issueDisputed:   return AppColors.error;
      case ActivityType.issueConfirmed:  return AppColors.success;
    }
  }
}