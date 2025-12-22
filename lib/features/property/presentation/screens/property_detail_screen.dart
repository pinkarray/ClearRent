import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/models/conversation_model.dart';
import '../../../../shared/data/mock_conversations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../messaging/presentation/widgets/share_property_sheet.dart';
import '../../../../services/property_service.dart';

class PropertyDetailScreen extends StatefulWidget {
  final PropertyModel property;
  final String userType;

  const PropertyDetailScreen({
    super.key,
    required this.property,
    this.userType = 'tenant',
  });

  @override
  State<PropertyDetailScreen> createState() => _PropertyDetailScreenState();
}

class _PropertyDetailScreenState extends State<PropertyDetailScreen> {
  int _currentImageIndex = 0;
  bool _isSaved = false;
  final PageController _imageController = PageController();
  
  // Services - properly in state class
  late final PropertyService _propertyService;

  // Determine current user ID based on userType
  String get _currentUserId => widget.userType == 'landlord' ? mockLandlordId : mockTenantId;

  @override
  void initState() {
    super.initState();
    _propertyService = PropertyService();
    _trackView();
  }

  @override
  void dispose() {
    _imageController.dispose();
    super.dispose();
  }

  /// Track when a tenant views this property
  Future<void> _trackView() async {
    // Only track if user is a tenant (not landlord viewing their own property)
    if (widget.userType == 'tenant') {
      try {
        await _propertyService.trackPropertyView(
          propertyId: widget.property.id,
          landlordId: widget.property.landlordId,
          propertyTitle: widget.property.title,
        );
      } catch (e) {
        debugPrint('❌ Failed to track view: $e');
      }
    }
  }

  void _toggleSave() {
    setState(() => _isSaved = !_isSaved);
  }

  void _shareProperty() {
    final conversations = widget.userType == 'landlord'
        ? getLandlordConversations()
        : getTenantConversations();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => SharePropertySheet(
        property: widget.property,
        conversations: conversations,
        currentUserId: _currentUserId,
        onSendInApp: (conversation) {
          // In real app, this would send the property to the chat
          // For now, just show confirmation (handled in SharePropertySheet)
        },
      ),
    );
  }

  void _contactLandlord() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _ContactSheet(
        property: widget.property,
        currentUserId: _currentUserId,
        onStartChat: (conversation) {
          // Navigate to chat screen
          context.push(
            '/chat',
            extra: {
              'conversation': conversation,
              'currentUserId': _currentUserId,
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final property = widget.property;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  // Image carousel with back button
                  SliverToBoxAdapter(
                    child: _buildImageCarousel(property),
                  ),

                  // Content
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Price and save button
                          _buildPriceRow(property),

                          const SizedBox(height: 16),

                          // Title
                          Text(
                            property.title,
                            style: AppTextStyles.h3,
                          ),

                          const SizedBox(height: 8),

                          // Location
                          Row(
                            children: [
                              const Icon(
                                Icons.location_on,
                                size: 18,
                                color: AppColors.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${property.address}, ${property.city}, ${property.state}',
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // Features row
                          _buildFeaturesRow(property),

                          const SizedBox(height: 24),

                          // Landlord info
                          _buildLandlordCard(property),

                          const SizedBox(height: 24),

                          // Fee breakdown
                          _buildFeeBreakdown(property),

                          const SizedBox(height: 24),

                          // Description
                          _buildSection(
                            title: 'Description',
                            child: Text(
                              property.description,
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: AppColors.textSecondary,
                                height: 1.6,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Amenities
                          if (property.amenities.isNotEmpty)
                            _buildSection(
                              title: 'Amenities',
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: property.amenities.map((amenity) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryLight.withAlpha(26),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _getAmenityIcon(amenity),
                                          size: 16,
                                          color: AppColors.primary,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          amenity,
                                          style: AppTextStyles.labelMedium.copyWith(
                                            color: AppColors.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),

                          if (property.amenities.isNotEmpty)
                            const SizedBox(height: 24),

                          // House rules
                          if (property.rules.isNotEmpty)
                            _buildSection(
                              title: 'House Rules',
                              child: Column(
                                children: property.rules.map((rule) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.info_outline,
                                          size: 18,
                                          color: AppColors.warning,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            rule,
                                            style: AppTextStyles.bodyMedium,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),

                          const SizedBox(height: 100),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomSheet: _buildBottomBar(),
      ),
    );
  }

  Widget _buildImageCarousel(PropertyModel property) {
    return Stack(
      children: [
        // Images
        SizedBox(
          height: 300,
          child: property.images.isEmpty
              ? Container(
                  color: AppColors.background,
                  child: const Center(
                    child: Icon(
                      Icons.image_not_supported,
                      size: 50,
                      color: AppColors.textHint,
                    ),
                  ),
                )
              : PageView.builder(
                  controller: _imageController,
                  itemCount: property.images.length,
                  onPageChanged: (index) {
                    setState(() => _currentImageIndex = index);
                  },
                  itemBuilder: (context, index) {
                    return CachedNetworkImage(
                      imageUrl: property.images[index],
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: AppColors.background,
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: AppColors.background,
                        child: const Icon(
                          Icons.image_not_supported,
                          size: 50,
                          color: AppColors.textHint,
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Gradient overlay at top
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 100,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withAlpha(128),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // Back button
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          left: 16,
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(26),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Icon(
                Icons.arrow_back,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),

        // Share button
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          right: 16,
          child: GestureDetector(
            onTap: _shareProperty,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(26),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Icon(
                Icons.share_outlined,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),

        // Image indicators
        if (property.images.length > 1)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(property.images.length, (index) {
                return Container(
                  width: index == _currentImageIndex ? 24 : 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: index == _currentImageIndex
                        ? Colors.white
                        : Colors.white.withAlpha(128),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),

        // Verified badge
        if (property.isVerified)
          Positioned(
            bottom: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.verified,
                    size: 16,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    AppStrings.verified,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPriceRow(PropertyModel property) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          property.formattedRent,
          style: AppTextStyles.h2.copyWith(
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            property.rentPeriod,
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: _toggleSave,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _isSaved
                  ? AppColors.error.withAlpha(26)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isSaved ? AppColors.error : AppColors.border,
              ),
            ),
            child: Icon(
              _isSaved ? Icons.favorite : Icons.favorite_border,
              color: _isSaved ? AppColors.error : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFeaturesRow(PropertyModel property) {
    // Check if any features exist
    final hasFeatures = property.bedrooms > 0 || property.bathrooms > 0 || property.toilets > 0;
    
    if (!hasFeatures) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          if (property.bedrooms > 0)
            _FeatureItem(
              icon: Icons.bed_outlined,
              value: '${property.bedrooms}',
              label: 'Bedrooms',
            ),
          if (property.bathrooms > 0)
            _FeatureItem(
              icon: Icons.bathtub_outlined,
              value: '${property.bathrooms}',
              label: 'Bathrooms',
            ),
          if (property.toilets > 0)
            _FeatureItem(
              icon: Icons.wc_outlined,
              value: '${property.toilets}',
              label: 'Toilets',
            ),
        ],
      ),
    );
  }

  Widget _buildLandlordCard(PropertyModel property) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withAlpha(51),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                property.landlordName?.isNotEmpty == true 
                    ? property.landlordName!.substring(0, 1).toUpperCase() 
                    : 'L',
                style: AppTextStyles.h4.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      property.hasAgent ? 'Listed via Agent' : 'Direct Landlord',
                      style: AppTextStyles.caption,
                    ),
                    if (property.isVerified) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.verified,
                        size: 14,
                        color: AppColors.primary,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  property.landlordName ?? 'Landlord',
                  style: AppTextStyles.labelLarge,
                ),
              ],
            ),
          ),

          // Call button
          GestureDetector(
            onTap: () => _callLandlord(property),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.phone_outlined,
                color: AppColors.primary,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _callLandlord(PropertyModel property) {
    final phone = property.landlordPhone;
    if (phone != null && phone.isNotEmpty) {
      // launchUrl(Uri.parse('tel:$phone'));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Calling $phone...'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Phone number not available. Try sending a message instead.'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Widget _buildFeeBreakdown(PropertyModel property) {
    final rent = property.rent;
    final agentFee = property.hasAgent && property.agentFeePaidBy == 'tenant'
        ? rent * property.agentFee / 100
        : 0.0;
    final total = rent + agentFee;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.infoLight.withAlpha(128),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.info.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.receipt_long_outlined,
                size: 20,
                color: AppColors.info,
              ),
              const SizedBox(width: 8),
              Text(
                AppStrings.feeBreakdown,
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.info,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          _FeeRow(
            label: AppStrings.rentToLandlord,
            amount: rent,
          ),
          
          if (agentFee > 0) ...[
            const SizedBox(height: 8),
            _FeeRow(
              label: '${AppStrings.agentFee} (${property.formattedAgentFee})',
              amount: agentFee,
            ),
          ],

          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),

          _FeeRow(
            label: 'Total First Payment',
            amount: total,
            isTotal: true,
          ),

          if (agentFee > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Agent fee is one-time (first year only)',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSection({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTextStyles.h4,
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
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
          // Price summary
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total',
                  style: AppTextStyles.caption,
                ),
                Text(
                  'NGN ${_formatAmount(widget.property.totalFirstPayment)}',
                  style: AppTextStyles.h4.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),

          // Contact button
          SizedBox(
            width: 180,
            child: AppButton(
              text: AppStrings.contactLandlord,
              onPressed: _contactLandlord,
              height: 50,
            ),
          ),
        ],
      ),
    );
  }

  String _formatAmount(double amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(2)}M';
    } else if (amount >= 1000) {
      return '${(amount / 1000).toStringAsFixed(0)},000';
    }
    return amount.toStringAsFixed(0);
  }

  IconData _getAmenityIcon(String amenity) {
    final lower = amenity.toLowerCase();
    if (lower.contains('power') || lower.contains('electricity')) {
      return Icons.bolt;
    } else if (lower.contains('water')) {
      return Icons.water_drop;
    } else if (lower.contains('security')) {
      return Icons.security;
    } else if (lower.contains('parking')) {
      return Icons.local_parking;
    } else if (lower.contains('pool') || lower.contains('swimming')) {
      return Icons.pool;
    } else if (lower.contains('gym')) {
      return Icons.fitness_center;
    } else if (lower.contains('garden')) {
      return Icons.grass;
    } else if (lower.contains('cctv')) {
      return Icons.videocam;
    } else if (lower.contains('kitchen')) {
      return Icons.kitchen;
    } else if (lower.contains('smart')) {
      return Icons.smart_toy;
    } else if (lower.contains('tiled') || lower.contains('floor')) {
      return Icons.grid_on;
    } else if (lower.contains('meter')) {
      return Icons.electric_meter;
    } else if (lower.contains('bq')) {
      return Icons.house;
    }
    return Icons.check_circle_outline;
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _FeatureItem({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          icon,
          size: 24,
          color: AppColors.primary,
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: AppTextStyles.h4,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTextStyles.caption,
        ),
      ],
    );
  }
}

class _FeeRow extends StatelessWidget {
  final String label;
  final double amount;
  final bool isTotal;

  const _FeeRow({
    required this.label,
    required this.amount,
    this.isTotal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: isTotal ? AppTextStyles.labelLarge : AppTextStyles.bodyMedium,
        ),
        Text(
          'NGN ${_formatAmount(amount)}',
          style: isTotal
              ? AppTextStyles.h4.copyWith(color: AppColors.primary)
              : AppTextStyles.labelLarge,
        ),
      ],
    );
  }

  String _formatAmount(double amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(2)}M';
    }
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) {
        result.add(',');
      }
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }
}

class _ContactSheet extends StatelessWidget {
  final PropertyModel property;
  final String currentUserId;
  final Function(ConversationModel) onStartChat;

  const _ContactSheet({
    required this.property,
    required this.currentUserId,
    required this.onStartChat,
  });

  void _startOrOpenChat(BuildContext context) {
    Navigator.pop(context);

    // Check if conversation already exists for this property
    final existingConversation = mockConversations.where(
      (c) => c.propertyId == property.id && 
             (c.tenantId == currentUserId || c.landlordId == currentUserId)
    ).firstOrNull;

    if (existingConversation != null) {
      // Open existing conversation
      onStartChat(existingConversation);
    } else {
      // Create new conversation
      final newConversation = ConversationModel(
        id: 'conv_${DateTime.now().millisecondsSinceEpoch}',
        propertyId: property.id,
        propertyTitle: property.title,
        propertyImage: property.images.isNotEmpty ? property.images.first : '',
        landlordId: property.landlordId,
        landlordName: property.landlordName ?? 'Landlord',
        tenantId: currentUserId,
        tenantName: 'Mide', // In real app, get from auth
        lastMessage: '',
        lastMessageTime: DateTime.now(),
        lastMessageSenderId: '',
        unreadCount: 0,
        property: property,
      );

      // Add to mock conversations (in real app, save to Firestore)
      mockConversations.add(newConversation);

      onStartChat(newConversation);
    }
  }

  void _callLandlord(BuildContext context) {
    Navigator.pop(context);
    
    final phone = property.landlordPhone;
    if (phone != null && phone.isNotEmpty) {
      // launchUrl(Uri.parse('tel:$phone'));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Calling $phone...'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Phone number not available. Try sending a message instead.'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
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

          Text(
            'Contact ${property.hasAgent ? 'Agent' : 'Landlord'}',
            style: AppTextStyles.h4,
          ),

          const SizedBox(height: 24),

          // Chat option
          _ContactOption(
            icon: Icons.chat_bubble_outline,
            title: 'Send a Message',
            subtitle: 'Chat directly in the app',
            onTap: () => _startOrOpenChat(context),
          ),

          const SizedBox(height: 12),

          // Call option
          _ContactOption(
            icon: Icons.phone_outlined,
            title: 'Call ${property.landlordName ?? 'Landlord'}',
            subtitle: property.landlordPhone ?? 'Phone not available',
            onTap: () => _callLandlord(context),
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

class _ContactOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ContactOption({
    required this.icon,
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
                color: AppColors.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: AppColors.primary,
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