import '../models/conversation_model.dart';
import '../models/message_model.dart';
import 'mock_properties.dart';

// Mock current user IDs (will be replaced with Firebase Auth)
const String mockLandlordId = 'landlord_001';
const String mockTenantId = 'tenant_001';

// Mock conversations
final List<ConversationModel> mockConversations = [
  ConversationModel(
    id: 'conv_001',
    propertyId: 'prop_001',
    propertyTitle: '3 Bedroom Flat in Lekki Phase 1',
    propertyImage: 'https://images.unsplash.com/photo-1560448204-e02f11c3d0e2?w=800',
    landlordId: mockLandlordId,
    landlordName: 'Chief Okonkwo',
    tenantId: 'tenant_002',
    tenantName: 'Adebayo Johnson',
    lastMessage: 'Is the property still available?',
    lastMessageTime: DateTime.now().subtract(const Duration(minutes: 5)),
    lastMessageSenderId: 'tenant_002',
    unreadCount: 2,
    property: mockProperties[0],
  ),
  ConversationModel(
    id: 'conv_002',
    propertyId: 'prop_002',
    propertyTitle: '2 Bedroom Apartment in Yaba',
    propertyImage: 'https://images.unsplash.com/photo-1502672260266-1c1ef2d93688?w=800',
    landlordId: mockLandlordId,
    landlordName: 'Chief Okonkwo',
    tenantId: 'tenant_003',
    tenantName: 'Chioma Eze',
    lastMessage: 'Thank you for the information. I\'ll visit tomorrow.',
    lastMessageTime: DateTime.now().subtract(const Duration(hours: 2)),
    lastMessageSenderId: 'tenant_003',
    unreadCount: 0,
    property: mockProperties[1],
  ),
  ConversationModel(
    id: 'conv_003',
    propertyId: 'prop_003',
    propertyTitle: 'Luxury Duplex in Ikoyi',
    propertyImage: 'https://images.unsplash.com/photo-1600596542815-ffad4c1539a9?w=800',
    landlordId: 'landlord_002',
    landlordName: 'Mrs. Adeyemi',
    tenantId: mockTenantId,
    tenantName: 'Mide',
    lastMessage: 'The rent is NGN 3.5M per year, negotiable.',
    lastMessageTime: DateTime.now().subtract(const Duration(days: 1)),
    lastMessageSenderId: 'landlord_002',
    unreadCount: 1,
    property: mockProperties.length > 2 ? mockProperties[2] : mockProperties[0],
  ),
  ConversationModel(
    id: 'conv_004',
    propertyId: 'prop_004',
    propertyTitle: 'Self Contain in Surulere',
    propertyImage: 'https://images.unsplash.com/photo-1560185007-cde436f6a4d0?w=800',
    landlordId: 'landlord_003',
    landlordName: 'Mr. Balogun',
    tenantId: mockTenantId,
    tenantName: 'Mide',
    lastMessage: 'When can I schedule a viewing?',
    lastMessageTime: DateTime.now().subtract(const Duration(days: 3)),
    lastMessageSenderId: mockTenantId,
    unreadCount: 0,
    property: mockProperties.length > 3 ? mockProperties[3] : mockProperties[0],
  ),
];

// Mock messages for conversation 1
final List<MessageModel> mockMessagesConv1 = [
  MessageModel(
    id: 'msg_001',
    conversationId: 'conv_001',
    senderId: 'tenant_002',
    senderName: 'Adebayo Johnson',
    text: 'Hello, I saw your property listing on ClearRent.',
    timestamp: DateTime.now().subtract(const Duration(hours: 3)),
  ),
  MessageModel(
    id: 'msg_002',
    conversationId: 'conv_001',
    senderId: mockLandlordId,
    senderName: 'Chief Okonkwo',
    text: 'Good afternoon! Yes, the 3 bedroom flat in Lekki. How can I help you?',
    timestamp: DateTime.now().subtract(const Duration(hours: 2, minutes: 45)),
  ),
  MessageModel(
    id: 'msg_003',
    conversationId: 'conv_001',
    senderId: 'tenant_002',
    senderName: 'Adebayo Johnson',
    text: 'I\'m interested in renting it. Is it still available?',
    timestamp: DateTime.now().subtract(const Duration(hours: 2, minutes: 30)),
  ),
  MessageModel(
    id: 'msg_004',
    conversationId: 'conv_001',
    senderId: mockLandlordId,
    senderName: 'Chief Okonkwo',
    text: 'Yes, it\'s still available. The rent is NGN 1.8M per year. Would you like to schedule a viewing?',
    timestamp: DateTime.now().subtract(const Duration(hours: 1)),
  ),
  MessageModel(
    id: 'msg_005',
    conversationId: 'conv_001',
    senderId: 'tenant_002',
    senderName: 'Adebayo Johnson',
    text: 'That sounds good. What documents do I need to bring?',
    timestamp: DateTime.now().subtract(const Duration(minutes: 30)),
  ),
  MessageModel(
    id: 'msg_006',
    conversationId: 'conv_001',
    senderId: 'tenant_002',
    senderName: 'Adebayo Johnson',
    text: 'Is the property still available?',
    timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
  ),
];

// Mock messages for conversation 2
final List<MessageModel> mockMessagesConv2 = [
  MessageModel(
    id: 'msg_010',
    conversationId: 'conv_002',
    senderId: 'tenant_003',
    senderName: 'Chioma Eze',
    text: 'Hi, I\'m looking for a 2 bedroom apartment in Yaba.',
    timestamp: DateTime.now().subtract(const Duration(days: 1)),
  ),
  MessageModel(
    id: 'msg_011',
    conversationId: 'conv_002',
    senderId: mockLandlordId,
    senderName: 'Chief Okonkwo',
    text: 'Hello Chioma! I have a lovely 2 bedroom available. It has 24/7 power and security.',
    timestamp: DateTime.now().subtract(const Duration(hours: 20)),
  ),
  MessageModel(
    id: 'msg_012',
    conversationId: 'conv_002',
    senderId: 'tenant_003',
    senderName: 'Chioma Eze',
    text: 'What\'s the rent and is there parking space?',
    timestamp: DateTime.now().subtract(const Duration(hours: 10)),
  ),
  MessageModel(
    id: 'msg_013',
    conversationId: 'conv_002',
    senderId: mockLandlordId,
    senderName: 'Chief Okonkwo',
    text: 'NGN 850K per year. Yes, there\'s parking for one car. No agent fee - you\'re dealing directly with me.',
    timestamp: DateTime.now().subtract(const Duration(hours: 5)),
  ),
  MessageModel(
    id: 'msg_014',
    conversationId: 'conv_002',
    senderId: 'tenant_003',
    senderName: 'Chioma Eze',
    text: 'Thank you for the information. I\'ll visit tomorrow.',
    timestamp: DateTime.now().subtract(const Duration(hours: 2)),
  ),
];

// Mock messages for conversation 3 (tenant view)
final List<MessageModel> mockMessagesConv3 = [
  MessageModel(
    id: 'msg_020',
    conversationId: 'conv_003',
    senderId: mockTenantId,
    senderName: 'Mide',
    text: 'Good day, I\'m interested in your duplex in Ikoyi.',
    timestamp: DateTime.now().subtract(const Duration(days: 2)),
  ),
  MessageModel(
    id: 'msg_021',
    conversationId: 'conv_003',
    senderId: 'landlord_002',
    senderName: 'Mrs. Adeyemi',
    text: 'Hello! Thank you for reaching out. It\'s a 4 bedroom duplex with BQ.',
    timestamp: DateTime.now().subtract(const Duration(days: 1, hours: 20)),
  ),
  MessageModel(
    id: 'msg_022',
    conversationId: 'conv_003',
    senderId: mockTenantId,
    senderName: 'Mide',
    text: 'What\'s the annual rent?',
    timestamp: DateTime.now().subtract(const Duration(days: 1, hours: 10)),
  ),
  MessageModel(
    id: 'msg_023',
    conversationId: 'conv_003',
    senderId: 'landlord_002',
    senderName: 'Mrs. Adeyemi',
    text: 'The rent is NGN 3.5M per year, negotiable.',
    timestamp: DateTime.now().subtract(const Duration(days: 1)),
  ),
];

// Get messages for a specific conversation
List<MessageModel> getMessagesForConversation(String conversationId) {
  switch (conversationId) {
    case 'conv_001':
      return mockMessagesConv1;
    case 'conv_002':
      return mockMessagesConv2;
    case 'conv_003':
      return mockMessagesConv3;
    default:
      return [];
  }
}

// Get conversations for landlord
List<ConversationModel> getLandlordConversations() {
  return mockConversations
      .where((c) => c.landlordId == mockLandlordId)
      .toList()
    ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
}

// Get conversations for tenant
List<ConversationModel> getTenantConversations() {
  return mockConversations
      .where((c) => c.tenantId == mockTenantId)
      .toList()
    ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
}