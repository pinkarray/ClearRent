import 'package:flutter/material.dart';
import 'dart:io';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
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
import '../../../../services/active_rental_service.dart';

class LandlordInspectionsScreen extends StatefulWidget {
  const LandlordInspectionsScreen({super.key});

  @override
  State<LandlordInspectionsScreen> createState() =>
      _LandlordInspectionsScreenState();
}

class _LandlordInspectionsScreenState extends State<LandlordInspectionsScreen>
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
          onPressed: () => context.pop(),
        ),
        title: Text('Inspection Requests', style: AppTextStyles.h4),
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
          _LandlordPendingTab(inspectionService: _inspectionService),
          _LandlordUpcomingTab(inspectionService: _inspectionService),
          _LandlordHistoryTab(inspectionService: _inspectionService),
        ],
      ),
    );
  }
}

// ============================================================
// PENDING TAB
// ============================================================
class _LandlordPendingTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _LandlordPendingTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getLandlordRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        if (snapshot.hasError) {
          return const _EmptyState(
            icon: Icons.error_outline,
            title: 'Error loading',
            subtitle: 'Please try again later',
          );
        }
        final pending =
            (snapshot.data ?? [])
                .where((r) => r.isPending || r.isDeclinedByAgent)
                .toList();
        if (pending.isEmpty) {
          return const _EmptyState(
            icon: Icons.inbox_outlined,
            title: 'No pending requests',
            subtitle: 'Inspection requests from tenants will appear here',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: pending.length,
          itemBuilder:
              (context, i) => _LandlordPendingCard(
                request: pending[i],
                inspectionService: inspectionService,
              ),
        );
      },
    );
  }
}

class _LandlordPendingCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  const _LandlordPendingCard({
    required this.request,
    required this.inspectionService,
  });

  @override
  State<_LandlordPendingCard> createState() => _LandlordPendingCardState();
}

class _LandlordPendingCardState extends State<_LandlordPendingCard> {
  final ConversationService _conversationService = ConversationService();
  bool _isLoading = false;
  bool _isMessageLoading = false;

  Future<void> _approve() async {
    setState(() => _isLoading = true);
    final ok = await widget.inspectionService.approveRequest(widget.request.id);
    if (!mounted) return;
    setState(() => _isLoading = false);
    _snack(
      ok ? 'Inspection approved! Tenant notified.' : 'Failed to approve.',
      ok ? AppColors.success : AppColors.error,
    );
  }

  Future<void> _decline() async {
    final reason = await _showDeclineDialog();
    if (reason == null) return;
    setState(() => _isLoading = true);
    final ok = await widget.inspectionService.landlordDeclineRequest(
      widget.request.id,
      reason: reason.isEmpty ? null : reason,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (ok) {
      _snack('Request declined. Tenant notified.', AppColors.textSecondary);
    }
  }

  Future<String?> _showDeclineDialog() async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Decline Request'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The tenant will be notified.',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: c,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'Reason (optional)',
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
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: Text(
                  'Decline',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _messageTenant() async {
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
        context.push(
          '/chat',
          extra: {
            'conversationId': conv.id,
            'propertyTitle': r.propertyTitle,
            'propertyImage':
                r.propertyImage.isNotEmpty ? r.propertyImage : null,
          },
        );
      } else {
        _snack('Could not start conversation.', AppColors.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
    }
  }

  void _snack(String msg, Color c) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor: c,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final agentDeclined = r.isDeclinedByAgent;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            agentDeclined
                ? Border.all(color: AppColors.warning, width: 2)
                : null,
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
          // Agent declined banner
          if (agentDeclined) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.warning,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Agent Declined',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.warning,
                          ),
                        ),
                        Text(
                          r.declineReason ?? 'You can approve this yourself.',
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
            const SizedBox(height: 12),
          ],

          // Property row
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child:
                    r.propertyImage.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl: r.propertyImage,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholderBox(60),
                        )
                        : _placeholderBox(60),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.propertyTitle,
                      style: AppTextStyles.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      r.propertyAddress,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Tenant row
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.primary.withAlpha(26),
                child: Text(
                  r.tenantName.isNotEmpty ? r.tenantName[0].toUpperCase() : 'T',
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
                    Text(r.tenantName, style: AppTextStyles.labelMedium),
                    Text(
                      'Tenant',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _messageButton(loading: _isMessageLoading, onTap: _messageTenant),
            ],
          ),
          const SizedBox(height: 16),

          // Date
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
                        r.formattedDate,
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                      Text(
                        r.requestedTimeDisplay,
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

          // Notes
          if (r.notes != null && r.notes!.isNotEmpty) ...[
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
                      r.notes!,
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
                  onPressed: _isLoading ? null : _decline,
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
                  text: agentDeclined ? 'Approve Anyway' : 'Approve',
                  onPressed: _isLoading ? null : _approve,
                  isLoading: _isLoading,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// UPCOMING TAB
// ============================================================
class _LandlordUpcomingTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _LandlordUpcomingTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getLandlordRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        final all = snapshot.data ?? [];
        final upcoming =
            all.where((r) => r.isApproved).toList()
              ..sort((a, b) => a.requestedDate.compareTo(b.requestedDate));
        if (upcoming.isEmpty) {
          return const _EmptyState(
            icon: Icons.event_available_outlined,
            title: 'No upcoming inspections',
            subtitle: 'Approved inspections will appear here',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: upcoming.length,
          itemBuilder:
              (ctx, i) => _LandlordUpcomingCard(
                request: upcoming[i],
                inspectionService: inspectionService,
              ),
        );
      },
    );
  }
}

class _LandlordUpcomingCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  const _LandlordUpcomingCard({
    required this.request,
    required this.inspectionService,
  });

  @override
  State<_LandlordUpcomingCard> createState() => _LandlordUpcomingCardState();
}

class _LandlordUpcomingCardState extends State<_LandlordUpcomingCard> {
  final ConversationService _conversationService = ConversationService();
  bool _isLoading = false;
  bool _isMessageLoading = false;
  bool _isArrivalLoading = false;

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  String _monthAbbr(int m) =>
      const [
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
      ][m - 1];

  Future<void> _markComplete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Complete Inspection'),
            content: const Text('Mark this inspection as completed?'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
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
    final ok = await widget.inspectionService.completeInspection(
      widget.request.id,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Inspection completed!'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _markArrived() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Confirm Arrival'),
            content: const Text(
              'Are you at the property? This will notify the tenant that you\'re ready.',
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
          content: const Text('You\'ve been marked as arrived! âœ“'),
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
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _messageTenant() async {
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
        context.push(
          '/chat',
          extra: {
            'conversationId': conv.id,
            'propertyTitle': r.propertyTitle,
            'propertyImage':
                r.propertyImage.isNotEmpty ? r.propertyImage : null,
          },
        );
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
    final isAgent = r.agentId != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: today ? AppColors.primary : AppColors.success.withAlpha(77),
          width: today ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badges
          Row(
            children: [
              if (today)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
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
              if (isAgent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.support_agent,
                        size: 16,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Agent Handling',
                        style: AppTextStyles.labelSmall.copyWith(
                          color: AppColors.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (today || isAgent) const SizedBox(height: 12),

          // Date + property
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
                      '${r.requestedDate.day}',
                      style: AppTextStyles.h4.copyWith(
                        color: AppColors.success,
                      ),
                    ),
                    Text(
                      _monthAbbr(r.requestedDate.month),
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
                    Text(r.propertyTitle, style: AppTextStyles.labelLarge),
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
                          r.requestedTimeDisplay,
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
                            r.propertyAddress,
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
                  r.tenantName.isNotEmpty ? r.tenantName[0].toUpperCase() : 'T',
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
                    Text(r.tenantName, style: AppTextStyles.labelMedium),
                    Text(
                      'Tenant',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _messageButton(loading: _isMessageLoading, onTap: _messageTenant),
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
              ),
            ],
          ),

          // Complete button (only if landlord handles, not agent)
          // Arrival & completion section (only if landlord self-handles)
          if (!isAgent && today) ...[
            const SizedBox(height: 16),

            // Show arrival status
            if (!r.handlerArrived) ...[
              // Landlord hasn't arrived yet â€” show arrival button
              if (r.tenantArrived) ...[
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
                          '${r.tenantName} has arrived and is waiting!',
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
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isArrivalLoading ? null : _markArrived,
                  icon:
                      _isArrivalLoading
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
            ] else ...[
              // Landlord arrived â€” show status + complete button
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
                        r.tenantArrived
                            ? 'Both arrived â€” ready to inspect!'
                            : 'You\'re here. Waiting for tenant...',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Only show complete when BOTH arrived
              if (r.bothArrived)
                SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    text: 'Mark as Completed',
                    onPressed: _isLoading ? null : _markComplete,
                    isLoading: _isLoading,
                  ),
                ),
            ],
          ],

          // Agent contact section (when agent is handling)
          if (isAgent) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.success.withAlpha(26),
                  child: Icon(
                    Icons.support_agent,
                    size: 18,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.agentName ?? 'Agent',
                        style: AppTextStyles.labelMedium,
                      ),
                      Text(
                        'Assigned Agent',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (r.agentPhone != null && r.agentPhone!.isNotEmpty)
                  IconButton(
                    onPressed: () async {
                      final uri = Uri.parse('tel:${r.agentPhone}');
                      if (await canLaunchUrl(uri)) await launchUrl(uri);
                    },
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
                  ),
              ],
            ),
            // Fallback complete â€” landlord can always complete as property owner
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _isLoading ? null : _markComplete,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child:
                    _isLoading
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(
                          'Mark as Completed',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
              ),
            ),
          ],

          // Self-handled complete button
          if (!isAgent) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: 'Mark as Completed',
                onPressed: _isLoading ? null : _markComplete,
                isLoading: _isLoading,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// HISTORY TAB â€” WITH RENTAL INTEREST TRACKING
// ============================================================
class _LandlordHistoryTab extends StatelessWidget {
  final InspectionService inspectionService;
  const _LandlordHistoryTab({required this.inspectionService});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InspectionRequest>>(
      stream: inspectionService.getLandlordRequests(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        final all = snapshot.data ?? [];
        final history =
            all
                .where((r) => r.isCompleted || r.isDeclined || r.isCancelled)
                .toList()
              ..sort(
                (a, b) => (b.completedAt ?? b.createdAt).compareTo(
                  a.completedAt ?? a.createdAt,
                ),
              );

        if (history.isEmpty) {
          return const _EmptyState(
            icon: Icons.history,
            title: 'No history yet',
            subtitle: 'Completed inspections will appear here',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: history.length,
          itemBuilder:
              (ctx, i) => _LandlordHistoryCard(
                request: history[i],
                inspectionService: inspectionService,
              ),
        );
      },
    );
  }
}

class _LandlordHistoryCard extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;
  const _LandlordHistoryCard({
    required this.request,
    required this.inspectionService,
  });

  @override
  State<_LandlordHistoryCard> createState() => _LandlordHistoryCardState();
}

class _LandlordHistoryCardState extends State<_LandlordHistoryCard> {
  final RentalInterestService _rentalInterestService = RentalInterestService();
  final ActiveRentalService _activeRentalService = ActiveRentalService();
  RentalInterest? _rentalInterest;
  bool _isLoadingInterest = true;
  bool _isAccepting = false;

  @override
  void initState() {
    super.initState();
    if (widget.request.isCompleted) {
      _loadInterest();
    } else {
      _isLoadingInterest = false;
    }
  }

  Future<void> _loadInterest() async {
    try {
      final interest = await _rentalInterestService.getInterestForInspection(
        widget.request.id,
      );
      if (mounted) {
        setState(() {
          _rentalInterest = interest;
          _isLoadingInterest = false;
        });
      }
    } catch (e) {
      developer.log('❌ Error loading interest: $e', name: 'LandlordHistory');
      if (mounted) setState(() => _isLoadingInterest = false);
    }
  }

  Future<void> _acceptRental() async {
    final interest = _rentalInterest;
    if (interest == null) return;

    // Step 1: Confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.celebration, color: AppColors.success),
                const SizedBox(width: 8),
                const Text('Accept Rental'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Accept ${interest.tenantName} as your tenant for:',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        interest.propertyTitle,
                        style: AppTextStyles.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Payment of ₦${_formatAmount(interest.paymentAmount)} verified.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.success,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(13),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.success.withAlpha(51)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This will mark the property as rented and create an active rental record.',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
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
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Accept Tenant'),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    // Step 2: Ask to upload agreement (optional)
    String? agreementUrl;
    if (mounted) {
      agreementUrl = await _showAgreementUploadDialog();
    }

    setState(() => _isAccepting = true);

    try {
      // Accept the rental interest
      final accepted = await _rentalInterestService.acceptRentalInterest(
        interest.id,
      );
      if (!accepted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Failed to accept. Try again.'),
              backgroundColor: AppColors.error,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
        return;
      }

      // Create the active rental
      final rental = await _activeRentalService.createActiveRental(
        rentalInterest: interest,
        inspectionRequest: widget.request,
      );

      // If landlord uploaded agreement, attach it
      if (rental != null && agreementUrl != null && agreementUrl.isNotEmpty) {
        await _activeRentalService.uploadAgreement(rental.id, agreementUrl);
      }

      // Reload interest BEFORE showing success â€” await it
      if (mounted) {
        await _loadInterest();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              agreementUrl != null
                  ? 'ðŸŽ‰ Rental confirmed with agreement attached!'
                  : 'ðŸŽ‰ Rental confirmed! You can upload the agreement later.',
            ),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      developer.log('❌ Accept error: $e', name: 'LandlordHistory');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Something went wrong.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isAccepting = false);
    }
  }

  Future<String?> _showAgreementUploadDialog() async {
    // Use PropertyService for image upload (has cloudinary_public)
    final propertyService = PropertyService();
    String? uploadedUrl;
    bool isUploading = false;

    return showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setDialogState) => AlertDialog(
                  title: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        color: AppColors.info,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Tenancy Agreement')),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Upload your tenancy agreement for the tenant to review.',
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),

                      if (uploadedUrl != null) ...[
                        // Show uploaded confirmation
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.success.withAlpha(26),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.success.withAlpha(77),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: AppColors.success,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Agreement uploaded!',
                                  style: AppTextStyles.labelMedium.copyWith(
                                    color: AppColors.success,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap:
                                    () => setDialogState(
                                      () => uploadedUrl = null,
                                    ),
                                child: Icon(
                                  Icons.close,
                                  size: 18,
                                  color: AppColors.textHint,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        // Upload button
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed:
                                isUploading
                                    ? null
                                    : () async {
                                      final picker = ImagePicker();
                                      final image = await picker.pickImage(
                                        source: ImageSource.gallery,
                                        maxWidth: 2000,
                                      );
                                      if (image == null) return;

                                      setDialogState(() => isUploading = true);
                                      try {
                                        // Use PropertyService.uploadImage
                                        final url = await propertyService
                                            .uploadImage(File(image.path));
                                        if (url != null) {
                                          setDialogState(() {
                                            uploadedUrl = url;
                                            isUploading = false;
                                          });
                                        } else {
                                          setDialogState(
                                            () => isUploading = false,
                                          );
                                        }
                                      } catch (e) {
                                        setDialogState(
                                          () => isUploading = false,
                                        );
                                      }
                                    },
                            icon:
                                isUploading
                                    ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.primary,
                                      ),
                                    )
                                    : const Icon(Icons.upload_file),
                            label: Text(
                              isUploading ? 'Uploading...' : 'Upload Agreement',
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: BorderSide(color: AppColors.primary),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(height: 12),
                      Text(
                        'You can also upload this later from your rental management screen.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textHint,
                        ),
                      ),
                    ],
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, null), // Skip
                      child: Text(
                        'Skip for now',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                    if (uploadedUrl != null)
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, uploadedUrl),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Continue'),
                      ),
                  ],
                ),
          ),
    );
  }

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
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
    } else {
      statusColor = AppColors.textHint;
      statusIcon = Icons.help_outline;
      statusText = r.statusDisplay;
    }

    final hasVerified =
        _rentalInterest?.status == RentalInterestStatus.paymentVerified;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            hasVerified ? Border.all(color: AppColors.success, width: 2) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ðŸ”’ LOCKED IN BANNER
          if (hasVerified) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.success.withAlpha(77)),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock, size: 20, color: AppColors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PAYMENT CONFIRMED â€” LOCKED IN',
                          style: AppTextStyles.labelSmall.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tenant has paid. Accept the rental below.',
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
            const SizedBox(height: 12),
          ],

          // Property + status row
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    r.propertyImage.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl: r.propertyImage,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholderBox(50),
                        )
                        : _placeholderBox(50),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.propertyTitle,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      r.formattedDate,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 4),
                    Text(
                      statusText,
                      style: AppTextStyles.labelSmall.copyWith(
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Tenant rating display
          if (r.isCompleted && r.tenantRated && r.tenantRating != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            // Show who the rating was given to
            if (r.ratedUserType != null) ...[
              Row(
                children: [
                  Icon(
                    r.ratedUserType == 'agent'
                        ? Icons.support_agent
                        : Icons.person_outline,
                    size: 13,
                    color: AppColors.textHint,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    r.ratedUserType == 'agent'
                        ? 'Rating given to agent: ${r.ratedUserName ?? r.agentName ?? 'Agent'}'
                        : 'Rating given to you',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            Row(
              children: [
                Text(
                  'Tenant rating: ',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                ...List.generate(
                  5,
                  (i) => Icon(
                    i < r.tenantRating! ? Icons.star : Icons.star_border,
                    size: 16,
                    color: AppColors.warning,
                  ),
                ),
                if (r.tenantReview != null && r.tenantReview!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 14,
                    color: AppColors.textHint,
                  ),
                ],
              ],
            ),
            if (r.tenantReview != null && r.tenantReview!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '"${r.tenantReview}"',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ],

          // Waiting for rating
          if (r.isCompleted && !r.tenantRated) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.hourglass_top,
                  size: 16,
                  color: AppColors.textHint,
                ),
                const SizedBox(width: 8),
                Text(
                  'Waiting for tenant to rate...',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textHint,
                  ),
                ),
              ],
            ),
          ],

          // Rental interest status
          if (_rentalInterest != null) ...[
            const SizedBox(height: 16),
            _buildRentalInterestStatus(),
          ],

          // Loading indicator
          if (r.isCompleted && _isLoadingInterest) ...[
            const SizedBox(height: 12),
            Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRentalInterestStatus() {
    final interest = _rentalInterest!;

    Color statusColor;
    IconData statusIcon;
    String title;
    String subtitle;

    switch (interest.status) {
      case RentalInterestStatus.pendingPayment:
        statusColor = AppColors.warning;
        statusIcon = Icons.payment;
        title = 'Tenant Interested â€” Payment Pending';
        subtitle = '${interest.tenantName} wants to rent. Waiting for payment.';
        break;
      case RentalInterestStatus.paymentUploaded:
        statusColor = AppColors.info;
        statusIcon = Icons.hourglass_top;
        title = 'Payment Uploaded â€” Verifying';
        subtitle = 'Admin is verifying the tenant\'s payment.';
        break;
      case RentalInterestStatus.paymentVerified:
        statusColor = AppColors.success;
        statusIcon = Icons.lock;
        title = 'ðŸ”’ Payment Verified â€” Accept Rental';
        subtitle =
            '${interest.tenantName}\'s payment has been confirmed. Accept below.';
        break;
      case RentalInterestStatus.rejected:
        statusColor = AppColors.error;
        statusIcon = Icons.error_outline;
        title = 'Payment Rejected';
        subtitle = 'Tenant needs to re-upload payment proof.';
        break;
      case RentalInterestStatus.accepted:
        statusColor = AppColors.success;
        statusIcon = Icons.celebration;
        title = 'ðŸŽ‰ Rental Active';
        subtitle = '${interest.tenantName} is now your tenant.';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusColor.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withAlpha(51)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(statusIcon, size: 24, color: statusColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.labelMedium.copyWith(
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Accept button for paymentVerified status
          if (interest.status == RentalInterestStatus.paymentVerified) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isAccepting ? null : _acceptRental,
                icon:
                    _isAccepting
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Icon(Icons.check_circle, size: 20),
                label: Text(_isAccepting ? 'Processing...' : 'Accept Rental'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// SHARED HELPERS
// ============================================================
Widget _placeholderBox(double size) => Container(
  width: size,
  height: size,
  color: AppColors.background,
  child: Icon(Icons.home, color: AppColors.textHint),
);

Widget _messageButton({required bool loading, required VoidCallback onTap}) =>
    IconButton(
      onPressed: loading ? null : onTap,
      icon:
          loading
              ? SizedBox(
                width: 34,
                height: 34,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
              )
              : Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.chat_outlined,
                  color: AppColors.primary,
                  size: 18,
                ),
              ),
    );

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: AppColors.primary),
            ),
            const SizedBox(height: 24),
            Text(title, style: AppTextStyles.h4, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}