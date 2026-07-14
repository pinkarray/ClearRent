import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:developer' as developer;
import '../../../../shared/widgets/highlight_wrap.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/models/rental_interest_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/tab_badge.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../shared/widgets/what_happens_now_hint.dart';
import '../../../../shared/widgets/reschedule_proposal_panel.dart';
import '../../../../shared/widgets/reschedule_propose_sheet.dart';
import '../../../../services/property_service.dart';
import '../../../../services/inspection_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/rental_interest_service.dart';
import '../../../../services/refund_service.dart';
import '../../../../shared/models/refund_model.dart';

class TenantInspectionsScreen extends StatefulWidget {
  /// Optional explicit tab to land on (0 = Requests, 1 = Scheduled, 2 = Completed).
  /// When null, the screen picks the most relevant tab automatically based on
  /// the tenant's data. Pass an explicit value when deep-linking from a
  /// notification or home-screen card that already knows which tab is right.
  final int? initialTab;

  /// Optional inspection id to highlight + pin to the top of its tab, set when
  /// deep-linking from a notification about a specific inspection.
  final String? initialRequestId;

  const TenantInspectionsScreen(
      {super.key, this.initialTab, this.initialRequestId});

  @override
  State<TenantInspectionsScreen> createState() =>
      _TenantInspectionsScreenState();
}

class _TenantInspectionsScreenState extends State<TenantInspectionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  StreamSubscription? _pendingDotSub;
  StreamSubscription? _upcomingSub;
  int _pendingCount = 0;
  int _upcomingCount = 0;
  int _historyActionableCount = 0;
  final InspectionService _inspectionService = InspectionService();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _pendingDotSub = _inspectionService.getTenantPendingRequests().listen((list) {
      if (!mounted) return;
      setState(() => _pendingCount = list.length);
    });

    // Drives the Upcoming + History attention badges off one stream, so the
    // tenant is pulled to the right tab even if a push was missed:
    //   • Upcoming  → approved inspections (mirrors the Upcoming tab filter)
    //   • History   → completed-but-unrated inspections (the "go rate it" nudge)
    _upcomingSub = _inspectionService.getTenantRequests().listen((list) {
      if (!mounted) return;
      setState(() {
        _upcomingCount = list.where((r) => r.isApproved).length;
        _historyActionableCount =
            list.where((r) => r.isCompleted && !r.tenantRated).length;
      });
    });

    // If an explicit tab was passed (e.g. from a notification deep-link),
    // respect it. Otherwise let the smart logic pick.
    if (widget.initialTab != null) {
      _tabController.index = widget.initialTab!.clamp(0, 2);
    } else {
      _selectInitialTab();
    }
  }

  @override
  void dispose() {
    _pendingDotSub?.cancel();
    _upcomingSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  /// Picks the most relevant tab for the tenant based on what's actually
  /// in their data. Tenant priority: Scheduled > Requests > Completed.
  /// A scheduled inspection is the most actionable thing for a tenant
  /// (they need to show up); pending requests are second priority.
  /// Falls back to Requests when everything is empty.
  ///
  /// The filter conditions here MUST mirror each tab's own filter exactly,
  /// otherwise we'd land on a tab that turns out empty.
  Future<void> _selectInitialTab() async {
    try {
      final all = await _inspectionService.getTenantRequests().first;
      if (!mounted) return;

      final hasRequests = all.any((r) =>
          r.isPending ||
          r.isPendingPayment ||
          r.isPendingVerification ||
          r.isDeclinedByAgent ||
          r.isExpiredUnapproved);
      final hasScheduled = all.any((r) => r.isApproved);
      final hasCompleted = all.any((r) =>
          r.isCompleted ||
          r.isDeclined ||
          r.isCancelled ||
          r.isRefunded ||
          r.isAwaitingOutcome);

      int target = 0; // default to Requests for empty state
      if (hasScheduled) {
        target = 1;
      } else if (hasRequests) {
        target = 0;
      } else if (hasCompleted) {
        target = 2;
      }

      if (mounted && _tabController.index != target) {
        _tabController.animateTo(target);
      }
    } catch (_) {
      // Non-fatal — keep default Requests tab.
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
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          // Preserve normal back navigation when there's history; only force
          // the tenant home when deep-linked as the stack root (nothing to pop).
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/tenant/home'),
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
          tabs: [
            Tab(child: TabBadge(label: 'Pending', count: _pendingCount)),
            Tab(child: TabBadge(label: 'Upcoming', count: _upcomingCount)),
            Tab(child: TabBadge(label: 'History', count: _historyActionableCount)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _TenantPendingTab(
              inspectionService: _inspectionService,
              highlightId: widget.initialRequestId),
          _TenantUpcomingTab(
              inspectionService: _inspectionService,
              highlightId: widget.initialRequestId),
          _TenantHistoryTab(
              inspectionService: _inspectionService,
              highlightId: widget.initialRequestId),
        ],
      ),
    );
  }
}

// ============================================================
// PENDING REQUESTS TAB
// ============================================================
class _TenantPendingTab extends StatefulWidget {
  final InspectionService inspectionService;
  final String? highlightId;
  const _TenantPendingTab({required this.inspectionService, this.highlightId});

  @override
  State<_TenantPendingTab> createState() => _TenantPendingTabState();
}

class _TenantPendingTabState extends State<_TenantPendingTab> {
  // Cache the stream once. The parent rebuilds this tab whenever a badge-count
  // subscription fires (e.g. the other party marks "on my way"); recreating the
  // stream inside build() would hand StreamBuilder a fresh instance, resetting
  // it to ConnectionState.waiting and flashing the loading spinner — the flicker.
  late final Stream<List<InspectionRequest>> _stream =
      widget.inspectionService.getTenantRequests();

  @override
  Widget build(BuildContext context) {
    final inspectionService = widget.inspectionService;
    final highlightId = widget.highlightId;
    return StreamBuilder<List<InspectionRequest>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        if (snapshot.hasError) {
          developer.log('❌ Error: ${snapshot.error}',
              name: 'TenantInspections');
          return const GuidanceEmptyState(
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
                r.isDeclinedByAgent ||
                r.isExpiredUnapproved)
            .toList();
        final ordered = pinToFront(pending, (r) => r.id == highlightId);

        if (pending.isEmpty) {
          return GuidanceEmptyState(
            icon: Icons.inbox_outlined,
            title: 'No pending requests',
            subtitle: 'Your inspection requests will appear here',
            actionLabel: 'Browse Properties',
            actionIcon: Icons.search,
            onAction: () => context.go('/tenant/home'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: ordered.length,
          itemBuilder: (context, index) => HighlightWrap(
            active: ordered[index].id == highlightId,
            child: _TenantPendingCard(
              request: ordered[index],
              inspectionService: inspectionService,
            ),
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

  /// Reschedule an inspection that expired unapproved — pick a new date/slot;
  /// it re-enters the approval queue (payment kept).
  Future<void> _rescheduleExpired() async {
    final payload = await ReschedulePropoSheet.show(context, widget.request);
    if (payload == null || !mounted) return;
    setState(() => _isLoading = true);
    final ok = await widget.inspectionService.rescheduleExpiredInspection(
      widget.request.id,
      payload.date,
      payload.timeSlot,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);
    _showSnack(
      ok
          ? 'Rescheduled — sent for approval again.'
          : 'Could not reschedule. Please try again.',
      ok ? AppColors.success : AppColors.error,
    );
  }

  /// Take the refund instead of rescheduling an expired inspection.
  Future<void> _refundExpired() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Get Refund'),
        content: const Text(
            'Take a full refund instead of rescheduling? An admin will '
            'process it shortly.'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Back',
                  style: TextStyle(color: AppColors.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Yes, Refund',
                  style: TextStyle(color: AppColors.primary))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _isLoading = true);
    final ok = await widget.inspectionService
        .refundExpiredInspection(widget.request.id);
    if (!mounted) return;
    setState(() => _isLoading = false);
    _showSnack(
      ok
          ? 'Refund requested. It\'ll be processed shortly.'
          : 'Could not request refund. Please try again.',
      ok ? AppColors.success : AppColors.error,
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

          // What happens now — keeps the tenant oriented while they wait.
          if (r.isPending || r.isPendingVerification || r.isDeclinedByAgent) ...[
            const SizedBox(height: 12),
            WhatHappensNowHint(
              text: r.isPendingVerification
                  ? 'We\'re confirming your payment. Once verified, your request '
                      'goes to the ${r.isAgentHandled ? 'agent' : 'landlord'} to pick a time.'
                  : r.isDeclinedByAgent
                      ? 'Under review — the landlord may still take this over. '
                          'We\'ll notify you of the outcome.'
                      : 'Your request is with the ${r.isAgentHandled ? 'agent' : 'landlord'}. '
                          'They\'ll confirm the time or suggest a new one — '
                          'you\'ll get a notification either way.',
              color: r.isDeclinedByAgent ? AppColors.info : AppColors.primary,
            ),
          ],

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
          // Actions — only when there's payment in flight (cancel
          // request and verifying badge). Paid requests must go
          // through handler-cancel instead.
          if (r.isPendingPayment) ...[
            const SizedBox(height: 16),
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
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(
                    text: 'Verifying...',
                    onPressed: null),
              ),
            ]),
          ],
          // Expired unapproved — tenant picks reschedule (free) or refund.
          if (r.isExpiredUnapproved) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'This wasn\'t approved before the date. Reschedule for free, '
                'or take a full refund.',
                style:
                    AppTextStyles.caption.copyWith(color: AppColors.warning),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isLoading ? null : _refundExpired,
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
                      : Text('Get Refund',
                          style: AppTextStyles.labelMedium
                              .copyWith(color: AppColors.textSecondary)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(
                  text: 'Reschedule',
                  onPressed: _isLoading ? null : _rescheduleExpired,
                ),
              ),
            ]),
          ],
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
class _TenantUpcomingTab extends StatefulWidget {
  final InspectionService inspectionService;
  final String? highlightId;
  const _TenantUpcomingTab({required this.inspectionService, this.highlightId});

  @override
  State<_TenantUpcomingTab> createState() => _TenantUpcomingTabState();
}

class _TenantUpcomingTabState extends State<_TenantUpcomingTab> {
  // Cached stream — see _TenantPendingTabState for why (avoids the rebuild flicker).
  late final Stream<List<InspectionRequest>> _stream =
      widget.inspectionService.getTenantRequests();

  @override
  Widget build(BuildContext context) {
    final highlightId = widget.highlightId;
    return StreamBuilder<List<InspectionRequest>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        final all = snapshot.data ?? [];
        final upcoming = all.where((r) => r.isApproved).toList()
          ..sort((a, b) => a.requestedDate.compareTo(b.requestedDate));
        final ordered = pinToFront(upcoming, (r) => r.id == highlightId);

        if (upcoming.isEmpty) {
          return GuidanceEmptyState(
            icon: Icons.event_available_outlined,
            title: 'No upcoming inspections',
            subtitle:
                'Once a request is approved, your visit shows up here. Browse '
                'properties to book one.',
            actionLabel: 'Browse Properties',
            actionIcon: Icons.search,
            onAction: () => context.go('/tenant/home'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: ordered.length,
          itemBuilder: (context, i) => HighlightWrap(
            active: ordered[i].id == highlightId,
            child: _TenantUpcomingCard(request: ordered[i]),
          ),
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
  final InspectionService _inspectionService = InspectionService();
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

  Future<void> _markOnWay() async {
    final ok =
        await _inspectionService.markTenantOnWay(widget.request.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Couldn\'t update status, try again'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _markArrived() async {
    final ok =
        await _inspectionService.markTenantArrived(widget.request.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Couldn\'t update status, try again'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _markMet() async {
    final ok =
        await _inspectionService.markMet(widget.request.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Couldn\'t update status, try again'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _proposeReschedule() async {
    final payload = await ReschedulePropoSheet.show(
      context,
      widget.request,
    );
    if (payload == null || !mounted) return;

    final ok = await _inspectionService.proposeReschedule(
      requestId: widget.request.id,
      newDate: payload.date,
      newTimeSlot: payload.timeSlot,
      reason: payload.reason,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Reschedule proposal sent'
              : 'Couldn\'t send proposal, try again',
        ),
        backgroundColor:
            ok ? AppColors.textPrimary : AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
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

        // Reschedule proposal panel (only when a proposal is active)
        if (r.hasPendingReschedule)
          RescheduleProposalPanel(
            request: r,
            currentUserId: r.tenantId,
          ),

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
                        ? 'Agent Will show you the property'
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

        // Handler's live status — so the tenant can see whether the
        // agent/landlord is on the way or has arrived. Arrived takes
        // priority. Hidden once met (cascade below shows in-progress).
        if (!r.met && r.handlerArrived) ...[
          const SizedBox(height: 12),
          _partyStatusStrip(
            icon: Icons.where_to_vote,
            color: AppColors.success,
            text:
                '${r.isAgentHandled ? (r.agentName ?? 'The agent') : r.landlordName} has arrived',
          ),
        ] else if (!r.met && r.handlerOnWay) ...[
          const SizedBox(height: 12),
          _partyStatusStrip(
            icon: Icons.directions_walk,
            color: AppColors.info,
            text:
                '${r.isAgentHandled ? (r.agentName ?? 'The agent') : r.landlordName} is on the way',
          ),
        ],

        // On Way / Arrived / Met — single-slot cascade that
        // progresses through the inspection-day state machine
        if (r.canTenantMarkOnWay) ...[
          const SizedBox(height: 12),
          AppButton(
            text: 'I\'m on my way',
            onPressed: _markOnWay,
          ),
        ] else if (r.tenantOnWay && !r.tenantArrived) ...[
          const SizedBox(height: 12),
          AppButton(
            text: 'I\'ve Arrived',
            onPressed: _markArrived,
          ),
        ] else if (r.canTenantMarkMet) ...[
          const SizedBox(height: 12),
          AppButton(
            text: (r.agentId != null && r.agentId!.isNotEmpty)
                ? 'I\'ve met the agent'
                : 'I\'ve met the landlord',
            onPressed: _markMet,
          ),
        ] else if (r.met) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(
              vertical: 12, horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(26),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.success.withAlpha(77),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle,
                    size: 18, color: AppColors.success),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Inspection in progress',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.success),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],

        // Reschedule button (hidden when a proposal is pending or
        // we're past the 2h cutoff or cap is reached)
        if (r.canInitiateReschedule) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _proposeReschedule,
            icon: Icon(Icons.event_repeat, size: 18,
                color: AppColors.primary),
            label: Text('Reschedule',
                style: AppTextStyles.labelMedium
                    .copyWith(color: AppColors.primary)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.primary),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              minimumSize: const Size(double.infinity, 0),
            ),
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
        ]
      ),
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

      Widget _partyStatusStrip({
    required IconData icon,
    required Color color,
    required String text,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: AppTextStyles.labelMedium.copyWith(color: color)),
          ),
        ]),
      );
}

// ============================================================
// HISTORY TAB MANDATORY RATING + INTEREST FLOW
// ============================================================
class _TenantHistoryTab extends StatefulWidget {
  final InspectionService inspectionService;
  final String? highlightId;
  const _TenantHistoryTab({required this.inspectionService, this.highlightId});

  @override
  State<_TenantHistoryTab> createState() => _TenantHistoryTabState();
}

class _TenantHistoryTabState extends State<_TenantHistoryTab> {
  // Cached stream — see _TenantPendingTabState for why (avoids the rebuild flicker).
  late final Stream<List<InspectionRequest>> _stream =
      widget.inspectionService.getTenantRequests();

  @override
  Widget build(BuildContext context) {
    final inspectionService = widget.inspectionService;
    final highlightId = widget.highlightId;
    return StreamBuilder<List<InspectionRequest>>(
      stream: _stream,
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
                r.isRefunded ||
                r.isAwaitingOutcome)
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
          return const GuidanceEmptyState(
              icon: Icons.history,
              title: 'No history yet',
              subtitle: 'Your past inspections will appear here');
        }

        final ordered = pinToFront(history, (r) => r.id == highlightId);
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: ordered.length,
          itemBuilder: (context, i) => HighlightWrap(
            active: ordered[i].id == highlightId,
            child: _TenantHistoryCard(
                request: ordered[i], inspectionService: inspectionService),
          ),
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

  final RefundService _refundService = RefundService();
  StreamSubscription<Refund?>? _refundSub;
  Refund? _refund;

  @override
  void initState() {
    super.initState();
    // Restore the persisted decline so the decision box stays gone across restarts.
    _hasPassed = widget.request.tenantPassed;
    if (widget.request.isCompleted && widget.request.tenantRated) {
      _loadRentalInterest();
    }
    if (widget.request.isRefunded) {
      _refundSub = _refundService
          .streamForInspection(widget.request.id)
          .listen((refund) {
        if (mounted) setState(() => _refund = refund);
      });
    }
  }

  @override
  void dispose() {
    _refundSub?.cancel();
    super.dispose();
  }

  String _formatPaidDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
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
        // A loser (lost_to_other) is owed a refund tracked at
        // refunds/{interestId} — stream it so the card shows Processing → Paid,
        // matching the inspection-refund card.
        if (interest != null && interest.isLostToOther) {
          _refundSub = _refundService
              .streamForRental(interest.id)
              .listen((refund) {
            if (mounted) setState(() => _refund = refund);
          });
        }
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

    // Rating is optional and no longer gates the decision — a tenant who
    // inspected can choose to rent / keep looking regardless of whether they
    // rated the handler's conduct.
    final needsDecision = r.isCompleted &&
        _hasCheckedInterest &&
        _rentalInterest == null &&
        !_hasPassed;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: r.isUnderReview
            ? Border.all(color: AppColors.info, width: 1.5)
            : needsDecision
                ? Border.all(color: AppColors.primary, width: 1.5)
                : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Dispute under review — the tenant reported a problem; an admin is on
        // it. Takes priority over any rating/decision prompt.
        if (r.isUnderReview) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.info.withAlpha(77))),
            child: Row(children: [
              Icon(Icons.shield_outlined, size: 20, color: AppColors.info),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('UNDER REVIEW',
                        style: AppTextStyles.labelSmall.copyWith(
                            color: AppColors.info,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                        'You reported a problem. Our team is reviewing it and '
                        'will sort out any refund.',
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

        // Refund status (shown only when refund doc has been created)
        if (_refund != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.info.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppColors.info.withAlpha(51))),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.replay,
                        size: 16, color: AppColors.info),
                    const SizedBox(width: 8),
                    Text('Refund',
                        style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.info,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: _refund!.isPaid
                              ? AppColors.success.withAlpha(26)
                              : AppColors.warning.withAlpha(26),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(
                          _refund!.isPaid ? 'Paid' : 'Processing',
                          style: AppTextStyles.labelSmall.copyWith(
                              color: _refund!.isPaid
                                  ? AppColors.success
                                  : AppColors.warning,
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                      '₦${_refund!.amount.toStringAsFixed(0)}',
                      style: AppTextStyles.naira(AppTextStyles.bodyLarge
                          .copyWith(fontWeight: FontWeight.w700))),
                  const SizedBox(height: 4),
                  Text(_refund!.reason,
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary)),
                  if (_refund!.isPaid && _refund!.paidAt != null) ...[
                    const SizedBox(height: 6),
                    Text(
                        'Paid on ${_formatPaidDate(_refund!.paidAt!)}',
                        style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            fontStyle: FontStyle.italic)),
                  ],
                ]),
          ),
        ],

        // ============ RATING SECTION — optional, scoped to handler conduct ============
        if (r.isCompleted && !r.isUnderReview) ...[
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
          else ...[
            Text('How was your agent? (optional)',
                style: AppTextStyles.labelMedium),
            const SizedBox(height: 2),
            Text(
                'On time, knew the property, professional? This isn\'t about '
                'whether you liked the place.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showRatingDialog(),
                icon: const Icon(Icons.star, size: 20),
                label: const Text('Rate Your Agent'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
              ),
            ),
          ],
        ],

        // ============ REPORT A PROBLEM (DISPUTE) ============
        // A distinct channel from rating: something went wrong (misrepresented
        // listing, no-show, unprofessional, safety, refund). Routes to admin.
        if ((r.isCompleted || r.isAwaitingOutcome || r.isApproved) &&
            !r.isUnderReview &&
            !r.isRefunded) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showReportDialog(r),
              icon: Icon(Icons.flag_outlined,
                  size: 18, color: AppColors.error),
              label: Text('Report a problem',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.error)),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4)),
            ),
          ),
        ],

        // ============ DECISION SECTION ============
        if (r.isCompleted &&
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
        title = 'Payment Processing';
        subtitle =
            'Your payment is being processed. This should only take a moment.';
        action = null;
        break;
      case RentalInterestStatus.paymentVerified:
        statusColor = AppColors.success;
        statusIcon = Icons.verified;
        title = 'Payment Confirmed!';
        subtitle =
            'Your payment has been confirmed. The landlord can now accept your rental.';
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
        title = ' Rental Confirmed!';
        subtitle =
            'Welcome to your new home! Your dashboard has been updated.';
        action = SizedBox(
            width: double.infinity,
            child: AppButton(
                text: 'Go to My Home',
                onPressed: () => context.go('/tenant/home')));
        break;
      case RentalInterestStatus.lostToOther:
        statusColor = AppColors.info;
        statusIcon = Icons.info_outline;
        title = 'Property Rented to Another Applicant';
        subtitle =
            'The landlord accepted another tenant for this property. '
            'Your full payment is being refunded — you don\'t need to do anything.';
        action = null;
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
              textCapitalization: TextCapitalization.sentences,
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
                              ? 'Thanks for your feedback!'
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

  // ---- Report a problem (dispute) ----
  // The category values MUST match the reportInspectionIssue Cloud Function's
  // allowed set (functions/src/inspection_dispute_ops.ts).
  static const List<(String, String, IconData)> _disputeCategories = [
    ('misrepresented', 'Property was misrepresented', Icons.error_outline),
    ('no_show', 'The agent/landlord didn\'t show up', Icons.person_off_outlined),
    ('unprofessional', 'Unprofessional conduct', Icons.sentiment_dissatisfied_outlined),
    ('safety', 'Safety concern', Icons.gpp_maybe_outlined),
    ('refund_request', 'I want a refund', Icons.replay),
  ];

  void _showReportDialog(InspectionRequest r) {
    String? selectedCategory;
    final detailsController = TextEditingController();
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Report a problem'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                  'Tell us what went wrong. This goes to our team to review — '
                  'it\'s separate from rating your agent.',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              ..._disputeCategories.map((c) {
                final selected = selectedCategory == c.$1;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () =>
                        setDialogState(() => selectedCategory = c.$1),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primary.withAlpha(20)
                            : AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: selected
                                ? AppColors.primary
                                : AppColors.border),
                      ),
                      child: Row(children: [
                        Icon(c.$3,
                            size: 20,
                            color: selected
                                ? AppColors.primary
                                : AppColors.textSecondary),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(c.$2,
                                style: AppTextStyles.bodyMedium.copyWith(
                                    color: selected
                                        ? AppColors.primary
                                        : AppColors.textPrimary))),
                        if (selected)
                          Icon(Icons.check_circle,
                              size: 18, color: AppColors.primary),
                      ]),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 4),
              TextField(
                controller: detailsController,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Add details (optional)',
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
          ),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          actions: [
            TextButton(
                onPressed:
                    submitting ? null : () => Navigator.pop(ctx),
                child: Text('Cancel',
                    style: TextStyle(color: AppColors.textSecondary))),
            ElevatedButton(
              onPressed: (selectedCategory == null || submitting)
                  ? null
                  : () async {
                      setDialogState(() => submitting = true);
                      final ok = await widget.inspectionService
                          .reportInspectionIssue(
                        r.id,
                        selectedCategory!,
                        details: detailsController.text.trim(),
                      );
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? 'Reported. Our team will review it shortly.'
                              : 'Couldn\'t submit your report. Please try again.'),
                          backgroundColor:
                              ok ? AppColors.success : AppColors.error,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ));
                      }
                    },
              style: ElevatedButton.styleFrom(
                  backgroundColor: selectedCategory == null
                      ? AppColors.textHint
                      : AppColors.error,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Submit report'),
            ),
          ],
        ),
      ),
    );
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
    const double tenantDealFee = 5000;
    final totalAmount = rentAmount + agentFee + tenantDealFee;

    final interest = await _rentalInterestService.createRentalInterest(
      inspectionRequest: widget.request,
      paymentAmount: totalAmount,
      rentAmount: rentAmount,
      agentFee: agentFee,
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
      final messenger = ScaffoldMessenger.of(context);
      final success =
          await widget.inspectionService.markTenantPassed(widget.request.id);
      if (!mounted) return;
      if (success) {
        setState(() {
          _hasCheckedInterest = true;
          _hasPassed = true;
        });
        messenger.showSnackBar(SnackBar(
          content: const Text(
              'No problem! Keep browsing to find your perfect home.'),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      } else {
        messenger.showSnackBar(SnackBar(
          content: const Text('Could not save your decision. Please try again.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }
}

// ============================================================
// EMPTY STATE
// ============================================================
