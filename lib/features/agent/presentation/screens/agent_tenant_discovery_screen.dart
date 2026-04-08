import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../services/conversation_service.dart';

/// Agent selects one of their assigned properties, then browses
/// verified tenants whose profile (budget, preferred area, work mode)
/// matches the property.
class AgentTenantDiscoveryScreen extends StatefulWidget {
  const AgentTenantDiscoveryScreen({super.key});

  @override
  State<AgentTenantDiscoveryScreen> createState() =>
      _AgentTenantDiscoveryScreenState();
}

class _AgentTenantDiscoveryScreenState
    extends State<AgentTenantDiscoveryScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ConversationService _conversationService = ConversationService();

  // Step 1: Pick a property
  List<PropertyModel> _assignedProperties = [];
  bool _isLoadingProperties = true;
  PropertyModel? _selectedProperty;

  // Step 2: Browse matching tenants
  List<Map<String, dynamic>> _matchingTenants = [];
  bool _isLoadingTenants = false;

  @override
  void initState() {
    super.initState();
    _loadAssignedProperties();
  }

  Future<void> _loadAssignedProperties() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      final snap = await _firestore
          .collection('properties')
          .where('assignedAgentId', isEqualTo: uid)
          .where('isAvailable', isEqualTo: true)
          .get();

      final props = snap.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        if (data['createdAt'] is Timestamp) {
          data['createdAt'] =
              (data['createdAt'] as Timestamp).toDate().toIso8601String();
        }
        return PropertyModel.fromJson(data);
      }).toList();

      setState(() {
        _assignedProperties = props;
        _isLoadingProperties = false;
      });
    } catch (e) {
      debugPrint('❌ Error loading assigned properties: $e');
      setState(() => _isLoadingProperties = false);
    }
  }

  Future<void> _loadMatchingTenants(PropertyModel property) async {
    setState(() {
      _selectedProperty = property;
      _isLoadingTenants = true;
      _matchingTenants = [];
    });

    try {
      // Get all verified tenants
      final snap = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'tenant')
          .where('verificationStatus', isEqualTo: 'verified')
          .get();

      final tenants = <Map<String, dynamic>>[];

      for (final doc in snap.docs) {
        final data = doc.data();
        data['uid'] = doc.id;

        // Score how well this tenant matches the property
        final score = _calculateMatchScore(data, property);
        if (score > 0) {
          data['_matchScore'] = score;
          data['_matchReasons'] = _getMatchReasons(data, property);
          tenants.add(data);
        }
      }

      // Sort by match score descending
      tenants.sort((a, b) =>
          (b['_matchScore'] as int).compareTo(a['_matchScore'] as int));

      setState(() {
        _matchingTenants = tenants;
        _isLoadingTenants = false;
      });
    } catch (e) {
      debugPrint('❌ Error loading tenants: $e');
      setState(() => _isLoadingTenants = false);
    }
  }

  /// Score 0-100 how well tenant matches property
  int _calculateMatchScore(
      Map<String, dynamic> tenant, PropertyModel property) {
    int score = 0;

    // Budget match (0-40 points)
    final budgetMin = (tenant['budgetMin'] as num?)?.toDouble() ?? 0;
    final budgetMax = (tenant['budgetMax'] as num?)?.toDouble() ?? 0;
    if (budgetMax > 0 && property.rent <= budgetMax) {
      score += 40;
    } else if (budgetMin > 0 && property.rent >= budgetMin * 0.8) {
      // Within 20% of their min budget
      score += 20;
    }
    // If no budget set, give partial credit (they haven't filtered themselves out)
    if (budgetMin == 0 && budgetMax == 0) score += 10;

    // Preferred area match (0-30 points)
    final preferredAreas =
        List<String>.from(tenant['preferredAreas'] ?? []);
    if (preferredAreas.isNotEmpty) {
      if (preferredAreas.contains(property.city)) {
        score += 30;
      }
    } else {
      // No preference set — partial credit
      score += 5;
    }

    // Work commute proximity (0-20 points)
    final workMode = tenant['workMode'] as String?;
    final workplaceArea = tenant['workplaceArea'] as String?;
    if (workMode == 'remote') {
      // Remote workers match any location
      score += 20;
    } else if (workMode == 'commute' || workMode == 'hybrid') {
      if (workplaceArea != null && workplaceArea == property.city) {
        // Property is in the same area as their workplace
        score += 20;
      } else if (workplaceArea != null) {
        // At least they've specified — partial credit
        score += 5;
      }
    }

    // Has complete profile bonus (0-10 points)
    if ((tenant['occupation'] as String?)?.isNotEmpty == true) score += 5;
    if (workMode != null) score += 5;

    return score;
  }

  List<String> _getMatchReasons(
      Map<String, dynamic> tenant, PropertyModel property) {
    final reasons = <String>[];

    final budgetMax = (tenant['budgetMax'] as num?)?.toDouble() ?? 0;
    if (budgetMax > 0 && property.rent <= budgetMax) {
      reasons.add('Within budget');
    }

    final preferredAreas =
        List<String>.from(tenant['preferredAreas'] ?? []);
    if (preferredAreas.contains(property.city)) {
      reasons.add('Prefers ${property.city}');
    }

    final workMode = tenant['workMode'] as String?;
    if (workMode == 'remote') {
      reasons.add('Works remotely');
    } else if (workMode == 'commute' || workMode == 'hybrid') {
      final workplaceArea = tenant['workplaceArea'] as String?;
      if (workplaceArea == property.city) {
        reasons.add('Works in ${property.city}');
      }
    }

    final occupation = tenant['occupation'] as String?;
    if (occupation != null && occupation.isNotEmpty) {
      reasons.add(occupation);
    }

    return reasons;
  }

  Future<void> _contactTenant(Map<String, dynamic> tenant) async {
    final agentId = _auth.currentUser?.uid;
    if (agentId == null || _selectedProperty == null) return;

    final tenantId = tenant['uid'] as String;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.primary),
              const SizedBox(height: 16),
              Text('Starting conversation...', style: AppTextStyles.bodyMedium),
            ],
          ),
        ),
      ),
    );

    try {
      // Get names for the conversation
      final tenantName = tenant['fullName'] as String? ?? 'Tenant';
      final landlordName = _selectedProperty!.landlordName ?? 'Landlord';

      // Get agent info
      final agentDoc = await _firestore.collection('users').doc(agentId).get();
      final agentName = agentDoc.data()?['fullName'] as String? ?? 'Agent';

      // Use the standard getOrCreate with property context
      final conversation =
          await _conversationService.getOrCreateConversation(
        propertyId: _selectedProperty!.id,
        propertyTitle: _selectedProperty!.title,
        propertyImage: _selectedProperty!.images.isNotEmpty
            ? _selectedProperty!.images.first
            : '',
        landlordId: _selectedProperty!.landlordId,
        landlordName: landlordName,
        tenantId: tenantId,
        tenantName: tenantName,
        agentId: agentId,
        agentName: agentName,
      );

      if (!mounted) return;
      Navigator.pop(context);

      if (conversation != null) {
        context.push('/chat', extra: {
          'conversationId': conversation.id,
          'propertyTitle': _selectedProperty!.title,
          'propertyImage': _selectedProperty!.images.isNotEmpty
              ? _selectedProperty!.images.first
              : null,
        });
      } else {
        _showSnackBar('Could not start conversation. Both parties must be verified.', isError: true);
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _showSnackBar('Something went wrong. Please try again.', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          _selectedProperty != null ? 'Find Tenants' : 'Search Tenants',
          style: AppTextStyles.h4,
        ),
        centerTitle: true,
        leading: _selectedProperty != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    setState(() {
                      _selectedProperty = null;
                      _matchingTenants = [];
                    }),
              )
            : null,
      ),
      body: _selectedProperty == null
          ? _buildPropertySelectionStep()
          : _buildTenantResultsStep(),
    );
  }

  // ── Step 1: Select which assigned property to find tenants for ──

  Widget _buildPropertySelectionStep() {
    if (_isLoadingProperties) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_assignedProperties.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.home_work_outlined,
                  size: 48, color: AppColors.textHint),
              const SizedBox(height: 16),
              Text(
                'No assigned properties',
                style: AppTextStyles.labelLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'You need to be assigned to a property before you can search for tenants. Go to Discover to find properties.',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Select a property to find matching tenants',
          style:
              AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        ..._assignedProperties.map((property) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildPropertySelectionCard(property),
            )),
      ],
    );
  }

  Widget _buildPropertySelectionCard(PropertyModel property) {
    return GestureDetector(
      onTap: () => _loadMatchingTenants(property),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: property.images.isNotEmpty
                  ? Image.network(
                      property.images.first,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(),
                    )
                  : _buildPlaceholder(),
            ),
            const SizedBox(width: 14),
            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(property.title,
                      style: AppTextStyles.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(
                    '${property.city} · ${property.formattedRent}${property.rentPeriod}',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${property.bedrooms} bed · ${property.propertyType}',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.textHint),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child:
          Icon(Icons.home_outlined, color: AppColors.textHint, size: 28),
    );
  }

  // ── Step 2: Show matching tenants ──

  Widget _buildTenantResultsStep() {
    if (_isLoadingTenants) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Property context card
        _buildSelectedPropertyBanner(),
        const SizedBox(height: 16),

        // Results
        Text(
          '${_matchingTenants.length} matching ${_matchingTenants.length == 1 ? 'tenant' : 'tenants'}',
          style: AppTextStyles.labelLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Sorted by how well they match this property.',
          style:
              AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),

        if (_matchingTenants.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                Icon(Icons.people_outline,
                    size: 48, color: AppColors.textHint),
                const SizedBox(height: 16),
                Text(
                  'No matching tenants yet',
                  style: AppTextStyles.labelLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'As more tenants sign up and complete their profiles, matches will appear here.',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          ..._matchingTenants.map((tenant) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildTenantCard(tenant),
              )),

        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildSelectedPropertyBanner() {
    final p = _selectedProperty!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(50)),
      ),
      child: Row(
        children: [
          Icon(Icons.home_work, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.title,
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(
                  '${p.city} · ${p.formattedRent}${p.rentPeriod} · ${p.bedrooms} bed',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTenantCard(Map<String, dynamic> tenant) {
    final name = tenant['fullName'] as String? ?? 'Tenant';
    final occupation = tenant['occupation'] as String? ?? '';
    final workMode = tenant['workMode'] as String?;
    final matchScore = tenant['_matchScore'] as int? ?? 0;
    final matchReasons =
        List<String>.from(tenant['_matchReasons'] ?? []);
    final profileImageUrl = tenant['profileImageUrl'] as String?;
    final maritalStatus = tenant['maritalStatus'] as String?;

    // Match quality label
    String matchLabel;
    Color matchColor;
    if (matchScore >= 70) {
      matchLabel = 'Strong match';
      matchColor = AppColors.success;
    } else if (matchScore >= 40) {
      matchLabel = 'Good match';
      matchColor = AppColors.primary;
    } else {
      matchLabel = 'Partial match';
      matchColor = AppColors.warning;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.primary.withAlpha(26),
                backgroundImage: profileImageUrl != null && profileImageUrl.isNotEmpty
                    ? NetworkImage(profileImageUrl)
                    : null,
                child: profileImageUrl == null || profileImageUrl.isEmpty
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'T',
                        style: AppTextStyles.labelLarge
                            .copyWith(color: AppColors.primary),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              // Name + occupation
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: AppTextStyles.labelLarge),
                    if (occupation.isNotEmpty)
                      Text(
                        occupation,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary),
                      ),
                  ],
                ),
              ),
              // Match badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: matchColor.withAlpha(26),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  matchLabel,
                  style: AppTextStyles.caption.copyWith(
                    color: matchColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Match reasons as chips
          if (matchReasons.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: matchReasons
                  .map((reason) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          reason,
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ))
                  .toList(),
            ),
          const SizedBox(height: 8),

          // Extra info row
          Row(
            children: [
              if (workMode != null) ...[
                Icon(
                  workMode == 'remote'
                      ? Icons.home_outlined
                      : workMode == 'hybrid'
                          ? Icons.sync_alt
                          : Icons.directions_car_outlined,
                  size: 14,
                  color: AppColors.textHint,
                ),
                const SizedBox(width: 4),
                Text(
                  workMode == 'remote'
                      ? 'Remote'
                      : workMode == 'hybrid'
                          ? 'Hybrid'
                          : 'Commutes',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint),
                ),
                const SizedBox(width: 12),
              ],
              if (maritalStatus != null) ...[
                Icon(Icons.people_outline, size: 14, color: AppColors.textHint),
                const SizedBox(width: 4),
                Text(
                  maritalStatus == 'single'
                      ? 'Single'
                      : maritalStatus == 'married'
                          ? 'Married'
                          : 'Family',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint),
                ),
              ],
              const Spacer(),
              // Contact button
              SizedBox(
                height: 34,
                child: ElevatedButton.icon(
                  onPressed: () => _contactTenant(tenant),
                  icon: const Icon(Icons.message_outlined, size: 14),
                  label: const Text('Message'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    textStyle: AppTextStyles.labelSmall
                        .copyWith(fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}