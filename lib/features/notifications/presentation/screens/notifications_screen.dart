import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
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
          final payload = m['payload'] as Map<String, dynamic>?;
          final route = payload?['route'] as String?;
          return _InboxItem(
            id: d.id,
            kind: _ItemKind.notification,
            title: (m['title'] as String?) ?? '',
            body: (m['body'] as String?) ?? '',
            createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
            read: (m['read'] as bool?) ?? false,
            route: (route != null && route.isNotEmpty) ? route : null,
            payload: payload,
            unreadCount: (m['unreadCount'] as num?)?.toInt() ?? 0,
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
        // Chat rows accumulate this until opened. Clearing it here is what
        // makes the next message start counting from one again, rather than
        // continuing from a number the user has already seen.
        'unreadCount': 0,
      });
    } catch (e) {
      AppLogger.e('Failed to mark notification read', error: e,
          name: 'NotificationsScreen');
    }
  }

  /// Open a notification/announcement in a detail sheet: full body (no
  /// truncation) plus a deep-link button when the payload carries a route.
  /// Marks unread notifications read on open.
  void _openDetail(_InboxItem item) {
    if (item.kind == _ItemKind.notification && !item.read) {
      _markNotificationRead(item.id);
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const SizedBox(height: 16),
                Text(item.title, style: AppTextStyles.h4),
                const SizedBox(height: 6),
                Text(
                  _InboxRow._relativeTime(item.createdAt),
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      item.body,
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: AppColors.textPrimary),
                    ),
                  ),
                ),
                if (item.route != null) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        // push (not go) so the target keeps a back stack —
                        // go replaces the stack and strands the user with a
                        // dead back button.
                        context.push(item.route!, extra: item.payload);
                      },
                      child: Text(
                        _actionLabel(item.route!),
                        style: AppTextStyles.labelMedium
                            .copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Friendly label for the deep-link button, derived from the route.
  static String _actionLabel(String route) {
    if (route.contains('my-rentals')) return 'Go to My Rentals';
    if (route.contains('tenant/home')) return 'Go to My Tenancy';
    if (route.contains('inspections')) return 'View Inspections';
    if (route.contains('chat')) return 'Open Chat';
    if (route.contains('documents')) return 'View Documents';
    if (route.contains('property')) return 'View Property';
    if (route.contains('landlord/rentals')) return 'Go to My Rentals';
    return 'View details';
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
              ? const GuidanceEmptyState(
                  icon: Icons.notifications_none_outlined,
                  title: 'No notifications yet',
                  subtitle:
                      'Announcements from ClearRent and event updates will '
                      'appear here.',
                )
              : _buildList(merged),
    );
  }

  Widget _buildList(List<_InboxItem> items) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: items.length + (_hasMoreNotifications ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
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
          onTap: () => _openDetail(items[i]),
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
  // Deep-link route from the notification payload (e.g. /tenant/my-rentals).
  // Null for announcements and notifications with no destination.
  final String? route;
  // Full payload, passed as go_router `extra` on navigation so param-bearing
  // routes (e.g. /chat needs conversationId) get what they require.
  final Map<String, dynamic>? payload;

  /// Messages stacked up behind this row. Chat notifications are one rolling
  /// doc per conversation, so a burst arrives as a count rather than as one
  /// row per message. 0 or 1 means there is nothing extra to say.
  final int unreadCount;

  _InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.read,
    this.announcementType,
    this.route,
    this.payload,
    this.unreadCount = 0,
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
                      // Chat rows stand for a whole conversation, so the
                      // messages behind this one are shown as a count instead
                      // of as their own rows.
                      if (!item.read && item.unreadCount > 1) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            item.unreadCount > 99
                                ? '99+'
                                : '${item.unreadCount}',
                            style: AppTextStyles.caption.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
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