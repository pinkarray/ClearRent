import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/verification_service.dart';

class VerificationBadge extends StatelessWidget {
  final VerificationStatus status;
  final bool showLabel;
  final bool compact;

  const VerificationBadge({
    super.key,
    required this.status,
    this.showLabel = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (status == VerificationStatus.none) {
      return const SizedBox.shrink();
    }

    final config = _getConfig();

    if (compact) {
      return Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: config.backgroundColor,
          shape: BoxShape.circle,
        ),
        child: Icon(config.icon, size: 12, color: config.color),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: showLabel ? 10 : 6,
        vertical: showLabel ? 6 : 4,
      ),
      decoration: BoxDecoration(
        color: config.backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(config.icon, size: showLabel ? 14 : 12, color: config.color),
          if (showLabel) ...[
            const SizedBox(width: 6),
            Text(
              config.label,
              style: AppTextStyles.labelSmall.copyWith(
                color: config.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  _BadgeConfig _getConfig() {
    switch (status) {
      case VerificationStatus.verified:
        return _BadgeConfig(
          icon: Icons.verified,
          label: 'Verified',
          color: AppColors.success,
          backgroundColor: AppColors.successLight,
        );
      case VerificationStatus.pending:
        return _BadgeConfig(
          icon: Icons.schedule,
          label: 'Pending',
          color: AppColors.warning,
          backgroundColor: AppColors.warningLight,
        );
      case VerificationStatus.rejected:
        return _BadgeConfig(
          icon: Icons.cancel,
          label: 'Rejected',
          color: AppColors.error,
          backgroundColor: AppColors.error.withAlpha(26),
        );
      case VerificationStatus.expired:
        return _BadgeConfig(
          icon: Icons.autorenew,
          label: 'Renewal due',
          color: AppColors.warning,
          backgroundColor: AppColors.warningLight,
        );
      case VerificationStatus.none:
        return _BadgeConfig(
          icon: Icons.help_outline,
          label: '',
          color: AppColors.textHint,
          backgroundColor: Colors.transparent,
        );
    }
  }
}

class _BadgeConfig {
  final IconData icon;
  final String label;
  final Color color;
  final Color backgroundColor;

  _BadgeConfig({
    required this.icon,
    required this.label,
    required this.color,
    required this.backgroundColor,
  });
}

// Larger verification badge for profile headers
class VerificationBadgeLarge extends StatelessWidget {
  final VerificationStatus status;
  final VoidCallback? onTap;
  // Role shown in the verified label, e.g. "Verified Tenant". Defaults to
  // Landlord (the badge's original consumer) so existing call sites are unchanged.
  final String role;

  const VerificationBadgeLarge({super.key, required this.status, this.onTap, this.role = 'Landlord'});

  @override
  Widget build(BuildContext context) {
    final config = _getConfig();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: config.backgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: config.borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(config.icon, size: 16, color: config.color),
            const SizedBox(width: 6),
            Text(
              config.label,
              style: AppTextStyles.labelMedium.copyWith(
                color: config.color,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: config.color),
            ],
          ],
        ),
      ),
    );
  }

  _BadgeConfigLarge _getConfig() {
    switch (status) {
      case VerificationStatus.verified:
        return _BadgeConfigLarge(
          icon: Icons.verified,
          label: 'Verified $role',
          color: Colors.white,
          backgroundColor: Colors.white.withAlpha(51),
          borderColor: Colors.white.withAlpha(77),
        );
      case VerificationStatus.pending:
        return _BadgeConfigLarge(
          icon: Icons.schedule,
          label: 'Verification Pending',
          color: Colors.white,
          backgroundColor: Colors.white.withAlpha(51),
          borderColor: Colors.white.withAlpha(77),
        );
      case VerificationStatus.rejected:
        return _BadgeConfigLarge(
          icon: Icons.error_outline,
          label: 'Verification Failed',
          color: Colors.white,
          backgroundColor: AppColors.error.withAlpha(77),
          borderColor: AppColors.error.withAlpha(128),
        );
      case VerificationStatus.expired:
        return _BadgeConfigLarge(
          icon: Icons.autorenew,
          label: 'Renewal Due',
          color: Colors.white,
          backgroundColor: AppColors.warning.withAlpha(77),
          borderColor: AppColors.warning.withAlpha(128),
        );
      case VerificationStatus.none:
        return _BadgeConfigLarge(
          icon: Icons.shield_outlined,
          label: 'Get Verified',
          color: Colors.white,
          backgroundColor: Colors.white.withAlpha(51),
          borderColor: Colors.white.withAlpha(77),
        );
    }
  }
}

class _BadgeConfigLarge {
  final IconData icon;
  final String label;
  final Color color;
  final Color backgroundColor;
  final Color borderColor;

  _BadgeConfigLarge({
    required this.icon,
    required this.label,
    required this.color,
    required this.backgroundColor,
    required this.borderColor,
  });
}

// "What does verified mean?" bottom sheet
class VerificationExplainer extends StatelessWidget {
  const VerificationExplainer({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const VerificationExplainer(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(24),
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
          const SizedBox(height: 24),

          // Header
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.successLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.verified,
                  color: AppColors.success,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What does Verified mean?', style: AppTextStyles.h4),
                    const SizedBox(height: 4),
                    Text(
                      'Your trust badge on ClearRent',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Explanation items
          _ExplainerItem(
            icon: Icons.person_outline,
            title: 'Identity Confirmed',
            description:
                'Landlord\'s NIN has been verified against official records.',
          ),
          const SizedBox(height: 16),
          _ExplainerItem(
            icon: Icons.home_outlined,
            title: 'Property Ownership',
            description:
                'Property documents prove ownership or management rights.',
          ),
          const SizedBox(height: 16),
          _ExplainerItem(
            icon: Icons.location_on_outlined,
            title: 'Address Verified',
            description:
                'Utility bill confirms the property address is accurate.',
          ),

          const SizedBox(height: 24),

          // Trust message
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withAlpha(26),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primaryLight.withAlpha(77)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  color: AppColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Verified landlords have passed our trust checks, reducing the risk of fraud.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Close button
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                'Got it',
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _ExplainerItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _ExplainerItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppColors.textPrimary, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTextStyles.labelLarge),
              const SizedBox(height: 2),
              Text(
                description,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
