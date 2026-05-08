import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants/colors.dart';

/// Bell icon with an unread-count dot.
///
/// Counts unread docs in the `notifications` collection where userId == [userId].
/// Tapping pushes `/notifications`.
class NotificationBell extends StatefulWidget {
  final String userId;

  const NotificationBell({super.key, required this.userId});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  StreamSubscription? _sub;
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.userId.isEmpty) return;
    _sub = FirebaseFirestore.instance
        .collection('notifications')
        .where('userId', isEqualTo: widget.userId)
        .where('read', isEqualTo: false)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() => _unreadCount = snap.docs.length);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/notifications'),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Stack(children: [
          Center(
            child: Icon(
              Icons.notifications_outlined,
              color: AppColors.textPrimary,
            ),
          ),
          if (_unreadCount > 0)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: AppColors.error,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ]),
      ),
    );
  }
}