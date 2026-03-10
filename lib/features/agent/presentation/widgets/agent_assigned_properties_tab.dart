import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';

class AgentAssignedPropertiesTab extends StatefulWidget {
  final bool isVerified;

  const AgentAssignedPropertiesTab({
    super.key,
    required this.isVerified,
  });

  @override
  State<AgentAssignedPropertiesTab> createState() => _AgentAssignedPropertiesTabState();
}

class _AgentAssignedPropertiesTabState extends State<AgentAssignedPropertiesTab> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  Widget build(BuildContext context) {
    if (!widget.isVerified) {
      return _buildVerificationRequired();
    }

    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return _buildEmptyState(
        icon: Icons.error_outline,
        title: 'Not Logged In',
        subtitle: 'Please log in to view assigned properties',
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('properties')
          .where('assignedAgentId', isEqualTo: userId)
          .snapshots(),
      builder: (context, snapshot) {
        // Debug logging
        debugPrint('🏠 AgentAssignedProperties - userId: $userId');
        debugPrint('🏠 AgentAssignedProperties - connectionState: ${snapshot.connectionState}');
        debugPrint('🏠 AgentAssignedProperties - hasError: ${snapshot.hasError}');
        if (snapshot.hasError) {
          debugPrint('🏠 AgentAssignedProperties - error: ${snapshot.error}');
        }
        debugPrint('🏠 AgentAssignedProperties - docs count: ${snapshot.data?.docs.length ?? 0}');
        
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        if (snapshot.hasError) {
          debugPrint('❌ Error loading assigned properties: ${snapshot.error}');
          return _buildEmptyState(
            icon: Icons.error_outline,
            title: 'Error Loading Properties',
            subtitle: 'Error: ${snapshot.error.toString().substring(0, 50)}...',
          );
        }

        final docs = snapshot.data?.docs ?? [];
        
        if (docs.isEmpty) {
          return _buildEmptyState(
            icon: Icons.home_work_outlined,
            title: 'No Assigned Properties',
            subtitle: 'Properties assigned to you by landlords will appear here',
          );
        }

        final properties = docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return PropertyModel.fromFirestore(data, doc.id);
        }).toList();

        // Sort by createdAt descending
        properties.sort((a, b) {
          final aDate = a.createdAt ?? DateTime(2000);
          final bDate = b.createdAt ?? DateTime(2000);
          return bDate.compareTo(aDate);
        });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Text('Assigned Properties', style: AppTextStyles.h2),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${properties.length}',
                      style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                itemCount: properties.length,
                itemBuilder: (context, index) {
                  return _AssignedPropertyCard(
                    property: properties[index],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildVerificationRequired() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_outline,
                size: 50,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(height: 24),
            Text('Verification Required', style: AppTextStyles.h4),
            const SizedBox(height: 8),
            Text(
              'Complete verification to view\nassigned properties',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.push('/agent/verification'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Get Verified',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.primaryLight.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 50, color: AppColors.primary),
            ),
            const SizedBox(height: 24),
            Text(title, style: AppTextStyles.h4),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ============ ASSIGNED PROPERTY CARD ============

class _AssignedPropertyCard extends StatelessWidget {
  final PropertyModel property;

  const _AssignedPropertyCard({required this.property});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/agent/property/${property.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(13),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: Stack(
                children: [
                  property.images.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: property.images.first,
                          height: 150,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            height: 150,
                            color: AppColors.background,
                            child: const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            height: 150,
                            color: AppColors.background,
                            child: Icon(Icons.home, size: 50, color: AppColors.textHint),
                          ),
                        )
                      : Container(
                          height: 150,
                          color: AppColors.background,
                          child: Center(
                            child: Icon(Icons.home, size: 50, color: AppColors.textHint),
                          ),
                        ),

                  // Availability badge
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: property.isAvailable
                            ? AppColors.success
                            : AppColors.textSecondary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        property.isAvailable ? 'Available' : 'Unavailable',
                        style: AppTextStyles.labelSmall.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  // Price badge
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(179),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${property.formattedRent}${property.rentPeriod}',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Content
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text(
                    property.title,
                    style: AppTextStyles.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),

                  // Location
                  Row(
                    children: [
                      Icon(Icons.location_on_outlined, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${property.address}, ${property.city}',
                          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Property details
                  Row(
                    children: [
                      _buildDetail(Icons.bed_outlined, '${property.bedrooms} Beds'),
                      const SizedBox(width: 16),
                      _buildDetail(Icons.bathtub_outlined, '${property.bathrooms} Baths'),
                      const SizedBox(width: 16),
                      _buildDetail(Icons.home_outlined, property.propertyType),
                    ],
                  ),

                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  // Landlord info
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(26),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            (property.landlordName ?? 'L').isNotEmpty
                                ? (property.landlordName ?? 'L')[0].toUpperCase()
                                : 'L',
                            style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              property.landlordName ?? 'Landlord',
                              style: AppTextStyles.labelMedium,
                            ),
                            Text(
                              'Landlord',
                              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),

                      // Stats
                      Row(
                        children: [
                          _buildStatBadge(Icons.visibility_outlined, '${property.viewCount}'),
                          const SizedBox(width: 8),
                          _buildStatBadge(Icons.mail_outline, '${property.inquiryCount}'),
                        ],
                      ),
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

  Widget _buildDetail(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(
          text,
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildStatBadge(IconData icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(
            value,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}