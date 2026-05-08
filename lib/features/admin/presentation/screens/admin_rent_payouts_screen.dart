import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../core/utils/app_logger.dart';

class AdminRentPayoutsScreen extends StatefulWidget {
  const AdminRentPayoutsScreen({super.key});

  @override
  State<AdminRentPayoutsScreen> createState() => _AdminRentPayoutsScreenState();
}

class _AdminRentPayoutsScreenState extends State<AdminRentPayoutsScreen>
    with SingleTickerProviderStateMixin {
  final ActiveRentalService _rentalService = ActiveRentalService();
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
        title: Text('Rent Payouts', style: AppTextStyles.h4),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          tabs: const [
            Tab(text: 'Landlord Payouts'),
            Tab(text: 'Agent Payouts'),
            Tab(text: 'Paid History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _PendingPayoutsTab(
            rentalService: _rentalService,
            payoutType: _PayoutType.landlord,
          ),
          _PendingPayoutsTab(
            rentalService: _rentalService,
            payoutType: _PayoutType.agent,
          ),
          _PaidHistoryTab(rentalService: _rentalService),
        ],
      ),
    );
  }
}

enum _PayoutType { landlord, agent }

// ════════════════════════════════════════════════════════════════
// PENDING PAYOUTS TAB
// ════════════════════════════════════════════════════════════════
class _PendingPayoutsTab extends StatelessWidget {
  final ActiveRentalService rentalService;
  final _PayoutType payoutType;

  const _PendingPayoutsTab({
    required this.rentalService,
    required this.payoutType,
  });

  @override
  Widget build(BuildContext context) {
    final stream = payoutType == _PayoutType.landlord
        ? rentalService.getPendingLandlordPayouts()
        : rentalService.getPendingAgentRentPayouts();

    return StreamBuilder<List<ActiveRental>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        if (snapshot.hasError) {
          AppLogger.e('Error loading payouts: ${snapshot.error}',
              name: 'RentPayouts');
          return _buildEmpty(
            Icons.error_outline,
            'Error Loading Payouts',
            'Check Firestore indexes. You may need a composite index for this query.',
          );
        }
        final rentals = snapshot.data ?? [];
        if (rentals.isEmpty) {
          return _buildEmpty(
            Icons.check_circle_outline,
            payoutType == _PayoutType.landlord
                ? 'No Pending Landlord Payouts'
                : 'No Pending Agent Payouts',
            'All payouts are up to date!',
          );
        }

        // Calculate totals
        double totalPending = 0;
        for (final r in rentals) {
          totalPending += payoutType == _PayoutType.landlord
              ? r.landlordPayout
              : r.agentPayout;
        }

        return Column(
          children: [
            // Summary bar
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.warning.withAlpha(77)),
              ),
              child: Row(
                children: [
                  Icon(Icons.pending_actions,
                      color: AppColors.warning, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${rentals.length} pending payout${rentals.length > 1 ? 's' : ''}',
                          style: AppTextStyles.labelMedium,
                        ),
                        Text(
                          'Total: ₦${NumberFormat('#,###').format(totalPending)}',
                          style: AppTextStyles.h4.copyWith(
                            color: AppColors.warning,
                            fontFamily: 'Roboto',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: rentals.length,
                itemBuilder: (context, index) => _RentPayoutCard(
                  rental: rentals[index],
                  rentalService: rentalService,
                  payoutType: payoutType,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmpty(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: AppColors.textHint),
          const SizedBox(height: 16),
          Text(title, style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              subtitle,
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// RENT PAYOUT CARD
// ════════════════════════════════════════════════════════════════
class _RentPayoutCard extends StatefulWidget {
  final ActiveRental rental;
  final ActiveRentalService rentalService;
  final _PayoutType payoutType;

  const _RentPayoutCard({
    required this.rental,
    required this.rentalService,
    required this.payoutType,
  });

  @override
  State<_RentPayoutCard> createState() => _RentPayoutCardState();
}

class _RentPayoutCardState extends State<_RentPayoutCard> {
  Map<String, dynamic>? _bankDetails;
  bool _isLoadingBank = true;
  bool _isMarking = false;

  String get _recipientId => widget.payoutType == _PayoutType.landlord
      ? widget.rental.landlordId
      : (widget.rental.toFirestore()['agentId'] as String? ?? '');

  String get _recipientName => widget.payoutType == _PayoutType.landlord
      ? widget.rental.landlordName
      : (_bankDetails?['fullName'] ?? 'Agent');

  String get _recipientLabel => widget.payoutType == _PayoutType.landlord
      ? 'Landlord'
      : 'Agent';

  double get _payoutAmount => widget.payoutType == _PayoutType.landlord
      ? widget.rental.landlordPayout
      : widget.rental.agentPayout;

  @override
  void initState() {
    super.initState();
    _loadBankDetails();
  }

  Future<void> _loadBankDetails() async {
    final id = _recipientId;
    if (id.isEmpty) {
      if (mounted) setState(() => _isLoadingBank = false);
      return;
    }
    final details = await widget.rentalService.getUserBankDetails(id);
    if (mounted) {
      setState(() {
        _bankDetails = details;
        _isLoadingBank = false;
      });
    }
  }

  Future<void> _callRecipient() async {
    final phone = _bankDetails?['phone'] as String?;
    if (phone == null || phone.isEmpty) {
      _snack('Phone number not available', AppColors.error);
      return;
    }
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _textRecipient() async {
    final phone = _bankDetails?['phone'] as String?;
    if (phone == null || phone.isEmpty) {
      _snack('Phone number not available', AppColors.error);
      return;
    }
    final amount = NumberFormat('#,###').format(_payoutAmount);
    final uri = Uri.parse(
      'sms:$phone?body=Hi $_recipientName, your ${widget.payoutType == _PayoutType.landlord ? 'rent' : 'agent fee'} '
      'payout of ₦$amount for ${widget.rental.propertyTitle} has been sent. '
      'Please confirm when received.',
    );
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _markAsPaid() async {
    final amount = NumberFormat('#,###').format(_payoutAmount);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Have you transferred ₦$amount to $_recipientName?'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: AppColors.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'A receipt will be created in their Documents screen and they\'ll receive a notification.',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.info),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
            ),
            child: const Text('Yes, I\'ve Paid'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isMarking = true);

    final ok = widget.payoutType == _PayoutType.landlord
        ? await widget.rentalService.markLandlordPaid(widget.rental.id)
        : await widget.rentalService.markAgentRentPaid(widget.rental.id);

    if (!mounted) return;
    setState(() => _isMarking = false);

    _snack(
      ok
          ? 'Marked as paid! Receipt created for $_recipientLabel.'
          : 'Failed to update. Try again.',
      ok ? AppColors.success : AppColors.error,
    );
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _snack('$label copied!', AppColors.primary);
  }

  String _formatDate(DateTime date) {
    return DateFormat('d MMM y').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rental;
    final amount = NumberFormat('#,###').format(_payoutAmount);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Type badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: widget.payoutType == _PayoutType.landlord
                  ? AppColors.primary.withAlpha(26)
                  : AppColors.info.withAlpha(26),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.payoutType == _PayoutType.landlord
                      ? Icons.person
                      : Icons.support_agent,
                  size: 12,
                  color: widget.payoutType == _PayoutType.landlord
                      ? AppColors.primary
                      : AppColors.info,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.payoutType == _PayoutType.landlord
                      ? 'LANDLORD RENT PAYOUT'
                      : 'AGENT FEE PAYOUT',
                  style: AppTextStyles.caption.copyWith(
                    color: widget.payoutType == _PayoutType.landlord
                        ? AppColors.primary
                        : AppColors.info,
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          // Property + amount
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: r.propertyImage.isNotEmpty
                    ? Image.network(
                        r.propertyImage,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.propertyTitle,
                        style: AppTextStyles.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(r.propertyAddress,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '₦$amount',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),

          // Recipient info
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.success.withAlpha(26),
                child: Icon(
                  widget.payoutType == _PayoutType.landlord
                      ? Icons.person
                      : Icons.support_agent,
                  size: 18,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_recipientName, style: AppTextStyles.labelMedium),
                    Text(_recipientLabel,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              IconButton(
                onPressed: _callRecipient,
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child:
                      Icon(Icons.phone, color: AppColors.success, size: 16),
                ),
              ),
              IconButton(
                onPressed: _textRecipient,
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child:
                      Icon(Icons.sms, color: AppColors.primary, size: 16),
                ),
              ),
            ],
          ),

          // Bank details
          const SizedBox(height: 12),
          if (_isLoadingBank)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  const Text('Loading bank details...'),
                ],
              ),
            )
          else if (_bankDetails != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.account_balance,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text('Bank Details',
                          style: AppTextStyles.labelSmall.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          )),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if ((_bankDetails!['bankName'] ?? '').toString().isNotEmpty)
                    _bankDetailRow('Bank', _bankDetails!['bankName']),
                  if ((_bankDetails!['accountName'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _bankDetailRow('Account Name', _bankDetails!['accountName']),
                  ],
                  if ((_bankDetails!['accountNumber'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => _copyToClipboard(
                          _bankDetails!['accountNumber'], 'Account number'),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text('Account No.',
                                style: AppTextStyles.caption
                                    .copyWith(color: AppColors.textSecondary)),
                          ),
                          Expanded(
                            child: Text(
                              _bankDetails!['accountNumber'],
                              style: AppTextStyles.labelMedium.copyWith(
                                fontFamily: 'monospace',
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                          Icon(Icons.copy, size: 14, color: AppColors.primary),
                        ],
                      ),
                    ),
                  ],
                  if ((_bankDetails!['bankName'] ?? '').toString().isEmpty &&
                      (_bankDetails!['accountNumber'] ?? '').toString().isEmpty)
                    Row(
                      children: [
                        Icon(Icons.warning_amber,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No bank details saved. Contact the $_recipientLabel to get their bank info.',
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.warning),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ] else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber,
                      size: 16, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Could not load bank details. Call or text to get payment info.',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.warning),
                    ),
                  ),
                ],
              ),
            ),

          // Fee breakdown
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Deal Breakdown',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.info,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 6),
                _breakdownRow('Total paid by tenant',
                    '₦${NumberFormat('#,###').format(r.totalPaid)}'),
                _breakdownRow('Rent amount',
                    '₦${NumberFormat('#,###').format(r.rentAmount)}'),
                if (r.agentFee > 0)
                  _breakdownRow('Agent fee',
                      '₦${NumberFormat('#,###').format(r.agentFee)}'),
                const Divider(height: 12),
                _breakdownRow('Landlord payout',
                    '₦${NumberFormat('#,###').format(r.landlordPayout)}',
                    highlight: widget.payoutType == _PayoutType.landlord),
                if (r.agentPayout > 0)
                  _breakdownRow('Agent payout',
                      '₦${NumberFormat('#,###').format(r.agentPayout)}',
                      highlight: widget.payoutType == _PayoutType.agent),
                _breakdownRow('ClearRent earnings',
                    '₦${NumberFormat('#,###').format(r.clearrentEarnings)}'),
              ],
            ),
          ),

          // Tenant + date info
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.person_outline,
                  size: 14, color: AppColors.textHint),
              const SizedBox(width: 6),
              Text('Tenant: ${r.tenantName}',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
              const Spacer(),
              Icon(Icons.calendar_today_outlined,
                  size: 12, color: AppColors.textHint),
              const SizedBox(width: 4),
              Text(_formatDate(r.createdAt),
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint, fontSize: 11)),
            ],
          ),

          // Mark as paid button
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isMarking ? null : _markAsPaid,
              icon: _isMarking
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle, size: 20),
              label: Text(_isMarking
                  ? 'Processing...'
                  : 'Mark as Paid (₦$amount)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bankDetailRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary)),
        ),
        Expanded(
          child: Text(value, style: AppTextStyles.labelSmall),
        ),
      ],
    );
  }

  Widget _breakdownRow(String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: highlight
                  ? AppTextStyles.labelSmall
                      .copyWith(color: AppColors.success)
                  : AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary, fontSize: 11)),
          Text(value,
              style: highlight
                  ? AppTextStyles.labelSmall.copyWith(
                      color: AppColors.success,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Roboto')
                  : AppTextStyles.caption
                      .copyWith(fontSize: 11, fontFamily: 'Roboto')),
        ],
      ),
    );
  }

  Widget _placeholder() => Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.home, size: 24, color: AppColors.textHint),
      );
}

// ════════════════════════════════════════════════════════════════
// PAID HISTORY TAB
// ════════════════════════════════════════════════════════════════
class _PaidHistoryTab extends StatelessWidget {
  final ActiveRentalService rentalService;
  const _PaidHistoryTab({required this.rentalService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ActiveRental>>(
      stream: rentalService.getCompletedRentPayouts(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        final rentals = snapshot.data ?? [];
        if (rentals.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.history, size: 64, color: AppColors.textHint),
                const SizedBox(height: 16),
                Text('No Payment History', style: AppTextStyles.h4),
                const SizedBox(height: 8),
                Text(
                  'Completed rent payouts will appear here.',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: rentals.length,
          itemBuilder: (context, index) {
            final r = rentals[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(26),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.check_circle,
                        color: AppColors.success, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.propertyTitle,
                            style: AppTextStyles.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          '${r.landlordName} • ${r.tenantName}',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                        if (r.landlordPaidAt != null)
                          Text(
                            'Paid ${DateFormat('d MMM y').format(r.landlordPaidAt!)}',
                            style: AppTextStyles.caption.copyWith(
                                color: AppColors.textHint, fontSize: 10),
                          ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₦${NumberFormat('#,###').format(r.landlordPayout)}',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.success,
                          fontFamily: 'Roboto',
                        ),
                      ),
                      if (r.agentPayout > 0)
                        Text(
                          '+₦${NumberFormat('#,###').format(r.agentPayout)} agent',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textHint,
                            fontSize: 10,
                            fontFamily: 'Roboto',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}