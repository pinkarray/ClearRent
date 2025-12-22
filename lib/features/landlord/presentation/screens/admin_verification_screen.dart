import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/verification_service.dart';

class AdminVerificationScreen extends StatefulWidget {
  const AdminVerificationScreen({super.key});

  @override
  State<AdminVerificationScreen> createState() => _AdminVerificationScreenState();
}

class _AdminVerificationScreenState extends State<AdminVerificationScreen> {
  final VerificationService _verificationService = VerificationService();
  
  List<PendingVerification> _pendingVerifications = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPendingVerifications();
  }

  Future<void> _loadPendingVerifications() async {
    setState(() => _isLoading = true);
    final verifications = await _verificationService.getPendingVerifications();
    if (mounted) {
      setState(() {
        _pendingVerifications = verifications;
        _isLoading = false;
      });
    }
  }

  Future<void> _openDocument(String? url) async {
    if (url == null) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _approveVerification(PendingVerification verification) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve Verification'),
        content: Text('Are you sure you want to approve ${verification.fullName}?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
            ),
            child: const Text('Approve', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _verificationService.approveVerification(verification.uid);
      if (!mounted) return;
      if (success) {
        _showMessage('Verification approved!', isError: false);
        _loadPendingVerifications();
      } else {
        _showMessage('Failed to approve verification', isError: true);
      }
    }
  }

  Future<void> _rejectVerification(PendingVerification verification) async {
    final reasonController = TextEditingController();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Verification'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Why is ${verification.fullName}\'s verification being rejected?'),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Enter reason for rejection...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('Reject', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && reasonController.text.isNotEmpty) {
      final success = await _verificationService.rejectVerification(
        verification.uid,
        reasonController.text,
      );
      if (!mounted) return;
      if (success) {
        _showMessage('Verification rejected', isError: false);
        _loadPendingVerifications();
      } else {
        _showMessage('Failed to reject verification', isError: true);
      }
    }
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
        behavior: SnackBarBehavior.floating,
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
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Verification Review',
          style: AppTextStyles.h4.copyWith(color: AppColors.textPrimary),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.primary),
            onPressed: _loadPendingVerifications,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _pendingVerifications.isEmpty
              ? _buildEmptyState()
              : _buildVerificationList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.successLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle_outline,
              size: 50,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'All caught up!',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'No pending verifications to review.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _pendingVerifications.length,
      itemBuilder: (context, index) {
        final verification = _pendingVerifications[index];
        return _VerificationCard(
          verification: verification,
          onOpenDocument: _openDocument,
          onApprove: () => _approveVerification(verification),
          onReject: () => _rejectVerification(verification),
        );
      },
    );
  }
}

class _VerificationCard extends StatelessWidget {
  final PendingVerification verification;
  final Function(String?) onOpenDocument;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _VerificationCard({
    required this.verification,
    required this.onOpenDocument,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight.withAlpha(51),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    verification.fullName.isNotEmpty 
                        ? verification.fullName[0].toUpperCase()
                        : 'U',
                    style: AppTextStyles.h4.copyWith(color: AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      verification.fullName,
                      style: AppTextStyles.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      verification.email,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.warningLight,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Pending',
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Documents
          Text(
            'Submitted Documents',
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),

          _DocumentRow(
            title: 'NIN / Government ID',
            url: verification.documents.ninUrl,
            onTap: () => onOpenDocument(verification.documents.ninUrl),
          ),
          const SizedBox(height: 8),
          _DocumentRow(
            title: 'Property Document',
            url: verification.documents.propertyDocUrl,
            onTap: () => onOpenDocument(verification.documents.propertyDocUrl),
          ),
          const SizedBox(height: 8),
          _DocumentRow(
            title: 'Utility Bill',
            url: verification.documents.utilityBillUrl,
            onTap: () => onOpenDocument(verification.documents.utilityBillUrl),
          ),

          const SizedBox(height: 16),

          // Submitted time
          if (verification.submittedAt != null)
            Text(
              'Submitted: ${_formatDate(verification.submittedAt!)}',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textHint,
              ),
            ),

          const SizedBox(height: 16),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: onApprove,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Approve',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} at ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class _DocumentRow extends StatelessWidget {
  final String title;
  final String? url;
  final VoidCallback onTap;

  const _DocumentRow({
    required this.title,
    required this.url,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasUrl = url != null && url!.isNotEmpty;

    return GestureDetector(
      onTap: hasUrl ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: hasUrl ? AppColors.primaryLight.withAlpha(26) : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasUrl ? AppColors.primaryLight : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasUrl ? Icons.description : Icons.description_outlined,
              size: 20,
              color: hasUrl ? AppColors.primary : AppColors.textHint,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: hasUrl ? AppColors.textPrimary : AppColors.textHint,
                ),
              ),
            ),
            if (hasUrl)
              const Icon(
                Icons.open_in_new,
                size: 18,
                color: AppColors.primary,
              )
            else
              Text(
                'Not uploaded',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                ),
              ),
          ],
        ),
      ),
    );
  }
}