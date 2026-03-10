import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';

class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isLoading = true;
  
  // Earnings data
  double _totalEarnings = 0;
  double _pendingPayouts = 0;
  double _completedPayouts = 0;
  List<TransactionModel> _transactions = [];

  @override
  void initState() {
    super.initState();
    _loadEarningsData();
  }

  Future<void> _loadEarningsData() async {
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid;
      
      if (userId == null) {
        debugPrint('❌ No user ID found');
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final snapshot = await _firestore
          .collection('transactions')
          .where('landlordId', isEqualTo: userId)
          .get();

      // Sort client-side
      final docs = snapshot.docs.toList();
      docs.sort((a, b) {
        final aTime = (a.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
        final bTime = (b.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
        return bTime.compareTo(aTime);
      });

      double total = 0;
      double pending = 0;
      double completed = 0;
      List<TransactionModel> transactions = [];

      for (final doc in docs) {
        final data = doc.data();
        final transaction = TransactionModel.fromJson(doc.id, data);
        transactions.add(transaction);

        total += transaction.amount;
        if (transaction.status == TransactionStatus.pending) {
          pending += transaction.amount;
        } else if (transaction.status == TransactionStatus.completed) {
          completed += transaction.amount;
        }
      }

      if (mounted) {
        setState(() {
          _totalEarnings = total;
          _pendingPayouts = pending;
          _completedPayouts = completed;
          _transactions = transactions;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading earnings: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshData() async {
    setState(() => _isLoading = true);
    await _loadEarningsData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Earnings',
          style: AppTextStyles.h4.copyWith(color: Colors.white),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : RefreshIndicator(
              onRefresh: _refreshData,
              color: AppColors.primary,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    // Header with earnings summary
                    _buildEarningsHeader(),
                    
                    // Transactions section
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Transaction History',
                                style: AppTextStyles.h4,
                              ),
                              if (_transactions.isNotEmpty)
                                Text(
                                  '${_transactions.length} transactions',
                                  style: AppTextStyles.caption,
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          
                          // Transactions list or empty state
                          _transactions.isEmpty
                              ? _buildEmptyState()
                              : ListView.separated(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _transactions.length,
                                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                                  itemBuilder: (context, index) {
                                    return _buildTransactionItem(_transactions[index]);
                                  },
                                ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildEarningsHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.primary,
            AppColors.primary.withAlpha(217),
          ],
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          children: [
            // Total Earnings
            Text(
              'Total Earnings',
              style: AppTextStyles.bodySmall.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatCurrency(_totalEarnings),
              style: AppTextStyles.h1.copyWith(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Pending & Completed row
            Row(
              children: [
                Expanded(
                  child: _buildSummaryCard(
                    icon: Icons.schedule,
                    label: 'Pending',
                    amount: _pendingPayouts,
                    color: AppColors.warning,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryCard(
                    icon: Icons.check_circle_outline,
                    label: 'Completed',
                    amount: _completedPayouts,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard({
    required IconData icon,
    required String label,
    required double amount,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(13),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withAlpha(26),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                Text(
                  _formatCurrencyCompact(amount),
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.account_balance_wallet_outlined,
              size: 32,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'No transactions yet',
            style: AppTextStyles.labelLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'When tenants pay rent through ClearRent, your transactions will appear here.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(26),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline, color: AppColors.info, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Add your bank details to receive payouts.',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.info,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionItem(TransactionModel transaction) {
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
              // Status icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _getStatusColor(transaction.status).withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _getStatusIcon(transaction.status),
                  color: _getStatusColor(transaction.status),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              
              // Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transaction.propertyTitle,
                      style: AppTextStyles.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'From ${transaction.tenantName}',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
              ),
              
              // Amount & Status
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatCurrencyCompact(transaction.amount),
                    style: AppTextStyles.labelLarge.copyWith(
                      color: _getStatusColor(transaction.status),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _getStatusColor(transaction.status).withAlpha(26),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _getStatusLabel(transaction.status),
                      style: AppTextStyles.labelSmall.copyWith(
                        color: _getStatusColor(transaction.status),
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          // Footer
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 12, color: AppColors.textHint),
                  const SizedBox(width: 4),
                  Text(
                    transaction.formattedDate,
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              Text(
                'Ref: ${transaction.reference}',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.pending:
        return AppColors.warning;
      case TransactionStatus.completed:
        return AppColors.success;
      case TransactionStatus.failed:
        return AppColors.error;
    }
  }

  IconData _getStatusIcon(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.pending:
        return Icons.schedule;
      case TransactionStatus.completed:
        return Icons.check_circle_outline;
      case TransactionStatus.failed:
        return Icons.error_outline;
    }
  }

  String _getStatusLabel(TransactionStatus status) {
    switch (status) {
      case TransactionStatus.pending:
        return 'Pending';
      case TransactionStatus.completed:
        return 'Completed';
      case TransactionStatus.failed:
        return 'Failed';
    }
  }

  String _formatCurrency(double amount) {
    if (amount >= 1000000) {
      return 'NGN ${(amount / 1000000).toStringAsFixed(2)}M';
    } else if (amount >= 1000) {
      final formatted = amount.toStringAsFixed(0);
      final chars = formatted.split('').reversed.toList();
      final result = <String>[];
      for (var i = 0; i < chars.length; i++) {
        if (i > 0 && i % 3 == 0) {
          result.add(',');
        }
        result.add(chars[i]);
      }
      return 'NGN ${result.reversed.join('')}';
    }
    return 'NGN ${amount.toStringAsFixed(0)}';
  }

  String _formatCurrencyCompact(double amount) {
    if (amount >= 1000000) {
      return 'NGN ${(amount / 1000000).toStringAsFixed(1)}M';
    } else if (amount >= 1000) {
      return 'NGN ${(amount / 1000).toStringAsFixed(0)}K';
    }
    return 'NGN ${amount.toStringAsFixed(0)}';
  }
}

// Transaction Model
enum TransactionStatus { pending, completed, failed }

class TransactionModel {
  final String id;
  final String propertyId;
  final String propertyTitle;
  final String tenantId;
  final String tenantName;
  final String landlordId;
  final double amount;
  final TransactionStatus status;
  final String reference;
  final DateTime createdAt;

  TransactionModel({
    required this.id,
    required this.propertyId,
    required this.propertyTitle,
    required this.tenantId,
    required this.tenantName,
    required this.landlordId,
    required this.amount,
    required this.status,
    required this.reference,
    required this.createdAt,
  });

  factory TransactionModel.fromJson(String id, Map<String, dynamic> json) {
    return TransactionModel(
      id: id,
      propertyId: json['propertyId'] ?? '',
      propertyTitle: json['propertyTitle'] ?? 'Unknown Property',
      tenantId: json['tenantId'] ?? '',
      tenantName: json['tenantName'] ?? 'Unknown Tenant',
      landlordId: json['landlordId'] ?? '',
      amount: (json['amount'] ?? 0).toDouble(),
      status: _parseStatus(json['status']),
      reference: json['reference'] ?? '',
      createdAt: json['createdAt'] != null
          ? (json['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  static TransactionStatus _parseStatus(String? status) {
    switch (status) {
      case 'pending':
        return TransactionStatus.pending;
      case 'completed':
        return TransactionStatus.completed;
      case 'failed':
        return TransactionStatus.failed;
      default:
        return TransactionStatus.pending;
    }
  }

  String get formattedDate {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[createdAt.month - 1]} ${createdAt.day}, ${createdAt.year}';
  }
}