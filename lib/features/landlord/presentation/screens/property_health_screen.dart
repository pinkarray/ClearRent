import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/property_service.dart';

/// Property Health Dashboard — the landlord's "back office" view of a property.
///
/// Shows:
///  • Overall health score derived from open/pending issues
///  • Per-category health cards (Plumbing, Electrical, Security, Structural, etc.)
///    mapped from the property's amenities + the 8 reportable issue categories
///  • Proactive maintenance log — landlord can record fixes before tenants report them
///  • Recent issue history for this property with statuses
///
/// Navigation: /landlord/property-health  (extra: PropertyModel)
class PropertyHealthScreen extends StatefulWidget {
  final PropertyModel property;
  const PropertyHealthScreen({super.key, required this.property});

  @override
  State<PropertyHealthScreen> createState() => _PropertyHealthScreenState();
}

class _PropertyHealthScreenState extends State<PropertyHealthScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final AuthService _authService = AuthService();
  final PropertyService _propertyService = PropertyService();
  String? _exactAddress; // exact street address from the gated subdoc

  // Cached once (widget.property is immutable) so tab changes and issue-stream
  // emissions don't recreate these and flash their sections.
  late final Stream<QuerySnapshot> _issuesStream = FirebaseFirestore.instance
      .collection('issues')
      .where('landlordId', isEqualTo: widget.property.landlordId)
      .where('propertyId', isEqualTo: widget.property.id)
      .snapshots();
  late final Stream<QuerySnapshot> _maintenanceStream = FirebaseFirestore
      .instance
      .collection('maintenance_logs')
      .where('landlordId', isEqualTo: widget.property.landlordId)
      .where('propertyId', isEqualTo: widget.property.id)
      .orderBy('loggedAt', descending: true)
      .limit(10)
      .snapshots();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadExactAddress();
  }

  /// The owner is entitled to the exact street address (gated subdoc).
  Future<void> _loadExactAddress() async {
    final loc = await _propertyService.getExactLocation(widget.property.id);
    if (mounted && loc != null && loc.address.isNotEmpty) {
      setState(() => _exactAddress = loc.address);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── CATEGORY SYSTEM ──────────────────────────────────────────────────────

  /// The 8 reportable issue categories — always present regardless of amenities.
  static const _coreCategories = [
    _CategoryDef(
      key: 'plumbing',
      label: 'Plumbing',
      icon: Icons.plumbing,
      amenityKeywords: ['water', 'heater', 'plumb'],
    ),
    _CategoryDef(
      key: 'electrical',
      label: 'Electrical',
      icon: Icons.electrical_services,
      amenityKeywords: ['power', 'meter', 'electric', 'air condition'],
    ),
    _CategoryDef(
      key: 'security',
      label: 'Security',
      icon: Icons.shield_outlined,
      amenityKeywords: ['security', 'cctv', 'gated'],
    ),
    _CategoryDef(
      key: 'structural',
      label: 'Structural',
      icon: Icons.foundation,
      amenityKeywords: ['ceiling', 'floor', 'tiled', 'pop', 'structural'],
    ),
    _CategoryDef(
      key: 'appliance',
      label: 'Appliances',
      icon: Icons.kitchen,
      amenityKeywords: ['kitchen', 'wardrobe', 'gym', 'cabinet'],
    ),
    _CategoryDef(
      key: 'pest',
      label: 'Pest Control',
      icon: Icons.bug_report_outlined,
      amenityKeywords: [],
    ),
    _CategoryDef(
      key: 'cleaning',
      label: 'Cleaning',
      icon: Icons.cleaning_services_outlined,
      amenityKeywords: ['garden', 'compound'],
    ),
    _CategoryDef(
      key: 'other',
      label: 'Other',
      icon: Icons.more_horiz,
      amenityKeywords: ['parking', 'balcony', 'swimming', 'pool', 'bq', 'quarter'],
    ),
  ];

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: StreamBuilder<QuerySnapshot>(
        stream: _issuesStream,
        builder: (context, issueSnap) {
          final issueDocs = issueSnap.data?.docs ?? [];
          final issues = issueDocs
              .map((d) => _IssueData.fromDoc(d))
              .toList();

          return NestedScrollView(
            headerSliverBuilder: (context, innerBoxScrolled) => [
              _buildAppBar(issues),
            ],
            body: TabBarView(
              controller: _tabController,
              children: [
                _HealthTab(
                  property: widget.property,
                  issues: issues,
                  categories: _coreCategories,
                  onLogMaintenance: _showMaintenanceLogSheet,
                  onViewIssues: _navigateToIssues,
                  maintenanceStream: _maintenanceStream,
                ),
                _IssueHistoryTab(issues: issues),
              ],
            ),
          );
        },
      ),
    );
  }

  SliverAppBar _buildAppBar(List<_IssueData> issues) {
    final score = _computeHealthScore(issues);
    final openCount = issues.where((i) => i.status == 'open').length;
    final pendingCount =
        issues.where((i) => i.status == 'pending_confirmation').length;
    final resolvedCount = issues.where((i) => i.status == 'resolved').length;

    return SliverAppBar(
      expandedHeight: 280,
      pinned: true,
      backgroundColor: AppColors.surface,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
        onPressed: () => context.pop(),
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.edit_outlined, color: AppColors.textPrimary),
          tooltip: 'Edit Property',
          onPressed: () =>
              context.push('/landlord/edit-property/${widget.property.id}'),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        background:
            _buildHeroHeader(score, openCount, pendingCount, resolvedCount),
      ),
      bottom: TabBar(
        controller: _tabController,
        labelColor: AppColors.primary,
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: AppColors.primary,
        indicatorWeight: 3,
        labelStyle: AppTextStyles.labelMedium,
        tabs: const [
          Tab(text: 'Health Overview'),
          Tab(text: 'Issue History'),
        ],
      ),
    );
  }

  Widget _buildHeroHeader(
      int score, int openCount, int pendingCount, int resolvedCount) {
    final scoreColor = _scoreColor(score);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
            bottom: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 56, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Property title + address
              Text(
                widget.property.title,
                style: AppTextStyles.h3,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.location_on_outlined,
                    size: 14, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _exactAddress ?? widget.property.approximateAddress,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Health score pill ──
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: scoreColor.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scoreColor.withAlpha(80)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_scoreIcon(score), size: 18, color: scoreColor),
                  const SizedBox(width: 8),
                  Text(
                    '$score%',
                    style: AppTextStyles.h4.copyWith(color: scoreColor),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Health Score',
                    style: AppTextStyles.caption
                        .copyWith(color: scoreColor.withAlpha(180)),
                  ),
                ]),
              ),
              const SizedBox(height: 12),

              // ── Open / Pending / Resolved stat boxes ──
              Row(children: [
                _QuickStat(
                  count: openCount,
                  label: 'Open',
                  color: openCount > 0 ? AppColors.error : AppColors.success,
                ),
                const SizedBox(width: 8),
                _QuickStat(
                  count: pendingCount,
                  label: 'Pending',
                  color: pendingCount > 0 ? AppColors.info : AppColors.textHint,
                ),
                const SizedBox(width: 8),
                _QuickStat(
                  count: resolvedCount,
                  label: 'Resolved',
                  color: AppColors.success,
                ),
              ]),
              // Extra spacing before the tab bar
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ── HEALTH SCORE ─────────────────────────────────────────────────────────

  int _computeHealthScore(List<_IssueData> issues) {
    if (issues.isEmpty) return 100;
    final penalty = issues.fold(0, (acc, i) {
      switch (i.status) {
        case 'open':
          return acc + 15;
        case 'in_progress':
          return acc + 8;
        case 'pending_confirmation':
          return acc + 5;
        default:
          return acc;
      }
    });
    return (100 - penalty).clamp(0, 100);
  }

  Color _scoreColor(int score) {
    if (score >= 80) return AppColors.success;
    if (score >= 50) return AppColors.warning;
    return AppColors.error;
  }

  IconData _scoreIcon(int score) {
    if (score >= 80) return Icons.verified_outlined;
    if (score >= 50) return Icons.warning_amber_outlined;
    return Icons.error_outline;
  }

  // ── SMART NAVIGATION ─────────────────────────────────────────────────────

  /// Navigate to the landlord issues screen, filtered to this property + category,
  /// pre-selecting the right tab based on the issue state.
  void _navigateToIssues(String category, _CategoryIssueState issueState) {
    // Map issue state to the tab index in LandlordIssuesScreen:
    // 0 = Open, 1 = In Progress, 2 = Pending, 3 = Resolved
    int tab;
    switch (issueState) {
      case _CategoryIssueState.open:
        tab = 0;
        break;
      case _CategoryIssueState.inProgress:
        tab = 1;
        break;
      case _CategoryIssueState.pending:
        tab = 2;
        break;
      default:
        tab = 0;
    }

    context.push('/landlord/issues', extra: {
      'propertyId': widget.property.id,
      'category': category,
      'initialTab': tab,
      'propertyTitle': widget.property.title,
    });
  }

  // ── MAINTENANCE LOG SHEET ─────────────────────────────────────────────────

  void _showMaintenanceLogSheet(String category) {
    final noteController = TextEditingController();
    String selectedCategory = category;
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            // Scrollable so the content never overflows when the keyboard
            // opens on the note field (was: bottom overflowed by 8px).
            child: SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 20),

                Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(26),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.build_outlined,
                        color: AppColors.success, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text('Log Maintenance', style: AppTextStyles.h4),
                ]),
                const SizedBox(height: 6),
                Text(
                  'Record a fix or service — even before a tenant reports it. This builds your property\'s maintenance history.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary, height: 1.5),
                ),
                const SizedBox(height: 20),

                // Category selector
                Text('Category', style: AppTextStyles.labelMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _coreCategories.map((cat) {
                    final selected = selectedCategory == cat.key;
                    return GestureDetector(
                      onTap: () =>
                          setSheetState(() => selectedCategory = cat.key),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppColors.primary.withAlpha(26)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? AppColors.primary
                                : AppColors.border,
                          ),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(cat.icon,
                              size: 14,
                              color: selected
                                  ? AppColors.primary
                                  : AppColors.textSecondary),
                          const SizedBox(width: 6),
                          Text(
                            cat.label,
                            style: AppTextStyles.labelSmall.copyWith(
                              color: selected
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Note
                Text('Note', style: AppTextStyles.labelMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: noteController,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText:
                        'e.g. "Generator serviced by Adekunle Electric. Oil changed, filters replaced."',
                    hintStyle: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: isSubmitting
                        ? null
                        : () async {
                            final note = noteController.text.trim();
                            if (note.isEmpty) return;
                            setSheetState(() => isSubmitting = true);
                            try {
                              await _saveMaintenanceLog(
                                  selectedCategory, note);
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (mounted) {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(SnackBar(
                                  content: const Text(
                                      'Maintenance log saved.'),
                                  backgroundColor: AppColors.success,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(10)),
                                ));
                              }
                            } catch (e) {
                              setSheetState(() => isSubmitting = false);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: isSubmitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Save Log Entry',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveMaintenanceLog(String category, String note) async {
    final uid = _authService.currentUserId;
    await FirebaseFirestore.instance
        .collection('maintenance_logs')
        .add({
      'propertyId': widget.property.id,
      'landlordId': uid,
      'category': category,
      'note': note,
      'loggedAt': FieldValue.serverTimestamp(),
    });
    developer.log('✅ Maintenance log saved', name: 'PropertyHealth');
  }
}

// ── CATEGORY ISSUE STATE ────────────────────────────────────────────────────

enum _CategoryIssueState {
  healthy,
  open,
  inProgress,
  pending,
}

// ── HEALTH TAB ──────────────────────────────────────────────────────────────

class _HealthTab extends StatelessWidget {
  final PropertyModel property;
  final List<_IssueData> issues;
  final List<_CategoryDef> categories;
  final void Function(String category) onLogMaintenance;
  final void Function(String category, _CategoryIssueState issueState) onViewIssues;
  // Cached by the parent so rebuilds don't recreate it.
  final Stream<QuerySnapshot> maintenanceStream;

  const _HealthTab({
    required this.property,
    required this.issues,
    required this.categories,
    required this.onLogMaintenance,
    required this.onViewIssues,
    required this.maintenanceStream,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {},
      color: AppColors.primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Amenities present on this property
            if (property.amenities.isNotEmpty) ...[
              _buildAmenitiesStrip(),
              const SizedBox(height: 24),
            ],

            // Category health cards
            Text('System Health', style: AppTextStyles.h4),
            const SizedBox(height: 4),
            Text(
              'Tap any category to log proactive maintenance.',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            _buildHealthGrid(context),
            const SizedBox(height: 28),

            // Maintenance log stream
            _buildMaintenanceLogSection(context),
          ],
        ),
      ),
    );
  }

  Widget _buildAmenitiesStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Property Amenities', style: AppTextStyles.labelLarge),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: property.amenities.map((a) => Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(13),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.primary.withAlpha(40)),
            ),
            child: Text(
              a,
              style: AppTextStyles.caption.copyWith(
                  color: AppColors.primary, fontWeight: FontWeight.w500),
            ),
          )).toList(),
        ),
      ],
    );
  }

  /// Determine the issue state for a category based on its active issues.
  _CategoryIssueState _getCategoryIssueState(List<_IssueData> catIssues) {
    final hasOpen = catIssues.any((i) => i.status == 'open');
    final hasInProgress = catIssues.any((i) => i.status == 'in_progress');
    final hasPending = catIssues.any((i) => i.status == 'pending_confirmation');

    if (hasOpen) return _CategoryIssueState.open;
    if (hasInProgress) return _CategoryIssueState.inProgress;
    if (hasPending) return _CategoryIssueState.pending;
    return _CategoryIssueState.healthy;
  }

  Widget _buildHealthGrid(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.35,
      ),
      itemCount: categories.length,
      itemBuilder: (context, i) {
        final cat = categories[i];
        final catIssues =
            issues.where((iss) => iss.category == cat.key).toList();
        final openIssues =
            catIssues.where((i) => i.status == 'open').length;
        final inProgress =
            catIssues.where((i) => i.status == 'in_progress').length;
        final pending = catIssues
            .where((i) => i.status == 'pending_confirmation')
            .length;

        final issueState = _getCategoryIssueState(catIssues);

        return _CategoryHealthCard(
          def: cat,
          openIssues: openIssues,
          inProgress: inProgress,
          pending: pending,
          issueState: issueState,
          isAmenitiPresent: property.amenities.any((a) => cat.amenityKeywords
              .any((kw) => a.toLowerCase().contains(kw))),
          onTap: issueState != _CategoryIssueState.healthy
              ? () => onViewIssues(cat.key, issueState)
              : () => onLogMaintenance(cat.key),
        );
      },
    );
  }

  Widget _buildMaintenanceLogSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Maintenance Log', style: AppTextStyles.h4),
            TextButton.icon(
              onPressed: () => onLogMaintenance('other'),
              icon: Icon(Icons.add, size: 16,
                  color: AppColors.primary),
              label: Text('Add Entry',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.primary)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Your proactive maintenance records. These are stored permanently and can support you in any dispute.',
          style: AppTextStyles.caption
              .copyWith(color: AppColors.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 14),
        StreamBuilder<QuerySnapshot>(
          stream: maintenanceStream,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                child: CircularProgressIndicator(
                    color: AppColors.primary),
              ));
            }
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.border,
                      style: BorderStyle.solid),
                ),
                child: Column(children: [
                  Icon(Icons.history_outlined,
                      size: 36, color: AppColors.textHint),
                  const SizedBox(height: 12),
                  Text('No maintenance logs yet',
                      style: AppTextStyles.labelMedium
                          .copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  Text(
                    'Tap "Add Entry" to record a fix or service. Even without tenant reports, good records protect you.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint, height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                ]),
              );
            }
            return Column(
              children: docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final category = data['category'] as String? ?? 'other';
                final note = data['note'] as String? ?? '';
                final ts = data['loggedAt'];
                DateTime? loggedAt;
                if (ts is Timestamp) loggedAt = ts.toDate();
                final catDef = _PropertyHealthScreenState._coreCategories
                    .firstWhere((c) => c.key == category,
                        orElse: () =>
                            _PropertyHealthScreenState._coreCategories.last);
                return _MaintenanceLogItem(
                  def: catDef,
                  note: note,
                  loggedAt: loggedAt,
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

// ── ISSUE HISTORY TAB ────────────────────────────────────────────────────────

class _IssueHistoryTab extends StatelessWidget {
  final List<_IssueData> issues;
  const _IssueHistoryTab({required this.issues});

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(26),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.verified_outlined,
                    size: 40, color: AppColors.success),
              ),
              const SizedBox(height: 24),
              Text('No issues reported',
                  style: AppTextStyles.h4, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'This property has a clean record. Keep it that way by logging maintenance proactively.',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final sorted = [...issues]..sort((a, b) {
        const order = {
          'open': 0,
          'in_progress': 1,
          'pending_confirmation': 2,
          'resolved': 3,
        };
        return (order[a.status] ?? 4).compareTo(order[b.status] ?? 4);
      });

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 100),
      itemCount: sorted.length,
      itemBuilder: (context, i) => _IssueHistoryCard(issue: sorted[i]),
    );
  }
}

// ── CATEGORY HEALTH CARD ─────────────────────────────────────────────────────

class _CategoryHealthCard extends StatelessWidget {
  final _CategoryDef def;
  final int openIssues;
  final int inProgress;
  final int pending;
  final _CategoryIssueState issueState;
  final bool isAmenitiPresent;
  final VoidCallback onTap;

  const _CategoryHealthCard({
    required this.def,
    required this.openIssues,
    required this.inProgress,
    required this.pending,
    required this.issueState,
    required this.isAmenitiPresent,
    required this.onTap,
  });

  Color get _statusColor {
    if (openIssues > 0) return AppColors.error;
    if (inProgress > 0) return AppColors.warning;
    if (pending > 0) return AppColors.info;
    return AppColors.success;
  }

  String get _statusLabel {
    if (openIssues > 0) return '$openIssues open';
    if (inProgress > 0) return 'In progress';
    if (pending > 0) return 'Pending';
    return 'Healthy';
  }

  IconData get _statusIcon {
    if (openIssues > 0) return Icons.error_outline;
    if (inProgress > 0) return Icons.construction_outlined;
    if (pending > 0) return Icons.hourglass_top_rounded;
    return Icons.check_circle_outline;
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: openIssues > 0
                ? AppColors.error.withAlpha(80)
                : AppColors.border,
            width: openIssues > 0 ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(8),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(def.icon, size: 18, color: color),
                ),
                // Show arrow for issues, wrench for maintenance
                Icon(
                  issueState != _CategoryIssueState.healthy
                      ? Icons.arrow_forward_ios
                      : Icons.build_outlined,
                  size: 12,
                  color: AppColors.textHint,
                ),
              ],
            ),
            const Spacer(),
            Text(def.label,
                style: AppTextStyles.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Row(children: [
              Icon(_statusIcon, size: 12, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _statusLabel,
                  style: AppTextStyles.caption
                      .copyWith(color: color, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ── MAINTENANCE LOG ITEM ─────────────────────────────────────────────────────

class _MaintenanceLogItem extends StatelessWidget {
  final _CategoryDef def;
  final String note;
  final DateTime? loggedAt;

  const _MaintenanceLogItem({
    required this.def,
    required this.note,
    required this.loggedAt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(26),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(def.icon, size: 16, color: AppColors.success),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(def.label,
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.success)),
                    if (loggedAt != null)
                      Text(
                        DateFormat('d MMM yyyy').format(loggedAt!),
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textHint),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(note,
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── ISSUE HISTORY CARD ───────────────────────────────────────────────────────

class _IssueHistoryCard extends StatelessWidget {
  final _IssueData issue;
  const _IssueHistoryCard({required this.issue});

  Color get _statusColor {
    switch (issue.status) {
      case 'open':
        return AppColors.error;
      case 'in_progress':
        return AppColors.warning;
      case 'pending_confirmation':
        return AppColors.info;
      case 'resolved':
        return AppColors.success;
      default:
        return AppColors.textHint;
    }
  }

  String get _statusLabel {
    switch (issue.status) {
      case 'open':
        return 'Open';
      case 'in_progress':
        return 'In Progress';
      case 'pending_confirmation':
        return 'Pending Confirmation';
      case 'resolved':
        return 'Resolved';
      default:
        return issue.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: issue.status == 'open'
              ? AppColors.error.withAlpha(60)
              : AppColors.border,
        ),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_categoryIcon(issue.category), size: 16, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(issue.title,
                  style: AppTextStyles.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(children: [
                Text(
                  issue.tenantName,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
                if (issue.createdAt != null) ...[
                  Text(
                    '  •  ${DateFormat('d MMM').format(issue.createdAt!)}',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                  ),
                ],
              ]),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            _statusLabel,
            style: AppTextStyles.labelSmall.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }

  IconData _categoryIcon(String cat) {
    switch (cat) {
      case 'plumbing':
        return Icons.plumbing;
      case 'electrical':
        return Icons.electrical_services;
      case 'structural':
        return Icons.foundation;
      case 'appliance':
        return Icons.kitchen;
      case 'pest':
        return Icons.bug_report_outlined;
      case 'security':
        return Icons.shield_outlined;
      case 'cleaning':
        return Icons.cleaning_services_outlined;
      default:
        return Icons.report_problem_outlined;
    }
  }
}

// ── QUICK STAT WIDGET ────────────────────────────────────────────────────────

class _QuickStat extends StatelessWidget {
  final int count;
  final String label;
  final Color color;
  const _QuickStat(
      {required this.count, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          Text(
            '$count',
            style: AppTextStyles.h4.copyWith(
              color: count > 0 ? color : AppColors.textHint,
            ),
          ),
          Text(
            label,
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textHint, fontSize: 10),
          ),
        ]),
      ),
    );
  }
}

// ── DATA MODELS ──────────────────────────────────────────────────────────────

class _IssueData {
  final String id;
  final String title;
  final String category;
  final String status;
  final String tenantName;
  final String priority;
  final DateTime? createdAt;

  const _IssueData({
    required this.id,
    required this.title,
    required this.category,
    required this.status,
    required this.tenantName,
    required this.priority,
    this.createdAt,
  });

  factory _IssueData.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    DateTime? ts;
    if (d['createdAt'] is Timestamp) ts = (d['createdAt'] as Timestamp).toDate();
    return _IssueData(
      id: doc.id,
      title: d['title'] ?? 'Untitled',
      category: d['category'] ?? 'other',
      status: d['status'] ?? 'open',
      tenantName: d['tenantName'] ?? 'Tenant',
      priority: d['priority'] ?? 'medium',
      createdAt: ts,
    );
  }
}

class _CategoryDef {
  final String key;
  final String label;
  final IconData icon;
  final List<String> amenityKeywords;

  const _CategoryDef({
    required this.key,
    required this.label,
    required this.icon,
    required this.amenityKeywords,
  });
}