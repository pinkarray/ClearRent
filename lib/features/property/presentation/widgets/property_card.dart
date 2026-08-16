import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';

class PropertyCard extends StatelessWidget {
  final PropertyModel property;
  final VoidCallback? onTap;
  final VoidCallback? onSave;
  final bool isSaved;

  const PropertyCard({
    super.key,
    required this.property,
    this.onTap,
    this.onSave,
    this.isSaved = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                  child: CachedNetworkImage(
                    imageUrl: property.images.isNotEmpty
                        ? property.images.first
                        : '',
                    height: 160,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    // Decode/cache at ~card size, not the full-res original, so
                    // the list stays in the memory cache and doesn't reload.
                    memCacheWidth: 800,
                    placeholder: (context, url) => Container(
                      height: 160,
                      color: AppColors.background,
                      child: Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      height: 160,
                      color: AppColors.background,
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        color: AppColors.textHint,
                        size: 40,
                      ),
                    ),
                  ),
                ),

                // Taken by someone else, or delisted.
                //
                // Browse never renders these — it filters on the same
                // `isListable` — but Saved does, because a bookmark the tenant
                // made should not silently disappear when the unit goes. It
                // must not still look bookable either, hence the scrim. Sits
                // BELOW the save button in the stack so unsaving still works.
                if (!property.isListable)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      child: Container(
                        color: Colors.black.withAlpha(115),
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.textSecondary,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'No longer available',
                            style: AppTextStyles.caption.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Save button
                Positioned(
                  top: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: onSave,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(26),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        isSaved ? Icons.favorite : Icons.favorite_border,
                        size: 20,
                        color: isSaved ? AppColors.error : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),

                // Verified badge
                if (property.isVerified)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.verified,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Verified',
                            style: AppTextStyles.labelSmall.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Property type badge
                Positioned(
                  bottom: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(153),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      PropertyModel.typeLabelFor(property.propertyType),
                      style: AppTextStyles.labelSmall.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            // Content
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Price
                  Row(
                    children: [
                      Text(
                        property.formattedRent,
                        style: AppTextStyles.price,
                      ),
                      Text(
                        property.rentPeriod,
                        style: AppTextStyles.bodySmall,
                      ),
                      const Spacer(),
                      if (property.hasAgent)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.warningLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Agent: ${property.formattedAgentFee}',
                            style: AppTextStyles.labelSmall.copyWith(
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Title
                  Text(
                    property.title,
                    style: AppTextStyles.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  // Which unit this is, when it's one of several in a building.
                  // Without it two identical flats in one compound are the same
                  // card twice.
                  if (property.unitDescriptor.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      property.unitDescriptor,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],

                  const SizedBox(height: 4),

                  // Location
                  Row(
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${property.city}, ${property.state}',
                          style: AppTextStyles.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Features. A single space (room / room & parlour / self
                  // contain) has no meaningful room COUNT — showing
                  // "1 bed · 1 bath" made a shared room identical to a
                  // self-contained one-bedroom flat. What it gets exclusively
                  // is the real spec, so that is what's shown.
                  if (property.isSingleSpaceListing)
                    Row(
                      children: [
                        Icon(
                          property.sharedFacilities.isEmpty
                              ? Icons.lock_outlined
                              : Icons.group_outlined,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            property.sharedFacilities.isEmpty
                                ? 'Private bathroom & kitchen'
                                : property.sharedFacilities,
                            style: AppTextStyles.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  else ...[
                    Row(
                      children: [
                        if (property.bedrooms > 0)
                          _FeatureChip(
                            icon: Icons.bed_outlined,
                            label: '${property.bedrooms}',
                          ),
                        if (property.bathrooms > 0) ...[
                          const SizedBox(width: 12),
                          _FeatureChip(
                            icon: Icons.bathtub_outlined,
                            label: '${property.bathrooms}',
                          ),
                        ],
                        if (property.toilets > 0) ...[
                          const SizedBox(width: 12),
                          _FeatureChip(
                            icon: Icons.wc_outlined,
                            label: '${property.toilets}',
                          ),
                        ],
                      ],
                    ),
                    // A multi-room unit can share too — a flat in a compound
                    // whose toilet is outside. Counts alone would read as
                    // fully self-contained, which is the same confusion the
                    // single-space line exists to prevent.
                    if (property.sharedFacilities.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.group_outlined,
                            size: 14,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              property.sharedFacilities,
                              style: AppTextStyles.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

}

class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FeatureChip({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: AppTextStyles.bodySmall,
        ),
      ],
    );
  }
}