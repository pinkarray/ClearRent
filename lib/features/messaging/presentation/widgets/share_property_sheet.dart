import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/models/conversation_model.dart';

class SharePropertySheet extends StatelessWidget {
  final PropertyModel property;
  final List<ConversationModel> conversations;
  final String currentUserId;
  final Function(ConversationModel conversation)? onSendInApp;

  const SharePropertySheet({
    super.key,
    required this.property,
    required this.conversations,
    required this.currentUserId,
    this.onSendInApp,
  });

  void _shareExternal(BuildContext context) {
    final shareText = '''Check out this property on ClearRent!

🏠 ${property.title}
💰 ${property.formattedRent}${property.rentPeriod}
📍 ${property.city}, ${property.state}
🛏️ ${property.bedrooms} Bedrooms • 🚿 ${property.bathrooms} Bathrooms

${property.description.length > 150 ? '${property.description.substring(0, 150)}...' : property.description}

Download ClearRent to view more: https://clearrent.app''';

    Navigator.pop(context);
    Share.share(shareText, subject: 'Property on ClearRent: ${property.title}');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Text(
            'Share Property',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),

          // Property preview
          Container(
            margin: const EdgeInsets.symmetric(vertical: 16),
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
                  child: Image.network(
                    property.images.isNotEmpty
                        ? property.images.first
                        : 'https://via.placeholder.com/60',
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 60,
                      height: 60,
                      color: AppColors.background,
                      child: const Icon(Icons.home, color: AppColors.textHint),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        property.title,
                        style: AppTextStyles.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${property.formattedRent}${property.rentPeriod}',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Send in ClearRent option
          _ShareOption(
            icon: Icons.chat_bubble_outline,
            iconColor: AppColors.primary,
            title: 'Send in ClearRent',
            subtitle: 'Share with your conversations',
            onTap: () {
              Navigator.pop(context);
              _showConversationPicker(context);
            },
          ),

          const SizedBox(height: 12),

          // Share to other apps option
          _ShareOption(
            icon: Icons.share_outlined,
            iconColor: AppColors.info,
            title: 'Share to other apps',
            subtitle: 'WhatsApp, Twitter, Copy link...',
            onTap: () => _shareExternal(context),
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  void _showConversationPicker(BuildContext context) {
    if (conversations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No conversations yet. Start a chat with a landlord first!'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _ConversationPickerSheet(
        conversations: conversations,
        currentUserId: currentUserId,
        property: property,
        onSelect: (conversation) {
          Navigator.pop(context);
          onSendInApp?.call(conversation);
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Property shared with ${conversation.getOtherPersonName(currentUserId)}'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.success,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ShareOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ShareOption({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: iconColor.withAlpha(26),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: iconColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppColors.textHint,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationPickerSheet extends StatelessWidget {
  final List<ConversationModel> conversations;
  final String currentUserId;
  final PropertyModel property;
  final Function(ConversationModel) onSelect;

  const _ConversationPickerSheet({
    required this.conversations,
    required this.currentUserId,
    required this.property,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Text(
            'Send to...',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 16),

          // Conversations list
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final conversation = conversations[index];
                final otherPersonName = conversation.getOtherPersonName(currentUserId);
                final otherPersonInitials = conversation.getOtherPersonInitials(currentUserId);

                return GestureDetector(
                  onTap: () => onSelect(conversation),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
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
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                otherPersonName,
                                style: AppTextStyles.labelLarge,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                conversation.propertyTitle,
                                style: AppTextStyles.caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(26),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.send,
                            size: 16,
                            color: AppColors.primary,
                          ),
                        ),
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