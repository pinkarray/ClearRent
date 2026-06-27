import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../models/property_model.dart';

class SharePropertySheet extends StatelessWidget {
  final PropertyModel property;
  final VoidCallback? onShareInApp;

  const SharePropertySheet({
    super.key,
    required this.property,
    this.onShareInApp,
  });

  String get _shareText {
    final buffer = StringBuffer();
    buffer.writeln('🏠 ${property.title}');
    buffer.writeln('');
    buffer.writeln('📍 ${property.publicLocation}');
    buffer.writeln('💰 ${property.formattedRent}');
    buffer.writeln('');
    buffer.writeln(
        '🛏️ ${property.bedrooms} Bedroom(s) | 🚿 ${property.bathrooms} Bathroom(s)');
    buffer.writeln('');
    if (property.description.isNotEmpty) {
      buffer.writeln(property.description);
      buffer.writeln('');
    }
    buffer.writeln('---');
    buffer.writeln('Listed via ClearRent - Rent Without Regret');
    buffer.writeln('https://verealtytech.com');

    return buffer.toString();
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
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
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
          Text('Share Property', style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            'Share this property listing',
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          if (onShareInApp != null) ...[
            GestureDetector(
              onTap: () {
                Navigator.pop(context);
                onShareInApp!();
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary.withAlpha(51)),
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
                      child: Icon(Icons.send, color: AppColors.primary),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Send to landlord in ClearRent',
                              style: AppTextStyles.labelLarge),
                          const SizedBox(height: 2),
                          Text('Start a chat about this property',
                              style: AppTextStyles.caption),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: AppColors.textHint),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ShareOption(
                icon: Icons.share,
                label: 'Share',
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
                  style: AppTextStyles.labelSmall
                      .copyWith(color: AppColors.textSecondary),
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
    ));
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