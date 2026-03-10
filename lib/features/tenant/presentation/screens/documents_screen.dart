import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/rental_interest_service.dart';

/// Shows tenant's documents: tenancy agreements and payment receipts.
/// All data fetched from Firestore.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ActiveRentalService _rentalService = ActiveRentalService();
  final RentalInterestService _interestService = RentalInterestService();

  List<ActiveRental> _rentals = [];
  List<RentalInterest> _receipts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final rentals = await _rentalService.getTenantRentals();
      final interests = await _interestService.getTenantInterests();

      if (mounted) {
        setState(() {
          _rentals = rentals;
          // Only show interests with uploaded receipts
          _receipts = interests
              .where((i) =>
                  i.paymentReceiptUrl != null &&
                  i.paymentReceiptUrl!.isNotEmpty)
              .toList()
            ..sort((a, b) => (b.paymentUploadedAt ?? b.createdAt)
                .compareTo(a.paymentUploadedAt ?? a.createdAt));
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading documents: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDate(DateTime date) {
    return DateFormat('d MMM y').format(date);
  }

  String _formatAmount(double amount) {
    return NumberFormat('#,###').format(amount);
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
                  if (_rentals.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _badge('${_rentals.length}'),
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
                    _badge('${_receipts.length}'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : TabBarView(
              controller: _tabController,
              children: [
                // Agreements tab
                _rentals.isEmpty
                    ? _buildEmptyState(true)
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        color: AppColors.primary,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(20),
                          itemCount: _rentals.length,
                          itemBuilder: (_, i) =>
                              _buildAgreementCard(_rentals[i]),
                        ),
                      ),

                // Receipts tab
                _receipts.isEmpty
                    ? _buildEmptyState(false)
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        color: AppColors.primary,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(20),
                          itemCount: _receipts.length,
                          itemBuilder: (_, i) =>
                              _buildReceiptCard(_receipts[i]),
                        ),
                      ),
              ],
            ),
    );
  }

  Widget _badge(String count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(26),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(count,
          style: AppTextStyles.caption.copyWith(
              color: AppColors.primary, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildAgreementCard(ActiveRental rental) {
    final isActive = rental.isActive;
    final hasAgreement =
        rental.agreementUrl != null && rental.agreementUrl!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.description_outlined,
                  color: AppColors.info, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tenancy Agreement',
                      style: AppTextStyles.labelMedium),
                  const SizedBox(height: 2),
                  Text(rental.propertyTitle,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.success.withAlpha(26)
                    : AppColors.error.withAlpha(26),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isActive ? 'Active' : 'Expired',
                style: AppTextStyles.caption.copyWith(
                    color: isActive ? AppColors.success : AppColors.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 10),
              ),
            ),
          ]),

          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Row(children: [
            Expanded(
              child: _buildDetail(
                Icons.calendar_today_outlined,
                'Lease Period',
                '${_formatDate(rental.leaseStartDate)} - ${_formatDate(rental.leaseEndDate)}',
              ),
            ),
            Expanded(
              child: _buildDetail(
                Icons.person_outline,
                'Landlord',
                rental.landlordName,
              ),
            ),
          ]),

          const SizedBox(height: 12),

          if (hasAgreement)
            Row(children: [
              Icon(Icons.insert_drive_file_outlined,
                  size: 14, color: AppColors.textHint),
              const SizedBox(width: 4),
              Text('PDF Agreement Available',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint)),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  // TODO: Open agreement PDF viewer
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: const Text('PDF viewer coming soon!'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ));
                },
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('View',
                      style: AppTextStyles.labelSmall
                          .copyWith(color: AppColors.primary)),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right,
                      size: 16, color: AppColors.primary),
                ]),
              ),
            ])
          else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.info_outline,
                    size: 14, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Agreement pending from landlord',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.warning),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _buildReceiptCard(RentalInterest receipt) {
    final color = receipt.status == RentalInterestStatus.paymentVerified ||
            receipt.status == RentalInterestStatus.accepted
        ? AppColors.success
        : receipt.status == RentalInterestStatus.rejected
            ? AppColors.error
            : AppColors.warning;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.receipt_outlined, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Payment Receipt',
                      style: AppTextStyles.labelMedium),
                  const SizedBox(height: 2),
                  Text(receipt.propertyTitle,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Text('₦${_formatAmount(receipt.paymentAmount)}',
                style: AppTextStyles.labelLarge
                    .copyWith(fontWeight: FontWeight.bold)),
          ]),

          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Row(children: [
            Expanded(
              child: _buildDetail(
                Icons.calendar_today_outlined,
                'Uploaded',
                _formatDate(
                    receipt.paymentUploadedAt ?? receipt.createdAt),
              ),
            ),
            Expanded(
              child: _buildDetail(
                Icons.info_outline,
                'Status',
                receipt.status == RentalInterestStatus.paymentVerified ||
                        receipt.status == RentalInterestStatus.accepted
                    ? 'Verified'
                    : receipt.status == RentalInterestStatus.rejected
                        ? 'Rejected'
                        : 'Pending',
              ),
            ),
          ]),

          // Show receipt image thumbnail
          if (receipt.paymentReceiptUrl != null) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _viewReceipt(receipt.paymentReceiptUrl!),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CachedNetworkImage(
                    imageUrl: receipt.paymentReceiptUrl!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      width: 40,
                      height: 40,
                      color: AppColors.background,
                      child: const Icon(Icons.image, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('View Receipt',
                    style: AppTextStyles.labelSmall
                        .copyWith(color: AppColors.primary)),
                Icon(Icons.chevron_right,
                    size: 16, color: AppColors.primary),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  void _viewReceipt(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Payment Receipt', style: AppTextStyles.labelLarge),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (_, __) => SizedBox(
                height: 300,
                child: Center(
                    child: CircularProgressIndicator(
                        color: AppColors.primary)),
              ),
              errorWidget: (_, __, ___) => const SizedBox(
                height: 300,
                child: Center(
                    child: Icon(Icons.broken_image, size: 48)),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  Widget _buildDetail(IconData icon, String label, String value) {
    return Row(children: [
      Icon(icon, size: 14, color: AppColors.textHint),
      const SizedBox(width: 6),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textHint, fontSize: 10)),
          Text(value,
              style: AppTextStyles.caption
                  .copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    ]);
  }

  Widget _buildEmptyState(bool isAgreement) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
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
          Text(isAgreement ? 'No Agreements Yet' : 'No Receipts Yet',
              style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            isAgreement
                ? 'Your rental agreements will appear here when you rent through ClearRent.'
                : 'Payment receipts will appear here after you make payments.',
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: () => context.go('/tenant/home'),
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Browse Properties'),
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          ),
        ]),
      ),
    );
  }
}