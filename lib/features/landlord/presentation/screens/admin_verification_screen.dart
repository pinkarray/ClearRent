import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/verification_service.dart';

class AdminVerificationScreen extends StatefulWidget {
  const AdminVerificationScreen({super.key});

  @override
  State<AdminVerificationScreen> createState() =>
      _AdminVerificationScreenState();
}

class _AdminVerificationScreenState extends State<AdminVerificationScreen>
    with SingleTickerProviderStateMixin {
  final VerificationService _verificationService = VerificationService();

  final Set<String> _processing = {};

  late TabController _tabController;
  List<PendingVerification> _allVerifications = [];
  bool _isLoading = true;

  String _selectedFilter = 'all';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadPendingVerifications();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<PendingVerification> get _filteredVerifications {
    if (_selectedFilter == 'all') return _allVerifications;
    return _allVerifications.where((v) => v.userType == _selectedFilter).toList();
  }

  int _getCountForType(String type) {
    if (type == 'all') return _allVerifications.length;
    return _allVerifications.where((v) => v.userType == type).length;
  }

  Future<void> _loadPendingVerifications() async {
    setState(() => _isLoading = true);
    try {
      final verifications = await _verificationService.getPendingVerifications();
      if (mounted) setState(() => _allVerifications = verifications);
    } catch (e) {
      _showMessage('Failed to load pending verifications', isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openDocument(String? url) async {
    if (url == null || url.isEmpty) {
      _showMessage('Document not available', isError: true);
      return;
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _showMessage('Could not open document', isError: true);
    }
  }

  Future<void> _approveVerification(PendingVerification verification) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve Verification'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to approve ${verification.fullName}?'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.successLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: AppColors.success, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This will mark them as a verified ${verification.userType}.',
                      style: AppTextStyles.bodySmall.copyWith(color: AppColors.success),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
            child: const Text('Approve', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final id = verification.requestId;
    setState(() => _processing.add(id));
    try {
      final success = await _verificationService.approveVerification(
        verification.uid, requestId: verification.requestId,
      );
      if (!mounted) return;
      if (success) {
        _showMessage('${verification.fullName} has been verified!', isError: false);
        await _loadPendingVerifications();
      } else {
        _showMessage('Failed to approve verification', isError: true);
      }
    } catch (e) {
      _showMessage('Failed to approve verification: $e', isError: true);
    } finally {
      if (mounted) setState(() => _processing.remove(id));
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
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: AppColors.warning, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('They will be able to re-submit with new documents.',
                        style: AppTextStyles.bodySmall.copyWith(color: AppColors.warning)),
                  ),
                ],
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (reasonController.text.trim().isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Please enter a reason')),
                );
                return;
              }
              Navigator.pop(ctx, true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Reject', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && reasonController.text.isNotEmpty) {
      final id = verification.requestId;
      setState(() => _processing.add(id));
      try {
        final success = await _verificationService.rejectVerification(
          verification.uid, reasonController.text, requestId: verification.requestId,
        );
        if (!mounted) return;
        if (success) {
          _showMessage('Verification rejected', isError: false);
          await _loadPendingVerifications();
        } else {
          _showMessage('Failed to reject verification', isError: true);
        }
      } catch (e) {
        _showMessage('Failed to reject verification: $e', isError: true);
      } finally {
        if (mounted) setState(() => _processing.remove(id));
      }
    }
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? AppColors.error : AppColors.success,
      behavior: SnackBarBehavior.floating,
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
        title: Text('Verification Review',
            style: AppTextStyles.h4.copyWith(color: AppColors.textPrimary)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: AppColors.primary),
            onPressed: _loadPendingVerifications,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: _buildFilterTabs(),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _filteredVerifications.isEmpty
              ? _buildEmptyState()
              : _buildVerificationList(),
    );
  }

  Widget _buildFilterTabs() {
    return Container(
      color: AppColors.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _buildFilterChip('All', 'all'),
            const SizedBox(width: 8),
            _buildFilterChip('Landlords', 'landlord'),
            const SizedBox(width: 8),
            _buildFilterChip('Tenants', 'tenant'),
            const SizedBox(width: 8),
            _buildFilterChip('Agents', 'agent'),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String type) {
    final isSelected = _selectedFilter == type;
    final count = _getCountForType(type);

    return GestureDetector(
      onTap: () => setState(() => _selectedFilter = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: AppTextStyles.labelMedium.copyWith(
                    color: isSelected ? Colors.white : AppColors.textSecondary)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white.withAlpha(51) : AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    style: AppTextStyles.caption.copyWith(
                        color: isSelected ? Colors.white : AppColors.primary,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(color: AppColors.successLight, shape: BoxShape.circle),
            child: Icon(Icons.check_circle_outline, size: 50, color: AppColors.success),
          ),
          const SizedBox(height: 24),
          Text('All caught up!', style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            _selectedFilter == 'all'
                ? 'No pending verifications to review.'
                : 'No pending $_selectedFilter verifications.',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredVerifications.length,
      itemBuilder: (context, index) {
        final verification = _filteredVerifications[index];
        return _VerificationCard(
          verification: verification,
          onOpenDocument: _openDocument,
          onApprove: () => _approveVerification(verification),
          onReject: () => _rejectVerification(verification),
          isProcessing: _processing.contains(verification.requestId),
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
  final bool isProcessing;

  const _VerificationCard({
    required this.verification,
    required this.onOpenDocument,
    required this.onApprove,
    required this.onReject,
    this.isProcessing = false,
  });

  Color get _userTypeColor {
    switch (verification.userType) {
      case 'landlord': return AppColors.primary;
      case 'tenant': return AppColors.info;
      case 'agent': return AppColors.warning;
      default: return AppColors.textSecondary;
    }
  }

  IconData get _userTypeIcon {
    switch (verification.userType) {
      case 'landlord': return Icons.home_outlined;
      case 'tenant': return Icons.person_outline;
      case 'agent': return Icons.support_agent;
      default: return Icons.person;
    }
  }

  String _getPaymentLabel() {
    switch (verification.userType) {
      case 'landlord': return '₦15,000';
      case 'tenant': return '₦5,000';
      case 'agent': return '₦10,000';
      default: return '';
    }
  }

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
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: _userTypeColor.withAlpha(26), shape: BoxShape.circle,
                ),
                child: Icon(_userTypeIcon, color: _userTypeColor, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(verification.fullName, style: AppTextStyles.labelLarge),
                    const SizedBox(height: 2),
                    Text(verification.email,
                        style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary)),
                    if (verification.phone.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(verification.phone,
                          style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _userTypeColor.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(verification.userType.toUpperCase(),
                    style: AppTextStyles.labelSmall.copyWith(
                        color: _userTypeColor, fontWeight: FontWeight.w600)),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Documents section
          Text('Submitted Documents',
              style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 12),

          ..._buildDocumentRows(),

          // Guarantor info for agents
          if (verification.userType == 'agent' && verification.guarantorName != null) ...[
            const SizedBox(height: 16),
            _buildGuarantorInfo(),
          ],

          // Payment info card
          if (verification.paymentAmount != null && verification.paymentAmount! > 0) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primary.withAlpha(51)),
              ),
              child: Row(
                children: [
                  Icon(Icons.payments_outlined, size: 20, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Text('Verification Fee: ', style: AppTextStyles.bodySmall),
                  Text(_getPaymentLabel(),
                      style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withAlpha(26),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('PENDING',
                        style: AppTextStyles.caption.copyWith(
                            color: AppColors.warning, fontWeight: FontWeight.w600, fontSize: 10)),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Submitted time
          if (verification.submittedAt != null)
            Text('Submitted: ${_formatDate(verification.submittedAt!)}',
                style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),

          const SizedBox(height: 16),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: isProcessing ? null : onReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: isProcessing
                      ? const SizedBox(height: 16, width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: isProcessing ? null : onApprove,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: isProcessing
                      ? const SizedBox(height: 16, width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Approve', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDocumentRows() {
    final List<Widget> rows = [];

    // NIN - all user types
    rows.add(_DocumentRow(
      title: 'NIN / Government ID',
      url: verification.documents.ninUrl,
      onTap: () => onOpenDocument(verification.documents.ninUrl),
    ));
    rows.add(const SizedBox(height: 8));

    switch (verification.userType) {
      case 'landlord':
        rows.add(_DocumentRow(
          title: 'Property Document',
          url: verification.documents.propertyDocUrl,
          onTap: () => onOpenDocument(verification.documents.propertyDocUrl),
        ));
        rows.add(const SizedBox(height: 8));
        rows.add(_DocumentRow(
          title: 'Utility Bill',
          url: verification.documents.utilityBillUrl,
          onTap: () => onOpenDocument(verification.documents.utilityBillUrl),
        ));
        break;
      case 'tenant':
        rows.add(_DocumentRow(
          title: 'Proof of Income',
          url: verification.documents.proofOfIncomeUrl,
          onTap: () => onOpenDocument(verification.documents.proofOfIncomeUrl),
        ));
        break;
      case 'agent':
        rows.add(_DocumentRow(
          title: 'Proof of Address',
          url: verification.documents.proofOfAddressUrl,
          onTap: () => onOpenDocument(verification.documents.proofOfAddressUrl),
        ));
        rows.add(const SizedBox(height: 8));
        rows.add(_DocumentRow(
          title: 'Guarantor\'s ID',
          url: verification.documents.guarantorIdUrl,
          onTap: () => onOpenDocument(verification.documents.guarantorIdUrl),
        ));
        if (verification.documents.experienceProofUrl != null) {
          rows.add(const SizedBox(height: 8));
          rows.add(_DocumentRow(
            title: 'Experience Proof (Optional)',
            url: verification.documents.experienceProofUrl,
            onTap: () => onOpenDocument(verification.documents.experienceProofUrl),
          ));
        }
        break;
    }

    // Payment proof - all user types
    if (verification.paymentProofUrl != null) {
      rows.add(const SizedBox(height: 12));
      rows.add(const Divider(height: 1));
      rows.add(const SizedBox(height: 12));
      rows.add(_DocumentRow(
        title: 'Payment Proof (${_getPaymentLabel()})',
        url: verification.paymentProofUrl,
        onTap: () => onOpenDocument(verification.paymentProofUrl),
      ));
    }

    return rows;
  }

  Widget _buildGuarantorInfo() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.infoLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.info.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.people_outline, size: 18, color: AppColors.info),
            const SizedBox(width: 8),
            Text('Guarantor Information',
                style: AppTextStyles.labelMedium.copyWith(color: AppColors.info)),
          ]),
          const SizedBox(height: 12),
          _buildGuarantorRow('Name', verification.guarantorName ?? 'N/A'),
          const SizedBox(height: 6),
          _buildGuarantorRow('Phone', verification.guarantorPhone ?? 'N/A'),
          const SizedBox(height: 6),
          _buildGuarantorRow('Address', verification.guarantorAddress ?? 'N/A'),
        ],
      ),
    );
  }

  Widget _buildGuarantorRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 60,
          child: Text('$label:', style: AppTextStyles.caption.copyWith(color: AppColors.info)),
        ),
        Expanded(
          child: Text(value, style: AppTextStyles.bodySmall.copyWith(color: AppColors.textPrimary)),
        ),
      ],
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

  const _DocumentRow({required this.title, required this.url, required this.onTap});

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
          border: Border.all(color: hasUrl ? AppColors.primaryLight : AppColors.border),
        ),
        child: Row(
          children: [
            Icon(hasUrl ? Icons.description : Icons.description_outlined,
                size: 20, color: hasUrl ? AppColors.primary : AppColors.textHint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: AppTextStyles.bodyMedium.copyWith(
                      color: hasUrl ? AppColors.textPrimary : AppColors.textHint)),
            ),
            if (hasUrl)
              Icon(Icons.open_in_new, size: 18, color: AppColors.primary)
            else
              Text('Not uploaded', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
          ],
        ),
      ),
    );
  }
}