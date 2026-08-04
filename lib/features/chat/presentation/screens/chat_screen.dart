import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/saved_properties_service.dart';
import '../../../../shared/models/property_model.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String? propertyTitle;
  final String? propertyImage;
  /// Optional pre-filled message text. The user can edit or discard before
  /// sending — we never auto-send. Used by features like agent reschedule
  /// that want to draft a message for the user.
  final String? initialDraft;

  /// Optional tappable openers shown in the empty state. Tapping one fills the
  /// input so the user can edit it; like [initialDraft], nothing is sent until
  /// they hit send. Used where a blank box is intimidating — e.g. a tenant
  /// reaching a handler for the first time after paying.
  final List<String>? suggestions;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.propertyTitle,
    this.propertyImage,
    this.initialDraft,
    this.suggestions,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ConversationService _conversationService = ConversationService();
  final AuthService _authService = AuthService();
  final VerificationService _verificationService = VerificationService();
  final PropertyService _propertyService = PropertyService();

  // Cached once (conversationId is fixed for this screen) so sending/typing
  // setState()s don't recreate the stream and reload the message list.
  late final Stream<List<MessageData>> _messagesStream =
      _conversationService.getMessagesStream(widget.conversationId);

  ConversationData? _conversation;
  List<MessageData> _messages = [];
  bool _isLoading = true;
  String _currentUserName = '';
  String _currentUserRole = 'tenant';
  String? _currentUserId;
  
  // Verification status
  bool _isCurrentUserVerified = false;
  bool _isOtherPartyVerified = false;
  bool _isCheckingVerification = true;
  
  // Call permission
  bool _otherPartyAllowsCalls = false;
  String? _otherPartyPhone;

  @override
  void initState() {
    super.initState();
    _currentUserId = _authService.currentUser?.uid;
    if (widget.initialDraft != null && widget.initialDraft!.isNotEmpty) {
      _messageController.text = widget.initialDraft!;
    }
    _loadData();
  }

  @override
  void dispose() {
    _conversationService.deleteIfEmpty(widget.conversationId);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    // Load user profile for sender name and role
    final profile = await _authService.getUserProfile();
    _currentUserName = profile?['fullName'] ?? 'User';
    _currentUserRole = profile?['accountType'] ?? 'tenant';

    // Load conversation details
    final conversation = await _conversationService.getConversation(widget.conversationId);
    
    if (mounted) {
      setState(() {
        _conversation = conversation;
        _isLoading = false;
      });

      // Mark as read
      _conversationService.markConversationAsRead(widget.conversationId);
      
      // Check verification status and call permissions for both parties
      _checkVerificationAndCallPermissions();
    }
  }

  Future<void> _checkVerificationAndCallPermissions() async {
    if (_conversation == null || _currentUserId == null) {
      setState(() => _isCheckingVerification = false);
      return;
    }

    try {
      // Check current user's verification using existing method (no parameter)
      final currentUserStatus = await _verificationService.getVerificationStatus();
      _isCurrentUserVerified = currentUserStatus.status == VerificationStatus.verified;

      // Determine other party and check their verification + call permission
      String? otherPartyId;
      if (_currentUserId == _conversation!.tenantId) {
        // Current user is tenant, other party is landlord
        otherPartyId = _conversation!.landlordId;
      } else if (_currentUserId == _conversation!.landlordId) {
        // Landlord's other party: tenant if present, otherwise agent
        if (_conversation!.tenantId.isNotEmpty) {
          otherPartyId = _conversation!.tenantId;
        } else if (_conversation!.agentId != null && _conversation!.agentId!.isNotEmpty) {
          otherPartyId = _conversation!.agentId;
        }
      } else if (_currentUserId == _conversation!.agentId) {
        // Agent's other party depends on conversation type:
        // In agent-tenant-landlord chats, other party is tenant
        // In agent-landlord only chats (no tenant), other party is landlord
        if (_conversation!.tenantId.isNotEmpty) {
          otherPartyId = _conversation!.tenantId;
        } else if (_conversation!.landlordId.isNotEmpty) {
          otherPartyId = _conversation!.landlordId;
        }
      }

      if (otherPartyId != null) {
        // Check other party's verification and call permission directly from Firestore
        final otherPartyDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(otherPartyId)
            .get();
        
        if (otherPartyDoc.exists) {
          final otherPartyData = otherPartyDoc.data();
          final otherPartyStatus = otherPartyData?['verificationStatus'] ?? 'none';
          _isOtherPartyVerified = otherPartyStatus == 'verified';
          
          // Check call permission (landlords can opt-in)
          _otherPartyAllowsCalls = otherPartyData?['allowsCalls'] ?? false;
          _otherPartyPhone = otherPartyData?['phone'];
        }
      }
    } catch (e) {
      debugPrint('❌ Error checking verification: $e');
    }

    if (mounted) {
      setState(() => _isCheckingVerification = false);
    }
  }

  bool get _canSendMessages => _isCurrentUserVerified && _isOtherPartyVerified;
  bool get _canMakeCall => _otherPartyAllowsCalls && _otherPartyPhone != null && _otherPartyPhone!.isNotEmpty;

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _sendMessage() async {
    if (!_canSendMessages) {
      _showVerificationRequired();
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    final message = await _conversationService.sendMessage(
      conversationId: widget.conversationId,
      text: text,
      senderName: _currentUserName,
      senderRole: _currentUserRole,
    );

    if (message != null) {
      _scrollToBottom();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to send message'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  Future<void> _makeCall() async {
    if (!_canMakeCall) {
      if (!_otherPartyAllowsCalls) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('This user has not enabled phone calls'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.warning,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Phone number not available'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.error,
          ),
        );
      }
      return;
    }

    final uri = Uri.parse('tel:$_otherPartyPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not open phone dialer'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  void _showVerificationRequired() {
    String message;
    String actionText;
    VoidCallback? onAction;

    if (!_isCurrentUserVerified) {
      message = 'You need to be verified to send messages.';
      actionText = 'Get Verified';
      onAction = () {
        Navigator.pop(context);
        // Navigate to verification screen based on user role
        if (_currentUserRole == 'landlord') {
          context.push('/landlord/verification');
        } else if (_currentUserRole == 'agent') {
          context.push('/agent/verification');
        } else {
          context.push('/tenant/verification');
        }
      };
    } else if (!_isOtherPartyVerified) {
      message = 'The other party hasn\'t completed verification yet. Messaging will be available once they\'re verified.';
      actionText = 'OK';
      onAction = () => Navigator.pop(context);
    } else {
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.verified_user_outlined, color: AppColors.warning),
            const SizedBox(width: 8),
            const Text('Verification Required'),
          ],
        ),
        content: Text(message),
        actions: [
          if (!_isCurrentUserVerified)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ElevatedButton(
            onPressed: onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(actionText),
          ),
        ],
      ),
    );
  }

  /// Get role badge color
  Color _getRoleBadgeColor(String role) {
    switch (role.toLowerCase()) {
      case 'system':
        return AppColors.textHint;
      case 'landlord':
        return const Color(0xFF6366F1); // Indigo
      case 'agent':
        return const Color(0xFF10B981); // Green/Teal
      case 'tenant':
        return const Color(0xFF3B82F6); // Blue
      default:
        return AppColors.textSecondary;
    }
  }

  /// Get role badge label
  String _getRoleBadgeLabel(String role) {
    switch (role.toLowerCase()) {
      case 'system':
        return 'System';
      case 'landlord':
        return 'Landlord';
      case 'agent':
        return 'Agent';
      case 'tenant':
        return 'Tenant';
      default:
        return role;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: const Text('Loading...'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final otherPersonName = _conversation?.getOtherPersonName(_currentUserId ?? '') ?? 'Chat';
    final otherPersonInitials = _conversation?.getOtherPersonInitials(_currentUserId ?? '') ?? '?';
    
    // Determine the other person's role for display in app bar.
    // Mirrors getOtherPersonName's counterpart precedence so the label
    // matches the name shown (e.g. an agent↔landlord chat isn't labelled
    // "Tenant").
    String otherPersonRole = 'User';
    if (_conversation != null && _currentUserId != null) {
      final c = _conversation!;
      final hasTenant = c.tenantId.isNotEmpty;
      final hasAgent = c.agentId != null && c.agentId!.isNotEmpty;
      if (_currentUserId == c.landlordId) {
        // Landlord's counterpart: tenant if present, else agent.
        otherPersonRole = hasTenant ? 'Tenant' : (hasAgent ? 'Agent' : 'User');
      } else if (_currentUserId == c.agentId) {
        // Agent's counterpart: tenant if present, else landlord.
        otherPersonRole = hasTenant ? 'Tenant' : 'Landlord';
      } else if (_currentUserId == c.tenantId) {
        // Tenant's counterpart: landlord (plus agent if one is on the thread).
        otherPersonRole = hasAgent ? 'Landlord / Agent' : 'Landlord';
      }
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            // Avatar with verification indicator
            Stack(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      otherPersonInitials,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
                // Verification badge
                if (_isOtherPartyVerified)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: AppColors.success,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2),
                      ),
                      child: const Icon(
                        Icons.check,
                        size: 8,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          otherPersonName,
                          style: AppTextStyles.labelLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_isOtherPartyVerified) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.verified,
                          size: 14,
                          color: AppColors.primary,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    otherPersonRole,
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Call button - only show if other party allows calls
          IconButton(
            icon: Icon(
              Icons.phone_outlined,
              color: _canMakeCall ? AppColors.primary : AppColors.textHint,
            ),
            onPressed: _makeCall,
          ),
          IconButton(
            icon: Icon(Icons.more_vert, color: AppColors.textPrimary),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          // Property reference card
          if (_conversation != null) _buildPropertyCard(),

          // Verification warning banner
          if (!_isCheckingVerification && !_canSendMessages)
            _buildVerificationBanner(),

          // Messages list (real-time stream)
          Expanded(
            child: StreamBuilder<List<MessageData>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && _messages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasData) {
                  _messages = snapshot.data!;
                  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
                }

                if (_messages.isEmpty) {
                  final showSuggestions = _canSendMessages &&
                      widget.suggestions != null &&
                      widget.suggestions!.isNotEmpty;
                  return Column(
                    children: [
                      Expanded(
                        child: GuidanceEmptyState(
                          icon: Icons.chat_bubble_outline,
                          title: 'Start the conversation',
                          subtitle: _isCheckingVerification || _canSendMessages
                              ? 'Send a message to begin chatting'
                              : 'Both parties need to be verified to chat',
                        ),
                      ),
                      if (showSuggestions) _buildSuggestionChips(),
                    ],
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    final isMe = message.senderId == _currentUserId;
                    final showDate = index == 0 ||
                        !_isSameDay(_messages[index - 1].timestamp, message.timestamp);
                    
                    final isFirstInGroup = index == 0 || 
                        _messages[index - 1].senderId != message.senderId ||
                        showDate;

                    return Column(
                      children: [
                        if (showDate) _buildDateDivider(message.timestamp),
                        message.isSystemMessage
                            ? _buildSystemMessage(message)
                            : message.isPropertyShare
                                ? _buildPropertyShareCard(message, isMe, isFirstInGroup)
                                : _buildMessageBubble(message, isMe, isFirstInGroup),
                      ],
                    );
                  },
                );
              },
            ),
          ),

          // Message input
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildVerificationBanner() {
    String message;
    IconData icon;
    Color color;

    if (!_isCurrentUserVerified) {
      message = 'Complete verification to send messages';
      icon = Icons.warning_amber_rounded;
      color = AppColors.warning;
    } else if (!_isOtherPartyVerified) {
      message = 'Waiting for the other party to complete verification';
      icon = Icons.hourglass_empty;
      color = AppColors.info;
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.bodySmall.copyWith(color: color),
            ),
          ),
          if (!_isCurrentUserVerified)
            TextButton(
              onPressed: () {
                if (_currentUserRole == 'landlord') {
                  context.push('/landlord/verification');
                } else if (_currentUserRole == 'agent') {
                  context.push('/agent/verification');
                } else {
                  context.push('/tenant/verification');
                }
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                backgroundColor: color,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                'Verify Now',
                style: AppTextStyles.labelSmall.copyWith(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPropertyCard() {
    final propertyTitle = widget.propertyTitle ?? _conversation?.propertyTitle ?? 'Property';
    final propertyImage = widget.propertyImage ?? _conversation?.propertyImage ?? '';

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: propertyImage.isNotEmpty
                ? Image.network(
                    propertyImage,
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 60,
                      height: 60,
                      color: AppColors.background,
                      child: Icon(Icons.home, color: AppColors.textHint),
                    ),
                  )
                : Container(
                    width: 60,
                    height: 60,
                    color: AppColors.background,
                    child: Icon(Icons.home, color: AppColors.textHint),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  propertyTitle,
                  style: AppTextStyles.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'Property inquiry',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateDivider(DateTime date) {
    String text;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      text = 'Today';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      text = 'Yesterday';
    } else {
      text = '${date.day}/${date.month}/${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              text,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textHint,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  Widget _buildSystemMessage(MessageData message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            message.text,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(MessageData message, bool isMe, bool isFirstInGroup) {
    String senderRole = message.senderRole;
    if (senderRole.isEmpty && _conversation != null) {
      if (message.senderId == _conversation!.landlordId) {
        senderRole = 'landlord';
      } else if (message.senderId == _conversation!.agentId) {
        senderRole = 'agent';
      } else if (message.senderId == _conversation!.tenantId) {
        senderRole = 'tenant';
      }
    }

    final roleColor = _getRoleBadgeColor(senderRole);
    final roleLabel = _getRoleBadgeLabel(senderRole);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: 4,
          top: isFirstInGroup ? 8 : 0,
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sender name and role badge (only for received messages and first in group)
            if (!isMe && isFirstInGroup) ...[
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.senderName,
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Role badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: roleColor.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: roleColor.withAlpha(77)),
                      ),
                      child: Text(
                        roleLabel,
                        style: AppTextStyles.caption.copyWith(
                          color: roleColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Message bubble
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                border: isMe ? null : Border.all(color: AppColors.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(8),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.text,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: isMe ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message.formattedTime,
                        style: AppTextStyles.caption.copyWith(
                          color: isMe ? Colors.white.withAlpha(179) : AppColors.textHint,
                          fontSize: 10,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        Icon(
                          message.isRead ? Icons.done_all : Icons.done,
                          size: 14,
                          color: message.isRead ? Colors.white : Colors.white.withAlpha(179),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tappable card rendered in place of a text bubble when a message is a
  /// shared property. Reads the snapshot fields stored on the message so it
  /// renders even if the property was later edited or deleted.
  Widget _buildPropertyShareCard(
      MessageData message, bool isMe, bool isFirstInGroup) {
    final title = message.sharedPropertyTitle ?? 'Property';
    final image = message.sharedPropertyImage ?? '';
    final rent = message.sharedPropertyRent ?? '';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: 4,
          top: isFirstInGroup ? 8 : 0,
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isMe && isFirstInGroup) ...[
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(
                  message.senderName,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            GestureDetector(
              onTap: () => _openSharedProperty(message.sharedPropertyId!),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  border: Border.all(color: AppColors.primary.withAlpha(77)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(8),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      child: image.isNotEmpty
                          ? Image.network(
                              image,
                              height: 140,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Container(
                                height: 140,
                                color: AppColors.background,
                                child: Icon(Icons.home,
                                    color: AppColors.textHint, size: 40),
                              ),
                            )
                          : Container(
                              height: 140,
                              color: AppColors.background,
                              child: Icon(Icons.home,
                                  color: AppColors.textHint, size: 40),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.home_work_outlined,
                                  size: 14, color: AppColors.primary),
                              const SizedBox(width: 4),
                              Text(
                                'Shared property',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title,
                            style: AppTextStyles.labelMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (rent.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              rent,
                              style: AppTextStyles.labelLarge.copyWith(
                                color: AppColors.primary,
                                fontFamily: 'Roboto',
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Tap to view',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(Icons.chevron_right,
                                  size: 14, color: AppColors.primary),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
              child: Text(
                message.formattedTime,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Fetch the shared property and open its detail screen. Only navigates
  /// if the property still exists — the /property-detail route casts
  /// state.extra as a non-null PropertyModel, so pushing null would crash.
  Future<void> _openSharedProperty(String propertyId) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final property = await _propertyService.getProperty(propertyId);

    if (!mounted) return;

    if (property == null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('This property is no longer available'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    router.push('/property-detail', extra: property);
  }

  /// Open the property picker so the user can share a listing into this
  /// conversation. On selection, sends a property-share message via
  /// sendPropertyShare. Landlord → own listings, agent → assigned,
  /// tenant → saved.
  Future<void> _openPropertyPicker() async {
    final selected = await showModalBottomSheet<PropertyModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PropertyPickerSheet(
        role: _currentUserRole,
        propertyService: _propertyService,
        savedPropertiesService: SavedPropertiesService(),
      ),
    );

    if (selected == null || !mounted) return;

    final message = await _conversationService.sendPropertyShare(
      conversationId: widget.conversationId,
      senderName: _currentUserName,
      senderRole: _currentUserRole,
      propertyId: selected.id,
      propertyTitle: selected.title,
      propertyImage: selected.images.isNotEmpty ? selected.images.first : '',
      propertyRent: selected.formattedRent,
    );

    if (!mounted) return;

    if (message != null) {
      _scrollToBottom();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not share property. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  /// Tappable openers for an empty thread. Fills the input rather than
  /// sending — the user stays the author and can edit before it goes.
  Widget _buildSuggestionChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: widget.suggestions!.map((suggestion) {
          return GestureDetector(
            onTap: () {
              _messageController.text = suggestion;
              _messageController.selection = TextSelection.fromPosition(
                TextPosition(offset: suggestion.length),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.primary.withAlpha(77)),
              ),
              child: Text(
                suggestion,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMessageInput() {
    final bool inputEnabled = _canSendMessages;
    // While the verification check is still in flight we don't yet know the
    // real status, so present a neutral (non-blocked) bar instead of flashing
    // "Verification required" and then clearing it once the check resolves.
    final bool showBlocked = !_isCheckingVerification && !_canSendMessages;

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(13),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Row(
        children: [
          // Attachment button
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
              icon: Icon(
                Icons.attach_file,
                color: showBlocked ? AppColors.textHint : AppColors.textSecondary,
              ),
              onPressed: inputEnabled ? _openPropertyPicker : null,
            ),
          ),
          const SizedBox(width: 12),

          // Text input
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _messageController,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 4,
                minLines: 1,
                enabled: !showBlocked,
                decoration: InputDecoration(
                  hintText: showBlocked
                      ? 'Verification required to send messages'
                      : 'Type a message...',
                  hintStyle: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textHint,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onSubmitted: inputEnabled ? (_) => _sendMessage() : null,
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Send button
          GestureDetector(
            onTap: inputEnabled
                ? _sendMessage
                : (showBlocked ? _showVerificationRequired : null),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: showBlocked ? AppColors.textHint : AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.send,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

/// Bottom sheet that lists the user's properties (role-appropriate) and
/// pops the selected PropertyModel. Landlord → own, agent → assigned,
/// tenant → saved. Tenant cross-listing search is a fast-follow.
class _PropertyPickerSheet extends StatefulWidget {
  final String role;
  final PropertyService propertyService;
  final SavedPropertiesService savedPropertiesService;

  const _PropertyPickerSheet({
    required this.role,
    required this.propertyService,
    required this.savedPropertiesService,
  });

  @override
  State<_PropertyPickerSheet> createState() => _PropertyPickerSheetState();
}

class _PropertyPickerSheetState extends State<_PropertyPickerSheet> {
  bool _isLoading = true;
  List<PropertyModel> _properties = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<PropertyModel> result = [];
    try {
      switch (widget.role) {
        case 'landlord':
          result = await widget.propertyService.getLandlordProperties();
          break;
        case 'agent':
          result = await widget.propertyService.getAgentProperties();
          break;
        case 'tenant':
        default:
          final ids = await widget.savedPropertiesService.getSavedPropertyIds();
          for (final id in ids) {
            final p = await widget.propertyService.getProperty(id);
            if (p != null) result.add(p);
          }
          break;
      }
    } catch (_) {
      // Leave result empty — the empty state covers it.
    }

    if (mounted) {
      setState(() {
        _properties = result;
        _isLoading = false;
      });
    }
  }

  String get _emptyMessage {
    switch (widget.role) {
      case 'landlord':
        return 'You have no listings to share yet.';
      case 'agent':
        return 'You have no assigned properties to share yet.';
      case 'tenant':
      default:
        return 'You haven\'t saved any properties yet. Save a property to share it here.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: 20),
          Text('Share a property', style: AppTextStyles.h4),
          const SizedBox(height: 4),
          Text(
            'Pick a property to send into this chat',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          else if (_properties.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                _emptyMessage,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _properties.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final p = _properties[index];
                  return GestureDetector(
                    onTap: () => Navigator.pop(context, p),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: p.images.isNotEmpty
                                ? Image.network(
                                    p.images.first,
                                    width: 56,
                                    height: 56,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) =>
                                        Container(
                                      width: 56,
                                      height: 56,
                                      color: AppColors.surface,
                                      child: Icon(Icons.home,
                                          color: AppColors.textHint),
                                    ),
                                  )
                                : Container(
                                    width: 56,
                                    height: 56,
                                    color: AppColors.surface,
                                    child: Icon(Icons.home,
                                        color: AppColors.textHint),
                                  ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.title,
                                  style: AppTextStyles.labelMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  p.formattedRent,
                                  style: AppTextStyles.labelMedium.copyWith(
                                    color: AppColors.primary,
                                    fontFamily: 'Roboto',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.send, size: 18, color: AppColors.primary),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}