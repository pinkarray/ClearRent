import 'package:flutter/material.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/tenancy_link_service.dart';
import '../../../../shared/models/tenancy_link_model.dart';

class TenancyRequestsScreen extends StatefulWidget {
  const TenancyRequestsScreen({super.key});

  @override
  State<TenancyRequestsScreen> createState() => _TenancyRequestsScreenState();
}

class _TenancyRequestsScreenState extends State<TenancyRequestsScreen> {
  final TenancyLinkService _linkService = TenancyLinkService();
  // Cached so any rebuild doesn't recreate the stream and flash the list.
  late final Stream<List<TenancyLinkModel>> _pendingLinksStream =
      _linkService.tenantPendingLinksStream();

  Future<void> _handleConfirm(TenancyLinkModel link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Accept Link Request'),
        content: Text(
          '${link.landlordName} wants to link you as a tenant at "${link.propertyTitle}". '
          'Accepting confirms you currently live there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _linkService.acceptLink(link.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'You are now linked to "${link.propertyTitle}"'
                : 'Something went wrong. Please try again.'),
            backgroundColor:
                success ? AppColors.success : AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  Future<void> _handleReject(TenancyLinkModel link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Decline Request'),
        content: Text(
          'Decline the link request from ${link.landlordName} for "${link.propertyTitle}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                Text('Decline', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _linkService.rejectLink(link.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Request declined'
                : 'Something went wrong. Please try again.'),
            backgroundColor:
                success ? AppColors.textSecondary : AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text('Tenancy Requests', style: AppTextStyles.h4),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: StreamBuilder<List<TenancyLinkModel>>(
        stream: _pendingLinksStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final pending = snapshot.data ?? [];

          if (pending.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.inbox_outlined,
                      size: 48,
                      color: AppColors.textHint,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('No pending requests',
                      style: AppTextStyles.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    'When a landlord links you to their property,\nit will appear here.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: pending.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final link = pending[index];
              return _buildRequestCard(link);
            },
          );
        },
      ),
    );
  }

  Widget _buildRequestCard(TenancyLinkModel link) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Landlord row
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight.withAlpha(51),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    link.landlordName.isNotEmpty
                        ? link.landlordName[0].toUpperCase()
                        : 'L',
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(link.landlordName,
                        style: AppTextStyles.labelLarge),
                    const SizedBox(height: 2),
                    Text(
                      'Sent ${_formatDate(link.createdAt)}',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Pending',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.warning),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Property info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.home_outlined,
                    size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    link.propertyTitle,
                    style: AppTextStyles.labelMedium,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Info note
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.infoLight.withAlpha(128),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Accepting this request confirms you are an existing tenant at this property. No verification fee required.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.info),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _handleReject(link),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withAlpha(128)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => _handleConfirm(link),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'recently';

    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.day}/${date.month}/${date.year}';
  }
}