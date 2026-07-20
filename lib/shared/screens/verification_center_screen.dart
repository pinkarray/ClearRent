import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../core/utils/app_logger.dart';
import '../../services/verification_service.dart';
import '../../services/auth_service.dart';
import '../../services/paystack_service.dart';
import 'paystack_checkout_screen.dart';

class VerificationCenterScreen extends StatefulWidget {
  const VerificationCenterScreen({super.key});

  @override
  State<VerificationCenterScreen> createState() => _VerificationCenterScreenState();
}

class _VerificationCenterScreenState extends State<VerificationCenterScreen> {
  final VerificationService _verificationService = VerificationService();
  final AuthService _authService = AuthService();
  final ImagePicker _picker = ImagePicker();

  VerificationData? _verificationData;
  StreamSubscription<VerificationData>? _verificationSub;
  String _accountType = 'landlord';
  bool _isLoading = true;
  bool _isSubmitting = false;

  // Free re-apply: a user who already PAID and was then rejected can resubmit
  // corrected documents without paying again (business decision). Set when the
  // user taps "Try Again" from the rejected state; carries the original payment
  // reference/amount so the resubmission stays tied to the paid slot.
  bool _isFreeReapply = false;
  String? _priorPaymentReference;
  double _priorPaymentAmount = 0;

  // Document files
  File? _ninFile;
  File? _utilityBillFile;
  File? _proofOfIncomeFile;
  File? _proofOfAddressFile;
  File? _guarantorIdFile;
  File? _experienceProofFile;

  // NIN number input
  final _ninNumberController = TextEditingController();

  // Agent guarantor details
  final _guarantorNameController = TextEditingController();
  final _guarantorPhoneController = TextEditingController();
  final _guarantorAddressController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadUserDataAndVerificationStatus();
  }

  @override
  void dispose() {
    _verificationSub?.cancel();
    _ninNumberController.dispose();
    _guarantorNameController.dispose();
    _guarantorPhoneController.dispose();
    _guarantorAddressController.dispose();
    super.dispose();
  }

  double get _verificationFee => VerificationFees.getFee(_accountType);
  String get _verificationFeeLabel => VerificationFees.getFeeLabel(_accountType);

  // Renewal: an expired user re-verifies their role proof + re-pays. Their
  // NIN is permanent and already on file, so the NIN steps are skipped.
  bool get _isRenewal =>
      _verificationData?.status == VerificationStatus.expired;

  Future<void> _loadUserDataAndVerificationStatus() async {
    final profile = await _authService.getUserProfile();
    if (profile != null && mounted) {
      setState(() {
        _accountType = profile['accountType'] ?? 'landlord';
      });
    }

    // Listen to verification status in real-time so admin approval
    // is reflected immediately without leaving and returning.
    _verificationSub = _verificationService.streamVerificationStatus().listen(
      (data) {
        if (mounted) {
          setState(() {
            _verificationData = data;
            _isLoading = false;
          });
        }
      },
      onError: (e) {
        AppLogger.e('Verification stream error', error: e, name: 'VerificationCenter');
        if (mounted) {
          setState(() => _isLoading = false);
        }
      },
    );
  }

  Future<void> _pickDocument(String type) async {
    final source = await _showImageSourcePicker();
    if (source == null) return;

    try {
      // NOTE: Do NOT pass maxWidth/maxHeight/imageQuality here.
      // Those params force the Android plugin to decode the image via
      // a content URI internally, which fails on some devices/galleries
      // (Samsung, Google Photos cloud-backed) with no_valid_image_uri.
      final XFile? image = await _picker.pickImage(source: source);

      if (image != null) {
        // Materialise bytes first — this resolves cloud-backed URIs
        // (Google Photos, etc.) before we touch the file path.
        final bytes = await image.readAsBytes();
        final tempDir = Directory.systemTemp;
        final tempFile = File(
          '${tempDir.path}/clearrent_doc_${type}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await tempFile.writeAsBytes(bytes);

        setState(() {
          switch (type) {
            case 'nin': _ninFile = tempFile; break;
            case 'utilityBill': _utilityBillFile = tempFile; break;
            case 'proofOfIncome': _proofOfIncomeFile = tempFile; break;
            case 'proofOfAddress': _proofOfAddressFile = tempFile; break;
            case 'guarantorId': _guarantorIdFile = tempFile; break;
            case 'experienceProof': _experienceProofFile = tempFile; break;
          }
        });
      }
    } catch (e, stack) {
      AppLogger.e('Error picking image: $e', error: e, name: 'VerificationCenter');
      AppLogger.e('Stack trace: $stack', name: 'VerificationCenter');
      _showError('Failed to select image. Please try again.');
    }
  }

  Future<ImageSource?> _showImageSourcePicker() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 20),
              Text('Select Image Source', style: AppTextStyles.h4),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildSourceOption(
                    icon: Icons.camera_alt_rounded, label: 'Camera',
                    onTap: () => Navigator.pop(context, ImageSource.camera),
                  ),
                  _buildSourceOption(
                    icon: Icons.photo_library_rounded, label: 'Gallery',
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceOption({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: AppColors.primary, size: 32),
          ),
          const SizedBox(height: 8),
          Text(label, style: AppTextStyles.labelMedium),
        ],
      ),
    );
  }

  bool get _isNinNumberValid {
    final nin = _ninNumberController.text.trim();
    return nin.length == 11 && RegExp(r'^\d{11}$').hasMatch(nin);
  }

  bool get _allRequiredDocsUploaded {
    // All roles require a valid NIN number + NIN slip photo — except a
    // renewal, where the NIN is already on file and not re-collected.
    if (!_isRenewal && (!_isNinNumberValid || _ninFile == null)) return false;

    switch (_accountType) {
      case 'landlord':
        return _utilityBillFile != null;
      case 'tenant':
        return _proofOfIncomeFile != null;
      case 'agent':
        return _proofOfAddressFile != null &&
               _guarantorIdFile != null &&
               _guarantorNameController.text.isNotEmpty &&
               _guarantorPhoneController.text.isNotEmpty &&
               _guarantorAddressController.text.isNotEmpty;
      default:
        return false;
    }
  }

  Future<void> _payAndSubmitVerification() async {
    if (!_allRequiredDocsUploaded) {
      _showError('Please upload all required documents first');
      return;
    }

    // Step 1: Resolve payment. A free re-apply (already paid, then rejected)
    // skips Paystack and reuses the original payment reference; a first-time
    // application collects the fee.
    late final String paymentReference;
    late final double paymentAmount;

    if (_isFreeReapply) {
      paymentReference = _priorPaymentReference ?? 'free_reapply';
      paymentAmount = _priorPaymentAmount;
    } else {
      AppLogger.i('About to launch Paystack checkout for $_verificationFeeLabel', name: 'VerificationCenter');
      final paymentResult = await PaystackCheckoutScreen.launch(
        context: context,
        amount: _verificationFee,
        type: PaystackService.typeVerification,
        metadata: {
          'accountType': _accountType,
          'description': '$_accountType verification fee',
        },
      );

      if (paymentResult == null) return; // User cancelled

      if (!paymentResult.success) {
        if (mounted) _showError('Payment was not completed. Please try again.');
        return;
      }
      paymentReference = paymentResult.reference;
      paymentAmount = paymentResult.amountPaid ?? _verificationFee;
    }

    // Step 2: Payment resolved — now submit verification docs
    if (!mounted) return;
    setState(() => _isSubmitting = true);

    // Encrypt + store NIN via Cloud Function (never plaintext). A renewal
    // reuses the NIN already on file, so there's nothing to (re)store.
    final ninNumber = _ninNumberController.text.trim();
    final ninStored =
        _isRenewal ? true : await _verificationService.submitNin(ninNumber);

    VerificationResult result;

    switch (_accountType) {
      case 'landlord':
        result = await _verificationService.submitLandlordVerification(
          ninFile: _ninFile,
          utilityBillFile: _utilityBillFile!,
          paymentReference: paymentReference,
          paymentAmount: paymentAmount,
        );
        break;
      case 'tenant':
        result = await _verificationService.submitTenantVerification(
          ninFile: _ninFile,
          proofOfIncomeFile: _proofOfIncomeFile!,
          paymentReference: paymentReference,
          paymentAmount: paymentAmount,
        );
        break;
      case 'agent':
        result = await _verificationService.submitAgentVerification(
          ninFile: _ninFile,
          proofOfAddressFile: _proofOfAddressFile!,
          guarantorIdFile: _guarantorIdFile!,
          guarantorName: _guarantorNameController.text.trim(),
          guarantorPhone: _guarantorPhoneController.text.trim(),
          guarantorAddress: _guarantorAddressController.text.trim(),
          paymentReference: paymentReference,
          paymentAmount: paymentAmount,
          experienceProofFile: _experienceProofFile,
        );
        break;
      default:
        result = VerificationResult(success: false, error: 'Unknown account type');
    }

    // Step 3: Record payment in Firestore payments collection — first-time only.
    // A free re-apply moved no money, so there's nothing new to record.
    if (!_isFreeReapply) {
      await PaystackService().recordPayment(
        reference: paymentReference,
        type: PaystackService.typeVerification,
        amount: paymentAmount,
        status: result.success && ninStored
            ? 'completed'
            : 'docs_upload_failed',
        extra: {'accountType': _accountType},
      );
    }

    if (result.success && _isFreeReapply) {
      _isFreeReapply = false; // consumed
    }

    setState(() => _isSubmitting = false);

    if (result.success) {
      _showSuccess('Verification submitted! We\'ll review your documents within 24-48 hours.');
      await _loadUserDataAndVerificationStatus();
    } else {
      _showError(result.error ?? 'Failed to submit verification. Please contact support.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message), backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating,
    ));
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message), backgroundColor: AppColors.success, behavior: SnackBarBehavior.floating,
    ));
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
        title: Text('Verification Center - ${_getUserTypeLabel()}',
            style: AppTextStyles.h4.copyWith(color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final status = _verificationData?.status ?? VerificationStatus.none;
    switch (status) {
      case VerificationStatus.verified: return _buildVerifiedState();
      case VerificationStatus.pending: return _buildPendingState();
      case VerificationStatus.rejected: return _buildRejectedState();
      case VerificationStatus.none: return _buildUploadForm();
      case VerificationStatus.expired: return _buildRenewalState();
    }
  }

  // ============ RENEWAL STATE (annual verification lapsed) ============
  Widget _buildRenewalState() {
    // Renewal re-collects the role proof + fee only — NIN is permanent and
    // already on file, so the upload form suppresses the NIN steps for
    // renewals (see _isRenewal).
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: AppColors.warningLight,
          child: Row(
            children: [
              Icon(Icons.autorenew, color: AppColors.warning),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your annual verification has expired. Renew below to '
                  'restore full access to bookings, listings, and messaging.',
                  style: AppTextStyles.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildUploadForm()),
      ],
    );
  }

  // ============ VERIFIED STATE ============
  Widget _buildVerifiedState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Container(
            width: 120, height: 120,
            decoration: BoxDecoration(color: AppColors.successLight, shape: BoxShape.circle),
            child: Icon(Icons.verified, size: 60, color: AppColors.success),
          ),
          const SizedBox(height: 24),
          Text('You\'re a verified ${_getUserTypeLabel()}!', style: AppTextStyles.h2),
          const SizedBox(height: 12),
          Text(_getVerifiedDescription(),
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center),
          const SizedBox(height: 40),
          ..._getVerifiedBenefits(),
        ],
      ),
    );
  }

  // ============ PENDING STATE ============
  Widget _buildPendingState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Container(
            width: 120, height: 120,
            decoration: BoxDecoration(color: AppColors.warningLight, shape: BoxShape.circle),
            child: Icon(Icons.hourglass_top_rounded, size: 60, color: AppColors.warning),
          ),
          const SizedBox(height: 24),
          Text('Verification Pending', style: AppTextStyles.h2),
          const SizedBox(height: 12),
          Text('We\'re reviewing your documents. This usually takes 24-48 hours.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center),
          if (_verificationData?.submittedAt != null) ...[
            const SizedBox(height: 8),
            Text('Submitted ${_formatDate(_verificationData!.submittedAt)}',
                style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
          ],
          const SizedBox(height: 40),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Documents Submitted', style: AppTextStyles.labelLarge),
                const SizedBox(height: 16),
                ..._getPendingDocumentsList(),
                const SizedBox(height: 16),
                _buildDocumentStatus('Payment', true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============ REJECTED STATE ============
  Widget _buildRejectedState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Container(
            width: 120, height: 120,
            decoration: BoxDecoration(color: AppColors.error.withAlpha(26), shape: BoxShape.circle),
            child: Icon(Icons.cancel_outlined, size: 60, color: AppColors.error),
          ),
          const SizedBox(height: 24),
          Text('Verification Rejected', style: AppTextStyles.h2),
          const SizedBox(height: 12),
          Text('Unfortunately, we couldn\'t verify your documents.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center),
          if (_verificationData?.rejectionReason != null) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.error.withAlpha(51)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reason:', style: AppTextStyles.labelMedium.copyWith(color: AppColors.error)),
                  const SizedBox(height: 8),
                  Text(_verificationData!.rejectionReason!,
                      style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _startReapply,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('Try Again', style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  /// Begin a re-application after a rejection. If the user already paid for the
  /// earlier attempt, the resubmission is free — carry the original payment
  /// reference so it stays tied to that paid slot.
  void _startReapply() {
    final data = _verificationData;
    final priorRef = data?.paymentReference;
    _isFreeReapply = priorRef != null && priorRef.isNotEmpty;
    _priorPaymentReference = priorRef;
    _priorPaymentAmount = data?.paymentAmount ?? 0;
    _resetForm();
  }

  void _resetForm() {
    setState(() {
      _verificationData = VerificationData();
      _ninFile = null;
      _utilityBillFile = null;
      _proofOfIncomeFile = null;
      _proofOfAddressFile = null;
      _guarantorIdFile = null;
      _experienceProofFile = null;
      _ninNumberController.clear();
      _guarantorNameController.clear();
      _guarantorPhoneController.clear();
      _guarantorAddressController.clear();
    });
  }

  // ============ UPLOAD FORM ============
  Widget _buildUploadForm() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeaderInfo(),
                const SizedBox(height: 32),

                Text('${_getUserTypeLabel()} Documents', style: AppTextStyles.h4),
                const SizedBox(height: 8),
                Text(_getUploadDescription(),
                    style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 24),

                // Document upload cards
                ..._buildDocumentUploadCards(),

                const SizedBox(height: 32),

                // ── PAYMENT INFO ──
                // Free re-apply (already paid, then rejected) shows a "no charge"
                // note instead of the fee + Paystack section.
                if (_isFreeReapply) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(13),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.success.withAlpha(51)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48, height: 48,
                          decoration: BoxDecoration(
                            color: AppColors.success.withAlpha(26),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.check_circle_outline, color: AppColors.success, size: 24),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('No payment needed',
                                  style: AppTextStyles.labelLarge.copyWith(color: AppColors.success)),
                              const SizedBox(height: 4),
                              Text('You already paid the verification fee. Resubmitting your corrected documents is free.',
                                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ] else ...[
                  Text('Verification Payment', style: AppTextStyles.h4),
                  const SizedBox(height: 8),
                  Text('A one-time verification fee is required to process your application.',
                      style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 16),

                  // Fee display
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(13),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primary.withAlpha(51)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48, height: 48,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(26),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.receipt_outlined, color: AppColors.primary, size: 24),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${_getUserTypeLabel()} Verification Fee',
                                  style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
                              const SizedBox(height: 4),
                              Text(_verificationFeeLabel,
                                  style: AppTextStyles.h3.copyWith(color: AppColors.primary)),
                            ],
                          ),
                        ),
                        Icon(Icons.lock_outline, size: 18, color: AppColors.success),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Paystack secure payment note
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(13),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.success.withAlpha(51)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.shield_outlined, size: 18, color: AppColors.success),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Payment is processed securely via Paystack. You can pay with card or bank transfer.',
                            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),
                ],

                // Privacy note
                _buildPrivacyNote(),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),

        // ── STICKY BOTTOM BUTTON ──
        Container(
          padding: EdgeInsets.fromLTRB(24, 12, 24, MediaQuery.of(context).padding.bottom + 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border.withAlpha(128))),
          ),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _allRequiredDocsUploaded && !_isSubmitting ? _payAndSubmitVerification : null,
              icon: _isSubmitting
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Icon(_isFreeReapply ? Icons.send : Icons.payment, color: Colors.white, size: 20),
              label: Text(
                _isSubmitting
                    ? 'Submitting...'
                    : _isFreeReapply
                        ? 'Resubmit for free'
                        : 'Pay $_verificationFeeLabel & Submit',
                style: AppTextStyles.labelLarge.copyWith(
                  color: _allRequiredDocsUploaded ? Colors.white : AppColors.textHint,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor: AppColors.border,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ============ HELPER WIDGETS ============

  Widget _buildHeaderInfo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primaryLight.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primaryLight.withAlpha(77)),
      ),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.verified_user_outlined, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Why get verified?', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary)),
                const SizedBox(height: 4),
                Text(_getWhyVerifyText(),
                    style: AppTextStyles.bodySmall.copyWith(color: AppColors.primary.withAlpha(204))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: AppColors.textHint),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Your documents are securely stored and only used for verification.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
          ),
        ],
      ),
    );
  }

  Widget _buildBenefitItem(IconData icon, String title, String description) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppColors.successLight, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: AppColors.success, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelLarge),
                const SizedBox(height: 2),
                Text(description, style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary)),
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
          width: 24, height: 24,
          decoration: BoxDecoration(
            color: uploaded ? AppColors.successLight : AppColors.background,
            shape: BoxShape.circle,
          ),
          child: Icon(uploaded ? Icons.check : Icons.circle_outlined,
              size: 14, color: uploaded ? AppColors.success : AppColors.textHint),
        ),
        const SizedBox(width: 12),
        Text(title, style: AppTextStyles.bodyMedium.copyWith(
            color: uploaded ? AppColors.textPrimary : AppColors.textSecondary)),
      ],
    );
  }

  // ============ FORM HELPERS ============

  String _getUserTypeLabel() {
    switch (_accountType) {
      case 'landlord': return 'Landlord';
      case 'tenant': return 'Tenant';
      case 'agent': return 'Agent';
      default: return 'User';
    }
  }

  String _getWhyVerifyText() {
    switch (_accountType) {
      case 'landlord': return 'Verified landlords get more inquiries and tenant trust.';
      case 'tenant': return 'Verified tenants get faster approval from landlords.';
      case 'agent': return 'Verified agents can receive property inspection assignments.';
      default: return 'Get verified to unlock all features.';
    }
  }

  String _getVerifiedDescription() {
    switch (_accountType) {
      case 'landlord': return 'Your identity has been confirmed. Tenants can trust that you\'re a legitimate landlord on ClearRent.';
      case 'tenant': return 'Your identity and income have been verified. Landlords can trust that you\'re a reliable tenant.';
      case 'agent': return 'Your identity has been verified. You can now receive property inspection assignments from landlords.';
      default: return 'Your account has been verified.';
    }
  }

  String _getUploadDescription() {
    switch (_accountType) {
      case 'landlord': return 'We need these documents to confirm your identity as a landlord.';
      case 'tenant': return 'We need these documents to verify your identity and ability to pay rent.';
      case 'agent': return 'We need these documents to verify your identity and establish trust with landlords.';
      default: return 'Please upload the required documents.';
    }
  }

  List<Widget> _getVerifiedBenefits() {
    switch (_accountType) {
      case 'landlord': return [
          _buildBenefitItem(Icons.visibility, 'Higher Visibility', 'Verified listings appear higher in search results'),
          const SizedBox(height: 16),
          _buildBenefitItem(Icons.favorite, 'More Trust', 'Tenants are more likely to contact verified landlords'),
          const SizedBox(height: 16),
          _buildBenefitItem(Icons.shield, 'Badge Display', 'Your verified badge appears on all your listings'),
        ];
      case 'tenant': return [
          _buildBenefitItem(Icons.thumb_up, 'Preferred Tenant', 'Landlords prioritize verified tenants'),
          const SizedBox(height: 16),
          _buildBenefitItem(Icons.speed, 'Faster Approval', 'Get approved for properties more quickly'),
          const SizedBox(height: 16),
          _buildBenefitItem(Icons.verified_user, 'Trust Badge', 'Your verified status shows on your profile'),
        ];
      case 'agent': return [
          _buildBenefitItem(Icons.assignment, 'Receive Assignments', 'Landlords can now assign properties to you'),
          const SizedBox(height: 16),
          _buildBenefitItem(Icons.monetization_on, 'Earn Money', 'Get paid for conducting property inspections'),
          const SizedBox(height: 16),
          _buildBenefitItem(Icons.star, 'Build Reputation', 'Collect ratings to attract more assignments'),
        ];
      default: return [];
    }
  }

  List<Widget> _getPendingDocumentsList() {
    switch (_accountType) {
      case 'landlord': return [
          _buildDocumentStatus('NIN Number', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('NIN Slip Photo', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Recent Utility Bill', true),
        ];
      case 'tenant': return [
          _buildDocumentStatus('NIN Number', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('NIN Slip Photo', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Proof of Income', true),
        ];
      case 'agent': return [
          _buildDocumentStatus('NIN Number', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('NIN Slip Photo', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Proof of Address', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Guarantor Details', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Experience Proof (Optional)', _verificationData?.hasExperienceProof ?? false),
        ];
      default: return [];
    }
  }

  List<Widget> _buildDocumentUploadCards() {
    switch (_accountType) {
      case 'landlord': return _buildLandlordDocs();
      case 'tenant': return _buildTenantDocs();
      case 'agent': return _buildAgentDocs();
      default: return [];
    }
  }

  /// NIN number input field — shared across all roles
  Widget _buildNinNumberField() {
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
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.pin_outlined, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('NIN Number', style: AppTextStyles.labelLarge),
                    Text('Enter your 11-digit National Identification Number',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              if (_isNinNumberValid)
                Icon(Icons.check_circle, color: AppColors.success, size: 22),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ninNumberController,
            keyboardType: TextInputType.number,
            maxLength: 11,
            onChanged: (_) => setState(() {}),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            decoration: InputDecoration(
              hintText: 'e.g. 12345678901',
              hintStyle: TextStyle(color: AppColors.textHint),
              counterText: '${_ninNumberController.text.length}/11',
              counterStyle: AppTextStyles.caption.copyWith(
                color: _isNinNumberValid ? AppColors.success : AppColors.textHint,
              ),
              prefixIcon: Icon(Icons.numbers, color: AppColors.textHint),
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _isNinNumberValid ? AppColors.success : AppColors.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildLandlordDocs() {
    return [
      if (!_isRenewal) ...[
        _buildNinNumberField(),
        const SizedBox(height: 16),
        _DocumentUploadCard(
          title: 'NIN Slip Photo',
          subtitle: 'Upload a clear photo of your physical or digital NIN slip',
          whatWeNeed: 'We need to see your full name, photo, and NIN number clearly.',
          icon: Icons.badge_outlined, file: _ninFile,
          onTap: () => _pickDocument('nin'), onRemove: () => setState(() => _ninFile = null),
        ),
        const SizedBox(height: 16),
      ],
      _DocumentUploadCard(
        title: 'Recent Utility Bill',
        subtitle: 'Electricity (PHCN), Water, or Waste bill from the last 3 months',
        whatWeNeed: 'Bill must show your name and a property address to confirm you\'re a real landlord.',
        icon: Icons.receipt_long_outlined, file: _utilityBillFile,
        onTap: () => _pickDocument('utilityBill'), onRemove: () => setState(() => _utilityBillFile = null),
      ),
    ];
  }

  List<Widget> _buildTenantDocs() {
    return [
      if (!_isRenewal) ...[
        _buildNinNumberField(),
        const SizedBox(height: 16),
        _DocumentUploadCard(
          title: 'NIN Slip Photo',
          subtitle: 'Upload a clear photo of your physical or digital NIN slip',
          whatWeNeed: 'We need to see your full name, photo, and NIN number clearly.',
          icon: Icons.badge_outlined, file: _ninFile,
          onTap: () => _pickDocument('nin'), onRemove: () => setState(() => _ninFile = null),
        ),
        const SizedBox(height: 16),
      ],
      _DocumentUploadCard(
        title: 'Proof of Income',
        subtitle: 'Employment letter, Bank statement, or Recent pay slip',
        whatWeNeed: 'Document should show your name, employer/bank, and indicate stable income.',
        icon: Icons.account_balance_outlined, file: _proofOfIncomeFile,
        onTap: () => _pickDocument('proofOfIncome'), onRemove: () => setState(() => _proofOfIncomeFile = null),
      ),
    ];
  }

  List<Widget> _buildAgentDocs() {
    return [
      if (!_isRenewal) ...[
        _buildNinNumberField(),
        const SizedBox(height: 16),
        _DocumentUploadCard(
          title: 'NIN Slip Photo',
          subtitle: 'Upload a clear photo of your physical or digital NIN slip',
          whatWeNeed: 'We need to see your full name, photo, and NIN number clearly.',
          icon: Icons.badge_outlined, file: _ninFile,
          onTap: () => _pickDocument('nin'), onRemove: () => setState(() => _ninFile = null),
        ),
        const SizedBox(height: 16),
      ],
      _DocumentUploadCard(
        title: 'Proof of Address',
        subtitle: 'Utility bill or Bank statement showing your residential address',
        whatWeNeed: 'Document must show your name and current home address.',
        icon: Icons.home_outlined, file: _proofOfAddressFile,
        onTap: () => _pickDocument('proofOfAddress'), onRemove: () => setState(() => _proofOfAddressFile = null),
      ),
      const SizedBox(height: 24),
      _buildGuarantorSection(),
      const SizedBox(height: 16),
      _DocumentUploadCard(
        title: 'Experience Proof (Optional)',
        subtitle: 'Reference letter, Previous work ID, or Testimonial',
        whatWeNeed: 'Any document showing your experience in property/real estate.',
        icon: Icons.workspace_premium_outlined, file: _experienceProofFile,
        onTap: () => _pickDocument('experienceProof'), onRemove: () => setState(() => _experienceProofFile = null),
        isOptional: true,
      ),
    ];
  }

  Widget _buildGuarantorSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: AppColors.info.withAlpha(26), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.people_outline, color: AppColors.info, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Guarantor Details', style: AppTextStyles.labelLarge),
                  Text('Someone who can vouch for your trustworthiness',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.infoLight, borderRadius: BorderRadius.circular(8)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Your guarantor should be someone with a stable job or business who knows you personally.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.info)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildTextField(controller: _guarantorNameController, label: 'Guarantor\'s Full Name',
              hint: 'Enter their full name', icon: Icons.person_outline,
              textCapitalization: TextCapitalization.words),
          const SizedBox(height: 12),
          _buildTextField(
            controller: _guarantorPhoneController, 
            label: 'Guarantor\'s Phone Number',
            hint: '08012345678', 
            icon: Icons.phone_outlined, 
            keyboardType: TextInputType.phone,
            maxLength: 11,
          ),
          const SizedBox(height: 12),
          _buildTextField(controller: _guarantorAddressController, label: 'Guarantor\'s Address',
              hint: 'Enter their home or work address', icon: Icons.location_on_outlined, maxLines: 2,
              textCapitalization: TextCapitalization.words),
          const SizedBox(height: 16),
          _DocumentUploadCard(
            title: 'Guarantor\'s ID', subtitle: 'Photo of your guarantor\'s NIN or Government ID',
            whatWeNeed: 'Clear photo showing their name and photo.',
            icon: Icons.badge_outlined, file: _guarantorIdFile,
            onTap: () => _pickDocument('guarantorId'), onRemove: () => setState(() => _guarantorIdFile = null),
            compact: true,
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller, required String label,
    required String hint, required IconData icon,
    TextInputType? keyboardType, int maxLines = 1, int? maxLength,  // Add maxLength
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        TextField(
          controller: controller, keyboardType: keyboardType, maxLines: maxLines,
          maxLength: maxLength,
          textCapitalization: textCapitalization,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
            prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 20),
            filled: true, fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppColors.primary)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.day}/${date.month}/${date.year}';
  }
}

// ============ DOCUMENT UPLOAD CARD ============
class _DocumentUploadCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String whatWeNeed;
  final IconData icon;
  final File? file;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final bool isOptional;
  final bool compact;

  const _DocumentUploadCard({
    required this.title, required this.subtitle, required this.whatWeNeed,
    required this.icon, required this.file, required this.onTap, required this.onRemove,
    this.isOptional = false, this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasFile = file != null;

    return GestureDetector(
      onTap: hasFile ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 12 : 16),
        decoration: BoxDecoration(
          color: hasFile ? AppColors.successLight.withAlpha(77) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: hasFile ? AppColors.success : AppColors.border, width: hasFile ? 1.5 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: compact ? 40 : 48, height: compact ? 40 : 48,
                decoration: BoxDecoration(
                  color: hasFile ? AppColors.success.withAlpha(26) : AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: hasFile
                    ? ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(file!, fit: BoxFit.cover))
                    : Icon(icon, color: AppColors.textSecondary, size: compact ? 20 : 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(title,
                            style: AppTextStyles.labelLarge.copyWith(
                                color: hasFile ? AppColors.success : AppColors.textPrimary)),
                      ),
                      if (isOptional) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: AppColors.textHint.withAlpha(26), borderRadius: BorderRadius.circular(4)),
                          child: Text('Optional', style: AppTextStyles.caption.copyWith(color: AppColors.textHint, fontSize: 10)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(hasFile ? 'Document uploaded ✓' : subtitle,
                        style: AppTextStyles.bodySmall.copyWith(
                            color: hasFile ? AppColors.success.withAlpha(204) : AppColors.textSecondary)),
                  ],
                ),
              ),
              if (hasFile)
                GestureDetector(
                  onTap: onRemove,
                  child: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(color: AppColors.error.withAlpha(26), borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.close, size: 18, color: AppColors.error),
                  ),
                )
              else
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.add, size: 18, color: AppColors.primary),
                ),
            ]),
            if (!hasFile && !compact) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.infoLight.withAlpha(128), borderRadius: BorderRadius.circular(8)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lightbulb_outline, size: 14, color: AppColors.info),
                    const SizedBox(width: 8),
                    Expanded(child: Text(whatWeNeed, style: AppTextStyles.caption.copyWith(color: AppColors.info))),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}