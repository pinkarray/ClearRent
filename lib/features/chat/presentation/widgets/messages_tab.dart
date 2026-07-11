import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/conversation_service.dart';

class MessagesTabReal extends StatefulWidget {
  final String emptyTitle;
  final String emptySubtitle;

  const MessagesTabReal({
    super.key,
    this.emptyTitle = 'No messages yet',
    this.emptySubtitle = 'Your conversations will appear here',
  });

  @override
  State<MessagesTabReal> createState() => _MessagesTabRealState();
}

class _MessagesTabRealState extends State<MessagesTabReal> {
  final ConversationService _conversationService = ConversationService();
  // Cached so a retry/refresh setState() doesn't recreate the stream.
  late final Stream<List<ConversationData>> _conversationsStream =
      _conversationService.getConversationsStream();

  @override
  Widget build(BuildContext context) {
    final currentUserId = _conversationService.currentUserId ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Messages',
            style: AppTextStyles.h2,
          ),
        ),
        Expanded(
          child: StreamBuilder<List<ConversationData>>(
            stream: _conversationsStream,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                );
              }

              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: AppColors.error),
                      const SizedBox(height: 16),
                      Text(
                        'Failed to load messages',
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() {}),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }

              final conversations = snapshot.data ?? [];

              if (conversations.isEmpty) {
                return GuidanceEmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: widget.emptyTitle,
                  subtitle: widget.emptySubtitle,
                );
              }

              return RefreshIndicator(
                onRefresh: () async {
                  // Force rebuild by triggering setState
                  setState(() {});
                },
                color: AppColors.primary,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: conversations.length,
                  itemBuilder: (context, index) {
                    final conversation = conversations[index];
                    return _ConversationTile(
                      conversation: conversation,
                      currentUserId: currentUserId,
                      onTap: () {
                        context.push(
                          '/chat',
                          extra: {
                            'conversationId': conversation.id,
                            'propertyTitle': conversation.propertyTitle,
                            'propertyImage': conversation.propertyImage,
                          },
                        );
                      },
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

}

class _ConversationTile extends StatelessWidget {
  final ConversationData conversation;
  final String currentUserId;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    required this.currentUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final otherPersonName = conversation.getOtherPersonName(currentUserId);
    final otherPersonInitials = conversation.getOtherPersonInitials(currentUserId);
    final unreadCount = conversation.getUnreadCount(currentUserId);
    final isUnread = unreadCount > 0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUnread ? AppColors.primary.withAlpha(13) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isUnread ? AppColors.primary.withAlpha(51) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  otherPersonInitials,
                  style: AppTextStyles.h4.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name and time
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          otherPersonName,
                          style: AppTextStyles.labelLarge.copyWith(
                            fontWeight: isUnread ? FontWeight.w700 : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        conversation.formattedTime,
                        style: AppTextStyles.caption.copyWith(
                          color: isUnread ? AppColors.primary : AppColors.textHint,
                          fontWeight: isUnread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),

                  // Property name
                  Text(
                    conversation.propertyTitle,
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),

                  // Last message and unread badge
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.lastMessage.isEmpty
                              ? 'No messages yet'
                              : conversation.lastMessage,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: isUnread
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight: isUnread ? FontWeight.w500 : FontWeight.normal,
                            fontStyle: conversation.lastMessage.isEmpty
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isUnread) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$unreadCount',
                            style: AppTextStyles.labelSmall.copyWith(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
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
}