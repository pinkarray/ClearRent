import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';

/// Full issue history for a tenant — all issues ever reported, grouped by
/// property. Permanent record that survives tenancy changes / landlord removals.
class TenantIssueHistoryScreen extends StatelessWidget {
  const TenantIssueHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = AuthService().currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Issue History', style: AppTextStyles.h4),
      ),
      body: uid.isEmpty
          ? const Center(child: Text('Not logged in'))
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('issues')
                  .where('tenantId', isEqualTo: uid)
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                      child: CircularProgressIndicator(color: AppColors.primary));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.error_outline, color: AppColors.error, size: 48),
                      const SizedBox(height: 12),
                      Text('Failed to load issues',
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: AppColors.textSecondary)),
                    ]),
                  );
                }

                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) return _buildEmpty();

                // Group by propertyId
                final grouped = <String, List<QueryDocumentSnapshot>>{};
                final propertyTitles = <String, String>{};
                for (final doc in docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  final pid = (data['propertyId'] as String?) ?? 'unknown';
                  grouped.putIfAbsent(pid, () => []).add(doc);
                  propertyTitles[pid] =
                      (data['propertyTitle'] as String?)?.trim().isNotEmpty == true
                          ? data['propertyTitle'] as String
                          : 'Unknown Property';
                }

                final propertyIds = grouped.keys.toList();

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                  itemCount: propertyIds.length,
                  itemBuilder: (context, i) {
                    final pid = propertyIds[i];
                    final issues = grouped[pid]!;
                    final title = propertyTitles[pid]!;
                    return _PropertyIssueGroup(
                        propertyTitle: title, issues: issues);
                  },
                );
              },
            ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
              color: AppColors.success.withAlpha(26), shape: BoxShape.circle),
          child:
              Icon(Icons.check_circle_outline, color: AppColors.success, size: 40),
        ),
        const SizedBox(height: 20),
        Text('No Issues Reported',
            style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Text('You haven\'t reported any issues yet.',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint)),
      ]),
    );
  }
}

// ── Per-property group ────────────────────────────────────────────────────────

class _PropertyIssueGroup extends StatefulWidget {
  final String propertyTitle;
  final List<QueryDocumentSnapshot> issues;
  const _PropertyIssueGroup(
      {required this.propertyTitle, required this.issues});

  @override
  State<_PropertyIssueGroup> createState() => _PropertyIssueGroupState();
}

class _PropertyIssueGroupState extends State<_PropertyIssueGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final resolved =
        widget.issues.where((d) => (d.data() as Map)['status'] == 'resolved').length;
    final open = widget.issues.length - resolved;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        // Header — tap to collapse
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.home_outlined,
                    color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.propertyTitle,
                      style: AppTextStyles.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '$open open · $resolved resolved · ${widget.issues.length} total',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ]),
              ),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                color: AppColors.textSecondary,
              ),
            ]),
          ),
        ),

        // Issue cards
        if (_expanded) ...[
          const Divider(height: 1),
          ...widget.issues.map((doc) => _IssueHistoryTile(
              issueId: doc.id,
              data: doc.data() as Map<String, dynamic>)),
        ],
      ]),
    );
  }
}

// ── Single issue row ──────────────────────────────────────────────────────────

class _IssueHistoryTile extends StatelessWidget {
  final String issueId;
  final Map<String, dynamic> data;
  const _IssueHistoryTile({required this.issueId, required this.data});

  List<String> get _images => List<String>.from(data['images'] ?? []);

  @override
  Widget build(BuildContext context) {
    final status = (data['status'] as String?) ?? 'open';
    final category = (data['category'] as String?) ?? 'general';
    final title = (data['title'] as String?)?.trim().isNotEmpty == true
        ? data['title'] as String
        : category;
    final priority = (data['priority'] as String?) ?? 'low';
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

    final statusColor = _statusColor(status);
    final statusLabel = _statusLabel(status);

    return GestureDetector(
      onTap: () => _showIssueDetail(context),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Category icon
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: _categoryColor(category).withAlpha(26),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(_categoryIcon(category),
                color: _categoryColor(category), size: 18),
          ),
          const SizedBox(width: 12),
          // Content
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(title,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                // Status chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: statusColor.withAlpha(26),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: statusColor.withAlpha(77))),
                  child: Text(statusLabel,
                      style: AppTextStyles.caption.copyWith(
                          color: statusColor, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                // Priority dot
                Container(
                  width: 6, height: 6,
                  margin: const EdgeInsets.only(right: 5, top: 1),
                  decoration: BoxDecoration(
                      color: _priorityColor(priority), shape: BoxShape.circle),
                ),
                Text('${_capitalize(priority)} priority',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
                if (_images.isNotEmpty) ...[
                  Text(' · ',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  Icon(Icons.photo_outlined, size: 13, color: AppColors.textHint),
                  const SizedBox(width: 2),
                  Text('${_images.length}',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                ],
                if (createdAt != null) ...[
                  Text(' · ',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  Text(_formatDate(createdAt),
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                ],
              ]),
            ]),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 18, color: AppColors.textHint),
        ]),
      ),
    );
  }

  void _showIssueDetail(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _IssueDetailScreen(issueId: issueId, data: data),
      ),
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'open':           return AppColors.error;
      case 'in_progress':   return AppColors.warning;
      case 'pending_confirmation': return AppColors.info;
      case 'resolved':      return AppColors.success;
      default:              return AppColors.textSecondary;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'open':           return 'Open';
      case 'in_progress':   return 'In Progress';
      case 'pending_confirmation': return 'Awaiting Confirm';
      case 'resolved':      return 'Resolved';
      default:              return _capitalize(s);
    }
  }

  Color _priorityColor(String p) {
    switch (p) {
      case 'high':   return AppColors.error;
      case 'medium': return AppColors.warning;
      default:       return AppColors.success;
    }
  }

  Color _categoryColor(String c) {
    switch (c) {
      case 'plumbing':     return const Color(0xFF3B82F6);
      case 'electrical':  return const Color(0xFFF59E0B);
      case 'structural':  return const Color(0xFFEF4444);
      case 'pest':        return const Color(0xFF8B5CF6);
      case 'appliance':   return const Color(0xFF10B981);
      default:            return AppColors.primary;
    }
  }

  IconData _categoryIcon(String c) {
    switch (c) {
      case 'plumbing':    return Icons.water_drop_outlined;
      case 'electrical':  return Icons.bolt_outlined;
      case 'structural':  return Icons.foundation_outlined;
      case 'pest':        return Icons.pest_control_outlined;
      case 'appliance':   return Icons.kitchen_outlined;
      default:            return Icons.report_problem_outlined;
    }
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  String _formatDate(DateTime d) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

// ── Issue Detail Screen ───────────────────────────────────────────────────────

class _IssueDetailScreen extends StatelessWidget {
  final String issueId;
  final Map<String, dynamic> data;
  const _IssueDetailScreen({required this.issueId, required this.data});

  List<String> get _images => List<String>.from(data['images'] ?? []);
  String get _status => (data['status'] as String?) ?? 'open';
  String get _category => (data['category'] as String?) ?? 'general';
  String get _priority => (data['priority'] as String?) ?? 'low';
  String get _title => (data['title'] as String?)?.trim().isNotEmpty == true
      ? data['title'] as String
      : _category;
  String get _description => (data['description'] as String?) ?? '';
  String get _propertyTitle => (data['propertyTitle'] as String?) ?? 'Property';
  DateTime? get _createdAt => (data['createdAt'] as Timestamp?)?.toDate();
  String? get _landlordNote => data['landlordNote'] as String?;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Issue Details', style: AppTextStyles.h4),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status + priority header. Wrapped so a long status label
            // ellipsizes on narrow screens instead of overflowing the row.
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: _buildStatusChip()),
                      const SizedBox(width: 8),
                      _buildPriorityChip(),
                    ],
                  ),
                ),
                if (_createdAt != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(_createdAt!),
                    style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 20),

            // Title
            Text(_title, style: AppTextStyles.h3),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.home_outlined, size: 14, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _propertyTitle,
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Description
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Description', style: AppTextStyles.labelMedium),
                  const SizedBox(height: 8),
                  Text(
                    _description.isNotEmpty ? _description : 'No description provided.',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),

            // Photos
            if (_images.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Photos (${_images.length})', style: AppTextStyles.labelMedium),
              const SizedBox(height: 12),
              SizedBox(
                height: 180,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    return GestureDetector(
                      onTap: () => _showFullImage(context, i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: _images[i],
                          width: 240,
                          height: 180,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(
                            width: 240, height: 180,
                            color: AppColors.border,
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppColors.primary,
                              ),
                            ),
                          ),
                          errorWidget: (_, _, _) => Container(
                            width: 240, height: 180,
                            color: AppColors.border,
                            child: Icon(Icons.broken_image, color: AppColors.textHint),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],

            // Landlord response
            if (_landlordNote != null && _landlordNote!.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.info.withAlpha(51)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.person_outline, size: 16, color: AppColors.info),
                        const SizedBox(width: 6),
                        Text('Landlord Response',
                            style: AppTextStyles.labelMedium.copyWith(color: AppColors.info)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _landlordNote!,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Status timeline
            const SizedBox(height: 20),
            _buildStatusTimeline(),

            // Tenant confirms or disputes the landlord's fix.
            if (_status == 'pending_confirmation') ...[
              const SizedBox(height: 24),
              _ConfirmFixButtons(issueId: issueId, data: data),
            ],

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    final color = _statusColorFor(_status);
    final label = _statusLabelFor(_status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.labelSmall.copyWith(
              color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildPriorityChip() {
    final color = _priorityColorFor(_priority);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text('${_capitalize(_priority)} Priority',
              style: AppTextStyles.caption.copyWith(
                  color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildStatusTimeline() {
    final steps = [
      {'key': 'open', 'label': 'Reported', 'icon': Icons.flag_outlined},
      {'key': 'in_progress', 'label': 'In Progress', 'icon': Icons.build_outlined},
      {'key': 'pending_confirmation', 'label': 'Pending Confirmation', 'icon': Icons.hourglass_top},
      {'key': 'resolved', 'label': 'Resolved', 'icon': Icons.check_circle_outline},
    ];

    final currentIndex = steps.indexWhere((s) => s['key'] == _status);

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
          Text('Status', style: AppTextStyles.labelMedium),
          const SizedBox(height: 16),
          ...steps.asMap().entries.map((entry) {
            final i = entry.key;
            final step = entry.value;
            final isActive = i <= currentIndex;
            final isCurrent = i == currentIndex;
            final isLast = i == steps.length - 1;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timeline dot + line
                Column(
                  children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: isActive
                            ? (isCurrent ? AppColors.primary : AppColors.success)
                            : AppColors.border,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        step['icon'] as IconData,
                        size: 14,
                        color: isActive ? Colors.white : AppColors.textHint,
                      ),
                    ),
                    if (!isLast)
                      Container(
                        width: 2, height: 24,
                        color: isActive ? AppColors.success.withAlpha(100) : AppColors.border,
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    step['label'] as String,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: isActive ? AppColors.textPrimary : AppColors.textHint,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  void _showFullImage(BuildContext context, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(
              'Photo ${initialIndex + 1} of ${_images.length}',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          body: PageView.builder(
            controller: PageController(initialPage: initialIndex),
            itemCount: _images.length,
            itemBuilder: (_, i) => InteractiveViewer(
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: _images[i],
                  fit: BoxFit.contain,
                  placeholder: (_, _) => CircularProgressIndicator(
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColorFor(String s) {
    switch (s) {
      case 'open':           return AppColors.error;
      case 'in_progress':   return AppColors.warning;
      case 'pending_confirmation': return AppColors.info;
      case 'resolved':      return AppColors.success;
      default:              return AppColors.textSecondary;
    }
  }

  String _statusLabelFor(String s) {
    switch (s) {
      case 'open':           return 'Open';
      case 'in_progress':   return 'In Progress';
      case 'pending_confirmation': return 'Awaiting Confirmation';
      case 'resolved':      return 'Resolved';
      default:              return _capitalize(s);
    }
  }

  Color _priorityColorFor(String p) {
    switch (p) {
      case 'high':   return AppColors.error;
      case 'medium': return AppColors.warning;
      default:       return AppColors.success;
    }
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  String _formatDate(DateTime d) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

// ── Confirm / dispute the landlord's fix (closes the loop) ────────────────────

class _ConfirmFixButtons extends StatefulWidget {
  final String issueId;
  final Map<String, dynamic> data;
  const _ConfirmFixButtons({required this.issueId, required this.data});

  @override
  State<_ConfirmFixButtons> createState() => _ConfirmFixButtonsState();
}

class _ConfirmFixButtonsState extends State<_ConfirmFixButtons> {
  bool _busy = false;

  Future<void> _update(
      Map<String, dynamic> fields, String okMsg, Color okColor) async {
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({...fields, 'updatedAt': FieldValue.serverTimestamp()});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(okMsg),
        backgroundColor: okColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Something went wrong. Please try again.'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Future<void> _confirm() => _update(
        {
          'status': 'resolved',
          'resolvedAt': FieldValue.serverTimestamp(),
          'tenantConfirmedAt': FieldValue.serverTimestamp(),
        },
        'Marked resolved — thanks for confirming!',
        AppColors.success,
      );

  Future<void> _dispute() async {
    final controller = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Not fixed?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            "Tell your landlord what's still wrong — it goes back to their "
            'In Progress list.',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'What\'s still wrong?',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ]),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Back',
                  style: TextStyle(color: AppColors.textSecondary))),
          TextButton(
              onPressed: () {
                if (controller.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: Text('Send', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (send != true || !mounted) return;
    await _update(
      {
        'status': 'in_progress',
        'tenantDisputeReason': controller.text.trim(),
      },
      'Sent back to your landlord.',
      AppColors.info,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.info.withAlpha(51)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Has this been fixed?', style: AppTextStyles.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Your landlord marked this as fixed. Confirm to close it, or let '
          'them know if it\'s not resolved.',
          style: AppTextStyles.caption
              .copyWith(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _dispute,
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('Not fixed',
                      style: AppTextStyles.labelMedium
                          .copyWith(color: AppColors.textSecondary)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: _busy ? null : _confirm,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: Text('Yes, fixed',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: Colors.white)),
            ),
          ),
        ]),
      ]),
    );
  }
}