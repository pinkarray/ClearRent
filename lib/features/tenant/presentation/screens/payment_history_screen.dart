import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';

class PaymentHistoryScreen extends StatefulWidget {
  const PaymentHistoryScreen({super.key});

  @override
  State<PaymentHistoryScreen> createState() => _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends State<PaymentHistoryScreen> {
  String _selectedFilter = 'all';

  // Demo payment data
  final List<PaymentModel> _payments = [
    PaymentModel(
      id: 'TXN-2024-001',
      propertyTitle: '3 Bedroom Flat in Lekki Phase 1',
      landlordName: 'Mr. Adebayo Johnson',
      amount: 2500000,
      serviceFee: 50000,
      totalAmount: 2550000,
      date: DateTime.now().subtract(const Duration(days: 5)),
      status: PaymentStatus.successful,
      paymentMethod: 'Bank Transfer',
      reference: 'CR-LKI-20240115-001',
    ),
    PaymentModel(
      id: 'TXN-2024-002',
      propertyTitle: '3 Bedroom Flat in Lekki Phase 1',
      landlordName: 'Mr. Adebayo Johnson',
      amount: 2500000,
      serviceFee: 0,
      totalAmount: 2500000,
      date: DateTime.now().subtract(const Duration(days: 370)),
      status: PaymentStatus.successful,
      paymentMethod: 'Paystack',
      reference: 'CR-LKI-20230115-001',
    ),
    PaymentModel(
      id: 'TXN-2023-003',
      propertyTitle: '2 Bedroom Apartment in Yaba',
      landlordName: 'Mrs. Chioma Okafor',
      amount: 1200000,
      serviceFee: 35000,
      totalAmount: 1235000,
      date: DateTime(2023, 1, 5),
      status: PaymentStatus.successful,
      paymentMethod: 'Card Payment',
      reference: 'CR-YBA-20230105-001',
    ),
    PaymentModel(
      id: 'TXN-2022-004',
      propertyTitle: '2 Bedroom Apartment in Yaba',
      landlordName: 'Mrs. Chioma Okafor',
      amount: 1200000,
      serviceFee: 0,
      totalAmount: 1200000,
      date: DateTime(2022, 1, 3),
      status: PaymentStatus.successful,
      paymentMethod: 'Bank Transfer',
      reference: 'CR-YBA-20220103-001',
    ),
  ];

  List<PaymentModel> get _filteredPayments {
    if (_selectedFilter == 'all') return _payments;
    return _payments.where((p) {
      switch (_selectedFilter) {
        case 'successful':
          return p.status == PaymentStatus.successful;
        case 'pending':
          return p.status == PaymentStatus.pending;
        case 'failed':
          return p.status == PaymentStatus.failed;
        default:
          return true;
      }
    }).toList();
  }

  double get _totalPaid {
    return _payments
        .where((p) => p.status == PaymentStatus.successful)
        .fold(0, (sum, p) => sum + p.totalAmount);
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
      body: Column(
        children: [
          // Summary Card
          _buildSummaryCard(),

          // Filter Tabs
          _buildFilterTabs(),

          // Payment List
          Expanded(
            child: _filteredPayments.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    itemCount: _filteredPayments.length,
                    itemBuilder: (context, index) {
                      return _buildPaymentCard(_filteredPayments[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final successCount = _payments.where((p) => p.status == PaymentStatus.successful).length;

    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary,
            AppColors.primaryLight,
          ],
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
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(51),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Rent Paid',
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.white.withAlpha(204),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '₦${_formatAmount(_totalPaid)}',
                      style: AppTextStyles.h3.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Stats Row
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(26),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildSummaryItem(
                    icon: Icons.check_circle_outline,
                    value: '$successCount',
                    label: 'Successful',
                  ),
                ),
                Container(
                  width: 1,
                  height: 40,
                  color: Colors.white.withAlpha(51),
                ),
                Expanded(
                  child: _buildSummaryItem(
                    icon: Icons.receipt_long_outlined,
                    value: '${_payments.length}',
                    label: 'Total',
                  ),
                ),
                Container(
                  width: 1,
                  height: 40,
                  color: Colors.white.withAlpha(51),
                ),
                Expanded(
                  child: _buildSummaryItem(
                    icon: Icons.home_outlined,
                    value: '2',
                    label: 'Properties',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withAlpha(204), size: 18),
        const SizedBox(height: 6),
        Text(
          value,
          style: AppTextStyles.labelLarge.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: Colors.white.withAlpha(179),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterTabs() {
    final filters = [
      {'value': 'all', 'label': 'All'},
      {'value': 'successful', 'label': 'Successful'},
      {'value': 'pending', 'label': 'Pending'},
      {'value': 'failed', 'label': 'Failed'},
    ];

    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        itemBuilder: (context, index) {
          final filter = filters[index];
          final isSelected = _selectedFilter == filter['value'];

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(filter['label']!),
              selected: isSelected,
              onSelected: (_) {
                setState(() => _selectedFilter = filter['value']!);
              },
              backgroundColor: AppColors.surface,
              selectedColor: AppColors.primary.withAlpha(26),
              checkmarkColor: AppColors.primary,
              labelStyle: AppTextStyles.labelMedium.copyWith(
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: isSelected ? AppColors.primary : AppColors.border,
                ),
              ),
              showCheckmark: false,
            ),
          );
        },
      ),
    );
  }

  Widget _buildPaymentCard(PaymentModel payment) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showPaymentDetails(payment),
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
                        color: _getStatusColor(payment.status).withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        _getStatusIcon(payment.status),
                        color: _getStatusColor(payment.status),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            payment.propertyTitle,
                            style: AppTextStyles.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatDateFull(payment.date),
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textHint,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '₦${_formatAmount(payment.totalAmount)}',
                          style: AppTextStyles.labelLarge.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _getStatusColor(payment.status).withAlpha(26),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getStatusText(payment.status),
                            style: AppTextStyles.caption.copyWith(
                              color: _getStatusColor(payment.status),
                              fontWeight: FontWeight.w600,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // Details Row
                Row(
                  children: [
                    Expanded(
                      child: _buildDetailItem(
                        icon: Icons.person_outline,
                        label: 'Landlord',
                        value: payment.landlordName,
                      ),
                    ),
                    Expanded(
                      child: _buildDetailItem(
                        icon: Icons.credit_card_outlined,
                        label: 'Method',
                        value: payment.paymentMethod,
                      ),
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

  Widget _buildEmptyState() {
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
                Icons.receipt_long_outlined,
                size: 48,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No Payments Found',
              style: AppTextStyles.h4,
            ),
            const SizedBox(height: 8),
            Text(
              _selectedFilter == 'all'
                  ? 'Your payment history will appear here\nonce you make payments through ClearRent.'
                  : 'No $_selectedFilter payments found.',
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

  void _showPaymentDetails(PaymentModel payment) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _getStatusColor(payment.status).withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _getStatusIcon(payment.status),
                    color: _getStatusColor(payment.status),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Payment Receipt', style: AppTextStyles.h4),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _getStatusColor(payment.status).withAlpha(26),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _getStatusText(payment.status),
                          style: AppTextStyles.caption.copyWith(
                            color: _getStatusColor(payment.status),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),

            // Details
            _buildReceiptRow('Property', payment.propertyTitle),
            _buildReceiptRow('Landlord', payment.landlordName),
            _buildReceiptRow('Date', _formatDateFull(payment.date)),
            _buildReceiptRow('Reference', payment.reference),
            _buildReceiptRow('Payment Method', payment.paymentMethod),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),

            // Amount breakdown
            _buildReceiptRow('Rent Amount', '₦${_formatAmountFull(payment.amount)}'),
            if (payment.serviceFee > 0)
              _buildReceiptRow('Service Fee', '₦${_formatAmountFull(payment.serviceFee)}'),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total', style: AppTextStyles.labelLarge),
                Text(
                  '₦${_formatAmountFull(payment.totalAmount)}',
                  style: AppTextStyles.h4.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Download button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Receipt download coming soon!'),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Download Receipt'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: AppTextStyles.bodySmall.copyWith(
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.successful:
        return AppColors.success;
      case PaymentStatus.pending:
        return AppColors.warning;
      case PaymentStatus.failed:
        return AppColors.error;
    }
  }

  IconData _getStatusIcon(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.successful:
        return Icons.check_circle_outline;
      case PaymentStatus.pending:
        return Icons.schedule;
      case PaymentStatus.failed:
        return Icons.cancel_outlined;
    }
  }

  String _getStatusText(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.successful:
        return 'Successful';
      case PaymentStatus.pending:
        return 'Pending';
      case PaymentStatus.failed:
        return 'Failed';
    }
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
    return amount.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  String _formatDateFull(DateTime date) {
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

// ============ MODELS ============

enum PaymentStatus { successful, pending, failed }

class PaymentModel {
  final String id;
  final String propertyTitle;
  final String landlordName;
  final double amount;
  final double serviceFee;
  final double totalAmount;
  final DateTime date;
  final PaymentStatus status;
  final String paymentMethod;
  final String reference;

  PaymentModel({
    required this.id,
    required this.propertyTitle,
    required this.landlordName,
    required this.amount,
    required this.serviceFee,
    required this.totalAmount,
    required this.date,
    required this.status,
    required this.paymentMethod,
    required this.reference,
  });
}