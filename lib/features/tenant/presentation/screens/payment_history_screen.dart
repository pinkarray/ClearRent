import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../services/rental_interest_service.dart';

/// Shows the tenant's rental payment history from Firestore.
/// Only shows payments that have been uploaded (any status from paymentUploaded onward).
class PaymentHistoryScreen extends StatefulWidget {
  const PaymentHistoryScreen({super.key});

  @override
  State<PaymentHistoryScreen> createState() => _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends State<PaymentHistoryScreen> {
  final RentalInterestService _service = RentalInterestService();

  List<RentalInterest> _payments = [];
  bool _isLoading = true;
  String _selectedFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadPayments();
  }

  Future<void> _loadPayments() async {
    try {
      final interests = await _service.getTenantInterests();
      if (mounted) {
        setState(() {
          // Only show interests that have progressed past pendingPayment
          _payments = interests
              .where((i) =>
                  i.status != RentalInterestStatus.pendingPayment)
              .toList()
            ..sort((a, b) => (b.paymentUploadedAt ?? b.createdAt)
                .compareTo(a.paymentUploadedAt ?? a.createdAt));
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading payments: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<RentalInterest> get _filteredPayments {
    if (_selectedFilter == 'all') return _payments;
    return _payments.where((p) {
      switch (_selectedFilter) {
        case 'verified':
          return p.status == RentalInterestStatus.paymentVerified ||
              p.status == RentalInterestStatus.accepted;
        case 'pending':
          return p.status == RentalInterestStatus.paymentUploaded;
        case 'rejected':
          return p.status == RentalInterestStatus.rejected;
        default:
          return true;
      }
    }).toList();
  }

  double get _totalPaid {
    return _payments
        .where((p) =>
            p.status == RentalInterestStatus.paymentVerified ||
            p.status == RentalInterestStatus.accepted)
        .fold(0.0, (sum, p) => sum + p.paymentAmount);
  }

  String _formatAmount(double amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(1)}M';
    } else if (amount >= 1000) {
      return '${(amount / 1000).toStringAsFixed(0)}K';
    }
    return amount.toStringAsFixed(0);
  }

  String _formatAmountFull(double amount) {
    return NumberFormat('#,###').format(amount);
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    return DateFormat('d MMMM y').format(date);
  }

  Color _getStatusColor(RentalInterestStatus status) {
    switch (status) {
      case RentalInterestStatus.paymentVerified:
      case RentalInterestStatus.accepted:
        return AppColors.success;
      case RentalInterestStatus.paymentUploaded:
        return AppColors.warning;
      case RentalInterestStatus.rejected:
        return AppColors.error;
      case RentalInterestStatus.pendingPayment:
        return AppColors.textHint;
    }
  }

  IconData _getStatusIcon(RentalInterestStatus status) {
    switch (status) {
      case RentalInterestStatus.paymentVerified:
      case RentalInterestStatus.accepted:
        return Icons.check_circle_outline;
      case RentalInterestStatus.paymentUploaded:
        return Icons.schedule;
      case RentalInterestStatus.rejected:
        return Icons.cancel_outlined;
      case RentalInterestStatus.pendingPayment:
        return Icons.hourglass_empty;
    }
  }

  String _getStatusText(RentalInterestStatus status) {
    switch (status) {
      case RentalInterestStatus.paymentVerified:
        return 'Verified';
      case RentalInterestStatus.accepted:
        return 'Confirmed';
      case RentalInterestStatus.paymentUploaded:
        return 'Pending';
      case RentalInterestStatus.rejected:
        return 'Rejected';
      case RentalInterestStatus.pendingPayment:
        return 'Awaiting';
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
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Payment History', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : _payments.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadPayments,
                  color: AppColors.primary,
                  child: Column(children: [
                    _buildSummaryCard(),
                    _buildFilterTabs(),
                    Expanded(
                      child: _filteredPayments.isEmpty
                          ? _buildNoResults()
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 8, 20, 20),
                              itemCount: _filteredPayments.length,
                              itemBuilder: (_, i) =>
                                  _buildPaymentCard(_filteredPayments[i]),
                            ),
                    ),
                  ]),
                ),
    );
  }

  Widget _buildSummaryCard() {
    final verified = _payments
        .where((p) =>
            p.status == RentalInterestStatus.paymentVerified ||
            p.status == RentalInterestStatus.accepted)
        .length;

    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryLight],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(77),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(51),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.account_balance_wallet_outlined,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total Rent Paid',
                    style: AppTextStyles.caption
                        .copyWith(color: Colors.white.withAlpha(204))),
                const SizedBox(height: 4),
                Text('₦${_formatAmountFull(_totalPaid)}',
                    style: AppTextStyles.h3.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(26),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            Expanded(
              child: Column(children: [
                Icon(Icons.check_circle_outline,
                    color: Colors.white.withAlpha(204), size: 18),
                const SizedBox(height: 6),
                Text('$verified',
                    style: AppTextStyles.labelLarge.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
                Text('Verified',
                    style: AppTextStyles.caption
                        .copyWith(color: Colors.white.withAlpha(179))),
              ]),
            ),
            Container(
                width: 1,
                height: 40,
                color: Colors.white.withAlpha(51)),
            Expanded(
              child: Column(children: [
                Icon(Icons.receipt_long_outlined,
                    color: Colors.white.withAlpha(204), size: 18),
                const SizedBox(height: 6),
                Text('${_payments.length}',
                    style: AppTextStyles.labelLarge.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
                Text('Total',
                    style: AppTextStyles.caption
                        .copyWith(color: Colors.white.withAlpha(179))),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildFilterTabs() {
    final filters = [
      {'value': 'all', 'label': 'All'},
      {'value': 'verified', 'label': 'Verified'},
      {'value': 'pending', 'label': 'Pending'},
      {'value': 'rejected', 'label': 'Rejected'},
    ];

    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: filters.length,
        itemBuilder: (_, i) {
          final f = filters[i];
          final selected = _selectedFilter == f['value'];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(f['label']!),
              selected: selected,
              onSelected: (_) =>
                  setState(() => _selectedFilter = f['value']!),
              backgroundColor: AppColors.surface,
              selectedColor: AppColors.primary.withAlpha(26),
              labelStyle: AppTextStyles.labelMedium.copyWith(
                  color: selected
                      ? AppColors.primary
                      : AppColors.textSecondary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                    color: selected
                        ? AppColors.primary
                        : AppColors.border),
              ),
              showCheckmark: false,
            ),
          );
        },
      ),
    );
  }

  Widget _buildPaymentCard(RentalInterest payment) {
    final color = _getStatusColor(payment.status);

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
              child: Icon(_getStatusIcon(payment.status),
                  color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(payment.propertyTitle,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    _formatDate(
                        payment.paymentUploadedAt ?? payment.createdAt),
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                  ),
                ],
              ),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('₦${_formatAmount(payment.paymentAmount)}',
                  style: AppTextStyles.labelLarge
                      .copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withAlpha(26),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _getStatusText(payment.status),
                  style: AppTextStyles.caption.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                      fontSize: 10),
                ),
              ),
            ]),
          ]),
          if (payment.status == RentalInterestStatus.rejected &&
              payment.paymentRejectionReason != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(13),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline,
                    size: 14, color: AppColors.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(payment.paymentRejectionReason!,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.error)),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildEmptyState() {
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
            child: const Icon(Icons.receipt_long_outlined,
                size: 48, color: AppColors.primary),
          ),
          const SizedBox(height: 24),
          Text('No Payments Yet', style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            'Your payment history will appear here when you make payments through ClearRent.',
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

  Widget _buildNoResults() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.filter_list, size: 40, color: AppColors.textHint),
          const SizedBox(height: 12),
          Text('No $_selectedFilter payments',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary)),
        ]),
      ),
    );
  }
}