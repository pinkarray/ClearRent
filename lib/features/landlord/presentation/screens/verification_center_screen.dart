import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/verification_service.dart';

class VerificationCenterScreen extends StatefulWidget {
  const VerificationCenterScreen({super.key});

  @override
  State<VerificationCenterScreen> createState() => _VerificationCenterScreenState();
}

class _VerificationCenterScreenState extends State<VerificationCenterScreen> {
  final VerificationService _verificationService = VerificationService();
  final ImagePicker _picker = ImagePicker();

  VerificationData? _verificationData;
  bool _isLoading = true;
  bool _isSubmitting = false;

  // Selected files
  File? _ninFile;
  File? _propertyDocFile;
  File? _utilityBillFile;

  @override
  void initState() {
    super.initState();
    _loadVerificationStatus();
  }

  Future<void> _loadVerificationStatus() async {
    final data = await _verificationService.getVerificationStatus();
    if (mounted) {
      setState(() {
        _verificationData = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDocument(String type) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          switch (type) {
            case 'nin':
              _ninFile = File(image.path);
              break;
            case 'propertyDoc':
              _propertyDocFile = File(image.path);
              break;
            case 'utilityBill':
              _utilityBillFile = File(image.path);
              break;
          }
        });
      }
    } catch (e) {
      debugPrint('❌ Error picking image: $e');
      _showError('Failed to select image. Please try again.');
    }
  }

  Future<void> _submitVerification() async {
    if (_ninFile == null || _propertyDocFile == null || _utilityBillFile == null) {
      _showError('Please upload all required documents');
      return;
    }

    setState(() => _isSubmitting = true);

    final result = await _verificationService.submitVerification(
      ninFile: _ninFile!,
      propertyDocFile: _propertyDocFile!,
      utilityBillFile: _utilityBillFile!,
    );

    setState(() => _isSubmitting = false);

    if (result.success) {
      _showSuccess('Verification submitted! We\'ll review your documents within 24-48 hours.');
      await _loadVerificationStatus();
    } else {
      _showError(result.error ?? 'Failed to submit verification');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.success,
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
          'Verification Center',
          style: AppTextStyles.h4.copyWith(color: AppColors.textPrimary),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final status = _verificationData?.status ?? VerificationStatus.none;

    switch (status) {
      case VerificationStatus.verified:
        return _buildVerifiedState();
      case VerificationStatus.pending:
        return _buildPendingState();
      case VerificationStatus.rejected:
        return _buildRejectedState();
      case VerificationStatus.none:
        return _buildUploadForm();
    }
  }

  Widget _buildVerifiedState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.successLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.verified,
              size: 60,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'You\'re Verified!',
            style: AppTextStyles.h2,
          ),
          const SizedBox(height: 12),
          Text(
            'Your identity and property ownership have been confirmed. Tenants can trust that you\'re a legitimate landlord.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),
          _buildBenefitItem(
            Icons.visibility,
            'Higher Visibility',
            'Verified listings appear higher in search results',
          ),
          const SizedBox(height: 16),
          _buildBenefitItem(
            Icons.favorite,
            'More Trust',
            'Tenants are more likely to contact verified landlords',
          ),
          const SizedBox(height: 16),
          _buildBenefitItem(
            Icons.shield,
            'Badge Display',
            'Your verified badge appears on all your listings',
          ),
        ],
      ),
    );
  }

  Widget _buildPendingState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.warningLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.schedule,
              size: 60,
              color: AppColors.warning,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Verification Pending',
            style: AppTextStyles.h2,
          ),
          const SizedBox(height: 12),
          Text(
            'We\'re reviewing your documents. This usually takes 24-48 hours. We\'ll notify you once the review is complete.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),
          Container(
            width: double.infinity,
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
                  'Documents Submitted',
                  style: AppTextStyles.labelLarge,
                ),
                const SizedBox(height: 16),
                _buildDocumentStatus('NIN/Government ID', true),
                const SizedBox(height: 12),
                _buildDocumentStatus('Property Document', true),
                const SizedBox(height: 12),
                _buildDocumentStatus('Utility Bill', true),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Submitted ${_formatDate(_verificationData?.submittedAt)}',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textHint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRejectedState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.error.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.error_outline,
              size: 60,
              color: AppColors.error,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Verification Failed',
            style: AppTextStyles.h2,
          ),
          const SizedBox(height: 12),
          Text(
            'We couldn\'t verify your documents. Please review the reason below and try again.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (_verificationData?.rejectionReason != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(26),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.error.withAlpha(77),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: AppColors.error,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reason',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.error,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _verificationData!.rejectionReason!,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                setState(() {
                  _verificationData = VerificationData();
                  _ninFile = null;
                  _propertyDocFile = null;
                  _utilityBillFile = null;
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Try Again',
                style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadForm() {
    final allUploaded = _ninFile != null && _propertyDocFile != null && _utilityBillFile != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withAlpha(26),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primaryLight.withAlpha(77),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.verified_user_outlined,
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
                        'Why get verified?',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Verified landlords get more inquiries and tenant trust.',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.primary.withAlpha(204),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          Text(
            'Upload Documents',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'We need these documents to verify your identity and property ownership.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),

          const SizedBox(height: 24),

          // NIN Upload
          _DocumentUploadCard(
            title: 'NIN or Government ID',
            subtitle: 'National ID, Voter\'s Card, or Driver\'s License',
            icon: Icons.badge_outlined,
            file: _ninFile,
            onTap: () => _pickDocument('nin'),
            onRemove: () => setState(() => _ninFile = null),
          ),

          const SizedBox(height: 16),

          // Property Document Upload
          _DocumentUploadCard(
            title: 'Property Document',
            subtitle: 'C of O, Deed of Assignment, or Tenancy Agreement',
            icon: Icons.description_outlined,
            file: _propertyDocFile,
            onTap: () => _pickDocument('propertyDoc'),
            onRemove: () => setState(() => _propertyDocFile = null),
          ),

          const SizedBox(height: 16),

          // Utility Bill Upload
          _DocumentUploadCard(
            title: 'Utility Bill',
            subtitle: 'Recent electricity, water, or waste bill',
            icon: Icons.receipt_long_outlined,
            file: _utilityBillFile,
            onTap: () => _pickDocument('utilityBill'),
            onRemove: () => setState(() => _utilityBillFile = null),
          ),

          const SizedBox(height: 32),

          // Privacy note
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: AppColors.textHint,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your documents are securely stored and only used for verification.',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Submit button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: allUploaded && !_isSubmitting ? _submitVerification : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor: AppColors.border,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : Text(
                      'Submit for Verification',
                      style: AppTextStyles.labelLarge.copyWith(
                        color: allUploaded ? Colors.white : AppColors.textHint,
                      ),
                    ),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildBenefitItem(IconData icon, String title, String description) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.successLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.success, size: 22),
          ),
          const SizedBox(width: 16),
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
      ),
    );
  }

  Widget _buildDocumentStatus(String title, bool uploaded) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: uploaded ? AppColors.successLight : AppColors.background,
            shape: BoxShape.circle,
          ),
          child: Icon(
            uploaded ? Icons.check : Icons.circle_outlined,
            size: 14,
            color: uploaded ? AppColors.success : AppColors.textHint,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: AppTextStyles.bodyMedium.copyWith(
            color: uploaded ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final now = DateTime.now();
    final diff = now.difference(date);
    
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} minutes ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} hours ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}

class _DocumentUploadCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final File? file;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _DocumentUploadCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.file,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hasFile = file != null;

    return GestureDetector(
      onTap: hasFile ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: hasFile ? AppColors.successLight.withAlpha(77) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hasFile ? AppColors.success : AppColors.border,
            width: hasFile ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: hasFile 
                    ? AppColors.success.withAlpha(26) 
                    : AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: hasFile
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        file!,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Icon(
                      icon,
                      color: AppColors.textSecondary,
                      size: 24,
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.labelLarge.copyWith(
                      color: hasFile ? AppColors.success : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasFile ? 'Document uploaded' : subtitle,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: hasFile 
                          ? AppColors.success.withAlpha(204) 
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (hasFile)
              GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 18,
                    color: AppColors.error,
                  ),
                ),
              )
            else
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.add,
                  size: 18,
                  color: AppColors.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}