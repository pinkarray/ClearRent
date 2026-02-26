import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/copyable_field.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/property_service.dart';

/// Bottom sheet for manual payment via bank transfer.
/// Shows account details, fee breakdown, and allows uploading payment proof.
class ManualPaymentSheet extends StatefulWidget {
  final PropertyModel property;
  final DateTime selectedDate;
  final String selectedTimeSlot;
  final String? notes;
  final InspectionFeeBreakdown feeBreakdown;

  const ManualPaymentSheet({
    super.key,
    required this.property,
    required this.selectedDate,
    required this.selectedTimeSlot,
    this.notes,
    required this.feeBreakdown,
  });

  /// Show the manual payment sheet and return true if request was created successfully
  static Future<bool?> show(
    BuildContext context, {
    required PropertyModel property,
    required DateTime selectedDate,
    required String selectedTimeSlot,
    String? notes,
    required InspectionFeeBreakdown feeBreakdown,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ManualPaymentSheet(
        property: property,
        selectedDate: selectedDate,
        selectedTimeSlot: selectedTimeSlot,
        notes: notes,
        feeBreakdown: feeBreakdown,
      ),
    );
  }

  @override
  State<ManualPaymentSheet> createState() => _ManualPaymentSheetState();
}

class _ManualPaymentSheetState extends State<ManualPaymentSheet> {
  final InspectionService _inspectionService = InspectionService();
  final PropertyService _propertyService = PropertyService();
  final ImagePicker _imagePicker = ImagePicker();

  File? _paymentProofFile;
  bool _isUploading = false;
  bool _isSubmitting = false;
  String? _uploadedProofUrl;

  // Bank account details
  static const String _accountNumber = '6507861182';
  static const String _accountName = 'Oredugba Ayomide';
  static const String _bankName = 'Providus Bank';

  String get _formattedDate {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return '${weekdays[widget.selectedDate.weekday - 1]}, ${months[widget.selectedDate.month - 1]} ${widget.selectedDate.day}';
  }

  String get _formattedTime {
    return InspectionService.timeSlotDisplay[widget.selectedTimeSlot] ?? widget.selectedTimeSlot;
  }

  Future<void> _pickPaymentProof() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );

      if (image == null) return;

      setState(() {
        _paymentProofFile = File(image.path);
        _uploadedProofUrl = null;
      });
    } catch (e) {
      debugPrint('❌ Error picking image: $e');
      _showError('Failed to pick image. Please try again.');
    }
  }

  Future<void> _takePaymentProofPhoto() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );

      if (image == null) return;

      setState(() {
        _paymentProofFile = File(image.path);
        _uploadedProofUrl = null;
      });
    } catch (e) {
      debugPrint('❌ Error taking photo: $e');
      _showError('Failed to take photo. Please try again.');
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Text('Upload Payment Proof', style: AppTextStyles.h4),
            const SizedBox(height: 24),
            ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.photo_library, color: AppColors.primary),
              ),
              title: Text('Choose from Gallery', style: AppTextStyles.labelLarge),
              subtitle: Text('Select a screenshot from your photos', style: AppTextStyles.caption),
              onTap: () {
                Navigator.pop(context);
                _pickPaymentProof();
              },
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.camera_alt, color: AppColors.info),
              ),
              title: Text('Take a Photo', style: AppTextStyles.labelLarge),
              subtitle: Text('Capture your payment confirmation', style: AppTextStyles.caption),
              onTap: () {
                Navigator.pop(context);
                _takePaymentProofPhoto();
              },
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  Future<void> _submitRequest() async {
    if (_paymentProofFile == null) {
      _showError('Please upload your payment proof');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      if (_uploadedProofUrl == null) {
        setState(() => _isUploading = true);
        _uploadedProofUrl = await _propertyService.uploadImage(_paymentProofFile!);
        setState(() => _isUploading = false);

        if (_uploadedProofUrl == null) {
          _showError('Failed to upload payment proof. Please try again.');
          setState(() => _isSubmitting = false);
          return;
        }
      }

      final result = await _inspectionService.createInspectionRequest(
        property: widget.property,
        requestedDate: widget.selectedDate,
        requestedTimeSlot: widget.selectedTimeSlot,
        notes: widget.notes,
        feeBreakdown: widget.feeBreakdown,
        paymentReference: 'MANUAL_${DateTime.now().millisecondsSinceEpoch}',
        paymentProofUrl: _uploadedProofUrl,
        paymentStatus: 'pending_verification',
      );

      if (!mounted) return;
      setState(() => _isSubmitting = false);

      if (result == 'already_pending') {
        Navigator.pop(context, false);
        _showError('You already have a pending request for this property');
        return;
      }
      if (result == 'not_verified') {
        Navigator.pop(context, false);
        _showError('You need to be verified to request inspections');
        return;
      }
      if (result == 'landlord_not_verified') {
        Navigator.pop(context, false);
        _showError('The landlord is not verified yet');
        return;
      }
      if (result == 'agent_not_verified') {
        Navigator.pop(context, false);
        _showError('The assigned agent is not verified yet');
        return;
      }

      if (result != null) {
        _showSuccessDialog();
      } else {
        _showError('Failed to submit request. Please try again.');
      }
    } catch (e) {
      debugPrint('❌ Error submitting request: $e');
      setState(() {
        _isUploading = false;
        _isSubmitting = false;
      });
      _showError('Something went wrong. Please try again.');
    }
  }

  void _showSuccessDialog() {
    final rootNavigator = Navigator.of(context, rootNavigator: true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle, color: AppColors.success, size: 48),
            ),
            const SizedBox(height: 24),
            Text('Request Submitted!', style: AppTextStyles.h3, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Your payment is being verified. Once confirmed, your inspection request will be sent to the agent.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.calendar_today, size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(_formattedDate, style: AppTextStyles.labelMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.access_time, size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(_formattedTime, style: AppTextStyles.labelMedium),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20, color: AppColors.info),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Payment verification usually takes 1-2 hours during business hours.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.info),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  // Close dialog first, then close sheet, then navigate
                  Navigator.pop(dialogContext);
                  rootNavigator.pop(true); // closes the bottom sheet with result=true
                  rootNavigator.context.go('/tenant/inspections');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'View My Inspections',
                  style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                rootNavigator.pop(true); // closes the sheet with result=true
              },
              child: Text(
                'Back to Property',
                style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('Complete Payment', style: AppTextStyles.h4),
                const SizedBox(height: 4),
                Text('Transfer the exact amount and upload proof', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFeeBreakdown(),
                  const SizedBox(height: 20),
                  BankAccountCard(
                    accountNumber: _accountNumber,
                    accountName: _accountName,
                    bankName: _bankName,
                    amount: widget.feeBreakdown.totalFee,
                    amountLabel: 'Amount to Transfer',
                  ),
                  const SizedBox(height: 20),
                  _buildUploadSection(),
                  const SizedBox(height: 20),
                  _buildImportantNotes(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPadding + 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border.withAlpha(128))),
            ),
            child: AppButton(
              text: _isUploading ? 'Uploading...' : (_isSubmitting ? 'Submitting...' : 'I\'ve Made the Transfer'),
              onPressed: (_paymentProofFile == null || _isSubmitting || _isUploading) ? null : _submitRequest,
              isLoading: _isSubmitting || _isUploading,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeeBreakdown() {
    final fee = widget.feeBreakdown;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.receipt_long, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Text('Fee Breakdown', style: AppTextStyles.labelMedium),
          ]),
          const SizedBox(height: 12),
          _feeRow('Agent Service Fee', fee.agentServiceFee),
          const SizedBox(height: 6),
          _feeRow('Transport Fee', fee.transportFee, subtitle: fee.distanceKm > 0 ? '${fee.distanceKm.toStringAsFixed(1)} km' : null),
          const SizedBox(height: 6),
          _feeRow('Platform Fee', fee.clearrentFee),
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: AppTextStyles.labelLarge),
              Text('₦${NumberFormat('#,###').format(fee.totalFee)}', style: AppTextStyles.h4.copyWith(color: AppColors.primary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _feeRow(String label, double amount, {String? subtitle}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppTextStyles.bodySmall),
          if (subtitle != null) Text(subtitle, style: AppTextStyles.caption.copyWith(color: AppColors.textHint, fontSize: 11)),
        ]),
        Text('₦${NumberFormat('#,###').format(amount)}', style: AppTextStyles.labelMedium),
      ],
    );
  }

  Widget _buildUploadSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Payment Proof', style: AppTextStyles.labelLarge),
        const SizedBox(height: 8),
        Text('Upload a screenshot of your successful transfer', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 12),
        if (_paymentProofFile != null)
          Stack(
            children: [
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.success, width: 2)),
                child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(_paymentProofFile!, fit: BoxFit.cover)),
              ),
              Positioned(
                top: 8, right: 8,
                child: Row(children: [
                  GestureDetector(
                    onTap: _showImageSourceDialog,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 4)]),
                      child: const Icon(Icons.edit, size: 18, color: AppColors.primary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() { _paymentProofFile = null; _uploadedProofUrl = null; }),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 4)]),
                      child: const Icon(Icons.close, size: 18, color: AppColors.error),
                    ),
                  ),
                ]),
              ),
              Positioned(
                bottom: 8, left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.success, borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_circle, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Text('Image Selected', style: AppTextStyles.caption.copyWith(color: Colors.white)),
                  ]),
                ),
              ),
            ],
          )
        else
          GestureDetector(
            onTap: _showImageSourceDialog,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withAlpha(128), width: 1.5),
              ),
              child: Column(children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), shape: BoxShape.circle),
                  child: const Icon(Icons.cloud_upload_outlined, color: AppColors.primary, size: 28),
                ),
                const SizedBox(height: 12),
                Text('Tap to upload screenshot', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
                const SizedBox(height: 4),
                Text('PNG, JPG up to 5MB', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _buildImportantNotes() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.lightbulb_outline, size: 18, color: AppColors.warning),
            const SizedBox(width: 8),
            Text('Important', style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning)),
          ]),
          const SizedBox(height: 10),
          _noteItem('Transfer the exact amount shown above'),
          _noteItem('Use the account number provided'),
          _noteItem('Screenshot must show the amount and recipient'),
          _noteItem('Payment verification takes 1-2 hours'),
        ],
      ),
    );
  }

  Widget _noteItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(margin: const EdgeInsets.only(top: 6), width: 4, height: 4, decoration: const BoxDecoration(color: AppColors.textSecondary, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary))),
      ]),
    );
  }
}