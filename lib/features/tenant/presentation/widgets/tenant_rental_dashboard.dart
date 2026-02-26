import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/conversation_service.dart';


class TenantRentalDashboard extends StatefulWidget {
  final ActiveRental rental;
  final String userName;
  final String userInitial;
  final bool isLoadingProfile;
  final VoidCallback onBrowseProperties;

  const TenantRentalDashboard({
    super.key,
    required this.rental,
    required this.userName,
    required this.userInitial,
    required this.isLoadingProfile,
    required this.onBrowseProperties,
  });

  @override
  State<TenantRentalDashboard> createState() => _TenantRentalDashboardState();
}

class _TenantRentalDashboardState extends State<TenantRentalDashboard> {
  final ActiveRentalService _activeRentalService = ActiveRentalService();
  final ConversationService _conversationService = ConversationService();
  bool _isTogglingReminder = false;
  bool _isMessageLoading = false;

  ActiveRental get rental => widget.rental;

  String get _firstName {
    final parts = widget.userName.split(' ');
    return parts.isNotEmpty ? parts.first : widget.userName;
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
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

  double get _leaseProgress {
    final total = rental.leaseEndDate.difference(rental.leaseStartDate).inDays;
    final elapsed =
        DateTime.now().difference(rental.leaseStartDate).inDays;
    if (total <= 0) return 1.0;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  Future<void> _toggleReminder() async {
    setState(() => _isTogglingReminder = true);
    final success = await _activeRentalService.togglePaymentReminder(
        rental.id, !rental.hasPaymentReminder);
    if (!mounted) return;
    setState(() => _isTogglingReminder = false);
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Failed to update reminder'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Future<void> _callLandlord() async {
    if (rental.landlordPhone == null || rental.landlordPhone!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Phone number not available'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    final uri = Uri.parse('tel:${rental.landlordPhone}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _messageLandlord() async {
    setState(() => _isMessageLoading = true);
    try {
      final conv = await _conversationService.getOrCreateConversation(
        propertyId: rental.propertyId,
        propertyTitle: rental.propertyTitle,
        propertyImage: rental.propertyImage,
        landlordId: rental.landlordId,
        landlordName: rental.landlordName,
        tenantId: rental.tenantId,
        tenantName: rental.tenantName,
      );
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': rental.propertyTitle,
          'propertyImage':
              rental.propertyImage.isNotEmpty ? rental.propertyImage : null,
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Could not start conversation'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      developer.log('❌ Message error: $e', name: 'RentalDashboard');
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        // Parent will handle refresh
      },
      color: AppColors.primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(),
            const SizedBox(height: 20),

            // Expiry warning
            if (rental.daysUntilLeaseEnd <= 30 &&
                rental.daysUntilLeaseEnd > 0)
              _buildExpiryWarning(),

            // Property hero card
            _buildPropertyHero(),
            const SizedBox(height: 16),

            // Lease timeline
            _buildLeaseTimeline(),
            const SizedBox(height: 16),

            // Landlord contact
            _buildLandlordCard(),
            const SizedBox(height: 16),

            // Pending fix confirmations — shown when landlord says something is fixed
            _buildPendingConfirmations(),

            // Quick actions
            _buildQuickActions(),
            const SizedBox(height: 16),

            // Payment info
            _buildPaymentCard(),
            const SizedBox(height: 24),

            // Browse more
            _buildBrowseMore(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.isLoadingProfile
                  ? Container(
                      width: 120, height: 16,
                      
                      decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(4)))
                          
                  : Text('Welcome home, $_firstName 🏠',
                      style: AppTextStyles.h3
                          .copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Text('My Rental', style: AppTextStyles.h3),
            ],
          ),
        ),
        // Status badge
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: rental.isExpiringSoon
                ? AppColors.warning.withAlpha(26)
                : AppColors.success.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: rental.isExpiringSoon
                    ? AppColors.warning
                    : AppColors.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              rental.statusDisplay,
              style: AppTextStyles.labelSmall.copyWith(
                color: rental.isExpiringSoon
                    ? AppColors.warning
                    : AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildExpiryWarning() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.warning.withAlpha(26),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.timer_outlined,
              color: AppColors.warning, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lease Expiring Soon',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.warning)),
              const SizedBox(height: 2),
              Text(
                '${rental.daysUntilLeaseEnd} days remaining. Start looking for your next home or contact your landlord to renew.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildPropertyHero() {
    return Container(
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
        children: [
          // Property image
          ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            child: SizedBox(
              height: 180,
              width: double.infinity,
              child: rental.propertyImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: rental.propertyImage,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _imagePlaceholder(),
                    )
                  : _imagePlaceholder(),
            ),
          ),
          // Property info
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rental.propertyTitle,
                    style: AppTextStyles.h4,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(rental.propertyAddress,
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
                const SizedBox(height: 12),
                // Rent amount
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(13),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '₦${_formatAmount(rental.rentAmount)}${rental.rentPeriod}',
                        style: AppTextStyles.labelLarge
                            .copyWith(color: AppColors.primary),
                      ),
                    ),
                    const Spacer(),
                    Text(rental.rentFrequency == 'yearly'
                        ? 'Annual rent'
                        : 'Monthly rent',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textHint)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaseTimeline() {
    final daysLeft = rental.daysUntilLeaseEnd;
    final totalDays = rental.leaseEndDate
        .difference(rental.leaseStartDate)
        .inDays;

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
          Row(children: [
            const Icon(Icons.calendar_today_outlined,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 8),
            Text('Lease Timeline', style: AppTextStyles.labelLarge),
            const Spacer(),
            Text(
              daysLeft > 0 ? '$daysLeft days left' : 'Expired',
              style: AppTextStyles.labelMedium.copyWith(
                color: daysLeft <= 30
                    ? AppColors.warning
                    : AppColors.success,
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _leaseProgress,
              minHeight: 8,
              backgroundColor: AppColors.background,
              valueColor: AlwaysStoppedAnimation<Color>(
                daysLeft <= 30
                    ? AppColors.warning
                    : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Date labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  Text(_formatDate(rental.leaseStartDate),
                      style: AppTextStyles.labelSmall),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('End',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  Text(_formatDate(rental.leaseEndDate),
                      style: AppTextStyles.labelSmall),
                ],
              ),
            ],
          ),

          // Total duration
          const SizedBox(height: 8),
          Center(
            child: Text(
              '$totalDays day lease (${rental.rentFrequency})',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandlordCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.primary.withAlpha(26),
          child: Text(
            rental.landlordName.isNotEmpty
                ? rental.landlordName[0].toUpperCase()
                : 'L',
            style: AppTextStyles.h4
                .copyWith(color: AppColors.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rental.landlordName,
                  style: AppTextStyles.labelLarge),
              const SizedBox(height: 2),
              Text('Your Landlord',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        // Message button
        IconButton(
          onPressed: _isMessageLoading ? null : _messageLandlord,
          icon: _isMessageLoading
              ? const SizedBox(
                  width: 36,
                  height: 36,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                )
              : Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.chat_outlined,
                      color: AppColors.primary, size: 20),
                ),
        ),
        // Call button
        IconButton(
          onPressed: _callLandlord,
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.phone,
                color: AppColors.success, size: 20),
          ),
        ),
      ]),
    );
  }

  // Streams issues in pending_confirmation state for this tenant's property.
  // Renders a confirmation card for each — tenant confirms or disputes.
  Widget _buildPendingConfirmations() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('issues')
          .where('tenantId', isEqualTo: rental.tenantId)
          .where('propertyId', isEqualTo: rental.propertyId)
          .where('status', isEqualTo: 'pending_confirmation')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final docs = snapshot.data!.docs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(
                    color: AppColors.info, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                'Fix${docs.length > 1 ? 'es' : ''} to Confirm (${docs.length})',
                style: AppTextStyles.labelLarge,
              ),
            ]),
            const SizedBox(height: 10),
            ...docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return _PendingConfirmationCard(
                issueId: doc.id,
                data: data,
              );
            }),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _QuickActionCard(
            icon: Icons.event_note_outlined,
            label: 'My Inspections',
            color: AppColors.primary,
            onTap: () => context.push('/tenant/inspections'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionCard(
            icon: Icons.description_outlined,
            label: 'Lease Details',
            color: AppColors.info,
            onTap: () =>
              context.push('/tenant/lease-details' , extra: rental),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionCard(
            icon: Icons.report_problem_outlined,
            label: 'Report Issue',
            color: AppColors.warning,
            onTap: () => context.push('/tenant/report-issue', extra: {
              'propertyId': rental.propertyId,
              'propertyTitle': rental.propertyTitle,
              'tenantId': rental.tenantId,
              'tenantName': rental.tenantName,
              'landlordId': rental.landlordId,
              'landlordName': rental.landlordName,
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentCard() {
    final daysUntilPayment = rental.daysUntilPaymentDue;
    final isOverdue = rental.isPaymentOverdue;
    final isDueSoon = rental.isPaymentDueSoon;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOverdue
              ? AppColors.error.withAlpha(77)
              : isDueSoon
                  ? AppColors.warning.withAlpha(77)
                  : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              isOverdue
                  ? Icons.warning_amber_rounded
                  : Icons.payment,
              size: 20,
              color: isOverdue
                  ? AppColors.error
                  : isDueSoon
                      ? AppColors.warning
                      : AppColors.primary,
            ),
            const SizedBox(width: 8),
            Text('Next Payment', style: AppTextStyles.labelLarge),
            const Spacer(),
            // Reminder toggle
            if (_isTogglingReminder)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              )
            else
              Row(children: [
                Text(
                  rental.hasPaymentReminder ? 'Reminder on' : 'Remind me',
                  style: AppTextStyles.caption.copyWith(
                    color: rental.hasPaymentReminder
                        ? AppColors.success
                        : AppColors.textHint,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: _toggleReminder,
                  child: Icon(
                    rental.hasPaymentReminder
                        ? Icons.notifications_active
                        : Icons.notifications_none_outlined,
                    size: 20,
                    color: rental.hasPaymentReminder
                        ? AppColors.success
                        : AppColors.textHint,
                  ),
                ),
              ]),
          ]),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Amount',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 2),
                  Text('₦${_formatAmount(rental.rentAmount)}',
                      style: AppTextStyles.h4
                          .copyWith(color: AppColors.textPrimary)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Due date',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 2),
                  Text(
                    _formatDate(rental.nextPaymentDue),
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isOverdue
                          ? AppColors.error
                          : isDueSoon
                              ? AppColors.warning
                              : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),

          if (isOverdue) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline,
                    size: 16, color: AppColors.error),
                const SizedBox(width: 8),
                Text(
                  'Payment is ${-daysUntilPayment} days overdue',
                  style: AppTextStyles.labelSmall
                      .copyWith(color: AppColors.error),
                ),
              ]),
            ),
          ] else if (isDueSoon) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline,
                    size: 16, color: AppColors.warning),
                const SizedBox(width: 8),
                Text(
                  'Due in $daysUntilPayment days',
                  style: AppTextStyles.labelSmall
                      .copyWith(color: AppColors.warning),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBrowseMore() {
    return GestureDetector(
      onTap: widget.onBrowseProperties,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(13),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(38)),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.search,
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Browse Properties',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.primary)),
                Text(
                  'Looking ahead? Browse for when your lease ends.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.primary),
        ]),
      ),
    );
  }

  Widget _imagePlaceholder() => Container(
        color: AppColors.background,
        child: const Center(
          child: Icon(Icons.home_outlined,
              size: 48, color: AppColors.textHint),
        ),
      );
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: AppTextStyles.labelSmall,
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

/// Card shown on the tenant dashboard when a landlord has marked an issue as fixed
/// and is awaiting tenant confirmation. Tenant can confirm or dispute.
class _PendingConfirmationCard extends StatefulWidget {
  final String issueId;
  final Map<String, dynamic> data;

  const _PendingConfirmationCard({
    required this.issueId,
    required this.data,
  });

  @override
  State<_PendingConfirmationCard> createState() =>
      _PendingConfirmationCardState();
}

class _PendingConfirmationCardState extends State<_PendingConfirmationCard> {
  bool _isActing = false;

  String get _title => widget.data['title'] ?? 'Issue';
  String get _category => widget.data['category'] ?? 'other';

  Future<void> _confirm() async {
    setState(() => _isActing = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
        'tenantConfirmedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify landlord
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
        await FirebaseFirestore.instance.collection('activities').add({
          'userId': landlordId,
          'type': 'issue_updated',
          'title': 'Fix Confirmed',
          'message':
              '${widget.data['tenantName'] ?? 'Your tenant'} confirmed the $_category issue has been resolved.',
          'propertyId': widget.data['propertyId'],
          'issueId': widget.issueId,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('❌ Error confirming fix: $e');
      if (mounted) setState(() => _isActing = false);
    }
  }

  Future<void> _dispute() async {
    // Ask tenant for a reason before disputing
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('What\'s still wrong?'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Describe what hasn\'t been fixed yet...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(ctx, reasonController.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Submit Dispute',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (reason == null || reason.isEmpty) return;

    setState(() => _isActing = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': 'in_progress',
        'disputeReason': reason,
        'disputedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify landlord with dispute reason
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
        await FirebaseFirestore.instance.collection('activities').add({
          'landlordId': landlordId,
          'type': 'issue_disputed',
          'title': 'Fix Disputed',
          'message':
              '${widget.data['tenantName'] ?? 'Your tenant'} says the $_category issue is not fully resolved: "$reason"',
          'propertyId': widget.data['propertyId'],
          'issueId': widget.issueId,
          'actorId': widget.data['tenantId'],
          'actorName': widget.data['tenantName'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('❌ Error disputing fix: $e');
      if (mounted) setState(() => _isActing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.info.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.build_outlined,
                  size: 16, color: AppColors.info),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(
                    'Your landlord says this is fixed',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.info),
                  ),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 12),

          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isActing ? null : _dispute,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: const BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text('Still Broken',
                    style: TextStyle(
                        color: AppColors.error, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _isActing ? null : _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _isActing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Confirmed Fixed', style: TextStyle(fontSize: 13)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}