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

  // Everyone on this thread except me, as @-mentionable handles. Built once
  // when the conversation loads.
  List<_MentionTarget> _mentionTargets = [];
  // Candidates matching what's being typed after an '@'. Empty = no overlay.
  List<_MentionTarget> _mentionMatches = [];

  // Edit mode. Non-null means the composer is rewriting an existing message
  // rather than composing a new one.
  String? _editingMessageId;
  bool _editingIsLastMessage = false;

  // Guards the read-receipt write so a burst of stream frames doesn't fire
  // one batch update each.
  bool _markingRead = false;

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
        _mentionTargets = _buildMentionTargets(conversation);
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

  /// The other people on this thread, as mention handles.
  ///
  /// A conversation carries at most a landlord, a tenant and an agent, so this
  /// is two entries at the outside. The current user is excluded — you don't
  /// mention yourself.
  List<_MentionTarget> _buildMentionTargets(ConversationData? c) {
    if (c == null) return [];

    final raw = <({String uid, String name, String role})>[
      (uid: c.landlordId, name: c.landlordName, role: 'Landlord'),
      (uid: c.tenantId, name: c.tenantName, role: 'Tenant'),
      (uid: c.agentId ?? '', name: c.agentName ?? '', role: 'Agent'),
    ].where((e) => e.uid.isNotEmpty && e.uid != _currentUserId).toList();

    // First name, stripped to word characters so punctuation in a stored name
    // can't produce a handle the parser will never match.
    String firstName(String name) =>
        name.trim().split(RegExp(r'\s+')).first.replaceAll(RegExp(r'\W'), '');

    final handles = raw.map((e) {
      final f = firstName(e.name);
      return f.isEmpty ? e.role : f;
    }).toList();

    return [
      for (var i = 0; i < raw.length; i++)
        _MentionTarget(
          uid: raw[i].uid,
          // Two people with the same first name would otherwise both answer to
          // one handle, so collisions fall back to the whole name unspaced.
          handle: handles.where((h) => h == handles[i]).length > 1
              ? raw[i].name.replaceAll(RegExp(r'\W'), '')
              : handles[i],
          fullName: raw[i].name.isNotEmpty ? raw[i].name : raw[i].role,
          role: raw[i].role,
        ),
    ];
  }

  /// Recompute the mention overlay from the caret position.
  ///
  /// Matches on the word being typed after an '@' that starts a word — so an
  /// email address in the middle of a sentence doesn't open the picker.
  void _updateMentionMatches() {
    final selection = _messageController.selection;
    final text = _messageController.text;
    final caret = selection.baseOffset;

    List<_MentionTarget> matches = [];
    if (_mentionTargets.isNotEmpty && caret > 0 && caret <= text.length) {
      final before = text.substring(0, caret);
      final at = before.lastIndexOf('@');
      final startsWord = at == 0 || (at > 0 && before[at - 1].trim().isEmpty);
      if (at >= 0 && startsWord) {
        final query = before.substring(at + 1);
        if (!query.contains(RegExp(r'\s'))) {
          matches = _mentionTargets
              .where((t) =>
                  t.handle.toLowerCase().startsWith(query.toLowerCase()))
              .toList();
          // An exact, complete handle needs no picker — the user is done.
          if (matches.length == 1 &&
              matches.first.handle.toLowerCase() == query.toLowerCase()) {
            matches = [];
          }
        }
      }
    }

    if (matches.length != _mentionMatches.length ||
        !matches.every((m) => _mentionMatches.any((e) => e.uid == m.uid))) {
      setState(() => _mentionMatches = matches);
    }
  }

  /// Replace the partial "@que" at the caret with the chosen handle.
  void _insertMention(_MentionTarget target) {
    final text = _messageController.text;
    final caret = _messageController.selection.baseOffset;
    final at = text.substring(0, caret).lastIndexOf('@');
    if (at < 0) return;

    final replacement = '@${target.handle} ';
    final updated = text.replaceRange(at, caret, replacement);
    _messageController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: at + replacement.length),
    );
    setState(() => _mentionMatches = []);
  }

  /// Which mention handles actually survive in the text being sent. Resolved
  /// from the final string rather than from what was tapped, so a mention the
  /// user typed over or deleted doesn't ship a phantom uid.
  List<String> _resolveMentions(String text) {
    return _mentionTargets
        .where((t) => RegExp('@${RegExp.escape(t.handle)}\\b',
                caseSensitive: false)
            .hasMatch(text))
        .map((t) => t.uid)
        .toList();
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

  /// The composer's one action: saves the edit if one is in progress,
  /// otherwise sends a new message.
  Future<void> _submitComposer() {
    return _editingMessageId != null ? _saveEdit() : _sendMessage();
  }

  Future<void> _sendMessage() async {
    if (!_canSendMessages) {
      _showVerificationRequired();
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final mentions = _resolveMentions(text);
    _messageController.clear();
    setState(() => _mentionMatches = []);

    final message = await _conversationService.sendMessage(
      conversationId: widget.conversationId,
      text: text,
      senderName: _currentUserName,
      senderRole: _currentUserRole,
      mentions: mentions,
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

  /// Put a message the user sent back into the composer.
  void _startEditing(MessageData message) {
    setState(() {
      _editingMessageId = message.id;
      _editingIsLastMessage = _messages.isNotEmpty &&
          _messages.last.id == message.id;
      _mentionMatches = [];
    });
    _messageController.value = TextEditingValue(
      text: message.text,
      selection: TextSelection.collapsed(offset: message.text.length),
    );
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _editingIsLastMessage = false;
      _mentionMatches = [];
    });
    _messageController.clear();
  }

  Future<void> _saveEdit() async {
    final messageId = _editingMessageId;
    if (messageId == null) return;

    final text = _messageController.text.trim();
    // An edit down to nothing is a delete — the rules reject empty text on the
    // edit path, so offer the real action instead of failing the write.
    if (text.isEmpty) {
      _confirmDelete(messageId, _editingIsLastMessage);
      return;
    }

    final isLast = _editingIsLastMessage;
    final mentions = _resolveMentions(text);
    _cancelEditing();

    final ok = await _conversationService.editMessage(
      conversationId: widget.conversationId,
      messageId: messageId,
      newText: text,
      mentions: mentions,
      isLastMessage: isLast,
    );

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not edit that message'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  /// Long-press sheet on a message the user sent. Property shares can be
  /// deleted but not edited — there is no text on them to rewrite.
  void _showMessageActions(MessageData message) {
    final isLast = _messages.isNotEmpty && _messages.last.id == message.id;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            if (!message.isPropertyShare)
              ListTile(
                leading: Icon(Icons.edit_outlined, color: AppColors.textPrimary),
                title: Text('Edit message', style: AppTextStyles.bodyMedium),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _startEditing(message);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppColors.error),
              title: Text(
                'Delete message',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDelete(message.id, isLast);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(String messageId, bool isLast) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete message?'),
        content: const Text(
          'The message will be removed for everyone in this chat.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _deleteMessage(messageId, isLast);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMessage(String messageId, bool isLast) async {
    if (_editingMessageId == messageId) _cancelEditing();

    final ok = await _conversationService.deleteMessage(
      conversationId: widget.conversationId,
      messageId: messageId,
      isLastMessage: isLast,
    );

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not delete that message'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  /// Mark whatever just arrived as read, so the sender's second tick lands
  /// while both people are looking at the thread.
  ///
  /// Marking used to happen once, in [_loadData], which meant a message that
  /// arrived while the screen was already open was never receipted — the
  /// sender only saw it turn blue after the reader closed and reopened the
  /// chat.
  void _markIncomingRead() {
    if (_markingRead || _currentUserId == null) return;
    final hasUnread = _messages.any(
      (m) => m.senderId != _currentUserId && !m.isRead,
    );
    if (!hasUnread) return;

    _markingRead = true;
    _conversationService
        .markConversationAsRead(widget.conversationId)
        .whenComplete(() => _markingRead = false);
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
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToBottom();
                    _markIncomingRead();
                  });
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

          // @-mention picker, above the composer so it doesn't cover the text
          // being typed.
          if (_mentionMatches.isNotEmpty) _buildMentionPicker(),

          // "Editing message" strip, so it's obvious the send button will
          // replace an existing message rather than add a new one.
          if (_editingMessageId != null) _buildEditingBanner(),

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

            // Message bubble. Long-press opens edit/delete, but only on your
            // own messages and only while they still exist.
            GestureDetector(
              onLongPress: isMe && !message.deleted
                  ? () => _showMessageActions(message)
                  : null,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: message.deleted
                      ? AppColors.surface
                      : (isMe ? AppColors.primary : AppColors.surface),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  border: (isMe && !message.deleted)
                      ? null
                      : Border.all(color: AppColors.border),
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
                    if (message.deleted)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.block,
                              size: 14, color: AppColors.textHint),
                          const SizedBox(width: 6),
                          Text(
                            'This message was deleted',
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textHint,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      )
                    else
                      _buildMessageText(message.text, isMe),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.isEdited && !message.deleted) ...[
                          Text(
                            'edited',
                            style: AppTextStyles.caption.copyWith(
                              color: isMe
                                  ? Colors.white.withAlpha(179)
                                  : AppColors.textHint,
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          message.formattedTime,
                          style: AppTextStyles.caption.copyWith(
                            color: (isMe && !message.deleted)
                                ? Colors.white.withAlpha(179)
                                : AppColors.textHint,
                            fontSize: 10,
                          ),
                        ),
                        if (isMe && !message.deleted) ...[
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
            ),
          ],
        ),
      ),
    );
  }

  /// Message text with any `@handle` picked out.
  ///
  /// Highlighting is derived from the text against the thread's current
  /// members rather than from the stored `mentions` ids, so a mention still
  /// reads correctly on an old message and never highlights a stale span.
  Widget _buildMessageText(String text, bool isMe) {
    final base = AppTextStyles.bodyMedium.copyWith(
      color: isMe ? Colors.white : AppColors.textPrimary,
    );

    if (_mentionTargets.isEmpty || !text.contains('@')) {
      return Text(text, style: base);
    }

    final handles =
        _mentionTargets.map((t) => RegExp.escape(t.handle)).join('|');
    final pattern = RegExp('@($handles)\\b', caseSensitive: false);

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(TextSpan(
        text: match.group(0),
        style: base.copyWith(
          fontWeight: FontWeight.w700,
          // On my own (primary-filled) bubble white text is already the
          // contrast; the mention leans on weight plus a subtle underline.
          color: isMe ? Colors.white : AppColors.primary,
          decoration: isMe ? TextDecoration.underline : TextDecoration.none,
          decorationColor: Colors.white.withAlpha(140),
        ),
      ));
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return RichText(
      text: TextSpan(style: base, children: spans),
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
              onLongPress: isMe ? () => _showMessageActions(message) : null,
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

  /// The list of people offered while an '@' is being typed. At most two
  /// entries on any thread, so it needs no scrolling.
  Widget _buildMentionPicker() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _mentionMatches.map((target) {
          return InkWell(
            onTap: () => _insertMention(target),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(26),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        target.initials,
                        style: AppTextStyles.labelSmall.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(target.fullName,
                            style: AppTextStyles.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          '@${target.handle} · ${target.role}',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEditingBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withAlpha(77)),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_outlined, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Editing message',
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.primary),
            ),
          ),
          GestureDetector(
            onTap: _cancelEditing,
            child: Icon(Icons.close, size: 18, color: AppColors.textSecondary),
          ),
        ],
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
                onChanged: inputEnabled ? (_) => _updateMentionMatches() : null,
                onSubmitted: inputEnabled ? (_) => _submitComposer() : null,
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Send button — becomes "save" while an edit is in progress.
          GestureDetector(
            onTap: inputEnabled
                ? _submitComposer
                : (showBlocked ? _showVerificationRequired : null),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: showBlocked ? AppColors.textHint : AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _editingMessageId != null ? Icons.check : Icons.send,
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

/// Someone on this thread who can be @-mentioned.
///
/// [handle] is what gets typed and highlighted — a single token, because the
/// parser reads the word after '@' and full names contain spaces. It's the
/// person's first name, falling back to their role, and de-collided by
/// [_buildMentionTargets] when two people share a first name.
class _MentionTarget {
  final String uid;
  final String handle;
  final String fullName;
  final String role;

  const _MentionTarget({
    required this.uid,
    required this.handle,
    required this.fullName,
    required this.role,
  });

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';
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