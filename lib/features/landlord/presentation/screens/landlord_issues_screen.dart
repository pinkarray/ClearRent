import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/conversation_service.dart';

/// Landlord screen to view and manage reported issues from tenants.
/// Shows issues grouped by status: Open, In Progress, Resolved.
class LandlordIssuesScreen extends StatefulWidget {
  const LandlordIssuesScreen({super.key});

  @override
  State<LandlordIssuesScreen> createState() => _LandlordIssuesScreenState();
}

class _LandlordIssuesScreenState extends State<LandlordIssuesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final AuthService _authService = AuthService();

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
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Reported Issues', style: AppTextStyles.h4),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          tabs: const [
            Tab(text: 'Open'),
            Tab(text: 'In Progress'),
            Tab(text: 'Resolved'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _IssuesTab(status: 'open', authService: _authService),
          _IssuesTab(status: 'in_progress', authService: _authService),
          _IssuesTab(status: 'resolved', authService: _authService),
        ],
      ),
    );
  }
}

class _IssuesTab extends StatelessWidget {
  final String status;
  final AuthService authService;
  const _IssuesTab({required this.status, required this.authService});

  @override
  Widget build(BuildContext context) {
    final currentUserId = authService.currentUserId;
    if (currentUserId == null) {
      return const Center(child: Text('Not authenticated'));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('issues')
          .where('landlordId', isEqualTo: currentUserId)
          .where('status', isEqualTo: status)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }

        if (snapshot.hasError) {
          developer.log('❌ Issues error: ${snapshot.error}', name: 'LandlordIssues');
          return _EmptyState(
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
            default:
              subtitle = 'Resolved issues will appear here';
          }
          return _EmptyState(
            icon: status == 'resolved'
                ? Icons.check_circle_outline
                : Icons.report_off_outlined,
            title: 'No ${status.replaceAll('_', ' ')} issues',
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

  const _IssueCard({
    required this.issueId,
    required this.data,
    required this.currentStatus,
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
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
        if (newStatus == 'resolved') 'resolvedAt': FieldValue.serverTimestamp(),
      });

      // Notify tenant
      final tenantId = widget.data['tenantId'];
      if (tenantId != null) {
        await FirebaseFirestore.instance.collection('activities').add({
          'userId': tenantId,
          'type': 'issue_updated',
          'title': newStatus == 'resolved'
              ? 'Issue Resolved'
              : 'Issue Update',
          'message': newStatus == 'resolved'
              ? 'Your $_category issue at $_propertyTitle has been resolved.'
              : 'Your $_category issue at $_propertyTitle is now being worked on.',
          'propertyId': widget.data['propertyId'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newStatus == 'resolved'
              ? 'Issue marked as resolved!'
              : 'Issue marked as in progress.'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      developer.log('❌ Error updating issue: $e', name: 'LandlordIssues');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to update issue'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _messageTenant() async {
    setState(() => _isMessageLoading = true);
    try {
      final conv = await _conversationService.getOrCreateConversation(
        propertyId: widget.data['propertyId'] ?? '',
        propertyTitle: _propertyTitle,
        propertyImage: '',
        landlordId: widget.data['landlordId'] ?? '',
        landlordName: widget.data['landlordName'] ?? '',
        tenantId: widget.data['tenantId'] ?? '',
        tenantName: _tenantName,
      );
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': _propertyTitle,
          'propertyImage': null,
        });
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
          const Divider(height: 1),
          const SizedBox(height: 12),

          // Property + tenant
          Row(children: [
            const Icon(Icons.home_outlined,
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
            const Icon(Icons.person_outline,
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

          const SizedBox(height: 16),

          // Action buttons
          Row(children: [
            // Message tenant
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isMessageLoading ? null : _messageTenant,
                icon: _isMessageLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.primary))
                    : const Icon(Icons.chat_outlined, size: 18),
                label: const Text('Message'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: const BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Status action buttons
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
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Working On It'),
                ),
              ),

            if (widget.currentStatus == 'in_progress')
              Expanded(
                child: ElevatedButton(
                  onPressed: _isUpdating
                      ? null
                      : () => _updateStatus('resolved'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isUpdating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Mark Resolved'),
                ),
              ),

            if (widget.currentStatus == 'resolved')
              Expanded(
                child: OutlinedButton(
                  onPressed: _isUpdating
                      ? null
                      : () => _updateStatus('open'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    side: const BorderSide(color: AppColors.warning),
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

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState(
      {required this.icon, required this.title, required this.subtitle});

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
            Text(title,
                style: AppTextStyles.h4, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(subtitle,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}