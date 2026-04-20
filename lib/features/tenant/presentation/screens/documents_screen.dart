import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../core/utils/app_logger.dart';

/// Shows tenant's documents: tenancy agreements and payment history.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ActiveRentalService _rentalService = ActiveRentalService();

  List<ActiveRental> _rentals = [];
  List<Map<String, dynamic>> _payments = [];
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
      final payments = await _loadPaystackPayments();

      if (mounted) {
        setState(() {
          _rentals = rentals;
          _payments = payments;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.e('Error loading documents: $e', name: 'DocumentsScreen');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Load all Paystack payment records for the current user
  Future<List<Map<String, dynamic>>> _loadPaystackPayments() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return [];

      final snapshot = await FirebaseFirestore.instance
          .collection('payments')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      AppLogger.e('Error loading payments: $e', name: 'DocumentsScreen');
      return [];
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
                text:
                    'Agreements${_rentals.isNotEmpty ? ' (${_rentals.length})' : ''}'),
            Tab(
                text:
                    'Payments${_payments.isNotEmpty ? ' (${_payments.length})' : ''}'),
          ],
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : TabBarView(
              controller: _tabController,
              children: [
                // ── Agreements Tab ──
                _rentals.isEmpty
                    ? _buildEmptyState(
                        icon: Icons.description_outlined,
                        title: 'No Agreements Yet',
                        subtitle:
                            'Your rental agreements will appear here when you rent through ClearRent.',
                      )
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

                // ── Payments Tab ──
                _payments.isEmpty
                    ? _buildEmptyState(
                        icon: Icons.payment_outlined,
                        title: 'No Payments Yet',
                        subtitle:
                            'Your payment history will appear here after you make payments on ClearRent.',
                      )
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        color: AppColors.primary,
                        child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            _buildPaymentsSummary(),
                            const SizedBox(height: 16),
                            ..._payments.map((p) => _buildPaymentCard(p)),
                          ],
                        ),
                      ),
              ],
            ),
    );
  }

  // ────────────────────────────────────────────────────────────────────
  // SHARED WIDGETS
  // ────────────────────────────────────────────────────────────────────

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
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
            child: Icon(icon, size: 48, color: AppColors.primary),
          ),
          const SizedBox(height: 24),
          Text(title, style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style:
                AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
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

  // ────────────────────────────────────────────────────────────────────
  // AGREEMENTS TAB
  // ────────────────────────────────────────────────────────────────────

  Widget _buildAgreementCard(ActiveRental rental) {
    final isActive = rental.isActive;
    final hasAgreement =
        rental.agreementUrl != null && rental.agreementUrl!.isNotEmpty;

    final agreementStatusLabel = _agreementStatusLabel(rental.agreementStatus);
    final agreementStatusColor = _agreementStatusColor(rental.agreementStatus);

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
          // Header row
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
                  Text('Tenancy Agreement', style: AppTextStyles.labelMedium),
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

          // Details row
          Row(children: [
            Expanded(
              child: _buildDetail(
                Icons.calendar_today_outlined,
                'Lease Period',
                '${_formatDate(rental.leaseStartDate)} – ${_formatDate(rental.leaseEndDate)}',
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

          // Rent amount
          _buildDetail(
            Icons.payments_outlined,
            'Rent',
            '₦${_formatAmount(rental.rentAmount)}/${rental.rentFrequency == 'yearly' ? 'yr' : 'mo'}',
          ),

          const SizedBox(height: 12),

          // Agreement status + actions
          if (hasAgreement) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: agreementStatusColor.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: agreementStatusColor.withAlpha(50)),
              ),
              child: Row(children: [
                Icon(_agreementStatusIcon(rental.agreementStatus),
                    size: 16, color: agreementStatusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    agreementStatusLabel,
                    style: AppTextStyles.caption
                        .copyWith(color: agreementStatusColor),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),

            // Action buttons row
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openDocument(rental.agreementUrl!),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: const Text('View'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _shareDocument(
                    url: rental.agreementUrl!,
                    title: 'Tenancy Agreement – ${rental.propertyTitle}',
                  ),
                  icon: const Icon(Icons.share_outlined, size: 16),
                  label: const Text('Share'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _downloadDocument(rental.agreementUrl!),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Icon(Icons.download_outlined,
                      size: 18, color: AppColors.textSecondary),
                ),
              ),
            ]),
          ] else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 14, color: AppColors.warning),
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

  String _agreementStatusLabel(AgreementStatus status) {
    switch (status) {
      case AgreementStatus.none:
        return 'Uploaded — awaiting your review';
      case AgreementStatus.pendingReview:
        return 'Uploaded — awaiting your review';
      case AgreementStatus.accepted:
        return 'You accepted — awaiting landlord finalization';
      case AgreementStatus.disputed:
        return 'You raised concerns — awaiting landlord response';
      case AgreementStatus.finalized:
        return 'Finalized — agreement is in effect';
    }
  }

  Color _agreementStatusColor(AgreementStatus status) {
    switch (status) {
      case AgreementStatus.none:
      case AgreementStatus.pendingReview:
        return AppColors.info;
      case AgreementStatus.accepted:
        return AppColors.warning;
      case AgreementStatus.disputed:
        return AppColors.error;
      case AgreementStatus.finalized:
        return AppColors.success;
    }
  }

  IconData _agreementStatusIcon(AgreementStatus status) {
    switch (status) {
      case AgreementStatus.none:
      case AgreementStatus.pendingReview:
        return Icons.rate_review_outlined;
      case AgreementStatus.accepted:
        return Icons.check_circle_outline;
      case AgreementStatus.disputed:
        return Icons.warning_amber_outlined;
      case AgreementStatus.finalized:
        return Icons.verified_outlined;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // PAYMENTS TAB
  // ────────────────────────────────────────────────────────────────────

  Widget _buildPaymentsSummary() {
    double total = 0;
    int completed = 0;
    for (final p in _payments) {
      if (p['status'] == 'completed') {
        total += (p['amount'] as num?)?.toDouble() ?? 0;
        completed++;
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(50)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total Paid',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text(
                  '₦${_formatAmount(total)}',
                  style: AppTextStyles.h3.copyWith(
                    color: AppColors.primary,
                    fontFamily: 'Roboto',
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Text('$completed',
                    style: AppTextStyles.h4.copyWith(color: AppColors.primary)),
                Text('transactions',
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary, fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentCard(Map<String, dynamic> payment) {
    final type = payment['type'] as String? ?? 'unknown';
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final status = payment['status'] as String? ?? 'unknown';
    final reference = payment['reference'] as String? ?? '';
    final createdAt = (payment['createdAt'] as Timestamp?)?.toDate();

    final typeLabel = _paymentTypeLabel(type);
    final typeIcon = _paymentTypeIcon(type);
    final typeColor = _paymentTypeColor(type);
    final statusColor =
        status == 'completed' ? AppColors.success : AppColors.warning;

    return GestureDetector(
      onTap: () => _showPaymentReceipt(payment),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Type icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: typeColor.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(typeIcon, color: typeColor, size: 20),
              ),
              const SizedBox(width: 12),

              // Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(typeLabel, style: AppTextStyles.labelMedium),
                    const SizedBox(height: 2),
                    Text(
                      reference.length > 24
                          ? '${reference.substring(0, 24)}…'
                          : reference,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint, fontSize: 10),
                    ),
                    if (createdAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formatDate(createdAt),
                        style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary, fontSize: 10),
                      ),
                    ],
                  ],
                ),
              ),

              // Amount + status
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₦${_formatAmount(amount)}',
                    style: AppTextStyles.labelLarge
                        .copyWith(fontFamily: 'Roboto'),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withAlpha(26),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      status == 'completed' ? 'Paid' : status,
                      style: AppTextStyles.caption.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 16, color: AppColors.textHint),
            ],
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────
  // PAYMENT RECEIPT DIALOG
  // ────────────────────────────────────────────────────────────────────

  void _showPaymentReceipt(Map<String, dynamic> payment) {
    final type = payment['type'] as String? ?? 'unknown';
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final status = payment['status'] as String? ?? 'unknown';
    final reference = payment['reference'] as String? ?? '';
    final userEmail = payment['userEmail'] as String? ?? '';
    final createdAt = (payment['createdAt'] as Timestamp?)?.toDate();
    final propertyId = payment['propertyId'] as String?;
    final rentalInterestId = payment['rentalInterestId'] as String?;

    final typeLabel = _paymentTypeLabel(type);
    final statusColor =
        status == 'completed' ? AppColors.success : AppColors.warning;
    final statusLabel = status == 'completed' ? 'Successful' : status;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textHint.withAlpha(77),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // Success icon
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: statusColor.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(
                status == 'completed'
                    ? Icons.check_circle
                    : Icons.hourglass_bottom,
                color: statusColor,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),

            // Title
            Text('Payment Receipt', style: AppTextStyles.h3),
            const SizedBox(height: 4),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(26),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                statusLabel,
                style: AppTextStyles.caption.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Amount
            Text(
              '₦${_formatAmount(amount)}',
              style: AppTextStyles.h2.copyWith(
                fontFamily: 'Roboto',
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 24),

            // Details card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _receiptRow('Type', typeLabel),
                  const SizedBox(height: 12),
                  if (createdAt != null) ...[
                    _receiptRow('Date', DateFormat('d MMM y, h:mm a').format(createdAt)),
                    const SizedBox(height: 12),
                  ],
                  _receiptRow('Email', userEmail),
                  const SizedBox(height: 12),
                  _receiptRow('Reference', reference, copyable: true),
                  if (propertyId != null) ...[
                    const SizedBox(height: 12),
                    _receiptRow('Property ID', propertyId),
                  ],
                  if (rentalInterestId != null) ...[
                    const SizedBox(height: 12),
                    _receiptRow('Rental ID', rentalInterestId),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Share button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  final receiptText = 'ClearRent Payment Receipt\n'
                      '━━━━━━━━━━━━━━━━━━━━━━\n'
                      'Type: $typeLabel\n'
                      'Amount: ₦${_formatAmount(amount)}\n'
                      'Status: $statusLabel\n'
                      'Date: ${createdAt != null ? DateFormat('d MMM y, h:mm a').format(createdAt) : 'N/A'}\n'
                      'Reference: $reference\n'
                      '━━━━━━━━━━━━━━━━━━━━━━\n'
                      'Powered by ClearRent × Paystack';
                  // ignore: deprecated_member_use
                  Share.share(receiptText);
                },
                icon: Icon(Icons.share_outlined, size: 18),
                label: const Text('Share Receipt'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Close
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Close',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _receiptRow(String label, String value, {bool copyable = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: AppTextStyles.labelSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (copyable)
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Reference copied'),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child:
                  Icon(Icons.copy, size: 14, color: AppColors.textHint),
            ),
          ),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────────
  // PAYMENT HELPERS
  // ────────────────────────────────────────────────────────────────────

  String _paymentTypeLabel(String type) {
    switch (type) {
      case 'verification':
        return 'Verification Fee';
      case 'inspection':
        return 'Inspection Fee';
      case 'listing':
        return 'Listing Fee';
      case 'rent':
        return 'Rent Payment';
      default:
        return 'Payment';
    }
  }

  IconData _paymentTypeIcon(String type) {
    switch (type) {
      case 'verification':
        return Icons.verified_user_outlined;
      case 'inspection':
        return Icons.event_available;
      case 'listing':
        return Icons.add_home_outlined;
      case 'rent':
        return Icons.payments_outlined;
      default:
        return Icons.payment;
    }
  }

  Color _paymentTypeColor(String type) {
    switch (type) {
      case 'verification':
        return AppColors.primary;
      case 'inspection':
        return AppColors.info;
      case 'listing':
        return AppColors.warning;
      case 'rent':
        return AppColors.success;
      default:
        return AppColors.textSecondary;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // DOCUMENT ACTIONS
  // ────────────────────────────────────────────────────────────────────

  Future<void> _openDocument(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Could not open document'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ));
        }
      }
    } catch (e) {
      AppLogger.e('Error opening document: $e', name: 'DocumentsScreen');
    }
  }

  Future<void> _downloadDocument(String url) async {
    await _openDocument(url);
  }

  Future<void> _shareDocument({
    required String url,
    required String title,
  }) async {
    try {
      // ignore: deprecated_member_use
      await Share.share('$title\n$url');
    } catch (e) {
      AppLogger.e('Error sharing document: $e', name: 'DocumentsScreen');
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // HELPER WIDGETS
  // ────────────────────────────────────────────────────────────────────

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
}