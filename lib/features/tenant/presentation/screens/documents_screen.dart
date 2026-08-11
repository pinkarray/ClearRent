import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/constants/colors.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/tenancy_link_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/tenancy_link_service.dart';
import '../../../../services/agreement_access_service.dart';
import '../../../../services/auth_service.dart';
import '../../../../core/utils/app_logger.dart';

/// Shows tenant's documents: tenancy agreements and payment history.
class DocumentsScreen extends StatefulWidget {
  /// Which tab to open on — 0 Agreements, 1 Payments.
  ///
  /// This screen is the single destination behind BOTH the "Documents" and the
  /// "Payment History" entry points, so the one that says payments has to land
  /// on payments. Before this it always opened on Agreements and the tenant had
  /// to find the tab themselves.
  final int initialTab;

  const DocumentsScreen({super.key, this.initialTab = 0});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ActiveRentalService _rentalService = ActiveRentalService();
  final TenancyLinkService _linkService = TenancyLinkService();
  final AgreementAccessService _agreementAccess = AgreementAccessService();

  /// Landlords and agents reach this screen too (`/landlord/documents`), but
  /// the Agreements tab is built from `getTenantRentals()` /
  /// `getTenantActiveLink()` — tenant-scoped queries that return nothing for
  /// them. They were shown a permanently empty "Agreements" tab beside a
  /// populated "Payments" one, which reads as data missing rather than a tab
  /// that was never theirs. Their agreements live on /landlord/agreements.
  bool _isTenant = true;

  List<ActiveRental> _rentals = [];
  // A landlord-linked tenancy with an attached agreement, surfaced alongside
  // active-rental agreements so linked tenants see their agreement here too.
  TenancyLinkModel? _link;
  List<Map<String, dynamic>> _payments = [];
  bool _isLoading = true;

  // Number of agreement entries shown in the Agreements tab.
  int get _agreementCount =>
      _rentals.length +
      ((_link?.agreementUrl?.isNotEmpty ?? false) ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      // Clamped: an out-of-range initialIndex throws rather than falling back.
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final profile = await AuthService().getUserProfile();
      final accountType = profile?['accountType'] as String? ?? 'tenant';
      if (mounted) setState(() => _isTenant = accountType == 'tenant');

      final rentals = await _rentalService.getTenantRentals();
      final link = await _linkService.getTenantActiveLink();
      final payments = await _loadPaystackPayments();

      if (mounted) {
        setState(() {
          _rentals = rentals;
          _link = link;
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

      // Query by userId only (auto-indexed) and sort client-side. A
      // server-side orderBy('createdAt') alongside the where would require a
      // composite index that isn't provisioned — when it's missing Firestore
      // throws and the catch below silently returns [], which showed up as a
      // permanently-empty Payments tab. Matches the client-sort pattern used
      // by earnings_screen / landlord_issues / activity_service.
      final snapshot = await FirebaseFirestore.instance
          .collection('payments')
          .where('userId', isEqualTo: uid)
          .get();

      final payments = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();

      DateTime ts(Map<String, dynamic> d) {
        final v = d['createdAt'];
        return v is Timestamp ? v.toDate() : DateTime(1970);
      }

      payments.sort((a, b) => ts(b).compareTo(ts(a)));
      return payments;
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
        title: Text(_isTenant ? 'Documents' : 'Payments & Receipts',
            style: AppTextStyles.h4),
        centerTitle: true,
        bottom: !_isTenant
            ? null
            : TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          tabs: [
            Tab(
                text:
                    'Agreements${_agreementCount > 0 ? ' ($_agreementCount)' : ''}'),
            Tab(
                text:
                    'Payments${_payments.isNotEmpty ? ' (${_payments.length})' : ''}'),
          ],
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : !_isTenant
              // Landlords/agents get the payments half only. The agreements
              // half is tenant-scoped by construction, so showing them an
              // empty tab implies missing data; theirs are a screen away.
              ? _buildLandlordPayments()
              : TabBarView(
              controller: _tabController,
              children: [
                // ── Agreements Tab ──
                _agreementCount == 0
                    ? const GuidanceEmptyState(
                        icon: Icons.description_outlined,
                        title: 'No Agreements Yet',
                        subtitle:
                            'Your rental agreements will appear here when you rent through ClearRent.',
                      )
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        color: AppColors.primary,
                        child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            if (_link?.agreementUrl?.isNotEmpty ?? false)
                              _buildLinkedAgreementCard(_link!),
                            ..._rentals.map(_buildAgreementCard),
                          ],
                        ),
                      ),

                // ── Payments Tab ──
                _payments.isEmpty
                    ? const GuidanceEmptyState(
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
                            ..._payments.map((p) => _buildPaymentEntry(p)),
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

  /// Payments only, plus a signpost to where a landlord's agreements actually
  /// live — so the screen never implies their documents are missing.
  Widget _buildLandlordPayments() {
    return RefreshIndicator(
      onRefresh: _loadData,
      color: AppColors.primary,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          GestureDetector(
            onTap: () => context.push('/landlord/agreements'),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withAlpha(60)),
              ),
              child: Row(
                children: [
                  Icon(Icons.description_outlined,
                      size: 20, color: AppColors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Tenancy agreements',
                            style: AppTextStyles.labelMedium
                                .copyWith(color: AppColors.primary)),
                        const SizedBox(height: 2),
                        Text(
                          'Your property and tenancy agreements are managed here',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppColors.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_payments.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: GuidanceEmptyState(
                icon: Icons.payment_outlined,
                title: 'No Payments Yet',
                subtitle:
                    'Payments you make on ClearRent — listing fees and the '
                    'like — will show up here with their receipts.',
              ),
            )
          else ...[
            _buildPaymentsSummary(),
            const SizedBox(height: 16),
            ..._payments.map((p) => _buildPaymentEntry(p)),
          ],
        ],
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
                    : rental.isPendingPayment
                        ? AppColors.warning.withAlpha(26)
                        : AppColors.error.withAlpha(26),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isActive
                    ? 'Active'
                    : rental.isPendingPayment
                        ? 'Awaiting Payment'
                        : 'Expired',
                style: AppTextStyles.caption.copyWith(
                    color: isActive
                        ? AppColors.success
                        : rental.isPendingPayment
                            ? AppColors.warning
                            : AppColors.error,
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
                  onPressed: () => _viewAgreement('active_rentals', rental.id),
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
                  onPressed: () => _shareAgreement(
                    'active_rentals', rental.id,
                    'Tenancy Agreement – ${rental.propertyTitle}',
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
          // Direct path into the full lease (review/accept/pay/dispute/message)
          // so the tenant doesn't have to go via inspection history to manage it.
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () =>
                  context.push('/tenant/lease-details', extra: rental),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open Lease Details'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // Agreement card for a landlord-linked tenancy. Links don't run the full
  // accept/dispute review lifecycle (that happens on promotion to an active
  // rental), so this is a simpler view: the document with View/Share/Download.
  Widget _buildLinkedAgreementCard(TenancyLinkModel link) {
    final hasLeaseTerm = link.leaseStartDate != null && link.leaseEndDate != null;

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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Tenancy Agreement', style: AppTextStyles.labelMedium),
                const SizedBox(height: 2),
                Text(link.propertyTitle,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(26),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('Linked',
                  style: AppTextStyles.caption.copyWith(
                      color: AppColors.success,
                      fontWeight: FontWeight.w600, fontSize: 10)),
            ),
          ]),

          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Row(children: [
            if (hasLeaseTerm)
              Expanded(
                child: _buildDetail(
                  Icons.calendar_today_outlined,
                  'Lease Period',
                  '${_formatDate(link.leaseStartDate!)} – ${_formatDate(link.leaseEndDate!)}',
                ),
              ),
            Expanded(
              child: _buildDetail(
                Icons.person_outline,
                'Landlord',
                link.landlordName,
              ),
            ),
          ]),

          const SizedBox(height: 12),
          _buildDetail(
            Icons.payments_outlined,
            'Rent',
            '₦${_formatAmount(link.rentAmount)}/${link.rentFrequency == 'yearly' ? 'yr' : 'mo'}',
          ),
          const SizedBox(height: 12),

          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _viewAgreement('tenancy_links', link.id),
                icon: const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('View'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _shareAgreement(
                  'tenancy_links', link.id,
                  'Tenancy Agreement – ${link.propertyTitle}',
                ),
                icon: const Icon(Icons.share_outlined, size: 16),
                label: const Text('Share'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  side: BorderSide(color: AppColors.border),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ]),
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

  /// A payment row, plus the confirm/dispute strip when it's a payout the
  /// signed-in user is the beneficiary of.
  Widget _buildPaymentEntry(Map<String, dynamic> payment) {
    final strip = _buildPayoutReceiptStrip(payment);
    final card = _buildPaymentCard(payment);
    if (strip == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [card, strip],
    );
  }

  Widget _buildPaymentCard(Map<String, dynamic> payment) {
    final type = payment['type'] as String? ?? 'unknown';
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final status = payment['status'] as String? ?? 'unknown';
    final reference = payment['reference'] as String? ?? '';
    final createdAt = (payment['createdAt'] as Timestamp?)?.toDate();
    // Web's list has carried this since it shipped; without it a tenant with
    // two rentals cannot tell which one a payment belongs to.
    final propertyTitle = payment['propertyTitle'] as String? ?? '';

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
                    if (propertyTitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        propertyTitle,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
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
  // PAYOUT RECEIPT — "did the money actually land?"
  //
  // Marking a payout paid only ever recorded that ClearRent SENT it. This is
  // the beneficiary's side of that. Lives on the payments receipt because it
  // is the one payout surface BOTH roles can read — an agent is not a party to
  // active_rentals at all.
  // ────────────────────────────────────────────────────────────────────

  /// The confirm/dispute strip under a `rent_payout` receipt, or null when the
  /// payment isn't a payout we can act on.
  Widget? _buildPayoutReceiptStrip(Map<String, dynamic> payment) {
    if (payment['type'] != 'rent_payout') return null;
    final rentalId = payment['relatedId'] as String?;
    if (rentalId == null || rentalId.isEmpty) return null;

    final state = payment['receiptState'] as String?;

    Widget wrap(Color color, IconData icon, String text, {Widget? action}) =>
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withAlpha(60)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
              if (action != null) ...[const SizedBox(height: 10), action],
            ],
          ),
        );

    switch (state) {
      case 'confirmed':
        return wrap(AppColors.success, Icons.verified,
            'You confirmed this payout arrived.');
      case 'disputed':
        return wrap(AppColors.warning, Icons.error_outline,
            'You reported this as never received. We\'re looking into it.');
      case 'resolved':
        final note = payment['receiptResolutionNote'] as String? ?? '';
        return wrap(
          AppColors.info,
          Icons.gavel,
          note.isEmpty ? 'This report has been resolved.' : note,
        );
      default:
        return wrap(
          AppColors.primary,
          Icons.help_outline,
          'Did this reach your bank account?',
          action: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _submitPayoutReceipt(rentalId, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withAlpha(90)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('No, it didn\'t'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _submitPayoutReceipt(rentalId, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Yes, received'),
                ),
              ),
            ],
          ),
        );
    }
  }

  /// Confirm, or collect a reason and dispute. Reloads on success so the strip
  /// reflects the new state — the payments list is a one-shot read.
  Future<void> _submitPayoutReceipt(String rentalId, bool received) async {
    String? reason;
    if (!received) {
      reason = await _askDisputeReason();
      // Cancelled the reason prompt — don't file a dispute they backed out of.
      if (reason == null || reason.trim().isEmpty) return;
    }

    try {
      await FirebaseFunctions.instance
          .httpsCallable('confirmPayoutReceipt')
          .call<Map<String, dynamic>>({
        'rentalId': rentalId,
        'action': received ? 'confirm' : 'dispute',
        if (!received) 'reason': reason!.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(received
              ? 'Thanks — payout confirmed.'
              : 'Reported. An admin will look into it.'),
          backgroundColor:
              received ? AppColors.success : AppColors.warning,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      await _loadData();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // The CF's failed-precondition messages are written for this user
          // ("You already confirmed this payout"), so show them as-is.
          content: Text(e.message ?? 'Could not record that. Try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } catch (e) {
      AppLogger.e('Payout receipt failed: $e', name: 'DocumentsScreen');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not record that. Try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<String?> _askDisputeReason() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Payout not received'),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tell us what you\'re seeing so an admin can trace the transfer.',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'e.g. Nothing has come into my GTBank account.',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Report'),
          ),
        ],
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
    final propertyTitle = payment['propertyTitle'] as String? ?? '';
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
                  if (propertyTitle.isNotEmpty) ...[
                    _receiptRow('Property', propertyTitle),
                    const SizedBox(height: 12),
                  ],
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
                  SharePlus.instance.share(ShareParams(text: receiptText));
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
      case 'rent_payout':
        return 'Rent Payout';
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
      case 'rent_payout':
        return Icons.account_balance_wallet_outlined;
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
      case 'rent_payout':
        return AppColors.success;
      default:
        return AppColors.textSecondary;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // DOCUMENT ACTIONS
  // ────────────────────────────────────────────────────────────────────

  // Agreements are private — resolve a short-lived signed URL via the CF
  // (which authorizes the caller as a party) before opening/sharing.
  Future<void> _viewAgreement(String collection, String docId) async {
    final url = await _agreementAccess.resolveUrl(
      collection: collection,
      docId: docId,
    );
    if (!mounted) return;
    if (url != null) {
      await _openDocument(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Could not open the agreement'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Future<void> _shareAgreement(
    String collection,
    String docId,
    String title,
  ) async {
    final url = await _agreementAccess.resolveUrl(
      collection: collection,
      docId: docId,
    );
    if (!mounted || url == null) return;
    await _shareDocument(url: url, title: title);
  }

  Future<void> _openDocument(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        // In-app browser (Chrome Custom Tab / Safari View Controller) so the
        // tenant views the agreement WITHOUT being thrown out to standalone
        // Chrome. Was LaunchMode.externalApplication.
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
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

  Future<void> _shareDocument({
    required String url,
    required String title,
  }) async {
    try {
      await SharePlus.instance.share(ShareParams(text: '$title\n$url'));
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