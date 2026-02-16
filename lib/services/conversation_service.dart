import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;

class ConversationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get currentUserId => _auth.currentUser?.uid;

  // ============ VERIFICATION CHECK ============

  /// Check if a user is verified
  Future<bool> _isUserVerified(String userId) async {
    // CRITICAL: Validate userId is not empty
    if (userId.isEmpty) {
      developer.log(
        '❌ Empty userId passed to _isUserVerified',
        name: 'ConversationService',
      );
      return false;
    }

    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) {
        developer.log(
          '❌ User document not found: $userId',
          name: 'ConversationService',
        );
        return false;
      }

      final userData = userDoc.data();
      final verificationStatus = userData?['verificationStatus'] ?? 'none';
      final isVerified = verificationStatus == 'verified';
      developer.log(
        '🔍 User $userId verification status: $verificationStatus (verified: $isVerified)',
        name: 'ConversationService',
      );
      return isVerified;
    } catch (e) {
      developer.log(
        '❌ Error checking verification for $userId: $e',
        name: 'ConversationService',
      );
      return false;
    }
  }

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
      developer.log(
        '❌ Error getting conversations: $e',
        name: 'ConversationService',
      );
      return [];
    }
  }

  /// Get or create a conversation between two users about a property
  /// Returns null if either party is not verified
  Future<ConversationData?> getOrCreateConversation({
    required String propertyId,
    required String propertyTitle,
    required String propertyImage,
    required String landlordId,
    required String landlordName,
    required String tenantId,
    required String tenantName,
    String? agentId,
    String? agentName,
  }) async {
    // CRITICAL: Validate required IDs are not empty
    if (landlordId.isEmpty) {
      developer.log(
        '❌ Cannot create conversation: landlordId is empty',
        name: 'ConversationService',
      );
      return null;
    }

    if (tenantId.isEmpty) {
      developer.log(
        '❌ Cannot create conversation: tenantId is empty',
        name: 'ConversationService',
      );
      return null;
    }

    try {
      // Verify both parties are verified before creating conversation
      final landlordVerified = await _isUserVerified(landlordId);
      if (!landlordVerified) {
        developer.log(
          '❌ Landlord not verified, cannot create conversation',
          name: 'ConversationService',
        );
        return null;
      }

      final tenantVerified = await _isUserVerified(tenantId);
      if (!tenantVerified) {
        developer.log(
          '❌ Tenant not verified, cannot create conversation',
          name: 'ConversationService',
        );
        return null;
      }

      // If agent is involved, verify them too
      if (agentId != null && agentId.isNotEmpty) {
        final agentVerified = await _isUserVerified(agentId);
        if (!agentVerified) {
          developer.log(
            '❌ Agent not verified, cannot create conversation',
            name: 'ConversationService',
          );
          return null;
        }
      }

      // Check if conversation already exists
      final existingQuery = await _firestore
          .collection('conversations')
          .where('propertyId', isEqualTo: propertyId)
          .where('landlordId', isEqualTo: landlordId)
          .where('tenantId', isEqualTo: tenantId)
          .limit(1)
          .get();

      if (existingQuery.docs.isNotEmpty) {
        developer.log(
          '✅ Found existing conversation: ${existingQuery.docs.first.id}',
          name: 'ConversationService',
        );
        return ConversationData.fromFirestore(existingQuery.docs.first);
      }

      // Create new conversation
      final conversationRef = _firestore.collection('conversations').doc();
      final now = DateTime.now();

      // Build participants list - include agent if present
      final participants = [landlordId, tenantId];
      if (agentId != null && agentId.isNotEmpty) {
        participants.add(agentId);
      }

      // Build unread counts - include agent if present
      final unreadCounts = <String, int>{
        landlordId: 0,
        tenantId: 0,
      };
      if (agentId != null && agentId.isNotEmpty) {
        unreadCounts[agentId] = 0;
      }

      final conversationData = {
        'id': conversationRef.id,
        'propertyId': propertyId,
        'propertyTitle': propertyTitle,
        'propertyImage': propertyImage,
        'landlordId': landlordId,
        'landlordName': landlordName,
        'tenantId': tenantId,
        'tenantName': tenantName,
        'agentId': agentId ?? '',
        'agentName': agentName ?? '',
        'participants': participants,
        'lastMessage': '',
        'lastMessageTime': Timestamp.fromDate(now),
        'lastMessageSenderId': '',
        'unreadCounts': unreadCounts,
        'createdAt': Timestamp.fromDate(now),
      };

      await conversationRef.set(conversationData);

      developer.log(
        '✅ Created new conversation: ${conversationRef.id}',
        name: 'ConversationService',
      );

      return ConversationData(
        id: conversationRef.id,
        propertyId: propertyId,
        propertyTitle: propertyTitle,
        propertyImage: propertyImage,
        landlordId: landlordId,
        landlordName: landlordName,
        tenantId: tenantId,
        tenantName: tenantName,
        agentId: agentId,
        agentName: agentName,
        participants: participants,
        lastMessage: '',
        lastMessageTime: now,
        lastMessageSenderId: '',
        unreadCounts: unreadCounts,
      );
    } catch (e) {
      developer.log(
        '❌ Error creating conversation: $e',
        name: 'ConversationService',
      );
      return null;
    }
  }

  /// Get a single conversation by ID
  Future<ConversationData?> getConversation(String conversationId) async {
    if (conversationId.isEmpty) {
      developer.log(
        '❌ Empty conversationId passed to getConversation',
        name: 'ConversationService',
      );
      return null;
    }

    try {
      final doc = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .get();
      if (doc.exists) {
        return ConversationData.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      developer.log(
        '❌ Error getting conversation: $e',
        name: 'ConversationService',
      );
      return null;
    }
  }

  // ============ MESSAGES ============

  /// Get messages for a conversation (real-time stream)
  Stream<List<MessageData>> getMessagesStream(String conversationId) {
    if (conversationId.isEmpty) {
      developer.log(
        '❌ Empty conversationId passed to getMessagesStream',
        name: 'ConversationService',
      );
      return Stream.value([]);
    }

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
    if (conversationId.isEmpty) {
      developer.log(
        '❌ Empty conversationId passed to getMessages',
        name: 'ConversationService',
      );
      return [];
    }

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
      developer.log(
        '❌ Error getting messages: $e',
        name: 'ConversationService',
      );
      return [];
    }
  }

  /// Send a message in a conversation
  /// Returns null if sender is not verified
  Future<MessageData?> sendMessage({
    required String conversationId,
    required String text,
    required String senderName,
    String? senderRole,
    String? imageUrl,
  }) async {
    if (conversationId.isEmpty) {
      developer.log(
        '❌ Cannot send message: conversationId is empty',
        name: 'ConversationService',
      );
      return null;
    }

    final senderId = currentUserId;
    if (senderId == null) {
      developer.log(
        '❌ Cannot send message: user not logged in',
        name: 'ConversationService',
      );
      return null;
    }

    // Verify sender is verified
    final senderVerified = await _isUserVerified(senderId);
    if (!senderVerified) {
      developer.log(
        '❌ Cannot send message: user not verified',
        name: 'ConversationService',
      );
      return null;
    }

    try {
      final messageRef = _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .doc();

      final now = DateTime.now();

      // If senderRole not provided, try to determine from user profile
      String role = senderRole ?? 'tenant';
      if (senderRole == null) {
        try {
          final userDoc = await _firestore.collection('users').doc(senderId).get();
          if (userDoc.exists) {
            role = userDoc.data()?['accountType'] ?? 'tenant';
          }
        } catch (e) {
          developer.log(
            '⚠️ Could not fetch user role: $e',
            name: 'ConversationService',
          );
        }
      }

      final messageData = {
        'id': messageRef.id,
        'conversationId': conversationId,
        'senderId': senderId,
        'senderName': senderName,
        'senderRole': role,
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

      developer.log(
        '✅ Message sent: ${messageRef.id}',
        name: 'ConversationService',
      );

      return MessageData(
        id: messageRef.id,
        conversationId: conversationId,
        senderId: senderId,
        senderName: senderName,
        senderRole: role,
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
      // Get conversation to find the other participants
      final conversationDoc = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .get();
      if (!conversationDoc.exists) return;

      final data = conversationDoc.data()!;
      final participants = List<String>.from(data['participants'] ?? []);

      // Build update map - increment unread for all other participants
      final updateData = <String, dynamic>{
        'lastMessage': lastMessage,
        'lastMessageTime': Timestamp.fromDate(timestamp),
        'lastMessageSenderId': lastMessageSenderId,
      };

      for (final participantId in participants) {
        if (participantId != lastMessageSenderId) {
          updateData['unreadCounts.$participantId'] = FieldValue.increment(1);
        }
      }

      await _firestore
          .collection('conversations')
          .doc(conversationId)
          .update(updateData);
    } catch (e) {
      developer.log(
        '❌ Error updating conversation: $e',
        name: 'ConversationService',
      );
    }
  }

  /// Mark all messages in a conversation as read for current user
  Future<void> markConversationAsRead(String conversationId) async {
    if (conversationId.isEmpty) {
      developer.log(
        '❌ Empty conversationId passed to markConversationAsRead',
        name: 'ConversationService',
      );
      return;
    }

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

      developer.log(
        '✅ Marked conversation as read: $conversationId',
        name: 'ConversationService',
      );
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
      developer.log(
        '❌ Error getting unread count: $e',
        name: 'ConversationService',
      );
      return 0;
    }
  }

  /// Get or create an agent-landlord conversation for a specific property
  Future<String?> getOrCreateAgentLandlordConversation({
    required String propertyId,
    required String landlordId,
    required String agentId,
  }) async {
    // Validate inputs
    if (propertyId.isEmpty || landlordId.isEmpty || agentId.isEmpty) {
      developer.log(
        '❌ Cannot create conversation: missing required IDs (property=$propertyId, landlord=$landlordId, agent=$agentId)',
        name: 'ConversationService',
      );
      return null;
    }

    try {
      developer.log(
        '🔍 Looking for agent-landlord conversation: property=$propertyId, landlord=$landlordId, agent=$agentId',
        name: 'ConversationService',
      );

      // Check if both users are verified
      final landlordVerified = await _isUserVerified(landlordId);
      if (!landlordVerified) {
        developer.log(
          '❌ Cannot create conversation: landlord not verified',
          name: 'ConversationService',
        );
        return null;
      }

      final agentVerified = await _isUserVerified(agentId);
      if (!agentVerified) {
        developer.log(
          '❌ Cannot create conversation: agent not verified',
          name: 'ConversationService',
        );
        return null;
      }

      // Look for existing agent-landlord conversation for this property
      final existingQuery = await _firestore
          .collection('conversations')
          .where('propertyId', isEqualTo: propertyId)
          .where('landlordId', isEqualTo: landlordId)
          .where('agentId', isEqualTo: agentId)
          .where('tenantId', isEqualTo: '')
          .limit(1)
          .get();

      if (existingQuery.docs.isNotEmpty) {
        final conversationId = existingQuery.docs.first.id;
        developer.log(
          '✅ Found existing agent-landlord conversation: $conversationId',
          name: 'ConversationService',
        );
        return conversationId;
      }

      // Get user details
      final landlordDoc = await _firestore.collection('users').doc(landlordId).get();
      final agentDoc = await _firestore.collection('users').doc(agentId).get();

      final landlordData = landlordDoc.data();
      final agentData = agentDoc.data();

      if (landlordData == null || agentData == null) {
        developer.log(
          '❌ Could not find user data',
          name: 'ConversationService',
        );
        return null;
      }

      // Get property details
      final propertyDoc = await _firestore.collection('properties').doc(propertyId).get();
      final propertyData = propertyDoc.data();

      final participants = [landlordId, agentId];

      // Create new conversation - use consistent field names!
      final conversationData = {
        'propertyId': propertyId,
        'propertyTitle': propertyData?['title'] ?? 'Property',
        'propertyImage': (propertyData?['images'] as List?)?.isNotEmpty == true
            ? propertyData!['images'][0]
            : '',
        'landlordId': landlordId,
        'landlordName': landlordData['fullName'] ?? 'Landlord',
        'tenantId': '', // No tenant in agent-landlord direct conversation
        'tenantName': '',
        'agentId': agentId,
        'agentName': agentData['fullName'] ?? 'Agent',
        'participants': participants, // Use 'participants' not 'participantIds'
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': '',
        'unreadCounts': {
          landlordId: 0,
          agentId: 0,
        },
        'conversationType': 'agent_landlord',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore.collection('conversations').add(conversationData);
      developer.log(
        '✅ Created new agent-landlord conversation: ${docRef.id}',
        name: 'ConversationService',
      );

      return docRef.id;
    } catch (e) {
      developer.log(
        '❌ Error getting/creating agent-landlord conversation: $e',
        name: 'ConversationService',
      );
      return null;
    }
  }

  /// Get or create an agent pitch conversation (no property)
  Future<String?> getOrCreateAgentPitchConversation({
    required String landlordId,
    required String agentId,
  }) async {
    // Validate inputs
    if (landlordId.isEmpty || agentId.isEmpty) {
      developer.log(
        '❌ Cannot create pitch conversation: missing required IDs (landlord=$landlordId, agent=$agentId)',
        name: 'ConversationService',
      );
      return null;
    }

    try {
      developer.log(
        '🔍 Looking for agent pitch conversation: landlord=$landlordId, agent=$agentId',
        name: 'ConversationService',
      );

      // Check if both users are verified
      final landlordVerified = await _isUserVerified(landlordId);
      if (!landlordVerified) {
        developer.log(
          '❌ Cannot create conversation: landlord not verified',
          name: 'ConversationService',
        );
        return null;
      }

      final agentVerified = await _isUserVerified(agentId);
      if (!agentVerified) {
        developer.log(
          '❌ Cannot create conversation: agent not verified',
          name: 'ConversationService',
        );
        return null;
      }

      // Look for existing pitch conversation
      final existingQuery = await _firestore
          .collection('conversations')
          .where('landlordId', isEqualTo: landlordId)
          .where('agentId', isEqualTo: agentId)
          .where('conversationType', isEqualTo: 'agent_pitch')
          .limit(1)
          .get();

      if (existingQuery.docs.isNotEmpty) {
        final conversationId = existingQuery.docs.first.id;
        developer.log(
          '✅ Found existing agent pitch conversation: $conversationId',
          name: 'ConversationService',
        );
        return conversationId;
      }

      // Get user details
      final landlordDoc = await _firestore.collection('users').doc(landlordId).get();
      final agentDoc = await _firestore.collection('users').doc(agentId).get();

      final landlordData = landlordDoc.data();
      final agentData = agentDoc.data();

      if (landlordData == null || agentData == null) {
        developer.log(
          '❌ Could not find user data',
          name: 'ConversationService',
        );
        return null;
      }

      final participants = [landlordId, agentId];

      // Create new pitch conversation
      final conversationData = {
        'propertyId': '',
        'propertyTitle': 'Agent Services Inquiry',
        'propertyImage': '',
        'landlordId': landlordId,
        'landlordName': landlordData['fullName'] ?? 'Landlord',
        'tenantId': '',
        'tenantName': '',
        'agentId': agentId,
        'agentName': agentData['fullName'] ?? 'Agent',
        'participants': participants, // Use 'participants' not 'participantIds'
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': '',
        'unreadCounts': {
          landlordId: 0,
          agentId: 0,
        },
        'conversationType': 'agent_pitch',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore.collection('conversations').add(conversationData);
      developer.log(
        '✅ Created new agent pitch conversation: ${docRef.id}',
        name: 'ConversationService',
      );

      return docRef.id;
    } catch (e) {
      developer.log(
        '❌ Error getting/creating agent pitch conversation: $e',
        name: 'ConversationService',
      );
      return null;
    }
  }

  /// Delete a conversation (soft delete - just remove from participant's view)
  Future<bool> deleteConversation(String conversationId) async {
    if (conversationId.isEmpty) {
      developer.log(
        '❌ Empty conversationId passed to deleteConversation',
        name: 'ConversationService',
      );
      return false;
    }

    final userId = currentUserId;
    if (userId == null) return false;

    try {
      await _firestore.collection('conversations').doc(conversationId).update({
        'deletedBy': FieldValue.arrayUnion([userId]),
      });
      developer.log(
        '✅ Conversation deleted: $conversationId',
        name: 'ConversationService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Error deleting conversation: $e',
        name: 'ConversationService',
      );
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
  final String? agentId;
  final String? agentName;
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
    this.agentId,
    this.agentName,
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
      agentId: data['agentId'],
      agentName: data['agentName'],
      participants: List<String>.from(data['participants'] ?? []),
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime:
          (data['lastMessageTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastMessageSenderId: data['lastMessageSenderId'] ?? '',
      unreadCounts: Map<String, int>.from(
        (data['unreadCounts'] as Map<String, dynamic>?)?.map(
              (key, value) => MapEntry(key, (value as num).toInt()),
            ) ??
            {},
      ),
    );
  }

  String getUserRole(String userId) {
    if (userId == landlordId) return 'landlord';
    if (userId == agentId) return 'agent';
    if (userId == tenantId) return 'tenant';
    return 'unknown';
  }

  String getUserName(String userId) {
    if (userId == landlordId) return landlordName;
    if (userId == agentId) return agentName ?? 'Agent';
    if (userId == tenantId) return tenantName;
    return 'Unknown';
  }

  String getOtherPersonName(String currentUserId) {
    if (currentUserId == tenantId) {
      return landlordName;
    }
    return tenantName.isNotEmpty ? tenantName : (agentName ?? 'Unknown');
  }

  String getOtherPersonInitials(String currentUserId) {
    final name = getOtherPersonName(currentUserId);
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  bool get hasAgent => agentId != null && agentId!.isNotEmpty;

  int getUnreadCount(String userId) {
    return unreadCounts[userId] ?? 0;
  }

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
  final String senderRole;
  final String text;
  final DateTime timestamp;
  final bool isRead;
  final String? imageUrl;

  MessageData({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    this.senderRole = 'tenant',
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
      senderRole: data['senderRole'] ?? 'tenant',
      text: data['text'] ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRead: data['isRead'] ?? false,
      imageUrl: data['imageUrl'],
    );
  }

  String get formattedTime {
    final hour = timestamp.hour;
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour:$minute $period';
  }
}