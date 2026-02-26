import 'package:cloud_firestore/cloud_firestore.dart';

enum ActivityType {
  propertyAdded,
  propertyViewed,
  inquiry,
  payment,
  issueReported,
  issueDisputed,
  issueConfirmed,
}

class ActivityModel {
  final String id;
  final String landlordId;
  final ActivityType type;
  final String title;
  final String subtitle;
  final String? propertyId;
  final String? propertyTitle;
  final String? actorId;
  final String? actorName;
  final bool isRead;
  final DateTime createdAt;

  ActivityModel({
    required this.id,
    required this.landlordId,
    required this.type,
    required this.title,
    required this.subtitle,
    this.propertyId,
    this.propertyTitle,
    this.actorId,
    this.actorName,
    this.isRead = false,
    required this.createdAt,
  });

  // Get icon based on type
  String get iconName {
    switch (type) {
      case ActivityType.propertyAdded:   return 'home';
      case ActivityType.propertyViewed:  return 'visibility';
      case ActivityType.inquiry:         return 'chat_bubble';
      case ActivityType.payment:         return 'payments';
      case ActivityType.issueReported:   return 'report_problem';
      case ActivityType.issueDisputed:   return 'warning';
      case ActivityType.issueConfirmed:  return 'check_circle';
    }
  }

  String get colorName {
    switch (type) {
      case ActivityType.propertyAdded:   return 'primary';
      case ActivityType.propertyViewed:  return 'info';
      case ActivityType.inquiry:         return 'warning';
      case ActivityType.payment:         return 'success';
      case ActivityType.issueReported:   return 'error';
      case ActivityType.issueDisputed:   return 'error';
      case ActivityType.issueConfirmed:  return 'success';
    }
  }

  // Format time ago
  String get timeAgo {
    final now = DateTime.now();
    final difference = now.difference(createdAt);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${(difference.inDays / 7).floor()}w ago';
    }
  }

  // From Firestore
  factory ActivityModel.fromJson(Map<String, dynamic> json) {
    return ActivityModel(
      id: json['id'] ?? '',
      landlordId: json['landlordId'] ?? '',
      type: _parseType(json['type']),
      title: json['title'] ?? '',
      subtitle: json['subtitle'] ?? '',
      propertyId: json['propertyId'],
      propertyTitle: json['propertyTitle'],
      actorId: json['actorId'],
      actorName: json['actorName'],
      isRead: json['isRead'] ?? false,
      createdAt: json['createdAt'] != null
          ? (json['createdAt'] is Timestamp
              ? (json['createdAt'] as Timestamp).toDate()
              : DateTime.parse(json['createdAt']))
          : DateTime.now(),
    );
  }

  // To Firestore
  Map<String, dynamic> toJson() {
    return {
      'landlordId': landlordId,
      'type': type.name,
      'title': title,
      'subtitle': subtitle,
      'propertyId': propertyId,
      'propertyTitle': propertyTitle,
      'actorId': actorId,
      'actorName': actorName,
      'isRead': isRead,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  static ActivityType _parseType(String? type) {
    switch (type) {
      case 'propertyAdded':   return ActivityType.propertyAdded;
      case 'propertyViewed':  return ActivityType.propertyViewed;
      case 'inquiry':         return ActivityType.inquiry;
      case 'payment':         return ActivityType.payment;
      case 'issue_reported':  return ActivityType.issueReported;
      case 'issue_disputed':  return ActivityType.issueDisputed;
      case 'issue_confirmed': return ActivityType.issueConfirmed;
      default:                return ActivityType.propertyViewed;
    }
  }

  // Copy with
  ActivityModel copyWith({
    String? id,
    String? landlordId,
    ActivityType? type,
    String? title,
    String? subtitle,
    String? propertyId,
    String? propertyTitle,
    String? actorId,
    String? actorName,
    bool? isRead,
    DateTime? createdAt,
  }) {
    return ActivityModel(
      id: id ?? this.id,
      landlordId: landlordId ?? this.landlordId,
      type: type ?? this.type,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      propertyId: propertyId ?? this.propertyId,
      propertyTitle: propertyTitle ?? this.propertyTitle,
      actorId: actorId ?? this.actorId,
      actorName: actorName ?? this.actorName,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}