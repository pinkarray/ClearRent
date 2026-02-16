import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../services/property_service.dart';
import '../../../../services/conversation_service.dart';

class AgentPropertyDetailScreen extends StatefulWidget {
  final String propertyId;

  const AgentPropertyDetailScreen({
    super.key,
    required this.propertyId,
  });

  @override
  State<AgentPropertyDetailScreen> createState() => _AgentPropertyDetailScreenState();
}

class _AgentPropertyDetailScreenState extends State<AgentPropertyDetailScreen> {
  final PropertyService _propertyService = PropertyService();
  final ConversationService _conversationService = ConversationService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  PropertyModel? _property;
  bool _isLoading = true;
  String? _error;
  int _currentImageIndex = 0;
  final PageController _imageController = PageController();

  // Inspection stats
  int _pendingInspections = 0;
  int _completedInspections = 0;

  @override
  void initState() {
    super.initState();
    _loadProperty();
  }

  @override
  void dispose() {
    _imageController.dispose();
    super.dispose();
  }

  Future<void> _loadProperty() async {
    try {
      final property = await _propertyService.getProperty(widget.propertyId);
      
      if (property == null) {
        setState(() {
          _error = 'Property not found';
          _isLoading = false;
        });
        return;
      }

      // Verify this agent is assigned to this property
      final currentUserId = _auth.currentUser?.uid;
      if (property.assignedAgentId != currentUserId) {
        setState(() {
          _error = 'You are not assigned to this property';
          _isLoading = false;
        });
        return;
      }

      // Load inspection stats
      await _loadInspectionStats();

      setState(() {
        _property = property;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('❌ Error loading property: $e');
      setState(() {
        _error = 'Failed to load property';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadInspectionStats() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      // Get pending inspections for this property
      final pendingSnapshot = await _firestore
          .collection('inspection_requests')
          .where('propertyId', isEqualTo: widget.propertyId)
          .where('agentId', isEqualTo: userId)
          .where('status', isEqualTo: 'pending')
          .count()
          .get();

      // Get completed inspections for this property
      final completedSnapshot = await _firestore
          .collection('inspection_requests')
          .where('propertyId', isEqualTo: widget.propertyId)
          .where('agentId', isEqualTo: userId)
          .where('status', isEqualTo: 'completed')
          .count()
          .get();

      if (mounted) {
        setState(() {
          _pendingInspections = pendingSnapshot.count ?? 0;
          _completedInspections = completedSnapshot.count ?? 0;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading inspection stats: $e');
    }
  }

  Future<void> _callLandlord() async {
    final phone = _property?.landlordPhone;
    if (phone == null || phone.isEmpty) {
      _showError('Landlord phone number not available');
      return;
    }

    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _showError('Could not open phone app');
    }
  }

  Future<void> _messageLandlord() async {
    final property = _property;
    if (property == null) {
      _showError('Property not found');
      return;
    }

    final landlordId = property.landlordId;
    final currentUserId = _auth.currentUser?.uid;
    
    if (currentUserId == null) {
      _showError('Please log in to send messages');
      return;
    }

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );

    try {
      // Get or create conversation between agent and landlord for this property
      final conversationId = await _conversationService.getOrCreateAgentLandlordConversation(
        propertyId: property.id,
        landlordId: landlordId,
        agentId: currentUserId,
      );

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      if (conversationId != null) {
        context.push('/chat', extra: {
          'conversationId': conversationId,
          'propertyTitle': property.title,
          'propertyImage': property.images.isNotEmpty ? property.images.first : null,
        });
      } else {
        _showError('Could not start conversation. Please try again.');
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog
      debugPrint('❌ Error starting conversation: $e');
      _showError('Failed to start conversation');
    }
  }

  void _shareProperty() {
    final property = _property;
    if (property == null) return;

    // Show share options
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _SharePropertySheet(property: property),
    );
  }

  void _viewInspectionRequests() {
    context.push('/agent/inspections');
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
        ),
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (_error != null || _property == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: AppColors.error),
              const SizedBox(height: 16),
              Text(_error ?? 'Something went wrong', style: AppTextStyles.h4),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final property = _property!;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // Image gallery with app bar
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            backgroundColor: AppColors.surface,
            leading: GestureDetector(
              onTap: () => context.pop(),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(128),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
            actions: [
              Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(128),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.share_outlined, color: Colors.white),
                  onPressed: _shareProperty,
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                children: [
                  // Image carousel
                  PageView.builder(
                    controller: _imageController,
                    onPageChanged: (index) {
                      setState(() => _currentImageIndex = index);
                    },
                    itemCount: property.images.isEmpty ? 1 : property.images.length,
                    itemBuilder: (context, index) {
                      if (property.images.isEmpty) {
                        return Container(
                          color: AppColors.surface,
                          child: const Center(
                            child: Icon(Icons.home, size: 80, color: AppColors.textHint),
                          ),
                        );
                      }
                      return CachedNetworkImage(
                        imageUrl: property.images[index],
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: AppColors.surface,
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.image_not_supported, size: 50),
                        ),
                      );
                    },
                  ),

                  // Image indicators
                  if (property.images.length > 1)
                    Positioned(
                      bottom: 16,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          property.images.length,
                          (index) => Container(
                            width: index == _currentImageIndex ? 24 : 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: index == _currentImageIndex
                                  ? Colors.white
                                  : Colors.white.withAlpha(128),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Agent badge
                  Positioned(
                    top: 100,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.support_agent, color: Colors.white, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            'Assigned to You',
                            style: AppTextStyles.labelSmall.copyWith(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Property details
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title and price
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(property.title, style: AppTextStyles.h3),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: property.isAvailable
                                  ? AppColors.success.withAlpha(26)
                                  : AppColors.textHint.withAlpha(26),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              property.isAvailable ? 'Available' : 'Occupied',
                              style: AppTextStyles.labelSmall.copyWith(
                                color: property.isAvailable ? AppColors.success : AppColors.textHint,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.location_on_outlined, size: 16, color: AppColors.textSecondary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${property.address}, ${property.city}, ${property.state}',
                              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        property.formattedRent,
                        style: AppTextStyles.h2.copyWith(color: AppColors.primary),
                      ),
                      Text(
                        property.rentPeriod,
                        style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),

                // Landlord info card
                _buildLandlordCard(property),

                // Inspection stats card
                _buildInspectionStatsCard(),

                // Property details
                _buildPropertyDetails(property),

                // Inspection schedule
                _buildInspectionSchedule(property),

                // Description
                _buildDescription(property),

                // Amenities
                if (property.amenities.isNotEmpty) _buildAmenities(property),

                // House rules
                if (property.rules.isNotEmpty) _buildRules(property),

                const SizedBox(height: 100),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildLandlordCard(PropertyModel property) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                (property.landlordName ?? 'L').isNotEmpty
                    ? (property.landlordName ?? 'L')[0].toUpperCase()
                    : 'L',
                style: AppTextStyles.h4.copyWith(color: AppColors.primary),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(property.landlordName ?? 'Landlord', style: AppTextStyles.labelLarge),
                Text(
                  'Property Owner',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _callLandlord,
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.call, color: AppColors.success, size: 20),
            ),
          ),
          IconButton(
            onPressed: _messageLandlord,
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.chat_outlined, color: AppColors.primary, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectionStatsCard() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_note, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Inspection Overview',
                style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  icon: Icons.pending_actions,
                  label: 'Pending',
                  value: '$_pendingInspections',
                  color: AppColors.warning,
                ),
              ),
              Container(width: 1, height: 40, color: AppColors.border),
              Expanded(
                child: _buildStatItem(
                  icon: Icons.check_circle_outline,
                  label: 'Completed',
                  value: '$_completedInspections',
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          if (_pendingInspections > 0) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _viewInspectionRequests,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: AppColors.warning, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You have $_pendingInspections pending inspection request${_pendingInspections > 1 ? 's' : ''}',
                        style: AppTextStyles.bodySmall.copyWith(color: AppColors.warning),
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: AppColors.warning, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 8),
        Text(value, style: AppTextStyles.h4.copyWith(color: color)),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildPropertyDetails(PropertyModel property) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Property Details', style: AppTextStyles.h4),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildDetailItem(Icons.home_outlined, 'Type', property.propertyType),
                    ),
                    Expanded(
                      child: _buildDetailItem(Icons.bed_outlined, 'Bedrooms', '${property.bedrooms}'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _buildDetailItem(Icons.bathtub_outlined, 'Bathrooms', '${property.bathrooms}'),
                    ),
                    Expanded(
                      child: _buildDetailItem(Icons.wc_outlined, 'Toilets', '${property.toilets}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailItem(IconData icon, String label, String value) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppColors.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            Text(value, style: AppTextStyles.labelMedium),
          ],
        ),
      ],
    );
  }

  Widget _buildInspectionSchedule(PropertyModel property) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Inspection Schedule', style: AppTextStyles.h4),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Days
                Text(
                  'Available Days',
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: property.inspectionDays.map((day) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        day.substring(0, 3),
                        style: AppTextStyles.labelSmall.copyWith(color: AppColors.primary),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                // Time slots
                Text(
                  'Time Slots',
                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                ...property.inspectionTimeSlots.map((slot) {
                  String displayTime;
                  switch (slot) {
                    case 'morning':
                      displayTime = 'Morning (9:00 AM - 12:00 PM)';
                      break;
                    case 'afternoon':
                      displayTime = 'Afternoon (12:00 PM - 3:00 PM)';
                      break;
                    case 'late_afternoon':
                      displayTime = 'Late Afternoon (3:00 PM - 6:00 PM)';
                      break;
                    case 'evening':
                      displayTime = 'Evening (6:00 PM - 8:00 PM)';
                      break;
                    default:
                      displayTime = slot;
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.access_time, size: 16, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        Text(displayTime, style: AppTextStyles.bodySmall),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDescription(PropertyModel property) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Description', style: AppTextStyles.h4),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              property.description.isNotEmpty ? property.description : 'No description provided.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: property.description.isNotEmpty ? AppColors.textPrimary : AppColors.textHint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmenities(PropertyModel property) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Amenities', style: AppTextStyles.h4),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: property.amenities.map((amenity) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.success.withAlpha(77)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: AppColors.success, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      amenity,
                      style: AppTextStyles.labelSmall.copyWith(color: AppColors.success),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildRules(PropertyModel property) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('House Rules', style: AppTextStyles.h4),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: property.rules.map((rule) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.rule, color: AppColors.warning, size: 18),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(rule, style: AppTextStyles.bodySmall),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
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
          // Contact landlord button
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _callLandlord,
              icon: const Icon(Icons.call),
              label: const Text('Call Landlord'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: AppColors.primary),
                foregroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // View inspections button
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _viewInspectionRequests,
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.event_note, color: Colors.white),
                  if (_pendingInspections > 0)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: AppColors.error,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$_pendingInspections',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              label: const Text('Inspections', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============ SHARE PROPERTY SHEET ============
class _SharePropertySheet extends StatelessWidget {
  final PropertyModel property;

  const _SharePropertySheet({required this.property});

  String get _shareText {
    final buffer = StringBuffer();
    buffer.writeln('🏠 ${property.title}');
    buffer.writeln('');
    buffer.writeln('📍 ${property.address}, ${property.city}, ${property.state}');
    buffer.writeln('💰 ${property.formattedRent}');
    buffer.writeln('');
    buffer.writeln('🛏️ ${property.bedrooms} Bedroom(s) | 🚿 ${property.bathrooms} Bathroom(s)');
    buffer.writeln('');
    if (property.description.isNotEmpty) {
      buffer.writeln(property.description.length > 150 
          ? '${property.description.substring(0, 150)}...' 
          : property.description);
      buffer.writeln('');
    }
    buffer.writeln('---');
    buffer.writeln('Listed via ClearRent - Rent Without Regret');
    buffer.writeln('Contact me for inspection!');
    
    return buffer.toString();
  }

  Future<void> _shareViaWhatsApp(BuildContext context) async {
    final text = Uri.encodeComponent(_shareText);
    final url = Uri.parse('whatsapp://send?text=$text');
    
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      // WhatsApp not installed, use regular share
      await Share.share(_shareText);
    }
    
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _shareGeneral(BuildContext context) async {
    await Share.share(_shareText);
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Property details copied to clipboard'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
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
          
          Text('Share Property', style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            'Share this property listing with potential tenants',
            style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          
          // Share options
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ShareOption(
                icon: Icons.chat,
                label: 'WhatsApp',
                color: const Color(0xFF25D366),
                onTap: () => _shareViaWhatsApp(context),
              ),
              _ShareOption(
                icon: Icons.share,
                label: 'More',
                color: AppColors.primary,
                onTap: () => _shareGeneral(context),
              ),
              _ShareOption(
                icon: Icons.copy,
                label: 'Copy',
                color: AppColors.info,
                onTap: () => _copyToClipboard(context),
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Preview
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Preview',
                  style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                Text(
                  _shareText,
                  style: AppTextStyles.caption,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

class _ShareOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ShareOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: AppTextStyles.labelSmall),
        ],
      ),
    );
  }
}