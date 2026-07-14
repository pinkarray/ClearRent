import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/tab_badge.dart';
import '../../../../shared/widgets/inspection_readiness_dialog.dart';
import '../../../../shared/widgets/highlight_wrap.dart';
import '../../../../shared/widgets/bank_details_gate.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';
import '../../../../shared/widgets/reschedule_proposal_panel.dart';
import '../../../../shared/widgets/reschedule_propose_sheet.dart';
import 'package:intl/intl.dart';
import '../../../../shared/widgets/refund_confirm_sheet.dart';
import '../../../../services/inspection_service.dart';
import '../../../../core/utils/inspection_pricing.dart';

class AgentInspectionsScreen extends StatefulWidget {
  /// Optional explicit tab to land on (0 = Requests, 1 = Scheduled, 2 = Completed).
  /// When null, the screen picks the most relevant tab automatically based on
  /// the agent's data. Pass an explicit value when deep-linking from a
  /// notification or home-screen card that already knows which tab is right.
  final int? initialTab;

  /// Optional inspection id to highlight + pin to the top of its tab, set when
  /// deep-linking from a notification about a specific inspection.
  final String? initialRequestId;
  const AgentInspectionsScreen(
      {super.key, this.initialTab, this.initialRequestId});

  @override
  State<AgentInspectionsScreen> createState() => _AgentInspectionsScreenState();
}

class _AgentInspectionsScreenState extends State<AgentInspectionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  StreamSubscription? _pendingDotSub;
  StreamSubscription? _upcomingSub;
  int _pendingCount = 0;
  int _upcomingCount = 0;
  final InspectionService _inspectionService = InspectionService();

  // Deep-link highlight target. Cleared once the agent accepts the highlighted
  // request so the emphasis frame doesn't carry over onto the Scheduled tab.
  late String? _highlightId = widget.initialRequestId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _pendingDotSub = _inspectionService.getAgentPendingRequests().listen((
      list,
    ) {
      if (!mounted) return;
      setState(() => _pendingCount = list.length);
    });

    // Count of approved (upcoming, not past) inspections — drives the
    // Scheduled tab's attention badge, so a newly-approved inspection lights
    // the dot even without tapping the push. Mirrors the Scheduled tab's
    // filter, which excludes past-dated approvals.
    _upcomingSub = _inspectionService.getAgentRequests().listen((list) {
      if (!mounted) return;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      setState(() => _upcomingCount = list.where((r) {
            final d = DateTime(r.requestedDate.year, r.requestedDate.month,
                r.requestedDate.day);
            return r.isApproved && !d.isBefore(today);
          }).length);
    });

    // If an explicit tab was passed (e.g. from the agent home screen's
    // "today's inspection" card or a notification deep-link), respect it.
    // Otherwise let the smart logic pick.
    if (widget.initialTab != null) {
      _tabController.index = widget.initialTab!.clamp(0, 2);
    } else {
      _selectInitialTab();
    }
  }

  /// Picks the most relevant tab for the agent based on what's actually
  /// in their data. Agent priority: Requests > Scheduled > Completed.
  /// Pending requests need the agent to accept/decline; that's where they
  /// should land first. Falls back to Requests when everything is empty.
  ///
  /// The filter conditions here MUST mirror each tab's own filter exactly,
  /// otherwise we'd land on a tab that turns out empty. Note Scheduled
  /// excludes past-dated approved inspections (matching the tab filter).
  Future<void> _selectInitialTab() async {
    try {
      final all = await _inspectionService.getAgentRequests().first;
      if (!mounted) return;

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final hasRequests = all.any((r) => r.isPending);
      final hasScheduled = all.any((r) {
        final requestDay = DateTime(
          r.requestedDate.year,
          r.requestedDate.month,
          r.requestedDate.day,
        );
        return r.isApproved && !requestDay.isBefore(today);
      });
      final hasCompleted = all.any((r) => r.isCompleted);

      int target = 0; // default to Requests for empty state
      if (hasRequests) {
        target = 0;
      } else if (hasScheduled) {
        target = 1;
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
  void dispose() {
    _pendingDotSub?.cancel();
    _upcomingSub?.cancel();
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
          // When deep-linked from a push (cold start, or after the splash
          // redirect collapses the stack) there may be nothing to pop, which
          // left the back button dead. Fall back to the agent home instead.
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/agent/home'),
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
            Tab(child: TabBadge(label: 'Scheduled', count: _upcomingCount)),
            const Tab(text: 'Completed'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _AgentPendingTab(
            inspectionService: _inspectionService,
            highlightId: _highlightId,
            onApproved: () {
              _tabController.animateTo(1);
              // Drop the deep-link highlight once the agent acts on it, so the
              // emphasis frame doesn't follow the card onto the Scheduled tab.
              if (_highlightId != null) {
                setState(() => _highlightId = null);
              }
            },
          ),
          _AgentScheduledTab(
              inspectionService: _inspectionService,
              highlightId: _highlightId),
          _AgentCompletedTab(
              inspectionService: _inspectionService,
              highlightId: _highlightId),
        ],
      ),
    );
  }
}

// ============ PENDING REQUESTS TAB ============
class _AgentPendingTab extends StatefulWidget {
  final InspectionService inspectionService;
  final VoidCallback onApproved;
  final String? highlightId;

  const _AgentPendingTab({
    required this.inspectionService,
    required this.onApproved,
    this.highlightId,
  });

  @override
  State<_AgentPendingTab> createState() => _AgentPendingTabState();
}

class _AgentPendingTabState extends State<_AgentPendingTab> {
  // Cache the stream once so parent rebuilds (driven by badge-count
  // subscriptions when the other party acts) don't reset StreamBuilder to
  // ConnectionState.waiting and flash the loading spinner — that's the flicker.
  late final Stream<List<InspectionRequest>> _stream =
      widget.inspectionService.getAgentRequests();

  @override
  Widget build(BuildContext context) {
    final inspectionService = widget.inspectionService;
    final highlightId = widget.highlightId;
    return StreamBuilder<List<InspectionRequest>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final allRequests = snapshot.data ?? [];
        final pendingRequests = allRequests.where((r) => r.isPending).toList();

        if (pendingRequests.isEmpty) {
          return const GuidanceEmptyState(
            icon: Icons.inbox_outlined,
            title: 'No pending requests',
            subtitle:
                'Inspection requests for your assigned properties will appear here',
          );
        }

        final ordered = pinToFront(pendingRequests, (r) => r.id == highlightId);
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: ordered.length,
          itemBuilder: (context, index) {
            return HighlightWrap(
              active: ordered[index].id == highlightId,
              child: _AgentPendingCard(
                request: ordered[index],
                inspectionService: inspectionService,
                onApproved: widget.onApproved,
              ),
            );
          },
        );
      },
    );
  }
}

class _AgentPendingCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  final VoidCallback? onApproved;

  const _AgentPendingCard({
    required this.request,
    required this.inspectionService,
    this.onApproved,
  });

  @override
  State<_AgentPendingCard> createState() => _AgentPendingCardState();
}

class _AgentPendingCardState extends State<_AgentPendingCard> {
  bool _isLoading = false;

  Future<void> _acceptRequest() async {
    // Gate: a handler needs a payout account on file before accepting, so their
    // inspection earnings and any dispute payout have somewhere to go.
    final canProceed = await ensureBankDetailsOnFile(
      context,
      bankDetailsRoute: '/agent/bank-details',
      reason: 'Add your bank account first — it\'s where your inspection '
          'earnings and any dispute payouts are sent.',
    );
    if (!canProceed || !mounted) return;

    final ready = await confirmInspectionReadiness(context);
    if (!ready || !mounted) return;
    setState(() => _isLoading = true);

    final success = await widget.inspectionService.approveRequest(
      widget.request.id,
    );

    // Fire the parent callback (switch to Scheduled + clear the deep-link
    // highlight) as soon as the write succeeds. The live stream frequently
    // drops this now-approved card from the Pending list before the future
    // resolves, disposing this card — gating it on the `mounted` check below
    // would silently skip it and strand the emphasis frame on the next tab.
    if (success) widget.onApproved?.call();

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Inspection scheduled! Don\'t forget to show up 😊',
          ),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Failed to accept request'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _declineRequest() async {
    final reason = await _showDeclineDialog();
    if (reason == null) return;

    setState(() => _isLoading = true);

    final success = await widget.inspectionService.agentDeclineRequest(
      widget.request.id,
      reason: reason.isEmpty ? null : reason,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Request declined. Landlord has 12 hours to override.',
          ),
          backgroundColor: AppColors.textSecondary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<String?> _showDeclineDialog() async {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Decline Request'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The landlord will have 12 hours to approve this inspection themselves.',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Reason (optional but helpful)',
                    hintStyle: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textHint,
                    ),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
              ],
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: Text(
                  'Decline',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;

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
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Property info
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child:
                    request.propertyImage.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl: request.propertyImage,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        )
                        : Container(
                          width: 60,
                          height: 60,
                          color: AppColors.background,
                          child: Icon(Icons.home, color: AppColors.textHint),
                        ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.propertyTitle,
                      style: AppTextStyles.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      request.propertyAddress,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 12,
                          color: AppColors.textHint,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          request.propertyCluster != null
                              ? InspectionPricing.getClusterLabel(
                                request.propertyCluster!,
                              )
                              : request.propertyAddress,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textHint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Earnings indicator
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Text(
                      'You earn',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.success,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      InspectionPricing.formatNaira(request.agentEarnings),
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Earnings breakdown
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _buildFeeRow(
              'Your earnings',
              request.agentEarnings,
              isTotal: true,
            ),
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Tenant info
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.primary.withAlpha(26),
                child: Text(
                  request.tenantName.isNotEmpty
                      ? request.tenantName[0].toUpperCase()
                      : 'T',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(request.tenantName, style: AppTextStyles.labelMedium),
                    Text(
                      'Tenant',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Requested date/time
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(13),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.formattedDate,
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                      Text(
                        request.requestedTimeDisplay,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (request.notes != null && request.notes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.note_outlined,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      request.notes!,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isLoading ? null : _declineRequest,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    'Decline',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(
                  text: 'Accept',
                  onPressed: _isLoading ? null : _acceptRequest,
                  isLoading: _isLoading,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeeRow(String label, double amount, {bool isTotal = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style:
              isTotal
                  ? AppTextStyles.labelMedium.copyWith(color: AppColors.success)
                  : AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
        ),
        Text(
          InspectionPricing.formatNaira(amount),
          style:
              isTotal
                  ? AppTextStyles.labelMedium.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                  )
                  : AppTextStyles.bodySmall,
        ),
      ],
    );
  }
}

// ============ SCHEDULED TAB ============
class _AgentScheduledTab extends StatefulWidget {
  final InspectionService inspectionService;
  final String? highlightId;

  const _AgentScheduledTab(
      {required this.inspectionService, this.highlightId});

  @override
  State<_AgentScheduledTab> createState() => _AgentScheduledTabState();
}

class _AgentScheduledTabState extends State<_AgentScheduledTab> {
  // Cached stream — see _AgentPendingTabState for why (avoids the rebuild flicker).
  late final Stream<List<InspectionRequest>> _stream =
      widget.inspectionService.getAgentRequests();

  @override
  Widget build(BuildContext context) {
    final inspectionService = widget.inspectionService;
    final highlightId = widget.highlightId;
    return StreamBuilder<List<InspectionRequest>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final allRequests = snapshot.data ?? [];
        final now = DateTime.now();
        final scheduledRequests =
            allRequests.where((r) {
                final today = DateTime(now.year, now.month, now.day);
                final requestDay = DateTime(
                  r.requestedDate.year,
                  r.requestedDate.month,
                  r.requestedDate.day,
                );
                return r.isApproved && !requestDay.isBefore(today);
              }).toList()
              ..sort((a, b) => a.requestedDate.compareTo(b.requestedDate));

        if (scheduledRequests.isEmpty) {
          return const GuidanceEmptyState(
            icon: Icons.event_available_outlined,
            title: 'No scheduled inspections',
            subtitle: 'Accepted inspections will appear here',
          );
        }

        final ordered =
            pinToFront(scheduledRequests, (r) => r.id == highlightId);
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: ordered.length,
          itemBuilder: (context, index) {
            return HighlightWrap(
              active: ordered[index].id == highlightId,
              child: _AgentScheduledCard(
                request: ordered[index],
                inspectionService: inspectionService,
              ),
            );
          },
        );
      },
    );
  }
}

class _AgentScheduledCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;

  const _AgentScheduledCard({
    required this.request,
    required this.inspectionService,
  });

  @override
  State<_AgentScheduledCard> createState() => _AgentScheduledCardState();
}

class _AgentScheduledCardState extends State<_AgentScheduledCard> {
  bool _isLoading = false;
  bool _isArrivalLoading = false;

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  Future<void> _markArrived() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Confirm Arrival'),
            content: const Text(
              'Are you at the property? This will notify the tenant that you\'re ready for the inspection.',
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Not Yet',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  'Yes, I\'m Here',
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
            ],
          ),
    );
    if (confirm != true) return;

    setState(() => _isArrivalLoading = true);
    final ok = await widget.inspectionService.markHandlerArrived(
      widget.request.id,
    );
    if (!mounted) return;
    setState(() => _isArrivalLoading = false);

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('You\'ve been marked as arrived! ✓'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _markComplete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Complete Inspection'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Mark this inspection as completed?'),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.account_balance_wallet,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'You\'ll earn ${InspectionPricing.formatNaira(widget.request.agentEarnings)}',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.success,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  'Complete',
                  style: TextStyle(color: AppColors.success),
                ),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    final success = await widget.inspectionService.completeInspection(
      widget.request.id,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Inspection completed! ${InspectionPricing.formatNaira(widget.request.agentEarnings)} earned 🎉',
          ),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _callTenant() async {
    if (widget.request.tenantPhone == null) return;
    final uri = Uri.parse('tel:${widget.request.tenantPhone}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _markOnWay() async {
    final ok = await widget.inspectionService.markHandlerOnWay(
      widget.request.id,
    );
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
        await widget.inspectionService.markMet(widget.request.id);
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
    final payload = await ReschedulePropoSheet.show(context, widget.request);
    if (payload == null || !mounted) return;

    final ok = await widget.inspectionService.proposeReschedule(
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
        backgroundColor: ok ? AppColors.textPrimary : AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _cancelInspection() async {
    final r = widget.request;
    final feeText = NumberFormat('#,###').format(r.totalFee);
    final reason = await RefundConfirmSheet.show(
      context,
      title: 'Cancel Inspection',
      warningMessage:
          'Cancelling will end this inspection for '
          '${r.propertyTitle} and refund ₦$feeText to the tenant.',
      confirmButtonText: 'Cancel & Refund',
    );
    if (reason == null || !mounted) return;

    final ok = await widget.inspectionService.handlerCancelRequest(
      requestId: widget.request.id,
      reason: reason,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Inspection cancelled. Refund processing.'
              : 'Couldn\'t cancel, try again',
        ),
        backgroundColor: ok ? AppColors.textPrimary : AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final isToday = _isToday(request.requestedDate);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isToday ? AppColors.primary : AppColors.success.withAlpha(77),
          width: isToday ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isToday)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.today, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    'TODAY',
                    style: AppTextStyles.labelSmall.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

          // Reschedule proposal panel (only when a proposal is active)
          if (request.hasPendingReschedule)
            RescheduleProposalPanel(
              request: request,
              currentUserId: request.agentId ?? '',
            ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Text(
                      '${request.requestedDate.day}',
                      style: AppTextStyles.h4.copyWith(
                        color: AppColors.success,
                      ),
                    ),
                    Text(
                      [
                        'Jan',
                        'Feb',
                        'Mar',
                        'Apr',
                        'May',
                        'Jun',
                        'Jul',
                        'Aug',
                        'Sep',
                        'Oct',
                        'Nov',
                        'Dec',
                      ][request.requestedDate.month - 1],
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.success,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.propertyTitle,
                      style: AppTextStyles.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.access_time,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          request.requestedTimeDisplay,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            request.propertyAddress,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  InspectionPricing.formatNaira(request.agentEarnings),
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),

          // Tenant contact
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.primary.withAlpha(26),
                child: Text(
                  request.tenantName.isNotEmpty
                      ? request.tenantName[0].toUpperCase()
                      : 'T',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(request.tenantName, style: AppTextStyles.labelMedium),
                    Text(
                      'Tenant',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (request.tenantPhone != null)
                IconButton(
                  onPressed: _callTenant,
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(26),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.phone,
                      color: AppColors.success,
                      size: 18,
                    ),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: EdgeInsets.zero,
                ),
            ],
          ),

          const SizedBox(height: 16),

          // Arrival & completion section
          if (_isToday(request.requestedDate)) ...[
            if (!request.handlerArrived) ...[
              // Tenant waiting notification
              // Tenant status: arrived takes priority over on-the-way.
              if (request.tenantArrived) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_pin_circle,
                        size: 18,
                        color: AppColors.info,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${request.tenantName} has arrived and is waiting!',
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.info,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (request.tenantOnWay) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.directions_walk,
                        size: 18,
                        color: AppColors.info,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${request.tenantName} is on the way.',
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.info,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // On Way / Arrive button — gates on whether we're
              // within 2h cutoff and whether handler has marked
              // themselves on-way yet.
              if (request.canHandlerMarkOnWay) ...[
                AppButton(
                  text: 'I\'m on my way',
                  onPressed: _markOnWay,
                ),
              ] else if (request.handlerOnWay) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isArrivalLoading ? null : _markArrived,
                    icon: _isArrivalLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.location_on, size: 18),
                    label: Text(
                      _isArrivalLoading
                          ? 'Confirming...'
                          : 'I\'ve Arrived at Property',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ] else ...[
              // Agent arrived — show status + met/complete cascade
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.success.withAlpha(77)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        !request.tenantArrived
                            ? 'You\'re here. Waiting for tenant...'
                            : request.met
                                ? 'Inspection in progress'
                                : 'Both arrived — ready to inspect!',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Prompt the tenant to confirm meeting. Met state
              // unlocks Mark as Completed.
              if (request.canHandlerMarkMet) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 18, color: AppColors.info),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Ask the tenant to confirm they\'ve seen '
                          'you so you can complete the inspection.',
                          style: AppTextStyles.bodySmall
                              .copyWith(color: AppColors.info),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    text: 'I\'ve met the tenant',
                    onPressed: _markMet,
                  ),
                ),
              ] else if (request.canMarkComplete)
                SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    text: 'Mark as Completed',
                    onPressed: _isLoading ? null : _markComplete,
                    isLoading: _isLoading,
                  ),
                ),
            ],
          ] else ...[
            // Not today — Mark as Completed still gated on met.
            // If the inspection hasn't been confirmed met,
            // nothing shows here (handler completes on the day).
            if (request.canMarkComplete)
              SizedBox(
                width: double.infinity,
                child: AppButton(
                  text: 'Mark as Completed',
                  onPressed: _isLoading ? null : _markComplete,
                  isLoading: _isLoading,
                ),
              ),
          ],

          // Reschedule button (hidden when proposal pending, past 2h
          // cutoff, or cap reached)
          if (request.canInitiateReschedule) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _proposeReschedule,
              icon: Icon(
                Icons.event_repeat,
                size: 18,
                color: AppColors.primary,
              ),
              label: Text(
                'Reschedule',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
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

          // Cancel & Refund (handler exit ramp for the tenant)
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _cancelInspection,
            icon: Icon(Icons.cancel_outlined, size: 18, color: AppColors.error),
            label: Text(
              'Cancel & Refund',
              style: AppTextStyles.labelMedium.copyWith(color: AppColors.error),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.error),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              minimumSize: const Size(double.infinity, 0),
            ),
          ),
        ],
      ),
    );
  }
}

// ============ COMPLETED TAB ============
class _AgentCompletedTab extends StatefulWidget {
  final InspectionService inspectionService;
  final String? highlightId;

  const _AgentCompletedTab(
      {required this.inspectionService, this.highlightId});

  @override
  State<_AgentCompletedTab> createState() => _AgentCompletedTabState();
}

class _AgentCompletedTabState extends State<_AgentCompletedTab> {
  // Cached stream — see _AgentPendingTabState for why (avoids the rebuild flicker).
  late final Stream<List<InspectionRequest>> _stream =
      widget.inspectionService.getAgentRequests();

  @override
  Widget build(BuildContext context) {
    final highlightId = widget.highlightId;
    return StreamBuilder<List<InspectionRequest>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final allRequests = snapshot.data ?? [];
        final completedRequests =
            pinToFront(
                allRequests.where((r) => r.isCompleted).toList(),
                (r) => r.id == highlightId);
        final totalEarnings = completedRequests.fold<double>(
          0,
          (sum, r) => sum + r.agentEarnings,
        );

        if (completedRequests.isEmpty) {
          return const GuidanceEmptyState(
            icon: Icons.check_circle_outline,
            title: 'No completed inspections',
            subtitle: 'Your completed inspections will appear here',
          );
        }

        return Column(
          children: [
            // Earnings summary
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.success, AppColors.success.withAlpha(204)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(51),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Earnings',
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: Colors.white.withAlpha(204),
                        ),
                      ),
                      Text(
                        InspectionPricing.formatNaira(totalEarnings),
                        style: AppTextStyles.h3.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Inspections',
                        style: AppTextStyles.caption.copyWith(
                          color: Colors.white.withAlpha(204),
                        ),
                      ),
                      Text(
                        '${completedRequests.length}',
                        style: AppTextStyles.h4.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: completedRequests.length,
                itemBuilder: (context, index) {
                  final request = completedRequests[index];
                  return HighlightWrap(
                    active: request.id == highlightId,
                    child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
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
                          child: Icon(
                            Icons.check_circle,
                            color: AppColors.success,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                request.propertyTitle,
                                style: AppTextStyles.labelMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${request.tenantName} • ${request.formattedDate}',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              if (request.tenantRating != null)
                                Row(
                                  children: [
                                    ...List.generate(
                                      5,
                                      (i) => Icon(
                                        i < request.tenantRating!
                                            ? Icons.star
                                            : Icons.star_border,
                                        size: 12,
                                        color: AppColors.warning,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '+${InspectionPricing.formatNaira(request.agentEarnings)}',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ============ EMPTY STATE ============
