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
import '../../../../shared/widgets/property_location_map.dart';
import '../../../../shared/widgets/property_readiness_sheet.dart';
import '../../../../services/property_service.dart';
import '../../../../services/conversation_service.dart';

/// One loaded property's detail data, kept in a small in-memory cache so that
/// leaving and re-opening the same property paints instantly instead of
/// showing the spinner and refetching from scratch. Refreshed silently on
/// every open, so it can't stay stale for long.
class _CachedDetail {
  final PropertyModel property;
  final String? exactAddress;
  final double? latitude;
  final double? longitude;
  final int pending;
  final int completed;
  const _CachedDetail(this.property, this.exactAddress, this.latitude,
      this.longitude, this.pending, this.completed);
}

final Map<String, _CachedDetail> _detailCache = {};

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
  String? _exactAddress; // exact street address from the gated subdoc
  double? _exactLatitude; // exact pin, same subdoc — the agent has to get there
  double? _exactLongitude;
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
    // Seed from cache for an instant paint on re-entry; _loadProperty() then
    // refreshes in the background without a spinner.
    final cached = _detailCache[widget.propertyId];
    if (cached != null) {
      _property = cached.property;
      _exactAddress = cached.exactAddress;
      _exactLatitude = cached.latitude;
      _exactLongitude = cached.longitude;
      _pendingInspections = cached.pending;
      _completedInspections = cached.completed;
      _isLoading = false;
    }
    _loadProperty();
  }

  @override
  void dispose() {
    _imageController.dispose();
    super.dispose();
  }

  Future<void> _loadProperty() async {
    // When we already have data on screen (seeded from cache), this is a silent
    // background refresh — don't replace good data with an error if it fails.
    final hasData = _property != null;
    try {
      final property = await _propertyService.getProperty(widget.propertyId);

      if (property == null) {
        if (!hasData) {
          setState(() {
            _error = 'Property not found';
            _isLoading = false;
          });
        }
        return;
      }

      // Verify this agent is assigned to this property
      final currentUserId = _auth.currentUser?.uid;
      if (property.assignedAgentId != currentUserId) {
        if (!hasData) {
          setState(() {
            _error = 'You are not assigned to this property';
            _isLoading = false;
          });
        }
        return;
      }

      // Load inspection stats
      await _loadInspectionStats();

      // The assigned agent is entitled to the exact address (gated subdoc).
      final loc = await _propertyService.getExactLocation(widget.propertyId);

      if (!mounted) return;
      setState(() {
        _property = property;
        _exactAddress = (loc != null && loc.address.isNotEmpty)
            ? loc.address
            : null;
        _exactLatitude = loc?.latitude;
        _exactLongitude = loc?.longitude;
        _isLoading = false;
      });
      _cacheCurrent();
    } catch (e) {
      debugPrint('❌ Error loading property: $e');
      if (!hasData) {
        setState(() {
          _error = 'Failed to load property';
          _isLoading = false;
        });
      }
    }
  }

  /// Store the currently-loaded data so re-entry can paint it instantly.
  void _cacheCurrent() {
    final p = _property;
    if (p != null) {
      _detailCache[widget.propertyId] = _CachedDetail(
        p,
        _exactAddress,
        _exactLatitude,
        _exactLongitude,
        _pendingInspections,
        _completedInspections,
      );
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
      builder: (context) => Center(
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
            icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
        ),
        body: Center(
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
            icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: AppColors.error),
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
              Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(128),
                  shape: BoxShape.circle,
                ),
                child: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  onSelected: (v) {
                    if (v == 'step_back') _confirmStepBack(property);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'step_back',
                      child: Row(children: [
                        Icon(Icons.logout, size: 20, color: AppColors.error),
                        const SizedBox(width: 12),
                        const Text('Step back from this property'),
                      ]),
                    ),
                  ],
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
                          child: Center(
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
                              property.statusLabel,
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
                          Icon(Icons.location_on_outlined, size: 16, color: AppColors.textSecondary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _exactAddress != null
                                  ? '$_exactAddress, ${property.city}, ${property.state}'
                                  : property.approximateAddress,
                              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // The assigned agent has to physically get here.
                      PropertyLocationMap(
                        latitude: _exactLatitude,
                        longitude: _exactLongitude,
                        emptyMessage:
                            'The landlord did not drop a map pin for this property. '
                            'Use the address, or message them for directions.',
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

                // Readiness gate (Phase 2)
                _buildReadinessCard(property),

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

  Future<void> _openReadinessSheet(PropertyModel property) async {
    final done = await PropertyReadinessSheet.show(context, property);
    if (done == true && mounted) {
      // Reflect the new readiness state without a full reload.
      setState(() => _property = property.copyWith(readyForInspections: true));
      _cacheCurrent();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Property is now bookable for inspections.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Readiness gate (Phase 2): until the agent vets the property it can't take
  /// inspections. Show a call-to-action when not ready, a confirmation when it is.
  Widget _buildReadinessCard(PropertyModel property) {
    if (property.readyForInspections) {
      return Container(
        margin: const EdgeInsets.only(top: 16, left: 20, right: 20),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.success.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.success.withAlpha(77)),
        ),
        child: Row(
          children: [
            Icon(Icons.verified, color: AppColors.success, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'You\'ve marked this property ready — tenants can book inspections.',
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 16, left: 20, right: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hourglass_top, color: AppColors.warning, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Not bookable yet',
                  style: AppTextStyles.labelLarge
                      .copyWith(color: AppColors.warning),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Vet this property against the readiness checklist to make it '
            'bookable for inspections.',
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _openReadinessSheet(property),
              icon: const Icon(Icons.checklist, size: 18),
              label: const Text('Confirm readiness'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
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
              child: Icon(Icons.call, color: AppColors.success, size: 20),
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
              child: Icon(Icons.chat_outlined, color: AppColors.primary, size: 20),
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
              Icon(Icons.event_note, color: AppColors.primary, size: 20),
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
                    Icon(Icons.info_outline, color: AppColors.warning, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You have $_pendingInspections pending inspection request${_pendingInspections > 1 ? 's' : ''}',
                        style: AppTextStyles.bodySmall.copyWith(color: AppColors.warning),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: AppColors.warning, size: 18),
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

  /// Let the assigned agent step back from this property, with a reason. The
  /// server reverts it to landlord-handled (fee preserved) and notifies the
  /// landlord. Blocked server-side if the agent has an in-flight inspection.
  Future<void> _confirmStepBack(PropertyModel property) async {
    final controller = TextEditingController();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              Text('Step back from this property', style: AppTextStyles.h4),
              const SizedBox(height: 6),
              Text(
                "The property reverts to the landlord, who'll be notified. "
                "You can't step back while you have a pending or scheduled "
                "inspection here.",
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Reason (e.g. too far, schedule conflict)',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    if (controller.text.trim().isEmpty) return;
                    Navigator.pop(sheetCtx, true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('Step back',
                      style: AppTextStyles.labelLarge
                          .copyWith(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;
    final reason = controller.text.trim();
    if (reason.isEmpty || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          Center(child: CircularProgressIndicator(color: AppColors.primary)),
    );
    final error =
        await _propertyService.agentUnassignFromProperty(property.id, reason);
    if (!mounted) return;
    Navigator.pop(context); // close loading

    if (error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              const Text('You\'ve stepped back. The landlord was notified.'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      context.pop(); // leave the property detail
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  /// Open the edit-schedule bottom sheet for the assigned agent.
  /// Lets agent change inspection days and time slots, then prompts to
  /// message the landlord with a pre-filled draft.
  Future<void> _openEditScheduleSheet(PropertyModel property) async {
    final result = await showModalBottomSheet<_ScheduleEditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _EditScheduleSheet(
        initialDays: property.inspectionDays,
        initialTimeSlots: property.inspectionTimeSlots,
      ),
    );

    if (result == null || !mounted) return;

    // Save changes
    final ok = await _propertyService.updateProperty(property.id, {
      'inspectionDays': result.days,
      'inspectionTimeSlots': result.timeSlots,
    });

    if (!mounted) return;

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not save changes. Please try again.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    // Refresh local property state immediately
    setState(() {
      _property = property.copyWith(
        inspectionDays: result.days,
        inspectionTimeSlots: result.timeSlots,
      );
    });

    // Open landlord chat with a pre-filled draft about the change
    await _messageLandlordAboutScheduleChange(
      property: _property!,
      newDays: result.days,
      newTimeSlots: result.timeSlots,
    );
  }

  /// Build a draft message and open the agent-landlord chat with it
  /// pre-filled (not auto-sent — agent reviews before sending).
  Future<void> _messageLandlordAboutScheduleChange({
    required PropertyModel property,
    required List<String> newDays,
    required List<String> newTimeSlots,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return;

    // Show loading indicator while we get/create the conversation
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );

    try {
      final conversationId =
          await _conversationService.getOrCreateAgentLandlordConversation(
        propertyId: property.id,
        landlordId: property.landlordId,
        agentId: currentUserId,
      );

      if (!mounted) return;
      Navigator.pop(context); // close loading

      if (conversationId == null) {
        // Schedule was saved but we couldn't open chat — non-fatal.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Schedule updated. Couldn\'t open chat — please message the landlord directly.',
            ),
            backgroundColor: AppColors.warning,
          ),
        );
        return;
      }

      // Build a friendly draft summarizing the change
      final dayList = newDays.isEmpty ? 'none set' : newDays.join(', ');
      final timeList = newTimeSlots.isEmpty
          ? 'none set'
          : newTimeSlots.map(_humanTimeSlot).join(', ');
      final draft =
          'Hi, I\'ve updated the inspection schedule for "${property.title}".\n\n'
          'New days: $dayList\n'
          'New times: $timeList\n\n'
          'Let me know if this works for you.';

      context.push('/chat', extra: {
        'conversationId': conversationId,
        'propertyTitle': property.title,
        'propertyImage':
            property.images.isNotEmpty ? property.images.first : null,
        'initialDraft': draft,
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // close loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Schedule updated, but the chat failed to open.',
          ),
          backgroundColor: AppColors.warning,
        ),
      );
    }
  }

  String _humanTimeSlot(String id) {
    switch (id) {
      case 'morning':
        return 'Morning';
      case 'afternoon':
        return 'Afternoon';
      case 'late_afternoon':
        return 'Late Afternoon';
      case 'evening':
        return 'Evening';
      default:
        return id;
    }
  }

  Widget _buildInspectionSchedule(PropertyModel property) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Inspection Schedule', style: AppTextStyles.h4),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _openEditScheduleSheet(property),
                icon: Icon(Icons.edit, size: 18, color: AppColors.primary),
                label: Text(
                  'Edit',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.primary,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
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
                        Icon(Icons.access_time, size: 16, color: AppColors.textSecondary),
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
                    Icon(Icons.check_circle, color: AppColors.success, size: 16),
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
                      Icon(Icons.rule, color: AppColors.warning, size: 18),
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
                side: BorderSide(color: AppColors.primary),
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
                        decoration: BoxDecoration(
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

/// Result returned from the edit-schedule bottom sheet.
class _ScheduleEditResult {
  final List<String> days;
  final List<String> timeSlots;
  const _ScheduleEditResult({required this.days, required this.timeSlots});
}

/// Bottom sheet UI matching the landlord's edit-property inspection section.
/// Pops a [_ScheduleEditResult] on save, or null on cancel.
class _EditScheduleSheet extends StatefulWidget {
  final List<String> initialDays;
  final List<String> initialTimeSlots;

  const _EditScheduleSheet({
    required this.initialDays,
    required this.initialTimeSlots,
  });

  @override
  State<_EditScheduleSheet> createState() => _EditScheduleSheetState();
}

class _EditScheduleSheetState extends State<_EditScheduleSheet> {
  static const List<String> _weekDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const List<Map<String, String>> _timeSlotOptions = [
    {'id': 'morning', 'label': 'Morning', 'time': '9:00 AM - 12:00 PM'},
    {'id': 'afternoon', 'label': 'Afternoon', 'time': '12:00 PM - 3:00 PM'},
    {
      'id': 'late_afternoon',
      'label': 'Late Afternoon',
      'time': '3:00 PM - 6:00 PM'
    },
    {'id': 'evening', 'label': 'Evening', 'time': '6:00 PM - 8:00 PM'},
  ];

  late List<String> _days;
  late List<String> _slots;

  @override
  void initState() {
    super.initState();
    _days = List.from(widget.initialDays);
    _slots = List.from(widget.initialTimeSlots);
  }

  void _save() {
    if (_days.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please select at least one day'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    if (_slots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please select at least one time slot'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      _ScheduleEditResult(days: _days, timeSlots: _slots),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text('Edit Inspection Schedule', style: AppTextStyles.h3),
              const SizedBox(height: 4),
              Text(
                'The landlord will be notified about this change.',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 20),

              // Available days
              Text('Available Days', style: AppTextStyles.labelLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _weekDays.map((day) {
                  final isSelected = _days.contains(day);
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _days.remove(day);
                        } else {
                          _days.add(day);
                        }
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary.withAlpha(26)
                            : AppColors.background,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        day.substring(0, 3),
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),

              // Time slots
              Text('Available Time Slots', style: AppTextStyles.labelLarge),
              const SizedBox(height: 12),
              ..._timeSlotOptions.map((slot) {
                final id = slot['id']!;
                final isSelected = _slots.contains(id);
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _slots.remove(id);
                      } else {
                        _slots.add(id);
                      }
                    });
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withAlpha(13)
                          : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.border,
                              width: 2,
                            ),
                          ),
                          child: isSelected
                              ? Icon(Icons.check,
                                  size: 14, color: AppColors.surface)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(slot['label']!,
                                  style: AppTextStyles.labelMedium),
                              const SizedBox(height: 2),
                              Text(
                                slot['time']!,
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
              }),
              const SizedBox(height: 24),

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: AppColors.border),
                      ),
                      child: Text(
                        'Cancel',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(
                        'Save Changes',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: AppColors.surface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    buffer.writeln('📍 ${property.publicLocation}');
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
      await SharePlus.instance.share(ShareParams(text: _shareText));
    }
    
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _shareGeneral(BuildContext context) async {
    await SharePlus.instance.share(ShareParams(text: _shareText));
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