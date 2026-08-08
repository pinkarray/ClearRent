import 'package:cloud_firestore/cloud_firestore.dart';

enum ActivityType {
  propertyAdded,
  propertyViewed,
  inquiry,
  payment,
  issueReported,
  issueDisputed,
  issueConfirmed,
  inspectionRequest,
  inspectionApproved,
  inspectionDeclined,
  inspectionCompleted,
  inspectionRated,
  payoutReceived,
  moveoutRequested,
  moveoutCompleted,
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
  final String? relatedId;
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
    this.relatedId,
    this.isRead = false,
    required this.createdAt,
  });

  // Get icon based on type
  String get iconName {
    switch (type) {
      case ActivityType.propertyAdded:       return 'home';
      case ActivityType.propertyViewed:      return 'visibility';
      case ActivityType.inquiry:             return 'chat_bubble';
      case ActivityType.payment:             return 'payments';
      case ActivityType.issueReported:       return 'report_problem';
      case ActivityType.issueDisputed:       return 'warning';
      case ActivityType.issueConfirmed:      return 'check_circle';
      case ActivityType.inspectionRequest:   return 'search';
      case ActivityType.inspectionApproved:  return 'event_available';
      case ActivityType.inspectionDeclined:  return 'event_busy';
      case ActivityType.inspectionCompleted: return 'done_all';
      case ActivityType.inspectionRated:     return 'star';
      case ActivityType.payoutReceived:      return 'account_balance_wallet';
      case ActivityType.moveoutRequested:    return 'logout';
      case ActivityType.moveoutCompleted:    return 'logout';
    }
  }

  String get colorName {
    switch (type) {
      case ActivityType.propertyAdded:       return 'primary';
      case ActivityType.propertyViewed:      return 'info';
      case ActivityType.inquiry:             return 'warning';
      case ActivityType.payment:             return 'success';
      case ActivityType.issueReported:       return 'error';
      case ActivityType.issueDisputed:       return 'error';
      case ActivityType.issueConfirmed:      return 'success';
      case ActivityType.inspectionRequest:   return 'warning';
      case ActivityType.inspectionApproved:  return 'success';
      case ActivityType.inspectionDeclined:  return 'error';
      case ActivityType.inspectionCompleted: return 'success';
      case ActivityType.inspectionRated:     return 'primary';
      case ActivityType.payoutReceived:      return 'success';
      case ActivityType.moveoutRequested:    return 'warning';
      case ActivityType.moveoutCompleted:    return 'info';
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
      landlordId: json['landlordId'] ?? json['userId'] ?? '',
      type: _parseType(json['type']),
      title: json['title'] ?? '',
      subtitle: json['subtitle'] ?? json['message'] ?? '',
      propertyId: json['propertyId'],
      propertyTitle: json['propertyTitle'],
      actorId: json['actorId'],
      actorName: json['actorName'],
      relatedId: json['relatedId'],
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
      'relatedId': relatedId,
      'isRead': isRead,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  static ActivityType _parseType(String? type) {
    switch (type) {
      case 'propertyAdded':          return ActivityType.propertyAdded;
      case 'propertyViewed':         return ActivityType.propertyViewed;
      case 'inquiry':                return ActivityType.inquiry;
      case 'payment':                return ActivityType.payment;
      case 'issue_reported':         return ActivityType.issueReported;
      case 'issue_disputed':         return ActivityType.issueDisputed;
      case 'issue_confirmed':        return ActivityType.issueConfirmed;
      case 'inspection_request':     return ActivityType.inspectionRequest;
      case 'inspection_request_agent': return ActivityType.inspectionRequest;
      case 'inspection_approved':    return ActivityType.inspectionApproved;
      // Inspection-day arrival updates (tenant/handler on the way + arrived).
      // Rendered like an approved-inspection update and routed to /inspections;
      // the stored title/message carry the specific wording.
      case 'tenant_on_way':          return ActivityType.inspectionApproved;
      case 'tenant_arrived':         return ActivityType.inspectionApproved;
      case 'handler_on_way':         return ActivityType.inspectionApproved;
      case 'handler_arrived':        return ActivityType.inspectionApproved;
      // Reschedule updates, written by onInspectionRequestUpdated. Same
      // treatment as the arrival updates above: they are changes to an
      // existing inspection, so they reuse that enum value and the stored
      // title/subtitle carry the specifics. Adding enum values instead would
      // leave every build already in the wild rendering these as
      // `propertyViewed` — the default below — with an eye icon.
      case 'reschedule_proposed':    return ActivityType.inspectionApproved;
      case 'reschedule_countered':   return ActivityType.inspectionApproved;
      case 'reschedule_approved':    return ActivityType.inspectionApproved;
      case 'reschedule_abandoned':   return ActivityType.inspectionApproved;
      case 'inspection_declined':    return ActivityType.inspectionDeclined;
      case 'inspection_completed':   return ActivityType.inspectionCompleted;
      case 'inspection_rated':       return ActivityType.inspectionRated;
      case 'payout_received':        return ActivityType.payoutReceived;
      case 'moveout_requested':      return ActivityType.moveoutRequested;
      case 'moveout_completed':      return ActivityType.moveoutCompleted;
      default:                       return ActivityType.propertyViewed;
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
    String? relatedId,
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
      relatedId: relatedId ?? this.relatedId,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}