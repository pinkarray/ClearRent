import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/widgets/tab_badge.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';

/// Landlord screen to view and manage reported issues from tenants.
/// Shows issues grouped by status: Open, In Progress, Resolved.
///
/// Accepts optional extras from navigation:
///   - `propertyId` (String?) — filter to a specific property
///   - `category` (String?) — filter to a specific issue category
///   - `initialTab` (int?) — which tab to open (0=Open, 1=In Progress, 2=Pending, 3=Resolved)
///   - `propertyTitle` (String?) — shown in the app bar when filtering
class LandlordIssuesScreen extends StatefulWidget {
  final String? propertyId;
  final String? category;
  final int initialTab;
  final String? propertyTitle;

  const LandlordIssuesScreen({
    super.key,
    this.propertyId,
    this.category,
    this.initialTab = 0,
    this.propertyTitle,
  });

  @override
  State<LandlordIssuesScreen> createState() => _LandlordIssuesScreenState();
}

class _LandlordIssuesScreenState extends State<LandlordIssuesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final AuthService _authService = AuthService();

  // Live per-status counts for the tab badges + the initial-tab pick.
  StreamSubscription? _issuesSub;
  int _openCount = 0;
  int _inProgressCount = 0;
  bool _didInitialTab = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 3),
    );
    _listenIssues();
  }

  @override
  void dispose() {
    _issuesSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  /// Live subscription powering the tab badges (Open / In Progress counts) and,
  /// on the first snapshot, opening the tab of the most recently-updated issue.
  /// Fetches by landlordId only (auto-indexed); filters in code so no composite
  /// index is needed.
  void _listenIssues() {
    final uid = _authService.currentUserId;
    if (uid == null) return;
    _issuesSub = FirebaseFirestore.instance
        .collection('issues')
        .where('landlordId', isEqualTo: uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      var docs = snap.docs;
      if (widget.propertyId != null) {
        docs = docs
            .where((d) => d.data()['propertyId'] == widget.propertyId)
            .toList();
      }
      if (widget.category != null) {
        docs = docs
            .where((d) => d.data()['category'] == widget.category)
            .toList();
      }
      var open = 0;
      var inProg = 0;
      for (final d in docs) {
        final s = d.data()['status'] as String? ?? 'open';
        if (s == 'open') {
          open++;
        } else if (s == 'in_progress') {
          inProg++;
        }
      }
      setState(() {
        _openCount = open;
        _inProgressCount = inProg;
      });

      // First load with no explicit tab → open the most recently-active tab.
      if (!_didInitialTab && widget.initialTab == 0 && docs.isNotEmpty) {
        _didInitialTab = true;
        DateTime ts(QueryDocumentSnapshot<Map<String, dynamic>> d) {
          final data = d.data();
          final v = data['updatedAt'] ?? data['createdAt'];
          return v is Timestamp ? v.toDate() : DateTime(1970);
        }

        final sorted = [...docs]..sort((a, b) => ts(b).compareTo(ts(a)));
        final status = sorted.first.data()['status'] as String? ?? 'open';
        _goToTabForStatus(status);
      }
    }, onError: (_) {});
  }

  static int _tabIndexForStatus(String status) {
    switch (status) {
      case 'in_progress':
        return 1;
      case 'pending_confirmation':
        return 2;
      case 'resolved':
        return 3;
      default:
        return 0;
    }
  }

  /// After an issue's status changes, follow it to its tab.
  void _goToTabForStatus(String status) {
    final idx = _tabIndexForStatus(status);
    if (mounted && _tabController.index != idx) _tabController.animateTo(idx);
  }

  /// Whether this screen is showing filtered results from property health.
  bool get _isFiltered => widget.propertyId != null || widget.category != null;

  String get _appBarTitle {
    if (widget.propertyTitle != null && widget.category != null) {
      return '${_capitalize(widget.category!)} Issues';
    }
    if (widget.propertyTitle != null) {
      return '${widget.propertyTitle} Issues';
    }
    return 'Reported Issues';
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
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
        title: Text(_appBarTitle, style: AppTextStyles.h4),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Column(
            children: [
              // Filter indicator chip
              if (_isFiltered)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Icon(Icons.filter_list, size: 14, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _filterDescription(),
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          // Navigate to unfiltered issues screen
                          context.pop();
                          context.push('/landlord/issues');
                        },
                        child: Text(
                          'View all',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              TabBar(
                controller: _tabController,
                labelColor: AppColors.primary,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.primary,
                indicatorWeight: 3,
                labelStyle: AppTextStyles.labelMedium,
                tabs: [
                  Tab(child: TabBadge(label: 'Open', count: _openCount)),
                  Tab(
                      child: TabBadge(
                          label: 'In Progress', count: _inProgressCount)),
                  const Tab(text: 'Pending'),
                  const Tab(text: 'Resolved'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _IssuesTab(
            status: 'open',
            authService: _authService,
            propertyId: widget.propertyId,
            category: widget.category,
            onMoved: _goToTabForStatus,
          ),
          _IssuesTab(
            status: 'in_progress',
            authService: _authService,
            propertyId: widget.propertyId,
            category: widget.category,
            onMoved: _goToTabForStatus,
          ),
          _IssuesTab(
            status: 'pending_confirmation',
            authService: _authService,
            propertyId: widget.propertyId,
            category: widget.category,
            onMoved: _goToTabForStatus,
          ),
          _IssuesTab(
            status: 'resolved',
            authService: _authService,
            propertyId: widget.propertyId,
            category: widget.category,
            onMoved: _goToTabForStatus,
          ),
        ],
      ),
    );
  }

  String _filterDescription() {
    final parts = <String>[];
    if (widget.propertyTitle != null) parts.add(widget.propertyTitle!);
    if (widget.category != null) parts.add(_capitalize(widget.category!));
    return 'Filtered: ${parts.join(' · ')}';
  }
}

class _IssuesTab extends StatelessWidget {
  final String status;
  final AuthService authService;
  final String? propertyId;
  final String? category;
  final void Function(String newStatus)? onMoved;

  const _IssuesTab({
    required this.status,
    required this.authService,
    this.propertyId,
    this.category,
    this.onMoved,
  });

  @override
  Widget build(BuildContext context) {
    final currentUserId = authService.currentUserId;
    if (currentUserId == null) {
      return const Center(child: Text('Not authenticated'));
    }

    // Build the query with optional filters
    Query query = FirebaseFirestore.instance
        .collection('issues')
        .where('landlordId', isEqualTo: currentUserId)
        .where('status', isEqualTo: status);

    if (propertyId != null) {
      query = query.where('propertyId', isEqualTo: propertyId);
    }
    if (category != null) {
      query = query.where('category', isEqualTo: category);
    }

    query = query.orderBy('createdAt', descending: true);

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }

        if (snapshot.hasError) {
          developer.log('❌ Issues error: ${snapshot.error}', name: 'LandlordIssues');
          return GuidanceEmptyState(
            icon: Icons.error_outline,
            title: 'Error loading issues',
            subtitle: 'Please try again later',
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          String subtitle;
          switch (status) {
            case 'open':
              subtitle = 'No open issues from tenants';
              break;
            case 'in_progress':
              subtitle = 'Issues you\'re working on will appear here';
              break;
            case 'pending_confirmation':
              subtitle = 'Issues awaiting tenant confirmation will appear here';
              break;
            default:
              subtitle = 'Resolved issues will appear here';
          }
          return GuidanceEmptyState(
            icon: status == 'resolved'
                ? Icons.check_circle_outline
                : status == 'pending_confirmation'
                    ? Icons.hourglass_empty_outlined
                    : Icons.report_off_outlined,
            title: status == 'pending_confirmation'
                ? 'No pending confirmations'
                : 'No ${status.replaceAll('_', ' ')} issues',
            subtitle: subtitle,
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            final docId = docs[index].id;
            return _IssueCard(
              issueId: docId,
              data: data,
              currentStatus: status,
              onMoved: onMoved,
            );
          },
        );
      },
    );
  }
}

class _IssueCard extends StatefulWidget {
  final String issueId;
  final Map<String, dynamic> data;
  final String currentStatus;
  final void Function(String newStatus)? onMoved;

  const _IssueCard({
    required this.issueId,
    required this.data,
    required this.currentStatus,
    this.onMoved,
  });

  @override
  State<_IssueCard> createState() => _IssueCardState();
}

class _IssueCardState extends State<_IssueCard> {
  final ConversationService _conversationService = ConversationService();
  bool _isUpdating = false;
  bool _isMessageLoading = false;

  String get _title => widget.data['title'] ?? 'Untitled Issue';
  String get _description => widget.data['description'] ?? '';
  String get _category => widget.data['category'] ?? 'other';
  String get _priority => widget.data['priority'] ?? 'medium';
  String get _tenantName => widget.data['tenantName'] ?? 'Tenant';
  String get _propertyTitle => widget.data['propertyTitle'] ?? 'Property';
  List<String> get _images =>
      List<String>.from(widget.data['images'] ?? []);

  DateTime? get _createdAt {
    final ts = widget.data['createdAt'];
    if (ts is Timestamp) return ts.toDate();
    return null;
  }

  IconData _getCategoryIcon() {
    switch (_category) {
      case 'plumbing': return Icons.plumbing;
      case 'electrical': return Icons.electrical_services;
      case 'structural': return Icons.foundation;
      case 'appliance': return Icons.kitchen;
      case 'pest': return Icons.bug_report;
      case 'security': return Icons.security;
      case 'cleaning': return Icons.cleaning_services;
      default: return Icons.report_problem_outlined;
    }
  }

  Color _getPriorityColor() {
    switch (_priority) {
      case 'high': return AppColors.error;
      case 'medium': return AppColors.warning;
      case 'low': return AppColors.info;
      default: return AppColors.textHint;
    }
  }

  Future<void> _updateStatus(String newStatus) async {
    setState(() => _isUpdating = true);
    try {
      final updateData = <String, dynamic>{
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
        if (newStatus == 'pending_confirmation')
          'pendingConfirmationAt': FieldValue.serverTimestamp(),
        if (newStatus == 'resolved')
          'resolvedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update(updateData);

      // The tenant's push + inbox notification is handled by the
      // `onIssueUpdated` Cloud Function (single source of truth), which fires
      // on this status change. No client-side notification write needed.

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newStatus == 'pending_confirmation'
              ? 'Tenant has been asked to confirm the fix.'
              : newStatus == 'in_progress'
                  ? 'Issue marked as in progress.'
                  : 'Issue re-opened.'),
          backgroundColor: newStatus == 'pending_confirmation'
              ? AppColors.info
              : AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        // Follow the issue to its new tab so the user sees where it went.
        widget.onMoved?.call(newStatus);
      }
    } catch (e) {
      developer.log('❌ Error updating issue: $e', name: 'LandlordIssues');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to update issue'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _messageTenant() async {
    setState(() => _isMessageLoading = true);
    try {
      final landlordId = widget.data['landlordId'] ?? '';
      final tenantId = widget.data['tenantId'] ?? '';

      if (landlordId.isEmpty || tenantId.isEmpty) {
        if (mounted) setState(() => _isMessageLoading = false);
        return;
      }

      String landlordName = widget.data['landlordName'] ?? '';
      String tenantName = _tenantName;
      try {
        final results = await Future.wait([
          FirebaseFirestore.instance.collection('users').doc(landlordId).get(),
          FirebaseFirestore.instance.collection('users').doc(tenantId).get(),
        ]);
        final landlordDoc = results[0];
        final tenantDoc = results[1];
        if (landlordDoc.exists) {
          landlordName = landlordDoc.data()?['fullName'] ?? landlordName;
        }
        if (tenantDoc.exists) {
          tenantName = tenantDoc.data()?['fullName'] ?? tenantName;
        }
      } catch (_) {}

      final conv = await _conversationService.getOrCreateConversation(
        propertyId: widget.data['propertyId'] ?? '',
        propertyTitle: _propertyTitle,
        propertyImage: '',
        landlordId: landlordId,
        landlordName: landlordName,
        tenantId: tenantId,
        tenantName: tenantName,
      );
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': _propertyTitle,
          'propertyImage': null,
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Could not open chat. Both parties must be verified.'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => _isMessageLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _priority == 'high'
              ? AppColors.error.withAlpha(77)
              : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: category + priority + date
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _getPriorityColor().withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_getCategoryIcon(),
                  size: 20, color: _getPriorityColor()),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title, style: AppTextStyles.labelLarge,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _getPriorityColor().withAlpha(26),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _priority.toUpperCase(),
                        style: AppTextStyles.labelSmall.copyWith(
                          color: _getPriorityColor(),
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _category.replaceAll('_', ' ').toUpperCase(),
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint, fontSize: 10),
                    ),
                  ]),
                ],
              ),
            ),
            if (_createdAt != null)
              Text(
                DateFormat('d MMM').format(_createdAt!),
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textHint),
              ),
          ]),

          const SizedBox(height: 12),
          Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 12),

          // Property + tenant
          Row(children: [
            Icon(Icons.home_outlined,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(_propertyTitle,
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
            Icon(Icons.person_outline,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Text(_tenantName,
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary)),
          ]),

          // Description
          if (_description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_description,
                style: AppTextStyles.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ],

          // Images
          if (_images.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 70,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _images.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: _images[i],
                      width: 70,
                      height: 70,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 70,
                        height: 70,
                        color: AppColors.border,
                        child: const Icon(Icons.broken_image, size: 20),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],

          // Pending confirmation banner
          if (widget.currentStatus == 'pending_confirmation') ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.info.withAlpha(60)),
              ),
              child: Row(children: [
                Icon(Icons.hourglass_top_rounded,
                    size: 16, color: AppColors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Waiting for tenant to confirm this fix. Once confirmed, the issue will be marked resolved.',
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.info, height: 1.4),
                  ),
                ),
              ]),
            ),
          ],

          // Dispute reason
          if (widget.data['disputeReason'] != null &&
              widget.currentStatus == 'in_progress') ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(13),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.error.withAlpha(60)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.error),
                  const SizedBox(width: 6),
                  Text('Tenant Disputed This Fix',
                      style: AppTextStyles.labelSmall.copyWith(color: AppColors.error)),
                ]),
                const SizedBox(height: 4),
                Text(
                  '"${widget.data['disputeReason']}"',
                  style: AppTextStyles.caption.copyWith(
                      color: AppColors.error, fontStyle: FontStyle.italic, height: 1.4),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 16),

          // Action buttons
          Row(children: [
            // Message tenant
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isMessageLoading ? null : _messageTenant,
                icon: _isMessageLoading
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.primary))
                    : const Icon(Icons.chat_outlined, size: 18),
                label: const Text('Message'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // open → working on it
            if (widget.currentStatus == 'open')
              Expanded(
                child: ElevatedButton(
                  onPressed: _isUpdating
                      ? null
                      : () => _updateStatus('in_progress'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isUpdating
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Working On It'),
                ),
              ),

            // in_progress → mark fixed
            if (widget.currentStatus == 'in_progress')
              Expanded(
                child: ElevatedButton(
                  onPressed: _isUpdating
                      ? null
                      : () => _updateStatus('pending_confirmation'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.info,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isUpdating
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Mark Fixed'),
                ),
              ),

            // pending_confirmation → still working
            if (widget.currentStatus == 'pending_confirmation')
              Expanded(
                child: OutlinedButton(
                  onPressed: _isUpdating
                      ? null
                      : () => _updateStatus('in_progress'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    side: BorderSide(color: AppColors.warning),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isUpdating
                      ? SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.warning))
                      : Text('Still Working',
                          style: TextStyle(color: AppColors.warning)),
                ),
              ),

            // resolved → re-open
            if (widget.currentStatus == 'resolved')
              Expanded(
                child: OutlinedButton(
                  onPressed: _isUpdating
                      ? null
                      : () => _updateStatus('open'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    side: BorderSide(color: AppColors.warning),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text('Re-open',
                      style: TextStyle(color: AppColors.warning)),
                ),
              ),
          ]),
        ],
      ),
    );
  }
}

