import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/app_logger.dart';

/// Inbox screen — merges `notifications` and `announcements` collections,
/// ordered newest-first.
///
/// - Notifications: per-user, with `read: bool`. Tap to mark read.
/// - Announcements: broadcasts, with per-user dismissal via
///   `users/{uid}.dismissedAnnouncements`. Tap a dismiss icon to dismiss.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  static const int _pageSize = 50;

  StreamSubscription? _notifSub;
  StreamSubscription? _announceSub;

  List<_InboxItem> _notifications = [];
  List<_InboxItem> _announcements = [];
  Set<String> _dismissedAnnouncements = {};
  DateTime _userJoinedAt = DateTime(2000);
  String _accountType = 'tenant';

  bool _ready = false;
  bool _loadingMore = false;
  bool _hasMoreNotifications = true;
  int _notifLimit = _pageSize;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final uid = _uid;
    if (uid == null) {
      setState(() => _ready = true);
      return;
    }

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = userDoc.data() ?? {};
      _userJoinedAt =
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime(2000);
      _accountType = (data['accountType'] as String?) ?? 'tenant';
      _dismissedAnnouncements =
          Set<String>.from(data['dismissedAnnouncements'] ?? []);
    } catch (e) {
      AppLogger.e('Failed to load user data', error: e,
          name: 'NotificationsScreen');
    }

    _subscribeNotifications();
    _subscribeAnnouncements();
  }

  void _subscribeNotifications() {
    final uid = _uid;
    if (uid == null) return;

    _notifSub?.cancel();
    _notifSub = FirebaseFirestore.instance
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(_notifLimit)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _notifications = snap.docs.map((d) {
          final m = d.data();
          return _InboxItem(
            id: d.id,
            kind: _ItemKind.notification,
            title: (m['title'] as String?) ?? '',
            body: (m['body'] as String?) ?? '',
            createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
            read: (m['read'] as bool?) ?? false,
          );
        }).toList();
        _hasMoreNotifications = snap.docs.length >= _notifLimit;
        _ready = true;
        _loadingMore = false;
      });
    }, onError: (e) {
      AppLogger.e('Notifications stream error', error: e,
          name: 'NotificationsScreen');
      if (mounted) setState(() => _ready = true);
    });
  }

  void _subscribeAnnouncements() {
    _announceSub?.cancel();
    _announceSub = FirebaseFirestore.instance
        .collection('announcements')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final filtered = snap.docs.where((doc) {
        final d = doc.data();
        final createdAt = (d['createdAt'] as Timestamp?)?.toDate();
        if (createdAt != null && createdAt.isBefore(_userJoinedAt)) {
          return false;
        }
        final targetType = d['targetType'] ?? 'all';
        final targetIds = List<String>.from(d['targetIds'] ?? []);
        return targetType == 'all' ||
            targetType == _accountType ||
            (_uid != null && targetIds.contains(_uid));
      }).map((d) {
        final m = d.data();
        return _InboxItem(
          id: d.id,
          kind: _ItemKind.announcement,
          title: (m['title'] as String?) ?? '',
          body: (m['body'] as String?) ?? '',
          createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
          read: _dismissedAnnouncements.contains(d.id),
          announcementType: (m['type'] as String?) ?? 'info',
        );
      }).toList();
      setState(() => _announcements = filtered);
    });
  }

  void _loadMore() {
    if (_loadingMore || !_hasMoreNotifications) return;
    setState(() {
      _loadingMore = true;
      _notifLimit += _pageSize;
    });
    _subscribeNotifications();
  }

  Future<void> _markNotificationRead(String id) async {
    try {
      await FirebaseFirestore.instance
          .collection('notifications')
          .doc(id)
          .update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      AppLogger.e('Failed to mark notification read', error: e,
          name: 'NotificationsScreen');
    }
  }

  Future<void> _dismissAnnouncement(String id) async {
    final uid = _uid;
    if (uid == null) return;
    setState(() => _dismissedAnnouncements = {..._dismissedAnnouncements, id});
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'dismissedAnnouncements': FieldValue.arrayUnion([id]),
      });
    } catch (e) {
      AppLogger.e('Failed to persist announcement dismissal',
          error: e, name: 'NotificationsScreen');
    }
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _announceSub?.cancel();
    super.dispose();
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final merged = [..._notifications, ..._announcements]
      ..sort((a, b) {
        final ad = a.createdAt ?? DateTime(2000);
        final bd = b.createdAt ?? DateTime(2000);
        return bd.compareTo(ad);
      });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text('Notifications', style: AppTextStyles.h4),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      body: !_ready
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : merged.isEmpty
              ? _buildEmptyState()
              : _buildList(merged),
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
            child: Icon(
              Icons.notifications_none_outlined,
              size: 50,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text('No notifications yet', style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            'Announcements from ClearRent and event\nupdates will appear here.',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<_InboxItem> items) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: items.length + (_hasMoreNotifications ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i == items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loadingMore
                  ? CircularProgressIndicator(color: AppColors.primary)
                  : TextButton(
                      onPressed: _loadMore,
                      child: Text(
                        'Load more',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.primary),
                      ),
                    ),
            ),
          );
        }
        return _InboxRow(
          item: items[i],
          onTap: () {
            if (items[i].kind == _ItemKind.notification && !items[i].read) {
              _markNotificationRead(items[i].id);
            }
          },
          onDismiss: items[i].kind == _ItemKind.announcement
              ? () => _dismissAnnouncement(items[i].id)
              : null,
        );
      },
    );
  }
}

// ─── Internal models / widgets ──────────────────────────────────────────────

enum _ItemKind { notification, announcement }

class _InboxItem {
  final String id;
  final _ItemKind kind;
  final String title;
  final String body;
  final DateTime? createdAt;
  final bool read;
  final String? announcementType;

  _InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.read,
    this.announcementType,
  });
}

class _InboxRow extends StatelessWidget {
  final _InboxItem item;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  const _InboxRow({
    required this.item,
    required this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isAnnouncement = item.kind == _ItemKind.announcement;
    final showUnreadDot = !item.read;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 6, right: 10),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: showUnreadDot
                    ? AppColors.primary
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: showUnreadDot
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isAnnouncement) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight.withAlpha(40),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'ClearRent',
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.primary),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.body,
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _relativeTime(item.createdAt),
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                  ),
                ],
              ),
            ),
            if (onDismiss != null)
              GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close,
                      size: 16, color: AppColors.textHint),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _relativeTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}