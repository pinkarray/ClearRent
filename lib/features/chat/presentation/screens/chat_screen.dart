import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/verification_service.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String? propertyTitle;
  final String? propertyImage;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.propertyTitle,
    this.propertyImage,
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
    _loadData();
  }

  @override
  void dispose() {
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
        // Current user is landlord, other party is tenant
        otherPartyId = _conversation!.tenantId;
      } else if (_currentUserId == _conversation!.agentId) {
        // Current user is agent, other party is tenant
        otherPartyId = _conversation!.tenantId;
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
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: const Text('Loading...'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final otherPersonName = _conversation?.getOtherPersonName(_currentUserId ?? '') ?? 'Chat';
    final otherPersonInitials = _conversation?.getOtherPersonInitials(_currentUserId ?? '') ?? '?';
    
    // Determine the other person's role for display in app bar
    String otherPersonRole = 'User';
    if (_conversation != null && _currentUserId != null) {
      if (_currentUserId == _conversation!.landlordId) {
        otherPersonRole = 'Tenant';
      } else if (_currentUserId == _conversation!.tenantId) {
        otherPersonRole = _conversation!.agentId != null ? 'Landlord / Agent' : 'Landlord';
      } else if (_currentUserId == _conversation!.agentId) {
        otherPersonRole = 'Tenant';
      }
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
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
            icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
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
              stream: _conversationService.getMessagesStream(widget.conversationId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && _messages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasData) {
                  _messages = snapshot.data!;
                  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
                }

                if (_messages.isEmpty) {
                  return _buildEmptyState();
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
                        _buildMessageBubble(message, isMe, isFirstInGroup),
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
                      child: const Icon(Icons.home, color: AppColors.textHint),
                    ),
                  )
                : Container(
                    width: 60,
                    height: 60,
                    color: AppColors.background,
                    child: const Icon(Icons.home, color: AppColors.textHint),
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chat_bubble_outline,
              size: 40,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Start the conversation',
            style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            _canSendMessages 
                ? 'Send a message to begin chatting'
                : 'Both parties need to be verified to chat',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
            textAlign: TextAlign.center,
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

  Widget _buildMessageInput() {
    final bool inputEnabled = _canSendMessages;
    
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
                color: inputEnabled ? AppColors.textSecondary : AppColors.textHint,
              ),
              onPressed: inputEnabled ? () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('File attachment coming soon'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                );
              } : null,
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
                enabled: inputEnabled,
                decoration: InputDecoration(
                  hintText: inputEnabled 
                      ? 'Type a message...'
                      : 'Verification required to send messages',
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
            onTap: inputEnabled ? _sendMessage : _showVerificationRequired,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: inputEnabled ? AppColors.primary : AppColors.textHint,
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