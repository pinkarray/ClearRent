import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/agreement_access_service.dart';
import '../../../../services/conversation_service.dart';

/// Landlord screen to manage tenancy agreements for all active rentals.
/// Upload agreements, track tenant responses, finalize or re-upload.
class LandlordAgreementsScreen extends StatefulWidget {
  const LandlordAgreementsScreen({super.key});

  @override
  State<LandlordAgreementsScreen> createState() => _LandlordAgreementsScreenState();
}

class _LandlordAgreementsScreenState extends State<LandlordAgreementsScreen> {
  final ActiveRentalService _rentalService = ActiveRentalService();
  List<ActiveRental> _rentals = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRentals();
  }

  Future<void> _loadRentals() async {
    setState(() => _isLoading = true);
    try {
      final rentals = await _rentalService.getLandlordRentals();
      if (mounted) {
        setState(() {
          // Show active/expiring rentals first, then others
          _rentals = rentals..sort((a, b) {
            final order = {'active': 0, 'expiring_soon': 1, 'expired': 2, 'terminated': 3};
            final aOrder = order[a.status.name] ?? 4;
            final bOrder = order[b.status.name] ?? 4;
            if (aOrder != bOrder) return aOrder.compareTo(bOrder);
            return b.createdAt.compareTo(a.createdAt);
          });
          _isLoading = false;
        });
      }
    } catch (e) {
      developer.log('❌ Error loading rentals: $e', name: 'LandlordAgreements');
      if (mounted) setState(() => _isLoading = false);
    }
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
        title: Text('Tenancy Agreements', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _rentals.isEmpty
              ? const GuidanceEmptyState(
                  icon: Icons.description_outlined,
                  title: 'No Active Rentals',
                  subtitle:
                      'Agreements will appear here once you have active tenants.',
                )
              : RefreshIndicator(
                  onRefresh: _loadRentals,
                  color: AppColors.primary,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _rentals.length,
                    itemBuilder: (context, i) => _AgreementCard(
                      rental: _rentals[i],
                      onUpdated: _loadRentals,
                    ),
                  ),
                ),
    );
  }

}

class _AgreementCard extends StatefulWidget {
  final ActiveRental rental;
  final VoidCallback onUpdated;
  const _AgreementCard({required this.rental, required this.onUpdated});

  @override
  State<_AgreementCard> createState() => _AgreementCardState();
}

class _AgreementCardState extends State<_AgreementCard> {
  final ActiveRentalService _rentalService = ActiveRentalService();
  final PropertyService _propertyService = PropertyService();
  final AgreementAccessService _agreementAccess = AgreementAccessService();
  final ConversationService _conversationService = ConversationService();
  bool _isUploading = false;
  bool _isFinalizing = false;

  ActiveRental get r => widget.rental;

  Color get _statusColor {
    switch (r.agreementStatus) {
      case AgreementStatus.none: return AppColors.textHint;
      case AgreementStatus.pendingReview: return AppColors.info;
      case AgreementStatus.accepted: return AppColors.success;
      case AgreementStatus.disputed: return AppColors.warning;
      case AgreementStatus.finalized: return AppColors.success;
    }
  }

  IconData get _statusIcon {
    switch (r.agreementStatus) {
      case AgreementStatus.none: return Icons.upload_file;
      case AgreementStatus.pendingReview: return Icons.hourglass_top;
      case AgreementStatus.accepted: return Icons.check_circle;
      case AgreementStatus.disputed: return Icons.warning_amber;
      case AgreementStatus.finalized: return Icons.verified;
    }
  }

  String get _statusLabel {
    switch (r.agreementStatus) {
      case AgreementStatus.none: return 'No Agreement';
      case AgreementStatus.pendingReview: return 'Awaiting Tenant Review';
      case AgreementStatus.accepted: return 'Tenant Accepted — Ready to Finalize';
      case AgreementStatus.disputed: return 'Tenant Has Concerns';
      case AgreementStatus.finalized: return 'Finalized';
    }
  }

  Future<void> _uploadAgreement({bool isReupload = false}) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (image == null) return;

    setState(() => _isUploading = true);
    try {
      // Private Storage (not Cloudinary) — agreements are sensitive PII.
      final url = await _propertyService.uploadAgreementDoc(File(image.path));
      if (url == null || url.isEmpty) throw Exception('Upload failed');

      bool success;
      if (isReupload) {
        success = await _rentalService.reuploadAgreement(r.id, url);
      } else {
        success = await _rentalService.sendAgreementToTenant(r.id, url);
      }

      if (mounted) {
        setState(() => _isUploading = false);
        if (success) {
          widget.onUpdated();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isReupload
                ? 'Revised agreement sent to ${r.tenantName}!'
                : 'Agreement sent to ${r.tenantName} for review!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      }
    } catch (e) {
      developer.log('❌ Upload error: $e', name: 'LandlordAgreements');
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to upload agreement. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  Future<void> _finalizeAgreement() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finalize Agreement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r.tenantName} has accepted the agreement. Do you want to finalize it?',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.info.withAlpha(51)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.gavel_outlined, size: 18, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'For full legal protection, remember to get the agreement stamped at your local LIRS/SIRS office.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ]),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success, foregroundColor: Colors.white),
            child: const Text('Finalize'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isFinalizing = true);

    final success = await _rentalService.landlordFinalizeAgreement(r.id);
    if (mounted) {
      setState(() => _isFinalizing = false);
      if (success) {
        widget.onUpdated();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Agreement finalized! Both parties have a copy.'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  Future<void> _messageTenant() async {
    try {
      final conv = await _conversationService.getOrCreateConversation(
        propertyId: r.propertyId,
        propertyTitle: r.propertyTitle,
        propertyImage: r.propertyImage,
        landlordId: r.landlordId,
        landlordName: r.landlordName,
        tenantId: r.tenantId,
        tenantName: r.tenantName,
      );
      if (conv != null && mounted) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': r.propertyTitle,
          'propertyImage': r.propertyImage.isNotEmpty ? r.propertyImage : null,
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: r.agreementStatus == AgreementStatus.disputed
              ? AppColors.warning.withAlpha(77)
              : r.agreementStatus == AgreementStatus.accepted
                  ? AppColors.success.withAlpha(77)
                  : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: Property + Tenant ──
          Row(children: [
            // Property thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: r.propertyImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: r.propertyImage,
                      width: 50, height: 50, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _placeholder())
                  : _placeholder(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.propertyTitle, style: AppTextStyles.labelLarge,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    Icon(Icons.person_outline, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text('Tenant: ${r.tenantName}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                  ]),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // ── Status badge ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _statusColor.withAlpha(13),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _statusColor.withAlpha(51)),
            ),
            child: Row(children: [
              Icon(_statusIcon, size: 20, color: _statusColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_statusLabel,
                    style: AppTextStyles.labelSmall.copyWith(color: _statusColor, fontWeight: FontWeight.w600)),
              ),
              if (r.agreementUploadedAt != null)
                Text(DateFormat('d MMM y').format(r.agreementUploadedAt!),
                    style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
            ]),
          ),

          // ── Dispute reason (if any) ──
          if (r.isAgreementDisputed && r.tenantDisputeReason != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tenant\'s concern:', style: AppTextStyles.caption.copyWith(color: AppColors.warning)),
                  const SizedBox(height: 4),
                  Text(r.tenantDisputeReason!,
                      style: AppTextStyles.bodySmall.copyWith(fontStyle: FontStyle.italic)),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // ── Action buttons based on status ──
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildActions() {
    switch (r.agreementStatus) {
      // No agreement → Upload button
      case AgreementStatus.none:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isUploading ? null : () => _uploadAgreement(),
            icon: _isUploading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload_file, size: 20),
            label: Text(_isUploading ? 'Uploading...' : 'Upload Agreement'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        );

      // Pending review → View + Message
      case AgreementStatus.pendingReview:
        return Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _viewAgreement(),
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: const Text('View'),
              style: _outlineStyle(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _messageTenant(),
              icon: const Icon(Icons.chat_outlined, size: 18),
              label: const Text('Message'),
              style: _outlineStyle(),
            ),
          ),
        ]);

      // Tenant accepted → Finalize button
      case AgreementStatus.accepted:
        return Column(children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isFinalizing ? null : () => _finalizeAgreement(),
              icon: _isFinalizing
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.verified_outlined, size: 20),
              label: Text(_isFinalizing ? 'Finalizing...' : 'Finalize Agreement'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _viewAgreement(),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('View'),
                style: _outlineStyle(),
              ),
            ),
          ]),
        ]);

      // Disputed → Re-upload + Message + View
      case AgreementStatus.disputed:
        return Column(children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isUploading ? null : () => _uploadAgreement(isReupload: true),
              icon: _isUploading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.upload_file, size: 20),
              label: Text(_isUploading ? 'Uploading...' : 'Upload Revised Agreement'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _viewAgreement(),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('View'),
                style: _outlineStyle(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _messageTenant(),
                icon: const Icon(Icons.chat_outlined, size: 18),
                label: const Text('Discuss'),
                style: _outlineStyle(),
              ),
            ),
          ]),
        ]);

      // Finalized → View only + stamp notice
      case AgreementStatus.finalized:
        return Column(children: [
          OutlinedButton.icon(
            onPressed: () => _viewAgreement(),
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('View Agreement'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: BorderSide(color: AppColors.success),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              minimumSize: const Size(double.infinity, 44),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.gavel_outlined, size: 16, color: AppColors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'For court admissibility, get this agreement stamped at your local LIRS/SIRS office.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ]),
          ),
        ]);
    }
  }

  // Agreements are private — resolve a short-lived signed URL via the CF
  // (which authorizes this landlord as a party) before opening.
  Future<void> _viewAgreement() async {
    if (r.agreementUrl == null) return;
    final url = await _agreementAccess.resolveUrl(
      collection: 'active_rentals',
      docId: r.id,
    );
    if (!mounted || url == null) return;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _placeholder() => Container(
        width: 50, height: 50,
        decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(10)),
        child: Icon(Icons.home_outlined, color: AppColors.textHint, size: 24),
      );

  ButtonStyle _outlineStyle() => OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        side: BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
}