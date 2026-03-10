import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _appVersion = '1.0.0';
  static const String _buildNumber = '1';
  static const String _websiteUrl = 'https://clearrent.ng';
  static const String _privacyUrl = 'https://clearrent.ng/privacy';
  static const String _termsUrl = 'https://clearrent.ng/terms';

  Future<void> _launchUrl(BuildContext context, String url) async {
    final Uri uri = Uri.parse(url);
    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        _showError(context, 'Could not open link');
      }
    } catch (e) {
      if (context.mounted) {
        _showError(context, 'Could not open link');
      }
    }
  }

  void _showError(BuildContext context, String message) {
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('About ClearRent', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 32),

            // App Logo & Info
            _buildAppHeader(),

            const SizedBox(height: 32),

            // App Description
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'ClearRent is Nigeria\'s trusted rental marketplace that connects landlords directly with tenants. We eliminate rental fraud by verifying landlords and providing transparent, secure transactions.',
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 32),

            // Features
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildFeatures(),
            ),

            const SizedBox(height: 32),

            // Links Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildLinksSection(context),
            ),

            const SizedBox(height: 32),

            // Version Info
            _buildVersionInfo(),

            const SizedBox(height: 24),

            // Copyright
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '© ${DateTime.now().year} ClearRent. All rights reserved.',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildAppHeader() {
    return Column(
      children: [
        // App Icon
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withAlpha(77),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.home_rounded,
            size: 50,
            color: Colors.white,
          ),
        ),

        const SizedBox(height: 16),

        // App Name
        Text(
          'ClearRent',
          style: AppTextStyles.h2.copyWith(
            color: AppColors.primary,
          ),
        ),

        const SizedBox(height: 4),

        // Tagline
        Text(
          'Rent Without Regret',
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _buildFeatures() {
    final features = [
      _FeatureItem(
        icon: Icons.verified_user_outlined,
        title: 'Verified Landlords',
        description: 'All landlords go through identity verification',
      ),
      _FeatureItem(
        icon: Icons.security_outlined,
        title: 'Secure Payments',
        description: 'Safe transactions powered by Paystack',
      ),
      _FeatureItem(
        icon: Icons.chat_outlined,
        title: 'Direct Communication',
        description: 'Connect directly with landlords or tenants',
      ),
      _FeatureItem(
        icon: Icons.visibility_outlined,
        title: 'Transparent Fees',
        description: 'No hidden charges, clear pricing always',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Why ClearRent?',
            style: AppTextStyles.labelLarge,
          ),
          const SizedBox(height: 16),
          ...features.map((feature) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    feature.icon,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        feature.title,
                        style: AppTextStyles.labelMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        feature.description,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildLinksSection(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _buildLinkItem(
            context: context,
            icon: Icons.language_outlined,
            title: 'Visit Website',
            subtitle: 'clearrent.ng',
            onTap: () => _launchUrl(context, _websiteUrl),
          ),
          Divider(height: 1, color: AppColors.border, indent: 56),
          _buildLinkItem(
            context: context,
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'How we handle your data',
            onTap: () => _launchUrl(context, _privacyUrl),
          ),
          Divider(height: 1, color: AppColors.border, indent: 56),
          _buildLinkItem(
            context: context,
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            subtitle: 'Our terms and conditions',
            onTap: () => _launchUrl(context, _termsUrl),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkItem({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppColors.textPrimary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.open_in_new,
              color: AppColors.textHint,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionInfo() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.info_outline,
            color: AppColors.textHint,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            'Version $_appVersion ($_buildNumber)',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureItem {
  final IconData icon;
  final String title;
  final String description;

  _FeatureItem({
    required this.icon,
    required this.title,
    required this.description,
  });
}