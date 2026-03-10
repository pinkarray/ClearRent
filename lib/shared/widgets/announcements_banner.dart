import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Home screen announcement banner.
///
/// Two key improvements:
/// 1. Only shows announcements created AFTER the user joined —
///    new users never see historic announcements.
/// 2. Dismissals are persisted to Firestore so they survive app restarts.
class AnnouncementsBanner extends StatefulWidget {
  final String userId;
  final String accountType;
  final String notificationsRoute;

  const AnnouncementsBanner({
    super.key,
    required this.userId,
    required this.accountType,
    required this.notificationsRoute,
  });

  @override
  State<AnnouncementsBanner> createState() => _AnnouncementsBannerState();
}

class _AnnouncementsBannerState extends State<AnnouncementsBanner> {
  List<Map<String, dynamic>> _announcements = [];
  Set<String> _dismissed = {};
  StreamSubscription? _sub;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Load persisted dismissals + user join date first
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .get();

    if (!mounted) return;

    final data = userDoc.data() ?? {};
    final joinedAt =
        (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime(2000);
    final persistedDismissed =
        Set<String>.from(data['dismissedAnnouncements'] ?? []);

    setState(() => _dismissed = persistedDismissed);

    // Subscribe — only announcements posted after the user joined
    _sub = FirebaseFirestore.instance
        .collection('announcements')
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;

      final filtered = snap.docs.where((doc) {
        final d = doc.data();

        // Skip anything older than when this user created their account
        final createdAt = (d['createdAt'] as Timestamp?)?.toDate();
        if (createdAt != null && createdAt.isBefore(joinedAt)) return false;

        // Filter by target role/uid
        final targetType = d['targetType'] ?? 'all';
        final targetIds = List<String>.from(d['targetIds'] ?? []);
        return targetType == 'all' ||
            targetType == widget.accountType ||
            targetIds.contains(widget.userId);
      }).map((doc) => {'id': doc.id, ...doc.data()}).toList();

      setState(() {
        _announcements = filtered;
        _ready = true;
      });
    });
  }

  Future<void> _dismiss(String id) async {
    // Optimistically update UI immediately
    if (!mounted) return;
    setState(() => _dismissed = {..._dismissed, id});

    // Persist to Firestore — awaited so we know if it failed
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .update({
        'dismissedAnnouncements': FieldValue.arrayUnion([id]),
      });
    } catch (e) {
      // If persist fails, keep dismissed in-memory for this session
      // but log so we can investigate
      debugPrint('⚠️ AnnouncementsBanner: failed to persist dismissal for $id: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();

    final visible = _announcements
        .where((a) => !_dismissed.contains(a['id'] as String))
        .take(1)
        .toList();

    if (visible.isEmpty) return const SizedBox.shrink();

    final a = visible.first;
    final type = (a['type'] ?? 'info') as String;
    final color = _color(type);

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, widget.notificationsRoute),
      child: Container(
        margin: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_icon(type), color: color, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (a['title'] ?? '') as String,
                    style: AppTextStyles.labelMedium.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (a['body'] ?? '') as String,
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _dismiss(a['id'] as String),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close, size: 16, color: color.withAlpha(160)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}