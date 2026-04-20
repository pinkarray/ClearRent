import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;

class ConversationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get currentUserId => _auth.currentUser?.uid;

  // ============ VERIFICATION CHECK ============

  Future<bool> _isUserVerified(String userId) async {
    if (userId.isEmpty) return false;
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) return false;
      return userDoc.data()?['verificationStatus'] == 'verified';
    } catch (e) {
      developer.log('❌ Error checking verification for $userId: $e',
          name: 'ConversationService');
      return false;
    }
  }

  // ============ CONVERSATIONS ============

  /// Get all conversations for the current user (real-time stream).
  /// Filters out conversations where the user is in removedParticipants.
  Stream<List<ConversationData>> getConversationsStream() {
    final userId = currentUserId;
    if (userId == null) return Stream.value([]);

    return _firestore
        .collection('conversations')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => ConversationData.fromFirestore(doc))
          // Client-side filter: exclude if user was removed
          .where((c) => !c.removedParticipants.contains(userId))
          .toList();
    });
  }

  /// Get all conversations for the current user (one-time fetch)
  Future<List<ConversationData>> getConversations() async {
    final userId = currentUserId;
    if (userId == null) return [];

    try {
      final snapshot = await _firestore
          .collection('conversations')
          .where('participants', arrayContains: userId)
          .orderBy('lastMessageTime', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => ConversationData.fromFirestore(doc))
          .where((c) => !c.removedParticipants.contains(userId))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting conversations: $e',
          name: 'ConversationService');
      return [];
    }
  }

  // ════════════════════════════════════════════════
  //  PROPERTY RENTAL CONVERSATION (landlord + tenant + optional agent)
  //  Single thread per property-tenant pair.
  // ════════════════════════════════════════════════

  /// Get or create the main property rental conversation.
  ///
  /// Lookup: `propertyId + tenantId` (landlord is always the property owner).
  /// If found → self-heals missing fields, adds agent if needed → returns.
  /// If not found → creates new conversation.
  ///
  /// This is the SINGLE entry point for all property rental messaging.
  /// Landlord, tenant, and agent all share this one thread.
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
    if (landlordId.isEmpty || tenantId.isEmpty) {
      developer.log(
          '❌ Cannot create conversation: landlordId or tenantId empty',
          name: 'ConversationService');
      return null;
    }

    try {
      // Verify parties
      final landlordVerified = await _isUserVerified(landlordId);
      if (!landlordVerified) {
        developer.log('❌ Landlord not verified', name: 'ConversationService');
        return null;
      }
      final tenantVerified = await _isUserVerified(tenantId);
      if (!tenantVerified) {
        developer.log('❌ Tenant not verified', name: 'ConversationService');
        return null;
      }
      if (agentId != null && agentId.isNotEmpty) {
        final agentVerified = await _isUserVerified(agentId);
        if (!agentVerified) {
          developer.log('❌ Agent not verified', name: 'ConversationService');
          return null;
        }
      }

      // ── LOOKUP: propertyId + tenantId ──
      // This finds the conversation regardless of which agent (or no agent)
      // was involved when it was created.
      final existingQuery = await _firestore
          .collection('conversations')
          .where('propertyId', isEqualTo: propertyId)
          .where('tenantId', isEqualTo: tenantId)
          // Exclude agent-landlord private chats and admin support
          .where('conversationType', whereIn: ['property_rental', null])
          .limit(5) // get a few in case of old duplicates
          .get();

      // Also check old-format conversations that don't have conversationType
      QuerySnapshot<Map<String, dynamic>>? legacyQuery;
      if (existingQuery.docs.isEmpty) {
        legacyQuery = await _firestore
            .collection('conversations')
            .where('propertyId', isEqualTo: propertyId)
            .where('tenantId', isEqualTo: tenantId)
            .where('landlordId', isEqualTo: landlordId)
            .limit(1)
            .get();
      }

      final allDocs = [
        ...existingQuery.docs,
        if (legacyQuery != null) ...legacyQuery.docs,
      ];

      if (allDocs.isNotEmpty) {
        final doc = allDocs.first;
        final existing = ConversationData.fromFirestore(doc);
        developer.log(
            '✅ Found existing conversation: ${existing.id}',
            name: 'ConversationService');

        // ── SELF-HEAL: patch missing fields ──
        final patch = <String, dynamic>{};

        // Add conversationType if missing
        final rawData = doc.data();
        if (rawData['conversationType'] == null) {
          patch['conversationType'] = 'property_rental';
        }

        // Update names if stale
        if (existing.landlordName.isEmpty && landlordName.isNotEmpty) {
          patch['landlordName'] = landlordName;
        }
        if (existing.tenantName.isEmpty && tenantName.isNotEmpty) {
          patch['tenantName'] = tenantName;
        }

        // Add agent if one is now assigned but wasn't before
        if (agentId != null &&
            agentId.isNotEmpty &&
            existing.currentAgentId != agentId) {
          patch['currentAgentId'] = agentId;
          patch['currentAgentName'] = agentName ?? '';
          patch['agentId'] = agentId;
          patch['agentName'] = agentName ?? '';

          // Add to participants if not already there
          if (!existing.participants.contains(agentId)) {
            patch['participants'] = FieldValue.arrayUnion([agentId]);
            patch['unreadCounts.$agentId'] = 0;
          }

          // Remove from removedParticipants if they were previously removed
          if (existing.removedParticipants.contains(agentId)) {
            patch['removedParticipants'] = FieldValue.arrayRemove([agentId]);
          }
        }

        if (patch.isNotEmpty) {
          patch['updatedAt'] = FieldValue.serverTimestamp();
          try {
            await _firestore
                .collection('conversations')
                .doc(existing.id)
                .update(patch);
            developer.log(
                '🔧 Patched conversation ${existing.id}: ${patch.keys}',
                name: 'ConversationService');
          } catch (e) {
            developer.log('⚠️ Failed to patch conversation: $e',
                name: 'ConversationService');
          }
        }

        return existing;
      }

      // ── CREATE NEW ──
      final conversationRef = _firestore.collection('conversations').doc();
      final now = DateTime.now();

      final participants = [landlordId, tenantId];
      if (agentId != null && agentId.isNotEmpty) {
        participants.add(agentId);
      }

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
        'currentAgentId': agentId ?? '',
        'currentAgentName': agentName ?? '',
        'participants': participants,
        'removedParticipants': <String>[],
        'conversationType': 'property_rental',
        'lastMessage': '',
        'lastMessageTime': Timestamp.fromDate(now),
        'lastMessageSenderId': '',
        'lastMessageSenderRole': '',
        'unreadCounts': unreadCounts,
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
      };

      await conversationRef.set(conversationData);

      developer.log('✅ Created new property_rental conversation: ${conversationRef.id}',
          name: 'ConversationService');

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
        currentAgentId: agentId,
        currentAgentName: agentName,
        participants: participants,
        removedParticipants: [],
        conversationType: 'property_rental',
        lastMessage: '',
        lastMessageTime: now,
        lastMessageSenderId: '',
        lastMessageSenderRole: '',
        unreadCounts: unreadCounts,
      );
    } catch (e) {
      developer.log('❌ Error in getOrCreateConversation: $e',
          name: 'ConversationService');
      return null;
    }
  }

  // ════════════════════════════════════════════════
  //  AGENT LIFECYCLE
  // ════════════════════════════════════════════════

  /// Add an agent to an existing property rental conversation.
  /// Called when landlord assigns an agent to a property.
  Future<void> addAgentToConversation({
    required String conversationId,
    required String agentId,
    required String agentName,
  }) async {
    if (conversationId.isEmpty || agentId.isEmpty) return;

    try {
      await _firestore.collection('conversations').doc(conversationId).update({
        'currentAgentId': agentId,
        'currentAgentName': agentName,
        'agentId': agentId,
        'agentName': agentName,
        'participants': FieldValue.arrayUnion([agentId]),
        'removedParticipants': FieldValue.arrayRemove([agentId]),
        'unreadCounts.$agentId': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Insert system message
      await _insertSystemMessage(
        conversationId,
        '$agentName has joined the conversation as the assigned agent.',
      );

      developer.log('✅ Agent $agentName added to conversation $conversationId',
          name: 'ConversationService');
    } catch (e) {
      developer.log('❌ Error adding agent to conversation: $e',
          name: 'ConversationService');
    }
  }

  /// Remove an agent from a property rental conversation.
  /// Called when landlord removes or swaps an agent.
  /// The agent loses access but their past messages remain visible.
  Future<void> removeAgentFromConversation({
    required String conversationId,
    required String agentId,
    required String agentName,
  }) async {
    if (conversationId.isEmpty || agentId.isEmpty) return;

    try {
      await _firestore.collection('conversations').doc(conversationId).update({
        'currentAgentId': '',
        'currentAgentName': '',
        'participants': FieldValue.arrayRemove([agentId]),
        'removedParticipants': FieldValue.arrayUnion([agentId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Note: we keep agentId/agentName on the doc for historical reference
      // (so old messages still show the right name). currentAgentId is cleared.

      await _insertSystemMessage(
        conversationId,
        '$agentName has been removed from this conversation.',
      );

      developer.log(
          '✅ Agent $agentName removed from conversation $conversationId',
          name: 'ConversationService');
    } catch (e) {
      developer.log('❌ Error removing agent from conversation: $e',
          name: 'ConversationService');
    }
  }

  /// Swap agent on a conversation — remove old, add new, insert system message.
  Future<void> swapAgentOnConversation({
    required String conversationId,
    required String oldAgentId,
    required String oldAgentName,
    required String newAgentId,
    required String newAgentName,
  }) async {
    if (conversationId.isEmpty) return;

    try {
      await _firestore.collection('conversations').doc(conversationId).update({
        'currentAgentId': newAgentId,
        'currentAgentName': newAgentName,
        'agentId': newAgentId,
        'agentName': newAgentName,
        'participants': FieldValue.arrayRemove([oldAgentId]),
        'removedParticipants': FieldValue.arrayUnion([oldAgentId]),
        'unreadCounts.$newAgentId': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Add new agent to participants (separate call to avoid conflict with arrayRemove)
      await _firestore.collection('conversations').doc(conversationId).update({
        'participants': FieldValue.arrayUnion([newAgentId]),
        'removedParticipants': FieldValue.arrayRemove([newAgentId]),
      });

      await _insertSystemMessage(
        conversationId,
        '$oldAgentName has been removed. $newAgentName is now the assigned agent.',
      );

      developer.log(
          '✅ Agent swapped on conversation $conversationId: $oldAgentName → $newAgentName',
          name: 'ConversationService');
    } catch (e) {
      developer.log('❌ Error swapping agent: $e',
          name: 'ConversationService');
    }
  }

  /// Find the property_rental conversation for a given property and tenant.
  /// Used when landlord assigns/removes agent and needs to update the conversation.
  Future<String?> findPropertyConversation({
    required String propertyId,
    required String tenantId,
  }) async {
    try {
      final query = await _firestore
          .collection('conversations')
          .where('propertyId', isEqualTo: propertyId)
          .where('tenantId', isEqualTo: tenantId)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) return query.docs.first.id;
      return null;
    } catch (e) {
      developer.log('❌ Error finding conversation: $e',
          name: 'ConversationService');
      return null;
    }
  }

  // ════════════════════════════════════════════════
  //  SYSTEM MESSAGES
  // ════════════════════════════════════════════════

  /// Insert a system message into a conversation.
  /// System messages are shown as centered gray text in the chat UI.
  Future<void> _insertSystemMessage(String conversationId, String text) async {
    try {
      final messageRef = _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .doc();

      final now = DateTime.now();

      await messageRef.set({
        'id': messageRef.id,
        'conversationId': conversationId,
        'senderId': 'system',
        'senderName': 'ClearRent',
        'senderRole': 'system',
        'text': text,
        'timestamp': Timestamp.fromDate(now),
        'isRead': true, // system messages are always "read"
      });

      // Update conversation last message
      await _firestore.collection('conversations').doc(conversationId).update({
        'lastMessage': text,
        'lastMessageSenderId': 'system',
        'lastMessageSenderRole': 'system',
        'lastMessageTime': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
      });
    } catch (e) {
      developer.log('❌ Error inserting system message: $e',
          name: 'ConversationService');
    }
  }

  // ════════════════════════════════════════════════
  //  GET SINGLE CONVERSATION
  // ════════════════════════════════════════════════

  Future<ConversationData?> getConversation(String conversationId) async {
    if (conversationId.isEmpty) return null;
    try {
      final doc = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .get();
      if (doc.exists) return ConversationData.fromFirestore(doc);
      return null;
    } catch (e) {
      developer.log('❌ Error getting conversation: $e',
          name: 'ConversationService');
      return null;
    }
  }

  // ════════════════════════════════════════════════
  //  MESSAGES
  // ════════════════════════════════════════════════

  Stream<List<MessageData>> getMessagesStream(String conversationId) {
    if (conversationId.isEmpty) return Stream.value([]);

    return _firestore
        .collection('conversations')
        .doc(conversationId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => MessageData.fromFirestore(doc)).toList());
  }

  Future<List<MessageData>> getMessages(String conversationId) async {
    if (conversationId.isEmpty) return [];
    try {
      final snapshot = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .orderBy('timestamp', descending: false)
          .get();
      return snapshot.docs
          .map((doc) => MessageData.fromFirestore(doc))
          .toList();
    } catch (e) {
      developer.log('❌ Error getting messages: $e',
          name: 'ConversationService');
      return [];
    }
  }

  /// Send a message in a conversation.
  /// Automatically determines senderRole from user profile if not provided.
  Future<MessageData?> sendMessage({
    required String conversationId,
    required String text,
    required String senderName,
    String? senderRole,
    String? imageUrl,
  }) async {
    if (conversationId.isEmpty) return null;

    final senderId = currentUserId;
    if (senderId == null) return null;

    final senderVerified = await _isUserVerified(senderId);
    if (!senderVerified) {
      developer.log('❌ Cannot send message: user not verified',
          name: 'ConversationService');
      return null;
    }

    // Check user is still a participant (not removed)
    try {
      final convDoc = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .get();
      if (convDoc.exists) {
        final removed =
            List<String>.from(convDoc.data()?['removedParticipants'] ?? []);
        if (removed.contains(senderId)) {
          developer.log('❌ Cannot send message: user was removed from conversation',
              name: 'ConversationService');
          return null;
        }
      }
    } catch (_) {}

    try {
      final messageRef = _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .doc();

      final now = DateTime.now();

      // Determine role
      String role = senderRole ?? 'tenant';
      if (senderRole == null) {
        try {
          final userDoc =
              await _firestore.collection('users').doc(senderId).get();
          if (userDoc.exists) {
            role = userDoc.data()?['accountType'] ?? 'tenant';
          }
        } catch (_) {}
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

      // Update conversation last message
      await _updateConversationLastMessage(
        conversationId: conversationId,
        lastMessage: text,
        lastMessageSenderId: senderId,
        lastMessageSenderRole: role,
        timestamp: now,
      );

      developer.log('✅ Message sent: ${messageRef.id}',
          name: 'ConversationService');

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
      developer.log('❌ Error sending message: $e',
          name: 'ConversationService');
      return null;
    }
  }

  Future<void> _updateConversationLastMessage({
    required String conversationId,
    required String lastMessage,
    required String lastMessageSenderId,
    required String lastMessageSenderRole,
    required DateTime timestamp,
  }) async {
    try {
      final conversationDoc = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .get();
      if (!conversationDoc.exists) return;

      final data = conversationDoc.data()!;
      final participants = List<String>.from(data['participants'] ?? []);

      final updateData = <String, dynamic>{
        'lastMessage': lastMessage,
        'lastMessageTime': Timestamp.fromDate(timestamp),
        'lastMessageSenderId': lastMessageSenderId,
        'lastMessageSenderRole': lastMessageSenderRole,
        'updatedAt': Timestamp.fromDate(timestamp),
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
      developer.log('❌ Error updating conversation: $e',
          name: 'ConversationService');
    }
  }

  /// Mark all messages as read for current user
  Future<void> markConversationAsRead(String conversationId) async {
    if (conversationId.isEmpty) return;
    final userId = currentUserId;
    if (userId == null) return;

    try {
      await _firestore
          .collection('conversations')
          .doc(conversationId)
          .update({'unreadCounts.$userId': 0});

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
    } catch (e) {
      developer.log('❌ Error marking as read: $e',
          name: 'ConversationService');
    }
  }

  /// Total unread count across all conversations
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
      return 0;
    }
  }

  // ════════════════════════════════════════════════
  //  AGENT-LANDLORD PRIVATE CONVERSATION
  //  Separate channel for property management discussions.
  // ════════════════════════════════════════════════

  Future<String?> getOrCreateAgentLandlordConversation({
    required String propertyId,
    required String landlordId,
    required String agentId,
  }) async {
    if (propertyId.isEmpty || landlordId.isEmpty || agentId.isEmpty) return null;

    try {
      final landlordVerified = await _isUserVerified(landlordId);
      final agentVerified = await _isUserVerified(agentId);
      if (!landlordVerified || !agentVerified) return null;

      // Look for existing
      final existingQuery = await _firestore
          .collection('conversations')
          .where('propertyId', isEqualTo: propertyId)
          .where('landlordId', isEqualTo: landlordId)
          .where('agentId', isEqualTo: agentId)
          .where('conversationType', isEqualTo: 'agent_landlord')
          .limit(1)
          .get();

      if (existingQuery.docs.isNotEmpty) {
        return existingQuery.docs.first.id;
      }

      // Get user details
      final landlordDoc =
          await _firestore.collection('users').doc(landlordId).get();
      final agentDoc =
          await _firestore.collection('users').doc(agentId).get();
      if (!landlordDoc.exists || !agentDoc.exists) return null;

      final propertyDoc =
          await _firestore.collection('properties').doc(propertyId).get();

      final participants = [landlordId, agentId];

      final conversationData = {
        'propertyId': propertyId,
        'propertyTitle': propertyDoc.data()?['title'] ?? 'Property',
        'propertyImage': (propertyDoc.data()?['images'] as List?)?.isNotEmpty == true
            ? propertyDoc.data()!['images'][0]
            : '',
        'landlordId': landlordId,
        'landlordName': landlordDoc.data()?['fullName'] ?? 'Landlord',
        'tenantId': '',
        'tenantName': '',
        'agentId': agentId,
        'agentName': agentDoc.data()?['fullName'] ?? 'Agent',
        'currentAgentId': agentId,
        'currentAgentName': agentDoc.data()?['fullName'] ?? 'Agent',
        'participants': participants,
        'removedParticipants': <String>[],
        'conversationType': 'agent_landlord',
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': '',
        'lastMessageSenderRole': '',
        'unreadCounts': {landlordId: 0, agentId: 0},
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _firestore.collection('conversations').add(conversationData);
      developer.log('✅ Created agent_landlord conversation: ${docRef.id}',
          name: 'ConversationService');
      return docRef.id;
    } catch (e) {
      developer.log('❌ Error in getOrCreateAgentLandlordConversation: $e',
          name: 'ConversationService');
      return null;
    }
  }

  // ════════════════════════════════════════════════
  //  AGENT PITCH CONVERSATION (no property)
  // ════════════════════════════════════════════════

  Future<String?> getOrCreateAgentPitchConversation({
    required String landlordId,
    required String agentId,
  }) async {
    if (landlordId.isEmpty || agentId.isEmpty) return null;

    try {
      final landlordVerified = await _isUserVerified(landlordId);
      final agentVerified = await _isUserVerified(agentId);
      if (!landlordVerified || !agentVerified) return null;

      final existingQuery = await _firestore
          .collection('conversations')
          .where('landlordId', isEqualTo: landlordId)
          .where('agentId', isEqualTo: agentId)
          .where('conversationType', isEqualTo: 'agent_pitch')
          .limit(1)
          .get();

      if (existingQuery.docs.isNotEmpty) {
        return existingQuery.docs.first.id;
      }

      final landlordDoc =
          await _firestore.collection('users').doc(landlordId).get();
      final agentDoc =
          await _firestore.collection('users').doc(agentId).get();
      if (!landlordDoc.exists || !agentDoc.exists) return null;

      final participants = [landlordId, agentId];

      final conversationData = {
        'propertyId': '',
        'propertyTitle': 'Agent Services Inquiry',
        'propertyImage': '',
        'landlordId': landlordId,
        'landlordName': landlordDoc.data()?['fullName'] ?? 'Landlord',
        'tenantId': '',
        'tenantName': '',
        'agentId': agentId,
        'agentName': agentDoc.data()?['fullName'] ?? 'Agent',
        'currentAgentId': agentId,
        'currentAgentName': agentDoc.data()?['fullName'] ?? 'Agent',
        'participants': participants,
        'removedParticipants': <String>[],
        'conversationType': 'agent_pitch',
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': '',
        'lastMessageSenderRole': '',
        'unreadCounts': {landlordId: 0, agentId: 0},
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef =
          await _firestore.collection('conversations').add(conversationData);
      developer.log('✅ Created agent_pitch conversation: ${docRef.id}',
          name: 'ConversationService');
      return docRef.id;
    } catch (e) {
      developer.log('❌ Error in getOrCreateAgentPitchConversation: $e',
          name: 'ConversationService');
      return null;
    }
  }

  // ════════════════════════════════════════════════
  //  ADMIN SUPPORT CONVERSATION
  // ════════════════════════════════════════════════

  Future<ConversationData?> getOrCreateAdminConversation({
    required String adminId,
    required String adminName,
    required String userId,
    required String userName,
  }) async {
    if (adminId.isEmpty || userId.isEmpty) return null;

    try {
      final existing = await _firestore
          .collection('conversations')
          .where('landlordId', isEqualTo: adminId)
          .where('tenantId', isEqualTo: userId)
          .where('conversationType', isEqualTo: 'admin_support')
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        return ConversationData.fromFirestore(existing.docs.first);
      }

      final ref = _firestore.collection('conversations').doc();
      final now = DateTime.now();

      final data = {
        'id': ref.id,
        'propertyId': '',
        'propertyTitle': 'ClearRent Support',
        'propertyImage': '',
        'landlordId': adminId,
        'landlordName': adminName,
        'tenantId': userId,
        'tenantName': userName,
        'agentId': '',
        'agentName': '',
        'currentAgentId': '',
        'currentAgentName': '',
        'participants': [adminId, userId],
        'removedParticipants': <String>[],
        'conversationType': 'admin_support',
        'lastMessage': '',
        'lastMessageTime': Timestamp.fromDate(now),
        'lastMessageSenderId': '',
        'lastMessageSenderRole': '',
        'unreadCounts': {adminId: 0, userId: 0},
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
      };

      await ref.set(data);

      return ConversationData(
        id: ref.id,
        propertyId: '',
        propertyTitle: 'ClearRent Support',
        propertyImage: '',
        landlordId: adminId,
        landlordName: adminName,
        tenantId: userId,
        tenantName: userName,
        participants: [adminId, userId],
        removedParticipants: [],
        conversationType: 'admin_support',
        lastMessage: '',
        lastMessageTime: now,
        lastMessageSenderId: '',
        lastMessageSenderRole: '',
        unreadCounts: {adminId: 0, userId: 0},
      );
    } catch (e) {
      developer.log('❌ Error creating admin conversation: $e',
          name: 'ConversationService');
      return null;
    }
  }

  // ════════════════════════════════════════════════
  //  VERIFICATION REMINDER
  // ════════════════════════════════════════════════

  Future<bool> sendVerificationReminder({
    required String adminId,
    required String userId,
    required String userName,
    required String userType,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': userId,
        'type': 'verification_reminder',
        'title': 'Complete Your Verification',
        'body':
            'Your ClearRent account is not yet verified. Complete verification to unlock messaging, inspections, and listings.',
        'isRead': false,
        'sentBy': adminId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      developer.log('❌ Error sending reminder: $e',
          name: 'ConversationService');
      return false;
    }
  }

  // ════════════════════════════════════════════════
  //  DELETE CONVERSATION
  // ════════════════════════════════════════════════

  Future<bool> deleteConversation(String conversationId) async {
    if (conversationId.isEmpty) return false;
    final userId = currentUserId;
    if (userId == null) return false;

    try {
      await _firestore
          .collection('conversations')
          .doc(conversationId)
          .update({
        'deletedBy': FieldValue.arrayUnion([userId]),
      });
      return true;
    } catch (e) {
      developer.log('❌ Error deleting conversation: $e',
          name: 'ConversationService');
      return false;
    }
  }
}

// ════════════════════════════════════════════════════════
//  DATA CLASSES
// ════════════════════════════════════════════════════════

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
  final String? currentAgentId;
  final String? currentAgentName;
  final List<String> participants;
  final List<String> removedParticipants;
  final String conversationType;
  final String lastMessage;
  final DateTime lastMessageTime;
  final String lastMessageSenderId;
  final String lastMessageSenderRole;
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
    this.currentAgentId,
    this.currentAgentName,
    required this.participants,
    this.removedParticipants = const [],
    this.conversationType = 'property_rental',
    required this.lastMessage,
    required this.lastMessageTime,
    required this.lastMessageSenderId,
    this.lastMessageSenderRole = '',
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
      currentAgentId: data['currentAgentId'] ?? data['agentId'],
      currentAgentName: data['currentAgentName'] ?? data['agentName'],
      participants: List<String>.from(data['participants'] ?? []),
      removedParticipants:
          List<String>.from(data['removedParticipants'] ?? []),
      conversationType: data['conversationType'] ?? 'property_rental',
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime:
          (data['lastMessageTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastMessageSenderId: data['lastMessageSenderId'] ?? '',
      lastMessageSenderRole: data['lastMessageSenderRole'] ?? '',
      unreadCounts: Map<String, int>.from(
        (data['unreadCounts'] as Map<String, dynamic>?)?.map(
                (key, value) => MapEntry(key, (value as num).toInt())) ??
            {},
      ),
    );
  }

  String getUserRole(String userId) {
    if (userId == landlordId) return 'landlord';
    if (userId == currentAgentId || userId == agentId) return 'agent';
    if (userId == tenantId) return 'tenant';
    return 'unknown';
  }

  String getUserName(String userId) {
    if (userId == landlordId) return landlordName;
    if (userId == currentAgentId || userId == agentId) {
      return currentAgentName ?? agentName ?? 'Agent';
    }
    if (userId == tenantId) return tenantName;
    return 'Unknown';
  }

  String getOtherPersonName(String currentUserId) {
    if (conversationType == 'agent_landlord' || conversationType == 'agent_pitch') {
      if (currentUserId == landlordId) return agentName ?? 'Agent';
      return landlordName;
    }
    if (currentUserId == tenantId) return landlordName;
    return tenantName.isNotEmpty ? tenantName : 'Unknown';
  }

  String getOtherPersonInitials(String currentUserId) {
    final name = getOtherPersonName(currentUserId);
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  bool get hasAgent =>
      currentAgentId != null && currentAgentId!.isNotEmpty;

  int getUnreadCount(String userId) => unreadCounts[userId] ?? 0;

  String get formattedTime {
    final now = DateTime.now();
    final difference = now.difference(lastMessageTime);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return '${lastMessageTime.day}/${lastMessageTime.month}/${lastMessageTime.year}';
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

  bool get isSystemMessage => senderRole == 'system' || senderId == 'system';

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
      timestamp:
          (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
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