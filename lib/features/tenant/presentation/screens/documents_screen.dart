import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Demo documents
  final List<DocumentModel> _agreements = [
    DocumentModel(
      id: '1',
      title: 'Tenancy Agreement',
      subtitle: '3 Bedroom Flat in Lekki Phase 1',
      propertyAddress: '15 Admiralty Way, Lekki Phase 1',
      landlordName: 'Mr. Adebayo Johnson',
      dateCreated: DateTime(2024, 1, 15),
      expiryDate: DateTime(2025, 1, 14),
      status: DocumentStatus.active,
      type: DocumentType.agreement,
      fileSize: '245 KB',
    ),
    DocumentModel(
      id: '2',
      title: 'Tenancy Agreement',
      subtitle: '2 Bedroom Apartment in Yaba',
      propertyAddress: '8 Herbert Macaulay Way, Yaba',
      landlordName: 'Mrs. Chioma Okafor',
      dateCreated: DateTime(2023, 1, 1),
      expiryDate: DateTime(2023, 12, 31),
      status: DocumentStatus.expired,
      type: DocumentType.agreement,
      fileSize: '198 KB',
    ),
  ];

  final List<DocumentModel> _receipts = [
    DocumentModel(
      id: '3',
      title: 'Rent Payment Receipt',
      subtitle: 'January 2024 - Lekki Phase 1',
      propertyAddress: '15 Admiralty Way, Lekki Phase 1',
      landlordName: 'Mr. Adebayo Johnson',
      dateCreated: DateTime(2024, 1, 15),
      amount: 2550000,
      status: DocumentStatus.active,
      type: DocumentType.receipt,
      fileSize: '89 KB',
    ),
    DocumentModel(
      id: '4',
      title: 'Rent Payment Receipt',
      subtitle: 'January 2023 - Lekki Phase 1',
      propertyAddress: '15 Admiralty Way, Lekki Phase 1',
      landlordName: 'Mr. Adebayo Johnson',
      dateCreated: DateTime(2023, 1, 15),
      amount: 2500000,
      status: DocumentStatus.active,
      type: DocumentType.receipt,
      fileSize: '85 KB',
    ),
    DocumentModel(
      id: '5',
      title: 'Rent Payment Receipt',
      subtitle: 'January 2023 - Yaba',
      propertyAddress: '8 Herbert Macaulay Way, Yaba',
      landlordName: 'Mrs. Chioma Okafor',
      dateCreated: DateTime(2023, 1, 5),
      amount: 1235000,
      status: DocumentStatus.active,
      type: DocumentType.receipt,
      fileSize: '82 KB',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
        title: Text('Documents', style: AppTextStyles.h4),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.description_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Text('Agreements'),
                  if (_agreements.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_agreements.length}',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.receipt_long_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Text('Receipts'),
                  if (_receipts.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_receipts.length}',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Agreements Tab
          _buildDocumentList(_agreements, isAgreement: true),

          // Receipts Tab
          _buildDocumentList(_receipts, isAgreement: false),
        ],
      ),
    );
  }

  Widget _buildDocumentList(List<DocumentModel> documents, {required bool isAgreement}) {
    if (documents.isEmpty) {
      return _buildEmptyState(isAgreement);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        return _buildDocumentCard(documents[index]);
      },
    );
  }

  Widget _buildDocumentCard(DocumentModel doc) {
    final isAgreement = doc.type == DocumentType.agreement;
    final isExpired = doc.status == DocumentStatus.expired;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpired ? AppColors.error.withAlpha(77) : AppColors.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showDocumentOptions(doc),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isAgreement
                            ? AppColors.info.withAlpha(26)
                            : AppColors.success.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isAgreement
                            ? Icons.description_outlined
                            : Icons.receipt_outlined,
                        color: isAgreement ? AppColors.info : AppColors.success,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            doc.title,
                            style: AppTextStyles.labelMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            doc.subtitle,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    // Status Badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isExpired
                            ? AppColors.error.withAlpha(26)
                            : AppColors.success.withAlpha(26),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isExpired ? 'Expired' : 'Active',
                        style: AppTextStyles.caption.copyWith(
                          color: isExpired ? AppColors.error : AppColors.success,
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // Details
                Row(
                  children: [
                    Expanded(
                      child: _buildDetailItem(
                        icon: Icons.calendar_today_outlined,
                        label: isAgreement ? 'Valid Until' : 'Date',
                        value: isAgreement
                            ? _formatDate(doc.expiryDate!)
                            : _formatDate(doc.dateCreated),
                      ),
                    ),
                    Expanded(
                      child: _buildDetailItem(
                        icon: isAgreement
                            ? Icons.person_outline
                            : Icons.payments_outlined,
                        label: isAgreement ? 'Landlord' : 'Amount',
                        value: isAgreement
                            ? doc.landlordName
                            : '₦${_formatAmount(doc.amount!)}',
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Action Row
                Row(
                  children: [
                    Icon(
                      Icons.insert_drive_file_outlined,
                      size: 14,
                      color: AppColors.textHint,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'PDF • ${doc.fileSize}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: AppColors.textHint,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textHint),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                  fontSize: 10,
                ),
              ),
              Text(
                value,
                style: AppTextStyles.caption.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool isAgreement) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isAgreement
                    ? Icons.description_outlined
                    : Icons.receipt_long_outlined,
                size: 48,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isAgreement ? 'No Agreements Yet' : 'No Receipts Yet',
              style: AppTextStyles.h4,
            ),
            const SizedBox(height: 8),
            Text(
              isAgreement
                  ? 'Your rental agreements will appear here\nwhen you rent through ClearRent.'
                  : 'Payment receipts will appear here\nafter you make payments.',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showDocumentOptions(DocumentModel doc) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),

            // Document Info
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: doc.type == DocumentType.agreement
                        ? AppColors.info.withAlpha(26)
                        : AppColors.success.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    doc.type == DocumentType.agreement
                        ? Icons.description_outlined
                        : Icons.receipt_outlined,
                    color: doc.type == DocumentType.agreement
                        ? AppColors.info
                        : AppColors.success,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(doc.title, style: AppTextStyles.labelLarge),
                      const SizedBox(height: 4),
                      Text(
                        doc.subtitle,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Actions
            _buildActionButton(
              icon: Icons.visibility_outlined,
              label: 'View Document',
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Document preview coming soon!'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildActionButton(
              icon: Icons.download_outlined,
              label: 'Download PDF',
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Download coming soon!'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildActionButton(
              icon: Icons.share_outlined,
              label: 'Share Document',
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Share coming soon!'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textPrimary, size: 20),
            const SizedBox(width: 12),
            Text(label, style: AppTextStyles.labelMedium),
            const Spacer(),
            const Icon(
              Icons.chevron_right,
              color: AppColors.textHint,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  String _formatAmount(double amount) {
    return amount.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }
}

// ============ MODELS ============

enum DocumentType { agreement, receipt }

enum DocumentStatus { active, expired }

class DocumentModel {
  final String id;
  final String title;
  final String subtitle;
  final String propertyAddress;
  final String landlordName;
  final DateTime dateCreated;
  final DateTime? expiryDate;
  final double? amount;
  final DocumentStatus status;
  final DocumentType type;
  final String fileSize;

  DocumentModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.propertyAddress,
    required this.landlordName,
    required this.dateCreated,
    this.expiryDate,
    this.amount,
    required this.status,
    required this.type,
    required this.fileSize,
  });
}