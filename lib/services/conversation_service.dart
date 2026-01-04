import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;

class ConversationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get currentUserId => _auth.currentUser?.uid;

  // ============ CONVERSATIONS ============

  /// Get all conversations for the current user (real-time stream)
  Stream<List<ConversationData>> getConversationsStream() {
    final userId = currentUserId;
    if (userId == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('conversations')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return ConversationData.fromFirestore(doc);
      }).toList();
    });
  }

  /// Get all conversations for the current user (one-time fetch)
  Future<List<ConversationData>> getConversations() async {
    final userId = currentUserId;
    if (userId == null) {
      return [];
    }

    try {
      final snapshot = await _firestore
          .collection('conversations')
          .where('participants', arrayContains: userId)
          .orderBy('lastMessageTime', descending: true)
          .get();

      return snapshot.docs.map((doc) {
        return ConversationData.fromFirestore(doc);
      }).toList();
    } catch (e) {
      developer.log('❌ Error getting conversations: $e', name: 'ConversationService');
      return [];
    }
  }

  /// Get or create a conversation between two users about a property
  Future<ConversationData?> getOrCreateConversation({
    required String propertyId,
    required String propertyTitle,
    required String propertyImage,
    required String landlordId,
    required String landlordName,
    required String tenantId,
    required String tenantName,
  }) async {
    try {
      // Check if conversation already exists
      final existingQuery = await _firestore
          .collection('conversations')
          .where('propertyId', isEqualTo: propertyId)
          .where('landlordId', isEqualTo: landlordId)
          .where('tenantId', isEqualTo: tenantId)
          .limit(1)
          .get();

      if (existingQuery.docs.isNotEmpty) {
        return ConversationData.fromFirestore(existingQuery.docs.first);
      }

      // Create new conversation
      final conversationRef = _firestore.collection('conversations').doc();
      final now = DateTime.now();

      final conversationData = {
        'id': conversationRef.id,
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'propertyImage': propertyImage,
        'landlordId': landlordId,
        'landlordName': landlordName,
        'tenantId': tenantId,
        'tenantName': tenantName,
        'participants': [landlordId, tenantId],
        'lastMessage': '',
        'lastMessageTime': Timestamp.fromDate(now),
        'lastMessageSenderId': '',
        'unreadCounts': {
          landlordId: 0,
          tenantId: 0,
        },
        'createdAt': Timestamp.fromDate(now),
      };

      await conversationRef.set(conversationData);

      developer.log('✅ Created new conversation: ${conversationRef.id}', name: 'ConversationService');

      return ConversationData(
        id: conversationRef.id,
        propertyId: propertyId,
        propertyTitle: propertyTitle,
        propertyImage: propertyImage,
        landlordId: landlordId,
        landlordName: landlordName,
        tenantId: tenantId,
        tenantName: tenantName,
        participants: [landlordId, tenantId],
        lastMessage: '',
        lastMessageTime: now,
        lastMessageSenderId: '',
        unreadCounts: {landlordId: 0, tenantId: 0},
      );
    } catch (e) {
      developer.log('❌ Error creating conversation: $e', name: 'ConversationService');
      return null;
    }
  }

  /// Get a single conversation by ID
  Future<ConversationData?> getConversation(String conversationId) async {
    try {
      final doc = await _firestore.collection('conversations').doc(conversationId).get();
      if (doc.exists) {
        return ConversationData.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      developer.log('❌ Error getting conversation: $e', name: 'ConversationService');
      return null;
    }
  }

  // ============ MESSAGES ============

  /// Get messages for a conversation (real-time stream)
  Stream<List<MessageData>> getMessagesStream(String conversationId) {
    return _firestore
        .collection('conversations')
        .doc(conversationId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return MessageData.fromFirestore(doc);
      }).toList();
    });
  }

  /// Get messages for a conversation (one-time fetch)
  Future<List<MessageData>> getMessages(String conversationId) async {
    try {
      final snapshot = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .orderBy('timestamp', descending: false)
          .get();

      return snapshot.docs.map((doc) {
        return MessageData.fromFirestore(doc);
      }).toList();
    } catch (e) {
      developer.log('❌ Error getting messages: $e', name: 'ConversationService');
      return [];
    }
  }

  /// Send a message in a conversation
  Future<MessageData?> sendMessage({
    required String conversationId,
    required String text,
    required String senderName,
    String? imageUrl,
  }) async {
    final senderId = currentUserId;
    if (senderId == null) {
      developer.log('❌ Cannot send message: user not logged in', name: 'ConversationService');
      return null;
    }

    try {
      final messageRef = _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .doc();

      final now = DateTime.now();

      final messageData = {
        'id': messageRef.id,
        'conversationId': conversationId,
        'senderId': senderId,
        'senderName': senderName,
        'text': text,
        'timestamp': Timestamp.fromDate(now),
        'isRead': false,
        if (imageUrl != null) 'imageUrl': imageUrl,
      };

      await messageRef.set(messageData);

      // Update conversation's last message
      await _updateConversationLastMessage(
        conversationId: conversationId,
        lastMessage: text,
        lastMessageSenderId: senderId,
        timestamp: now,
      );

      developer.log('✅ Message sent: ${messageRef.id}', name: 'ConversationService');

      return MessageData(
        id: messageRef.id,
        conversationId: conversationId,
        senderId: senderId,
        senderName: senderName,
        text: text,
        timestamp: now,
        isRead: false,
        imageUrl: imageUrl,
      );
    } catch (e) {
      developer.log('❌ Error sending message: $e', name: 'ConversationService');
      return null;
    }
  }

  /// Update conversation's last message and increment unread count
  Future<void> _updateConversationLastMessage({
    required String conversationId,
    required String lastMessage,
    required String lastMessageSenderId,
    required DateTime timestamp,
  }) async {
    try {
      // Get conversation to find the other participant
      final conversationDoc = await _firestore.collection('conversations').doc(conversationId).get();
      if (!conversationDoc.exists) return;

      final data = conversationDoc.data()!;
      final participants = List<String>.from(data['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != lastMessageSenderId,
        orElse: () => '',
      );

      // Update conversation
      await _firestore.collection('conversations').doc(conversationId).update({
        'lastMessage': lastMessage,
        'lastMessageTime': Timestamp.fromDate(timestamp),
        'lastMessageSenderId': lastMessageSenderId,
        if (otherUserId.isNotEmpty) 'unreadCounts.$otherUserId': FieldValue.increment(1),
      });
    } catch (e) {
      developer.log('❌ Error updating conversation: $e', name: 'ConversationService');
    }
  }

  /// Mark all messages in a conversation as read for current user
  Future<void> markConversationAsRead(String conversationId) async {
    final userId = currentUserId;
    if (userId == null) return;

    try {
      // Reset unread count for current user
      await _firestore.collection('conversations').doc(conversationId).update({
        'unreadCounts.$userId': 0,
      });

      // Mark all messages as read (optional - for message-level tracking)
      final unreadMessages = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .where('senderId', isNotEqualTo: userId)
          .where('isRead', isEqualTo: false)
          .get();

      final batch = _firestore.batch();
      for (final doc in unreadMessages.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
      await batch.commit();

      developer.log('✅ Marked conversation as read: $conversationId', name: 'ConversationService');
    } catch (e) {
      developer.log('❌ Error marking as read: $e', name: 'ConversationService');
    }
  }

  /// Get unread count for current user across all conversations
  Future<int> getTotalUnreadCount() async {
    final userId = currentUserId;
    if (userId == null) return 0;

    try {
      final conversations = await getConversations();
      int total = 0;
      for (final conv in conversations) {
        total += conv.unreadCounts[userId] ?? 0;
      }
      return total;
    } catch (e) {
      developer.log('❌ Error getting unread count: $e', name: 'ConversationService');
      return 0;
    }
  }

  /// Delete a conversation (soft delete - just remove from participant's view)
  Future<bool> deleteConversation(String conversationId) async {
    final userId = currentUserId;
    if (userId == null) return false;

    try {
      await _firestore.collection('conversations').doc(conversationId).update({
        'deletedBy': FieldValue.arrayUnion([userId]),
      });
      developer.log('✅ Conversation deleted: $conversationId', name: 'ConversationService');
      return true;
    } catch (e) {
      developer.log('❌ Error deleting conversation: $e', name: 'ConversationService');
      return false;
    }
  }
}

// ============ DATA CLASSES ============

class ConversationData {
  final String id;
  final String propertyId;
  final String propertyTitle;
  final String propertyImage;
  final String landlordId;
  final String landlordName;
  final String tenantId;
  final String tenantName;
  final List<String> participants;
  final String lastMessage;
  final DateTime lastMessageTime;
  final String lastMessageSenderId;
  final Map<String, int> unreadCounts;

  ConversationData({
    required this.id,
    required this.propertyId,
    required this.propertyTitle,
    required this.propertyImage,
    required this.landlordId,
    required this.landlordName,
    required this.tenantId,
    required this.tenantName,
    required this.participants,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.lastMessageSenderId,
    required this.unreadCounts,
  });

  factory ConversationData.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ConversationData(
      id: doc.id,
      propertyId: data['propertyId'] ?? '',
      propertyTitle: data['propertyTitle'] ?? '',
      propertyImage: data['propertyImage'] ?? '',
      landlordId: data['landlordId'] ?? '',
      landlordName: data['landlordName'] ?? '',
      tenantId: data['tenantId'] ?? '',
      tenantName: data['tenantName'] ?? '',
      participants: List<String>.from(data['participants'] ?? []),
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime: (data['lastMessageTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastMessageSenderId: data['lastMessageSenderId'] ?? '',
      unreadCounts: Map<String, int>.from(
        (data['unreadCounts'] as Map<String, dynamic>?)?.map(
              (key, value) => MapEntry(key, (value as num).toInt()),
            ) ??
            {},
      ),
    );
  }

  /// Get the other person's name (for display)
  String getOtherPersonName(String currentUserId) {
    return currentUserId == landlordId ? tenantName : landlordName;
  }

  /// Get the other person's initials (for avatar)
  String getOtherPersonInitials(String currentUserId) {
    final name = getOtherPersonName(currentUserId);
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  /// Get unread count for a specific user
  int getUnreadCount(String userId) {
    return unreadCounts[userId] ?? 0;
  }

  /// Format the last message time for display
  String get formattedTime {
    final now = DateTime.now();
    final difference = now.difference(lastMessageTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${lastMessageTime.day}/${lastMessageTime.month}/${lastMessageTime.year}';
    }
  }
}

class MessageData {
  final String id;
  final String conversationId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime timestamp;
  final bool isRead;
  final String? imageUrl;

  MessageData({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.isRead = false,
    this.imageUrl,
  });

  factory MessageData.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MessageData(
      id: doc.id,
      conversationId: data['conversationId'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      text: data['text'] ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRead: data['isRead'] ?? false,
      imageUrl: data['imageUrl'],
    );
  }

  /// Format the timestamp for display
  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}