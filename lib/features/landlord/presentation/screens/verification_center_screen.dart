import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../shared/widgets/copyable_field.dart';

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
  String _accountType = 'landlord';
  bool _isLoading = true;
  bool _isSubmitting = false;

  // Document files
  File? _ninFile;
  File? _utilityBillFile;
  File? _proofOfIncomeFile;
  File? _proofOfAddressFile;
  File? _guarantorIdFile;
  File? _experienceProofFile;

  // Payment proof
  File? _paymentProofFile;

  // Agent guarantor details
  final _guarantorNameController = TextEditingController();
  final _guarantorPhoneController = TextEditingController();
  final _guarantorAddressController = TextEditingController();

  // Bank account details
  static const String _accountNumber = '6507861182';
  static const String _accountName = 'Oredugba Ayomide';
  static const String _bankName = 'Providus Bank';

  @override
  void initState() {
    super.initState();
    _loadUserDataAndVerificationStatus();
  }

  @override
  void dispose() {
    _guarantorNameController.dispose();
    _guarantorPhoneController.dispose();
    _guarantorAddressController.dispose();
    super.dispose();
  }

  double get _verificationFee => VerificationFees.getFee(_accountType);
  String get _verificationFeeLabel => VerificationFees.getFeeLabel(_accountType);

  Future<void> _loadUserDataAndVerificationStatus() async {
    final profile = await _authService.getUserProfile();
    if (profile != null) {
      setState(() {
        _accountType = profile['accountType'] ?? 'landlord';
      });
    }

    final data = await _verificationService.getVerificationStatus();
    if (mounted) {
      setState(() {
        _verificationData = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDocument(String type) async {
    final source = await _showImageSourcePicker();
    if (source == null) return;

    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          switch (type) {
            case 'nin': _ninFile = File(image.path); break;
            case 'utilityBill': _utilityBillFile = File(image.path); break;
            case 'proofOfIncome': _proofOfIncomeFile = File(image.path); break;
            case 'proofOfAddress': _proofOfAddressFile = File(image.path); break;
            case 'guarantorId': _guarantorIdFile = File(image.path); break;
            case 'experienceProof': _experienceProofFile = File(image.path); break;
            case 'paymentProof': _paymentProofFile = File(image.path); break;
          }
        });
      }
    } catch (e) {
      debugPrint('❌ Error picking image: $e');
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

  bool get _allRequiredDocsUploaded {
    // Payment proof is always required
    if (_paymentProofFile == null) return false;

    switch (_accountType) {
      case 'landlord':
        return _ninFile != null && _utilityBillFile != null;
      case 'tenant':
        return _ninFile != null && _proofOfIncomeFile != null;
      case 'agent':
        return _ninFile != null &&
               _proofOfAddressFile != null &&
               _guarantorIdFile != null &&
               _guarantorNameController.text.isNotEmpty &&
               _guarantorPhoneController.text.isNotEmpty &&
               _guarantorAddressController.text.isNotEmpty;
      default:
        return false;
    }
  }

  Future<void> _submitVerification() async {
    if (!_allRequiredDocsUploaded) {
      _showError('Please upload all required documents and payment proof');
      return;
    }

    setState(() => _isSubmitting = true);

    VerificationResult result;

    switch (_accountType) {
      case 'landlord':
        result = await _verificationService.submitLandlordVerification(
          ninFile: _ninFile!,
          utilityBillFile: _utilityBillFile!,
          paymentProofFile: _paymentProofFile!,
        );
        break;
      case 'tenant':
        result = await _verificationService.submitTenantVerification(
          ninFile: _ninFile!,
          proofOfIncomeFile: _proofOfIncomeFile!,
          paymentProofFile: _paymentProofFile!,
        );
        break;
      case 'agent':
        result = await _verificationService.submitAgentVerification(
          ninFile: _ninFile!,
          proofOfAddressFile: _proofOfAddressFile!,
          guarantorIdFile: _guarantorIdFile!,
          guarantorName: _guarantorNameController.text.trim(),
          guarantorPhone: _guarantorPhoneController.text.trim(),
          guarantorAddress: _guarantorAddressController.text.trim(),
          paymentProofFile: _paymentProofFile!,
          experienceProofFile: _experienceProofFile,
        );
        break;
      default:
        result = VerificationResult(success: false, error: 'Unknown account type');
    }

    setState(() => _isSubmitting = false);

    if (result.success) {
      _showSuccess('Verification submitted! We\'ll review your documents and payment within 24-48 hours.');
      await _loadUserDataAndVerificationStatus();
    } else {
      _showError(result.error ?? 'Failed to submit verification');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message), backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating,
    ));
  }

  void _showSuccess(String message) {
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
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Verification Center - ${_getUserTypeLabel()}',
            style: AppTextStyles.h4.copyWith(color: AppColors.textPrimary)),
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
      case VerificationStatus.verified: return _buildVerifiedState();
      case VerificationStatus.pending: return _buildPendingState();
      case VerificationStatus.rejected: return _buildRejectedState();
      case VerificationStatus.none: return _buildUploadForm();
    }
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
            child: const Icon(Icons.verified, size: 60, color: AppColors.success),
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
            child: const Icon(Icons.schedule, size: 60, color: AppColors.warning),
          ),
          const SizedBox(height: 24),
          Text('Verification Pending', style: AppTextStyles.h2),
          const SizedBox(height: 12),
          Text('We\'re reviewing your documents and payment. This usually takes 24-48 hours.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center),
          const SizedBox(height: 40),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface, borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Documents Submitted', style: AppTextStyles.labelLarge),
                const SizedBox(height: 16),
                ..._getPendingDocumentsList(),
                const SizedBox(height: 12),
                _buildDocumentStatus('Payment Proof', true),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('Submitted ${_formatDate(_verificationData?.submittedAt)}',
              style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
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
            child: const Icon(Icons.error_outline, size: 60, color: AppColors.error),
          ),
          const SizedBox(height: 24),
          Text('Verification Failed', style: AppTextStyles.h2),
          const SizedBox(height: 12),
          Text('We couldn\'t verify your documents. Please review the reason below and try again.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          if (_verificationData?.rejectionReason != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(26), borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.error.withAlpha(77)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: AppColors.error, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Reason', style: AppTextStyles.labelMedium.copyWith(color: AppColors.error)),
                        const SizedBox(height: 4),
                        Text(_verificationData!.rejectionReason!,
                            style: AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
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
              onPressed: _resetForm,
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

  void _resetForm() {
    setState(() {
      _verificationData = VerificationData();
      _ninFile = null;
      _utilityBillFile = null;
      _proofOfIncomeFile = null;
      _proofOfAddressFile = null;
      _guarantorIdFile = null;
      _experienceProofFile = null;
      _paymentProofFile = null;
      _guarantorNameController.clear();
      _guarantorPhoneController.clear();
      _guarantorAddressController.clear();
    });
  }

  // ============ UPLOAD FORM ============
  Widget _buildUploadForm() {
    return SingleChildScrollView(
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

          // ── PAYMENT SECTION ──
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
                  child: const Icon(Icons.receipt_outlined, color: AppColors.primary, size: 24),
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
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Bank account card (reusable widget)
          BankAccountCard(
            accountNumber: _accountNumber,
            accountName: _accountName,
            bankName: _bankName,
            amount: _verificationFee,
            amountLabel: 'Amount to Transfer',
          ),

          const SizedBox(height: 16),

          // Payment proof upload
          _DocumentUploadCard(
            title: 'Payment Proof',
            subtitle: 'Upload a screenshot of your successful transfer',
            whatWeNeed: 'Screenshot must clearly show the amount ($_verificationFeeLabel), recipient name, and transaction status.',
            icon: Icons.payment_outlined,
            file: _paymentProofFile,
            onTap: () => _pickDocument('paymentProof'),
            onRemove: () => setState(() => _paymentProofFile = null),
          ),

          const SizedBox(height: 32),

          // Privacy note
          _buildPrivacyNote(),

          const SizedBox(height: 24),

          // Submit button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _allRequiredDocsUploaded && !_isSubmitting ? _submitVerification : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor: AppColors.border,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isSubmitting
                  ? const SizedBox(width: 24, height: 24,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Submit for Verification',
                      style: AppTextStyles.labelLarge.copyWith(
                        color: _allRequiredDocsUploaded ? Colors.white : AppColors.textHint)),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
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
            child: const Icon(Icons.verified_user_outlined, color: AppColors.primary, size: 20),
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
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textHint),
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
          _buildDocumentStatus('NIN/Government ID', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Recent Utility Bill', true),
        ];
      case 'tenant': return [
          _buildDocumentStatus('NIN/Government ID', true),
          const SizedBox(height: 12),
          _buildDocumentStatus('Proof of Income', true),
        ];
      case 'agent': return [
          _buildDocumentStatus('NIN/Government ID', true),
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

  List<Widget> _buildLandlordDocs() {
    return [
      _DocumentUploadCard(
        title: 'NIN or Government ID',
        subtitle: 'Upload a clear photo of your National ID, Voter\'s Card, or Driver\'s License',
        whatWeNeed: 'We need to see your full name, photo, and ID number clearly.',
        icon: Icons.badge_outlined, file: _ninFile,
        onTap: () => _pickDocument('nin'), onRemove: () => setState(() => _ninFile = null),
      ),
      const SizedBox(height: 16),
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
      _DocumentUploadCard(
        title: 'NIN or Government ID',
        subtitle: 'Upload a clear photo of your National ID, Voter\'s Card, or Driver\'s License',
        whatWeNeed: 'We need to see your full name, photo, and ID number clearly.',
        icon: Icons.badge_outlined, file: _ninFile,
        onTap: () => _pickDocument('nin'), onRemove: () => setState(() => _ninFile = null),
      ),
      const SizedBox(height: 16),
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
      _DocumentUploadCard(
        title: 'NIN or Government ID',
        subtitle: 'Upload a clear photo of your National ID, Voter\'s Card, or Driver\'s License',
        whatWeNeed: 'We need to see your full name, photo, and ID number clearly.',
        icon: Icons.badge_outlined, file: _ninFile,
        onTap: () => _pickDocument('nin'), onRemove: () => setState(() => _ninFile = null),
      ),
      const SizedBox(height: 16),
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
              child: const Icon(Icons.people_outline, color: AppColors.info, size: 20),
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
                const Icon(Icons.info_outline, size: 16, color: AppColors.info),
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
              hint: 'Enter their full name', icon: Icons.person_outline),
          const SizedBox(height: 12),
          _buildTextField(controller: _guarantorPhoneController, label: 'Guarantor\'s Phone Number',
              hint: '08012345678', icon: Icons.phone_outlined, keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          _buildTextField(controller: _guarantorAddressController, label: 'Guarantor\'s Address',
              hint: 'Enter their home or work address', icon: Icons.location_on_outlined, maxLines: 2),
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
    TextInputType? keyboardType, int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        TextField(
          controller: controller, keyboardType: keyboardType, maxLines: maxLines,
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
                    child: const Icon(Icons.close, size: 18, color: AppColors.error),
                  ),
                )
              else
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: AppColors.primary.withAlpha(26), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.add, size: 18, color: AppColors.primary),
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