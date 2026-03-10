import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloudinary_public/cloudinary_public.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/rental_interest_service.dart';

class RentalPaymentScreen extends StatefulWidget {
  final RentalInterest rentalInterest;
  final InspectionRequest inspectionRequest;

  const RentalPaymentScreen({
    super.key,
    required this.rentalInterest,
    required this.inspectionRequest,
  });

  @override
  State<RentalPaymentScreen> createState() => _RentalPaymentScreenState();
}

class _RentalPaymentScreenState extends State<RentalPaymentScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  final RentalInterestService _rentalInterestService =
      RentalInterestService();

  // Same Cloudinary config as PropertyService
  final _cloudinary = CloudinaryPublic(
    'den5t1dai',
    'clearrent_uploads',
    cache: false,
  );

  File? _selectedImage;
  bool _isUploading = false;
  bool _copied = false;

  bool get _isRejected =>
      widget.rentalInterest.status == RentalInterestStatus.rejected;

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
        title: Text('Rental Payment', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Rejection warning
            if (_isRejected) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(13),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.error.withAlpha(51))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.warning_amber_rounded,
                          color: AppColors.error, size: 20),
                      const SizedBox(width: 8),
                      Text('Payment Rejected',
                          style: AppTextStyles.labelLarge
                              .copyWith(color: AppColors.error)),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                        widget.rentalInterest.paymentRejectionReason ??
                            'Your payment could not be verified.',
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text('Please re-upload your payment proof below.',
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.error)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Property info card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border)),
              child: Row(children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(26),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.home_outlined,
                      color: AppColors.primary, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.inspectionRequest.propertyTitle,
                          style: AppTextStyles.labelLarge,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.location_on_outlined,
                            size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 4),
                        Expanded(
                            child: Text(
                                widget
                                    .inspectionRequest.propertyAddress,
                                style: AppTextStyles.caption.copyWith(
                                    color: AppColors.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis)),
                      ]),
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            // Payment amount
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary.withAlpha(51))),
              child: Column(children: [
                Text('Amount to Pay',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                if (widget.rentalInterest.paymentAmount > 0)
                  Text(
                      '₦${_formatAmount(widget.rentalInterest.paymentAmount)}',
                      style: AppTextStyles.h3
                          .copyWith(color: AppColors.primary))
                else
                  Text('Transfer exact rent amount',
                      style: AppTextStyles.labelLarge
                          .copyWith(color: AppColors.primary)),
                const SizedBox(height: 4),
                Text('Rental payment',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ]),
            ),
            const SizedBox(height: 24),

            // Bank details
            Text('Transfer to this account',
                style: AppTextStyles.labelLarge),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border)),
              child: Column(children: [
                _bankDetailRow('Bank', 'Providus Bank'),
                const Divider(height: 24),
                _bankDetailRow('Account Number', '6507861182',
                    isCopyable: true),
                const Divider(height: 24),
                _bankDetailRow('Account Name', 'Oredugba Ayomide'),
              ]),
            ),
            const SizedBox(height: 24),

            // Upload proof
            Text('Upload Payment Proof', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            Text(
                'Take a screenshot of your transfer confirmation and upload it below.',
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 12),

            if (_selectedImage != null) ...[
              // Image preview
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(_selectedImage!,
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: _pickImage,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                          color: Colors.black.withAlpha(153),
                          borderRadius: BorderRadius.circular(20)),
                      child: Text('Change',
                          style: AppTextStyles.labelSmall
                              .copyWith(color: Colors.white)),
                    ),
                  ),
                ),
              ]),
            ] else ...[
              // Upload buttons
              Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _pickImage,
                    child: Container(
                      height: 100,
                      decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AppColors.primary, width: 1.5)),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                  color: AppColors.primary.withAlpha(26),
                                  shape: BoxShape.circle),
                              child: Icon(
                                  Icons.photo_library_outlined,
                                  color: AppColors.primary,
                                  size: 20),
                            ),
                            const SizedBox(height: 8),
                            Text('Gallery',
                                style: AppTextStyles.labelMedium
                                    .copyWith(color: AppColors.primary)),
                          ]),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: _takePhoto,
                    child: Container(
                      height: 100,
                      decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AppColors.border, width: 1.5)),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                  color: AppColors.textHint.withAlpha(26),
                                  shape: BoxShape.circle),
                              child: Icon(
                                  Icons.camera_alt_outlined,
                                  color: AppColors.textSecondary,
                                  size: 20),
                            ),
                            const SizedBox(height: 8),
                            Text('Camera',
                                style: AppTextStyles.labelMedium.copyWith(
                                    color: AppColors.textSecondary)),
                          ]),
                    ),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 32),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: _isUploading
                    ? 'Uploading...'
                    : _isRejected
                        ? 'Re-submit Payment Proof'
                        : 'Submit Payment Proof',
                onPressed:
                    (_selectedImage != null && !_isUploading)
                        ? _submitPayment
                        : null,
                isLoading: _isUploading,
              ),
            ),
            const SizedBox(height: 16),

            // Info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.infoLight.withAlpha(128),
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                Icon(Icons.info_outline,
                    size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        'We\'ll verify your payment within 24 hours. Once confirmed, the landlord will finalize your rental.',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.info))),
              ]),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _bankDetailRow(String label, String value,
      {bool isCopyable = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary)),
        Row(children: [
          Text(value, style: AppTextStyles.labelMedium),
          if (isCopyable) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                setState(() => _copied = true);
                Future.delayed(const Duration(seconds: 2),
                    () { if (mounted) setState(() => _copied = false); });
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: const Text('Account number copied!'),
                  backgroundColor: AppColors.success,
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ));
              },
              child: Icon(
                  _copied ? Icons.check : Icons.copy,
                  size: 18,
                  color:
                      _copied ? AppColors.success : AppColors.primary),
            ),
          ],
        ]),
      ],
    );
  }

  Future<void> _pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (image != null) {
        setState(() => _selectedImage = File(image.path));
      }
    } catch (e) {
      developer.log('❌ Gallery error: $e', name: 'RentalPayment');
      _showError('Failed to pick image.');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (image != null) {
        setState(() => _selectedImage = File(image.path));
      }
    } catch (e) {
      developer.log('❌ Camera error: $e', name: 'RentalPayment');
      _showError('Failed to take photo.');
    }
  }

  Future<void> _submitPayment() async {
    if (_selectedImage == null) return;
    setState(() => _isUploading = true);

    try {
      // Upload to Cloudinary (same pattern as PropertyService)
      developer.log('📤 Uploading rental payment proof...',
          name: 'RentalPayment');

      final response = await _cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          _selectedImage!.path,
          folder: 'clearrent/rental_payments',
          resourceType: CloudinaryResourceType.Image,
        ),
      );

      final imageUrl = response.secureUrl;
      developer.log('✅ Upload successful: $imageUrl',
          name: 'RentalPayment');

      // Update rental interest with proof URL
      final success = await _rentalInterestService.uploadPaymentProof(
          widget.rentalInterest.id, imageUrl);

      if (!mounted) return;
      setState(() => _isUploading = false);

      if (success) {
        _showSuccessDialog();
      } else {
        _showError('Failed to submit payment. Please try again.');
      }
    } catch (e) {
      developer.log('❌ Upload error: $e', name: 'RentalPayment');
      if (mounted) {
        setState(() => _isUploading = false);
        _showError('Upload failed. Please try again.');
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                  color: AppColors.successLight,
                  shape: BoxShape.circle),
              child: Icon(Icons.check,
                  size: 40, color: AppColors.success),
            ),
            const SizedBox(height: 24),
            Text('Payment Submitted!', style: AppTextStyles.h3),
            const SizedBox(height: 8),
            Text(
                'We\'ll verify your payment within 24 hours. You\'ll be notified once confirmed.',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: 'Back to Inspections',
                onPressed: () {
                  Navigator.pop(ctx);
                  context.pop();
                },
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10)),
    ));
  }

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }
}