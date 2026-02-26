import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
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
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
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
                  return const Center(
                      child: CircularProgressIndicator(color: AppColors.primary));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.error_outline, color: AppColors.error, size: 48),
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
              const Icon(Icons.check_circle_outline, color: AppColors.success, size: 40),
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
                child: const Icon(Icons.home_outlined,
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
          ...widget.issues.map((doc) =>
              _IssueHistoryTile(data: doc.data() as Map<String, dynamic>)),
        ],
      ]),
    );
  }
}

// ── Single issue row ──────────────────────────────────────────────────────────

class _IssueHistoryTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _IssueHistoryTile({required this.data});

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

    return Padding(
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
      ]),
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