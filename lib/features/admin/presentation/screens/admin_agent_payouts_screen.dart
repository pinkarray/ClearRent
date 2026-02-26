import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../services/inspection_service.dart';
import '../../../../core/utils/inspection_pricing.dart';

class AdminAgentPayoutsScreen extends StatefulWidget {
  const AdminAgentPayoutsScreen({super.key});

  @override
  State<AdminAgentPayoutsScreen> createState() =>
      _AdminAgentPayoutsScreenState();
}

class _AdminAgentPayoutsScreenState extends State<AdminAgentPayoutsScreen>
    with SingleTickerProviderStateMixin {
  final InspectionService _inspectionService = InspectionService();
  late TabController _tabController;

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
        title: const Text('Handler Payouts', style: AppTextStyles.h4),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          tabs: const [
            Tab(text: 'Pending'),
            Tab(text: 'Paid'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _PendingPayoutsTab(inspectionService: _inspectionService),
          _PaidPayoutsTab(inspectionService: _inspectionService),
        ],
      ),
    );
  }
}

// ============================================================
// PENDING PAYOUTS TAB
// ============================================================
class _PendingPayoutsTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _PendingPayoutsTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getPendingAgentPayouts(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        if (snapshot.hasError) {
          developer.log(
            '❌ Error loading pending payouts: ${snapshot.error}',
            name: 'AdminPayouts',
          );
          return _buildEmpty(
            Icons.error_outline,
            'Error Loading Payouts',
            'Check Firestore indexes. You may need to create a composite index.',
          );
        }

        final requests = snapshot.data ?? [];
        if (requests.isEmpty) {
          return _buildEmpty(
            Icons.check_circle_outline,
            'No Pending Payouts',
            'All handlers have been paid!',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: requests.length,
          itemBuilder: (context, index) => _PayoutCard(
            request: requests[index],
            inspectionService: inspectionService,
          ),
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
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PAID PAYOUTS TAB
// ============================================================
class _PaidPayoutsTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _PaidPayoutsTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getPaidAgentPayouts(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final requests = snapshot.data ?? [];
        if (requests.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.history, size: 64, color: AppColors.textHint),
                const SizedBox(height: 16),
                const Text('No Payment History', style: AppTextStyles.h4),
                const SizedBox(height: 8),
                Text(
                  'Completed payouts will appear here.',
                  style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: requests.length,
          itemBuilder: (context, index) => _PaidCard(request: requests[index]),
        );
      },
    );
  }
}

// ============================================================
// PENDING PAYOUT CARD — handler-agnostic (agent OR landlord)
// ============================================================
class _PayoutCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;

  const _PayoutCard({required this.request, required this.inspectionService});

  @override
  State<_PayoutCard> createState() => _PayoutCardState();
}

class _PayoutCardState extends State<_PayoutCard> {
  Map<String, dynamic>? _bankDetails;
  bool _isLoadingBank = true;
  bool _isMarking = false;

  // Handler info — agent or landlord
  bool get _isAgentHandled => widget.request.isAgentHandled;
  String get _handlerName => _isAgentHandled
      ? (widget.request.agentName ?? 'Agent')
      : widget.request.landlordName;
  String get _handlerLabel =>
      _isAgentHandled ? 'Agent' : 'Landlord (Self-handled)';
  IconData get _handlerIcon =>
      _isAgentHandled ? Icons.support_agent : Icons.person;
  String? get _handlerId =>
      _isAgentHandled ? widget.request.agentId : widget.request.landlordId;
  String? get _handlerPhone => _bankDetails?['agentPhone'] ??
      (_isAgentHandled
          ? widget.request.agentPhone
          : widget.request.landlordPhone);

  @override
  void initState() {
    super.initState();
    _loadBankDetails();
  }

  Future<void> _loadBankDetails() async {
    final id = _handlerId;
    if (id == null) {
      if (mounted) setState(() => _isLoadingBank = false);
      return;
    }
    final details =
        await widget.inspectionService.getAgentBankDetails(id);
    if (mounted) {
      setState(() {
        _bankDetails = details;
        _isLoadingBank = false;
      });
    }
  }

  Future<void> _callHandler() async {
    final phone = _handlerPhone;
    if (phone == null || phone.toString().isEmpty) {
      _snack('Phone number not available', AppColors.error);
      return;
    }
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _textHandler() async {
    final phone = _handlerPhone;
    if (phone == null || phone.toString().isEmpty) {
      _snack('Phone number not available', AppColors.error);
      return;
    }
    final uri = Uri.parse(
      'sms:$phone?body=Hi $_handlerName, your payment of '
      '${InspectionPricing.formatNaira(widget.request.agentEarnings)} '
      'for the inspection at ${widget.request.propertyTitle} has been sent. '
      'Please confirm when received.',
    );
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _markAsPaid() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Have you transferred '
              '${InspectionPricing.formatNaira(widget.request.agentEarnings)} '
              'to $_handlerName?',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: AppColors.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isAgentHandled
                          ? 'The agent will be notified and asked to confirm receipt.'
                          : 'The landlord will be notified and asked to confirm receipt.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.info),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
    final ok =
        await widget.inspectionService.markAgentPaid(widget.request.id);
    if (!mounted) return;
    setState(() => _isMarking = false);

    _snack(
      ok
          ? 'Marked as paid! They\'ll be asked to confirm.'
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

  @override
  Widget build(BuildContext context) {
    final r = widget.request;

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
          // Handler type badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: _isAgentHandled
                  ? AppColors.info.withAlpha(26)
                  : AppColors.primary.withAlpha(26),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _handlerIcon,
                  size: 12,
                  color: _isAgentHandled ? AppColors.info : AppColors.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  _isAgentHandled ? 'AGENT HANDLED' : 'LANDLORD SELF-HANDLED',
                  style: AppTextStyles.caption.copyWith(
                    color:
                        _isAgentHandled ? AppColors.info : AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          // Header — property + amount
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
              // Amount badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  InspectionPricing.formatNaira(r.agentEarnings),
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),

          // Handler info
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.success.withAlpha(26),
                child: Icon(_handlerIcon, size: 18, color: AppColors.success),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_handlerName, style: AppTextStyles.labelMedium),
                    Text(_handlerLabel,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              // Call button
              IconButton(
                onPressed: _callHandler,
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.phone,
                      color: AppColors.success, size: 16),
                ),
                tooltip: 'Call ${_isAgentHandled ? "agent" : "landlord"}',
              ),
              // Text button
              IconButton(
                onPressed: _textHandler,
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sms,
                      color: AppColors.primary, size: 16),
                ),
                tooltip: 'Text ${_isAgentHandled ? "agent" : "landlord"}',
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
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                  SizedBox(width: 10),
                  Text('Loading bank details...'),
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
                      const Icon(Icons.account_balance,
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

                  // Bank name
                  if (_bankDetails!['bankName'] != null &&
                      _bankDetails!['bankName'].toString().isNotEmpty) ...[
                    _bankDetailRow('Bank', _bankDetails!['bankName']),
                    const SizedBox(height: 6),
                  ],

                  // Account name
                  if (_bankDetails!['accountName'] != null &&
                      _bankDetails!['accountName']
                          .toString()
                          .isNotEmpty) ...[
                    _bankDetailRow(
                        'Account Name', _bankDetails!['accountName']),
                    const SizedBox(height: 6),
                  ],

                  // Account number — tappable to copy
                  if (_bankDetails!['accountNumber'] != null &&
                      _bankDetails!['accountNumber'].toString().isNotEmpty)
                    GestureDetector(
                      onTap: () => _copyToClipboard(
                        _bankDetails!['accountNumber'],
                        'Account number',
                      ),
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
                          const Icon(Icons.copy,
                              size: 14, color: AppColors.primary),
                        ],
                      ),
                    ),

                  // No bank details warning
                  if ((_bankDetails!['bankName'] == null ||
                          _bankDetails!['bankName'].toString().isEmpty) &&
                      (_bankDetails!['accountNumber'] == null ||
                          _bankDetails!['accountNumber']
                              .toString()
                              .isEmpty))
                    Row(
                      children: [
                        const Icon(Icons.warning_amber,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No bank details saved. Contact the '
                            '${_isAgentHandled ? "agent" : "landlord"} '
                            'to get their bank info.',
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.warning),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ] else ...[
            // Bank details failed to load
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber,
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
          ],

          // Fee breakdown
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Fee Breakdown',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.info,
                            fontWeight: FontWeight.w600,
                          )),
                      const SizedBox(height: 4),
                      Text(
                        'Total paid: ${InspectionPricing.formatNaira(r.totalFee)} • '
                        '${_isAgentHandled ? "Agent" : "Landlord"}: '
                        '${InspectionPricing.formatNaira(r.agentEarnings)} • '
                        'ClearRent: ${InspectionPricing.formatNaira(r.clearrentFee)}',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Completed date + tenant
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.check_circle,
                  size: 14, color: AppColors.success),
              const SizedBox(width: 6),
              Text(
                'Completed ${_formatDate(r.completedAt)}',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
              const Spacer(),
              Text(
                'Tenant: ${r.tenantName}',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),

          // Mark as Paid button
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isMarking ? null : _markAsPaid,
              icon: _isMarking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.payments, size: 20),
              label: Text(_isMarking
                  ? 'Processing...'
                  : 'Mark as Paid — ${InspectionPricing.formatNaira(r.agentEarnings)}'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
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

  Widget _placeholder() => Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.home, color: AppColors.textHint, size: 24),
      );

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}

// ============================================================
// PAID CARD — history view (handler-agnostic)
// ============================================================
class _PaidCard extends StatelessWidget {
  final InspectionRequest request;
  const _PaidCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final r = request;
    final confirmed = r.agentConfirmedPayment;
    final isAgent = r.isAgentHandled;
    final handlerName =
        isAgent ? (r.agentName ?? 'Agent') : r.landlordName;
    final handlerLabel = isAgent ? 'Agent' : 'Landlord';
    final handlerIcon = isAgent ? Icons.support_agent : Icons.person;
    final awaitingText = isAgent
        ? 'Awaiting agent confirmation'
        : 'Awaiting landlord confirmation';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: confirmed
              ? AppColors.success.withAlpha(77)
              : AppColors.warning.withAlpha(77),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: confirmed
                ? AppColors.success.withAlpha(26)
                : AppColors.warning.withAlpha(26),
            child: Icon(
              confirmed ? Icons.check_circle : handlerIcon,
              size: 18,
              color: confirmed ? AppColors.success : AppColors.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(handlerName,
                          style: AppTextStyles.labelMedium,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isAgent
                            ? AppColors.info.withAlpha(26)
                            : AppColors.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        handlerLabel,
                        style: AppTextStyles.caption.copyWith(
                          color:
                              isAgent ? AppColors.info : AppColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  r.propertyTitle,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  confirmed ? 'Confirmed received ✓' : awaitingText,
                  style: AppTextStyles.caption.copyWith(
                    color: confirmed ? AppColors.success : AppColors.warning,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                InspectionPricing.formatNaira(r.agentEarnings),
                style: AppTextStyles.labelMedium
                    .copyWith(color: AppColors.success),
              ),
              if (r.agentPaidAt != null)
                Text(
                  _formatDate(r.agentPaidAt),
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textHint,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}';
  }
}