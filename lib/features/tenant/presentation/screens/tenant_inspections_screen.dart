import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/property_service.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/rental_interest_service.dart';

class TenantInspectionsScreen extends StatefulWidget {
  const TenantInspectionsScreen({super.key});

  @override
  State<TenantInspectionsScreen> createState() =>
      _TenantInspectionsScreenState();
}

class _TenantInspectionsScreenState extends State<TenantInspectionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final InspectionService _inspectionService = InspectionService();

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
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.go('/tenant/home'),
        ),
        title: Text('My Inspections', style: AppTextStyles.h4),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          tabs: const [
            Tab(text: 'Pending'),
            Tab(text: 'Upcoming'),
            Tab(text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _TenantPendingTab(inspectionService: _inspectionService),
          _TenantUpcomingTab(inspectionService: _inspectionService),
          _TenantHistoryTab(inspectionService: _inspectionService),
        ],
      ),
    );
  }
}

// ============================================================
// PENDING REQUESTS TAB
// ============================================================
class _TenantPendingTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _TenantPendingTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getTenantRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        if (snapshot.hasError) {
          developer.log('❌ Error: ${snapshot.error}',
              name: 'TenantInspections');
          return const _EmptyState(
            icon: Icons.error_outline,
            title: 'Error loading requests',
            subtitle: 'Please try again later',
          );
        }

        final allRequests = snapshot.data ?? [];
        final pending = allRequests
            .where((r) =>
                r.isPending ||
                r.isPendingPayment ||
                r.isPendingVerification ||
                r.isDeclinedByAgent)
            .toList();

        if (pending.isEmpty) {
          return _EmptyState(
            icon: Icons.inbox_outlined,
            title: 'No pending requests',
            subtitle: 'Your inspection requests will appear here',
            actionLabel: 'Browse Properties',
            onAction: () => context.go('/tenant/home'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: pending.length,
          itemBuilder: (context, index) => _TenantPendingCard(
            request: pending[index],
            inspectionService: inspectionService,
          ),
        );
      },
    );
  }
}

class _TenantPendingCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  const _TenantPendingCard(
      {required this.request, required this.inspectionService});

  @override
  State<_TenantPendingCard> createState() => _TenantPendingCardState();
}

class _TenantPendingCardState extends State<_TenantPendingCard> {
  final ConversationService _conversationService = ConversationService();
  bool _isLoading = false;
  bool _isMessageLoading = false;

  Future<void> _cancelRequest() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Request'),
        content: Text(widget.request.isPaid
            ? 'Are you sure? Your payment will be refunded.'
            : 'Are you sure you want to cancel this request?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('No, Keep It',
                  style: TextStyle(color: AppColors.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  Text('Yes, Cancel', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _isLoading = true);
    final success =
        await widget.inspectionService.cancelRequest(widget.request.id);
    if (!mounted) return;
    setState(() => _isLoading = false);

    _showSnack(
      success
          ? (widget.request.isPaid
              ? 'Request cancelled. Refund will be processed.'
              : 'Request cancelled.')
          : 'Failed to cancel. Please try again.',
      success ? AppColors.success : AppColors.error,
    );
  }

  Future<void> _messageHandler() async {
    final r = widget.request;
    final recipientId = r.isAgentHandled ? r.agentId : r.landlordId;
    if (recipientId == null) {
      _showSnack('Contact not available', AppColors.error);
      return;
    }
    setState(() => _isMessageLoading = true);
    try {
      final conv = await _conversationService.getOrCreateConversation(
        propertyId: r.propertyId,
        propertyTitle: r.propertyTitle,
        propertyImage: r.propertyImage,
        landlordId: r.landlordId,
        landlordName: r.landlordName,
        tenantId: r.tenantId,
        tenantName: r.tenantName,
        agentId: r.agentId,
        agentName: r.agentName,
      );
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': r.propertyTitle,
          'propertyImage':
              r.propertyImage.isNotEmpty ? r.propertyImage : null,
        });
      } else {
        _showSnack(
            'Could not start conversation. Both parties must be verified.',
            AppColors.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      _showSnack('Failed to start conversation', AppColors.error);
    }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;

    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (r.isPendingPayment) {
      statusText = 'Awaiting Payment';
      statusColor = AppColors.warning;
      statusIcon = Icons.payment;
    } else if (r.isPendingVerification) {
      statusText = 'Verifying Payment';
      statusColor = AppColors.info;
      statusIcon = Icons.hourglass_top;
    } else if (r.isDeclinedByAgent) {
      statusText = 'Under Review';
      statusColor = AppColors.info;
      statusIcon = Icons.hourglass_top;
    } else {
      statusText = 'Awaiting Response';
      statusColor = AppColors.primary;
      statusIcon = Icons.schedule;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(13),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: statusColor.withAlpha(26),
                borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(statusIcon, size: 16, color: statusColor),
              const SizedBox(width: 6),
              Text(statusText,
                  style: AppTextStyles.labelSmall.copyWith(
                      color: statusColor, fontWeight: FontWeight.w600)),
            ]),
          ),
          const SizedBox(height: 12),

          // Property info
          Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: r.propertyImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: r.propertyImage,
                      width: 70,
                      height: 70,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _propertyPlaceholder())
                  : _propertyPlaceholder(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.propertyTitle,
                        style: AppTextStyles.labelLarge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.location_on_outlined,
                          size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                          child: Text(r.propertyAddress,
                              style: AppTextStyles.caption
                                  .copyWith(color: AppColors.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis)),
                    ]),
                  ]),
            ),
          ]),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Date / time
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Icon(Icons.calendar_today_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(r.formattedDate,
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.primary)),
                    Text(r.requestedTimeDisplay,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary)),
                  ])),
            ]),
          ),

          // Handler
          const SizedBox(height: 12),
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: r.isAgentHandled
                  ? AppColors.success.withAlpha(26)
                  : AppColors.primary.withAlpha(26),
              child: Icon(
                  r.isAgentHandled ? Icons.support_agent : Icons.person,
                  size: 16,
                  color: r.isAgentHandled
                      ? AppColors.success
                      : AppColors.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      r.isAgentHandled
                          ? (r.agentName ?? 'Agent')
                          : r.landlordName,
                      style: AppTextStyles.labelMedium),
                  Text(
                      r.isAgentHandled
                          ? 'Will conduct inspection'
                          : 'Landlord',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary)),
                ])),
            IconButton(
              onPressed: _isMessageLoading ? null : _messageHandler,
              icon: _isMessageLoading
                  ? SizedBox(
                      width: 32,
                      height: 32,
                      child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.primary)))
                  : Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(26),
                          shape: BoxShape.circle),
                      child: Icon(Icons.chat_outlined,
                          color: AppColors.primary, size: 16)),
            ),
          ]),

          // Notes
          if (r.notes != null && r.notes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10)),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.note_outlined,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(r.notes!,
                            style: AppTextStyles.bodySmall
                                .copyWith(color: AppColors.textSecondary))),
                  ]),
            ),
          ],
          const SizedBox(height: 16),

          // Actions
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isLoading ? null : _cancelRequest,
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Cancel Request',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.textSecondary)),
              ),
            ),
            if (r.isPendingPayment) ...[
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(
                    text: 'Pay Now',
                    onPressed: () =>
                        context.push('/tenant/inspection-payment/${r.id}')),
              ),
            ],
          ]),
        ],
      ),
    );
  }

  Widget _propertyPlaceholder() => Container(
      width: 70,
      height: 70,
      color: AppColors.background,
      child: Icon(Icons.home, color: AppColors.textHint));
}

// ============================================================
// UPCOMING TAB
// ============================================================
class _TenantUpcomingTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _TenantUpcomingTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getTenantRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        final all = snapshot.data ?? [];
        final upcoming = all.where((r) => r.isApproved).toList()
          ..sort((a, b) => a.requestedDate.compareTo(b.requestedDate));

        if (upcoming.isEmpty) {
          return const _EmptyState(
              icon: Icons.event_available_outlined,
              title: 'No upcoming inspections',
              subtitle: 'Approved inspections will appear here');
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: upcoming.length,
          itemBuilder: (context, i) =>
              _TenantUpcomingCard(request: upcoming[i]),
        );
      },
    );
  }
}

class _TenantUpcomingCard extends StatefulWidget {
  final InspectionRequest request;
  const _TenantUpcomingCard({required this.request});

  @override
  State<_TenantUpcomingCard> createState() => _TenantUpcomingCardState();
}

class _TenantUpcomingCardState extends State<_TenantUpcomingCard> {
  final ConversationService _conversationService = ConversationService();
  bool _isMessageLoading = false;

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  bool _isTomorrow(DateTime d) {
    final t = DateTime.now().add(const Duration(days: 1));
    return d.year == t.year && d.month == t.month && d.day == t.day;
  }

  String _monthAbbr(int m) =>
      const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][m - 1];

  Future<void> _callHandler() async {
    final phone = widget.request.isAgentHandled
        ? widget.request.agentPhone
        : widget.request.landlordPhone;
    if (phone == null || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Phone number not available'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
      return;
    }
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _messageHandler() async {
    final r = widget.request;
    setState(() => _isMessageLoading = true);
    try {
      final conv = await _conversationService.getOrCreateConversation(
        propertyId: r.propertyId,
        propertyTitle: r.propertyTitle,
        propertyImage: r.propertyImage,
        landlordId: r.landlordId,
        landlordName: r.landlordName,
        tenantId: r.tenantId,
        tenantName: r.tenantName,
        agentId: r.agentId,
        agentName: r.agentName,
      );
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': r.propertyTitle,
          'propertyImage':
              r.propertyImage.isNotEmpty ? r.propertyImage : null,
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final today = _isToday(r.requestedDate);
    final tomorrow = _isTomorrow(r.requestedDate);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: today
                ? AppColors.primary
                : AppColors.success.withAlpha(77),
            width: today ? 2 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Date badges
        Row(children: [
          if (today)
            _badge('TODAY', AppColors.primary, Icons.today)
          else if (tomorrow)
            _badge('TOMORROW', AppColors.info, Icons.upcoming),
          _badge('Approved', AppColors.success, Icons.check_circle),
        ]),
        const SizedBox(height: 12),

        // Property + date
        Row(children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: (today ? AppColors.primary : AppColors.success)
                    .withAlpha(26),
                borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              Text('${r.requestedDate.day}',
                  style: AppTextStyles.h3.copyWith(
                      color:
                          today ? AppColors.primary : AppColors.success)),
              Text(_monthAbbr(r.requestedDate.month),
                  style: AppTextStyles.caption.copyWith(
                      color:
                          today ? AppColors.primary : AppColors.success)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(r.propertyTitle, style: AppTextStyles.labelLarge),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.access_time,
                      size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(r.requestedTimeDisplay,
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.textSecondary)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Icon(Icons.location_on_outlined,
                      size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                      child: Text(r.propertyAddress,
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                ]),
              ])),
        ]),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // Handler contact
        Row(children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: r.isAgentHandled
                ? AppColors.success.withAlpha(26)
                : AppColors.primary.withAlpha(26),
            child: Icon(
                r.isAgentHandled ? Icons.support_agent : Icons.person,
                size: 20,
                color: r.isAgentHandled
                    ? AppColors.success
                    : AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    r.isAgentHandled
                        ? (r.agentName ?? 'Agent')
                        : r.landlordName,
                    style: AppTextStyles.labelMedium),
                Text(
                    r.isAgentHandled
                        ? 'Agent â€¢ Will show you the property'
                        : 'Landlord',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ])),
          _iconBtn(Icons.chat_outlined, AppColors.primary,
              _isMessageLoading ? null : _messageHandler, _isMessageLoading),
          _iconBtn(
              Icons.phone, AppColors.success, _callHandler, false),
        ]),

        // Tip for today
        if (today) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.primary.withAlpha(51))),
            child: Row(children: [
              Icon(Icons.info_outline,
                  size: 20, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      'Remember to bring a valid ID and arrive 5 minutes early!',
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.primary))),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _badge(String text, Color color, IconData icon) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: color == AppColors.success
                ? color.withAlpha(26)
                : color,
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 16,
              color: color == AppColors.success ? color : Colors.white),
          const SizedBox(width: 6),
          Text(text,
              style: AppTextStyles.labelSmall.copyWith(
                  color: color == AppColors.success ? color : Colors.white,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _iconBtn(
          IconData icon, Color color, VoidCallback? onTap, bool loading) =>
      IconButton(
        onPressed: onTap,
        icon: loading
            ? SizedBox(
                width: 34,
                height: 34,
                child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color)))
            : Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: color.withAlpha(26), shape: BoxShape.circle),
                child: Icon(icon, color: color, size: 18)),
      );
}

// ============================================================
// HISTORY TAB â€” MANDATORY RATING + INTEREST FLOW
// ============================================================
class _TenantHistoryTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _TenantHistoryTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getTenantRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        final all = snapshot.data ?? [];
        final history = all
            .where((r) =>
                r.isCompleted ||
                r.isDeclined ||
                r.isCancelled ||
                r.isRefunded)
            .toList()
          ..sort((a, b) {
            // Unrated completed first
            if (a.isCompleted &&
                !a.tenantRated &&
                !(b.isCompleted && !b.tenantRated)) {
              return -1;
            }
            if (b.isCompleted &&
                !b.tenantRated &&
                !(a.isCompleted && !a.tenantRated)) {
              return 1;
            }
            return (b.completedAt ?? b.createdAt)
                .compareTo(a.completedAt ?? a.createdAt);
          });

        if (history.isEmpty) {
          return const _EmptyState(
              icon: Icons.history,
              title: 'No history yet',
              subtitle: 'Your past inspections will appear here');
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: history.length,
          itemBuilder: (context, i) => _TenantHistoryCard(
              request: history[i], inspectionService: inspectionService),
        );
      },
    );
  }
}

class _TenantHistoryCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  const _TenantHistoryCard(
      {required this.request, required this.inspectionService});

  @override
  State<_TenantHistoryCard> createState() => _TenantHistoryCardState();
}

class _TenantHistoryCardState extends State<_TenantHistoryCard> {
  final RentalInterestService _rentalInterestService =
      RentalInterestService();
  RentalInterest? _rentalInterest;
  bool _isLoadingInterest = false;
  bool _hasCheckedInterest = false;
  bool _hasPassed = false; // true after tenant taps "I'll Keep Looking"

  @override
  void initState() {
    super.initState();
    if (widget.request.isCompleted && widget.request.tenantRated) {
      _loadRentalInterest();
    }
  }

  Future<void> _loadRentalInterest() async {
    setState(() => _isLoadingInterest = true);
    try {
      final interest = await _rentalInterestService
          .getInterestForInspection(widget.request.id);
      if (mounted) {
        setState(() {
          _rentalInterest = interest;
          _isLoadingInterest = false;
          _hasCheckedInterest = true;
        });
      }
    } catch (e) {
      developer.log('❌ Error loading rental interest: $e',
          name: 'TenantHistory');
      if (mounted) {
        setState(
            () { _isLoadingInterest = false; _hasCheckedInterest = true; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;

    Color statusColor;
    IconData statusIcon;
    String statusText;

    if (r.isCompleted) {
      statusColor = AppColors.success;
      statusIcon = Icons.check_circle;
      statusText = 'Completed';
    } else if (r.isDeclined) {
      statusColor = AppColors.error;
      statusIcon = Icons.cancel;
      statusText = 'Declined';
    } else if (r.isCancelled) {
      statusColor = AppColors.textSecondary;
      statusIcon = Icons.block;
      statusText = 'Cancelled';
    } else if (r.isRefunded) {
      statusColor = AppColors.info;
      statusIcon = Icons.replay;
      statusText = 'Refunded';
    } else {
      statusColor = AppColors.textHint;
      statusIcon = Icons.help_outline;
      statusText = r.statusDisplay;
    }

    final needsRating = r.isCompleted && !r.tenantRated;
    final needsDecision = r.isCompleted &&
        r.tenantRated &&
        _hasCheckedInterest &&
        _rentalInterest == null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: needsRating
            ? Border.all(color: AppColors.warning, width: 2)
            : needsDecision
                ? Border.all(color: AppColors.primary, width: 1.5)
                : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // âš¡ ACTION REQUIRED BANNER
        if (needsRating) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withAlpha(77))),
            child: Row(children: [
              Icon(Icons.bolt, size: 20, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('ACTION REQUIRED',
                        style: AppTextStyles.labelSmall.copyWith(
                            color: AppColors.warning,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('Rate your inspection to unlock next steps',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary)),
                  ])),
            ]),
          ),
          const SizedBox(height: 12),
        ],

        // Property row
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: r.propertyImage.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: r.propertyImage,
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                        width: 50,
                        height: 50,
                        color: AppColors.background,
                        child: Icon(Icons.home,
                            color: AppColors.textHint, size: 24)))
                : Container(
                    width: 50,
                    height: 50,
                    color: AppColors.background,
                    child: Icon(Icons.home,
                        color: AppColors.textHint, size: 24)),
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
                Text(r.formattedDate,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: statusColor.withAlpha(26),
                borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(statusIcon, size: 14, color: statusColor),
              const SizedBox(width: 4),
              Text(statusText,
                  style:
                      AppTextStyles.labelSmall.copyWith(color: statusColor)),
            ]),
          ),
        ]),

        // Decline reason
        if (r.isDeclined &&
            r.declineReason != null &&
            r.declineReason!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: AppColors.error.withAlpha(13),
                borderRadius: BorderRadius.circular(8)),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: AppColors.error),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(r.declineReason!,
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.error))),
                ]),
          ),
        ],

        // ============ RATING SECTION (ALL completed, not just agent-handled) ============
        if (r.isCompleted) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          if (r.tenantRated && r.tenantRating != null)
            Row(children: [
              Text('Your rating: ', style: AppTextStyles.bodySmall),
              ...List.generate(
                  5,
                  (i) => Icon(
                      i < r.tenantRating! ? Icons.star : Icons.star_border,
                      size: 18,
                      color: AppColors.warning)),
            ])
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showRatingDialog(),
                icon: const Icon(Icons.star, size: 20),
                label: const Text('Rate Your Experience'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
              ),
            ),
        ],

        // ============ DECISION SECTION ============
        if (r.isCompleted &&
            r.tenantRated &&
            _hasCheckedInterest &&
            _rentalInterest == null &&
            !_hasPassed) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withAlpha(51))),
            child: Column(children: [
              Text('What\'s your decision?',
                  style: AppTextStyles.labelLarge
                      .copyWith(color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text('Would you like to rent this property?',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              SizedBox(
                  width: double.infinity,
                  child: AppButton(
                      text: 'I Want to Rent This Property',
                      onPressed: () => _expressInterest())),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _passOnProperty(),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10))),
                  child: Text('I\'ll Keep Looking',
                      style: AppTextStyles.labelMedium
                          .copyWith(color: AppColors.textSecondary)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                  'Note: Your inspection fee is non-refundable as it compensates the agent/landlord for showing the property.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint, fontSize: 11),
                  textAlign: TextAlign.center),
            ]),
          ),
        ],

        // ============ PASSED CONFIRMATION ============
        if (_hasPassed) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withAlpha(13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              Icon(Icons.search, color: AppColors.textSecondary, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(
                'You passed on this property. Keep browsing to find your perfect home!',
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
              )),
            ]),
          ),
        ],

        // ============ RENTAL INTEREST STATUS ============
        if (_rentalInterest != null) ...[
          const SizedBox(height: 16),
          _buildRentalInterestStatus(),
        ],

        // Loading
        if (r.isCompleted && r.tenantRated && _isLoadingInterest) ...[
          const SizedBox(height: 12),
          Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primary))),
        ],
      ]),
    );
  }

  // ---- Rental interest status widget ----
  Widget _buildRentalInterestStatus() {
    final interest = _rentalInterest!;
    Color statusColor;
    IconData statusIcon;
    String title;
    String subtitle;
    Widget? action;

    switch (interest.status) {
      case RentalInterestStatus.pendingPayment:
        statusColor = AppColors.warning;
        statusIcon = Icons.payment;
        title = 'Payment Pending';
        subtitle = 'Complete your rental payment to secure this property';
        action = SizedBox(
            width: double.infinity,
            child: AppButton(
                text: 'Complete Payment',
                onPressed: () => context.push('/tenant/rental-payment',
                    extra: {
                      'rentalInterest': interest,
                      'inspectionRequest': widget.request
                    })));
        break;
      case RentalInterestStatus.paymentUploaded:
        statusColor = AppColors.info;
        statusIcon = Icons.hourglass_top;
        title = 'Verifying Payment';
        subtitle =
            'We\'re verifying your payment. This usually takes 24 hours.';
        action = null;
        break;
      case RentalInterestStatus.paymentVerified:
        statusColor = AppColors.success;
        statusIcon = Icons.verified;
        title = 'Payment Confirmed!';
        subtitle =
            'Your payment has been verified. The landlord will finalize your rental shortly.';
        action = null;
        break;
      case RentalInterestStatus.rejected:
        statusColor = AppColors.error;
        statusIcon = Icons.error_outline;
        title = 'Payment Rejected';
        subtitle = interest.paymentRejectionReason ??
            'Your payment could not be verified. Please re-upload.';
        action = SizedBox(
            width: double.infinity,
            child: AppButton(
                text: 'Re-upload Payment',
                onPressed: () => context.push('/tenant/rental-payment',
                    extra: {
                      'rentalInterest': interest,
                      'inspectionRequest': widget.request
                    })));
        break;
      case RentalInterestStatus.accepted:
        statusColor = AppColors.success;
        statusIcon = Icons.celebration;
        title = 'ðŸŽ‰ Rental Confirmed!';
        subtitle =
            'Welcome to your new home! Your dashboard has been updated.';
        action = SizedBox(
            width: double.infinity,
            child: AppButton(
                text: 'Go to My Home',
                onPressed: () => context.go('/tenant/home')));
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: statusColor.withAlpha(13),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: statusColor.withAlpha(51))),
      child: Column(children: [
        Row(children: [
          Icon(statusIcon, size: 24, color: statusColor),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: AppTextStyles.labelLarge
                        .copyWith(color: statusColor)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ])),
        ]),
        if (action != null) ...[const SizedBox(height: 12), action],
      ]),
    );
  }

  // ---- Rating dialog ----
  void _showRatingDialog() {
    int selectedRating = 0;
    final reviewController = TextEditingController();
    final r = widget.request;
    final target =
        r.isAgentHandled ? (r.agentName ?? 'the agent') : r.landlordName;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Rate Your Experience'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('How was your inspection with $target?',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                    5,
                    (i) => GestureDetector(
                          onTap: () =>
                              setDialogState(() => selectedRating = i + 1),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(
                                i < selectedRating
                                    ? Icons.star
                                    : Icons.star_border,
                                size: 36,
                                color: AppColors.warning),
                          ),
                        ))),
            if (selectedRating > 0) ...[
              const SizedBox(height: 8),
              Text(_ratingLabel(selectedRating),
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.warning)),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: reviewController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Write a review (optional)',
                hintStyle: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textHint),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.border)),
              ),
            ),
          ]),
          ), // SingleChildScrollView
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Later',
                    style: TextStyle(color: AppColors.textSecondary))),
            ElevatedButton(
              onPressed: selectedRating > 0
                  ? () async {
                      Navigator.pop(ctx);
                      final success =
                          await widget.inspectionService.rateInspection(
                        r.id,
                        selectedRating,
                        review: reviewController.text.isNotEmpty
                            ? reviewController.text
                            : null,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(success
                              ? 'Thanks for your feedback! Now make your decision.'
                              : 'Failed to submit rating. Please try again.'),
                          backgroundColor:
                              success ? AppColors.success : AppColors.error,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ));
                        if (success) _loadRentalInterest();
                      }
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                  backgroundColor: selectedRating > 0
                      ? AppColors.primary
                      : AppColors.textHint,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }

  String _ratingLabel(int r) {
    switch (r) {
      case 1: return 'Poor';
      case 2: return 'Fair';
      case 3: return 'Good';
      case 4: return 'Very Good';
      case 5: return 'Excellent!';
      default: return '';
    }
  }

  // ---- Express interest ----
  Future<void> _expressInterest() async {
    // Fetch actual property rent before creating interest
    final property = await PropertyService().getProperty(
      widget.request.propertyId,
    );

    if (property == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Could not load property details. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
      return;
    }

    final rentAmount = property.rent;
    final agentFee = property.agentFee;
    final totalAmount = rentAmount + agentFee;

    final interest = await _rentalInterestService.createRentalInterest(
      inspectionRequest: widget.request,
      paymentAmount: totalAmount,
    );

    if (mounted) {
      if (interest != null) {
        setState(() => _rentalInterest = interest);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
              'Great choice! Complete your payment to secure the property.'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to express interest. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  // ---- Pass ----
  Future<void> _passOnProperty() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Not Interested?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Are you sure you want to pass on this property?',
              style: AppTextStyles.bodyMedium),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(8)),
            child: Text(
                'Your inspection fee is non-refundable as it compensates the agent/landlord for showing the property.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary)),
          ),
        ]),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Go Back',
                  style: TextStyle(color: AppColors.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Yes, I\'ll Keep Looking',
                  style: TextStyle(color: AppColors.primary))),
        ],
      ),
    );
    if (confirm == true && mounted) {
      setState(() {
        _hasCheckedInterest = true;
        _hasPassed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('No problem! Keep browsing to find your perfect home.'),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }
}

// ============================================================
// EMPTY STATE
// ============================================================
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: AppColors.primary)),
          const SizedBox(height: 24),
          Text(title, style: AppTextStyles.h4, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(subtitle,
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 24),
            TextButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.search),
                label: Text(actionLabel!),
                style: TextButton.styleFrom(foregroundColor: AppColors.primary)),
          ],
        ]),
      ),
    );
  }
}