import 'package:cloud_firestore/cloud_firestore.dart';
import 'property_model.dart';

class ConversationModel {
  final String id;
  final String propertyId;
  final String propertyTitle;
  final String propertyImage;
  final String landlordId;
  final String landlordName;
  final String tenantId;
  final String tenantName;
  final String lastMessage;
  final DateTime lastMessageTime;
  final String lastMessageSenderId;
  final int unreadCount;
  final PropertyModel? property;

  ConversationModel({
    required this.id,
    required this.propertyId,
    required this.propertyTitle,
    required this.propertyImage,
    required this.landlordId,
    required this.landlordName,
    required this.tenantId,
    required this.tenantName,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.lastMessageSenderId,
    this.unreadCount = 0,
    this.property,
  });

  factory ConversationModel.fromJson(Map<String, dynamic> json) {
    return ConversationModel(
      id: json['id'] ?? '',
      propertyId: json['propertyId'] ?? '',
      propertyTitle: json['propertyTitle'] ?? '',
      propertyImage: json['propertyImage'] ?? '',
      landlordId: json['landlordId'] ?? '',
      landlordName: json['landlordName'] ?? '',
      tenantId: json['tenantId'] ?? '',
      tenantName: json['tenantName'] ?? '',
      lastMessage: json['lastMessage'] ?? '',
      lastMessageTime: json['lastMessageTime'] is Timestamp
          ? (json['lastMessageTime'] as Timestamp).toDate()
          : DateTime.parse(json['lastMessageTime'] ?? DateTime.now().toIso8601String()),
      lastMessageSenderId: json['lastMessageSenderId'] ?? '',
      unreadCount: json['unreadCount'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'propertyId': propertyId,
      'propertyTitle': propertyTitle,
      'propertyImage': propertyImage,
      'landlordId': landlordId,
      'landlordName': landlordName,
      'tenantId': tenantId,
      'tenantName': tenantName,
      'lastMessage': lastMessage,
      'lastMessageTime': Timestamp.fromDate(lastMessageTime),
      'lastMessageSenderId': lastMessageSenderId,
      'unreadCount': unreadCount,
    };
  }

  // Get the other person's name based on current user
  String getOtherPersonName(String currentUserId) {
    return currentUserId == landlordId ? tenantName : landlordName;
  }

  // Get initials for avatar
  String getOtherPersonInitials(String currentUserId) {
    final name = getOtherPersonName(currentUserId);
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String get formattedTime {
    final now = DateTime.now();
    final difference = now.difference(lastMessageTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d';
    } else {
      return '${lastMessageTime.day}/${lastMessageTime.month}';
    }
  }
}