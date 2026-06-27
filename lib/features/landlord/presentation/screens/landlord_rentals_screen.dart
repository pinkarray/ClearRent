import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/widgets/tab_badge.dart';

class LandlordRentalsScreen extends StatefulWidget {
  const LandlordRentalsScreen({super.key});

  @override
  State<LandlordRentalsScreen> createState() => _LandlordRentalsScreenState();
}

class _LandlordRentalsScreenState extends State<LandlordRentalsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ActiveRentalService _rentalService = ActiveRentalService();
  final ConversationService _conversationService = ConversationService();

  List<ActiveRental> _allRentals = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadRentals();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadRentals() async {
    setState(() => _isLoading = true);
    try {
      final rentals = await _rentalService.getLandlordRentals();
      if (!mounted) return;
      setState(() {
        _allRentals = rentals;
        _isLoading = false;
      });
    } catch (e) {
      developer.log('❌ Error loading rentals: $e',
          name: 'LandlordRentals');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  List<ActiveRental> get _activeRentals => _allRentals
      .where((r) => r.isActive || r.isExpiringSoon || r.isGraceLocked)
      .toList()
    ..sort((a, b) => a.leaseEndDate.compareTo(b.leaseEndDate));

  List<ActiveRental> get _pastRentals => _allRentals
      .where((r) =>
          r.isExpired ||
          r.isTerminated ||
          r.isEndedByTenant ||
          r.isEndedByLandlord)
      .toList()
    ..sort((a, b) => b.leaseEndDate.compareTo(a.leaseEndDate));

  /// Active rentals that need the landlord's attention — leases expiring
  /// soon or in the post-expiry grace window (renewal / re-list decision).
  int get _expiringCount =>
      _activeRentals.where((r) => r.isExpiringSoon || r.isGraceLocked).length;

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
        title: Text('My Rentals', style: AppTextStyles.h4),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          tabs: [
            Tab(
              child: TabBadge(
                label: 'Active (${_activeRentals.length})',
                count: _expiringCount,
              ),
            ),
            Tab(text: 'Past (${_pastRentals.length})'),
          ],
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildRentalList(_activeRentals, isActive: true),
                _buildRentalList(_pastRentals, isActive: false),
              ],
            ),
    );
  }

  Widget _buildRentalList(List<ActiveRental> rentals,
      {required bool isActive}) {
    if (rentals.isEmpty) {
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
                child: Icon(
                  isActive ? Icons.home_outlined : Icons.history,
                  size: 40,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                isActive ? 'No active rentals' : 'No past rentals',
                style: AppTextStyles.h4,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isActive
                    ? 'When tenants rent your properties, they\'ll appear here'
                    : 'Expired or terminated rentals will appear here',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRentals,
      color: AppColors.primary,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: rentals.length,
        itemBuilder: (context, index) => _RentalCard(
          rental: rentals[index],
          conversationService: _conversationService,
          rentalService: _rentalService,
          isActive: isActive,
          onChanged: _loadRentals,
        ),
      ),
    );
  }
}

// ============================================================
// RENTAL CARD
// ============================================================
class _RentalCard extends StatefulWidget {
  final ActiveRental rental;
  final ConversationService conversationService;
  final ActiveRentalService rentalService;
  final bool isActive;
  final VoidCallback onChanged;

  const _RentalCard({
    required this.rental,
    required this.conversationService,
    required this.rentalService,
    required this.isActive,
    required this.onChanged,
  });

  @override
  State<_RentalCard> createState() => _RentalCardState();
}

class _RentalCardState extends State<_RentalCard> {
  bool _isMessageLoading = false;

  ActiveRental get rental => widget.rental;

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
    final total =
        rental.leaseEndDate.difference(rental.leaseStartDate).inDays;
    final elapsed =
        DateTime.now().difference(rental.leaseStartDate).inDays;
    if (total <= 0) return 1.0;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  Future<void> _messageTenant() async {
    setState(() => _isMessageLoading = true);
    try {
      final conv =
          await widget.conversationService.getOrCreateConversation(
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
      }
    } catch (e) {
      developer.log('❌ Message error: $e', name: 'LandlordRentals');
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
    }
  }

  /// Opens the end-tenancy sheet. Only reachable on a grace_locked rental.
  /// Records status ended_by_landlord server-side; ClearRent notifies the
  /// tenant and preserves the record — this is not an eviction.
  Future<void> _showEndTenancySheet() async {
    final controller = TextEditingController();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('End Tenancy', style: AppTextStyles.h4),
              const SizedBox(height: 6),
              Text(
                'This lease has lapsed and the tenant hasn\'t renewed. Ending '
                'it here updates your records and notifies the tenant — it is '
                'not a legal eviction. The tenant can add their own account.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Reason (e.g. lease expired, not renewed)',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    if (controller.text.trim().isEmpty) return;
                    Navigator.pop(sheetCtx, true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('End Tenancy',
                      style: AppTextStyles.labelLarge
                          .copyWith(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;
    final reason = controller.text.trim();
    if (reason.isEmpty) return;

    final ok =
        await widget.rentalService.landlordRemoveTenant(rental.id, reason);
    if (!mounted) return;
    if (ok) {
      widget.onChanged(); // reload — rental flips to ended_by_landlord → Past
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            'Could not end tenancy. It may no longer be eligible.'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final daysLeft = rental.daysUntilLeaseEnd;
    final isExpiring = rental.isExpiringSoon;

    // Status
    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (rental.isExpired) {
      statusColor = AppColors.error;
      statusText = 'Expired';
      statusIcon = Icons.event_busy;
    } else if (rental.isTerminated) {
      statusColor = AppColors.textSecondary;
      statusText = 'Terminated';
      statusIcon = Icons.cancel_outlined;
    } else if (rental.isEndedByTenant) {
      statusColor = AppColors.textSecondary;
      statusText = 'Tenant Moved Out';
      statusIcon = Icons.logout;
    } else if (rental.isEndedByLandlord) {
      statusColor = AppColors.textSecondary;
      statusText = 'Ended';
      statusIcon = Icons.cancel_outlined;
    } else if (rental.isGraceLocked) {
      statusColor = AppColors.warning;
      statusText = 'Renewal Due';
      statusIcon = Icons.lock_clock_outlined;
    } else if (isExpiring) {
      statusColor = AppColors.warning;
      statusText = '$daysLeft days left';
      statusIcon = Icons.timer_outlined;
    } else {
      statusColor = AppColors.success;
      statusText = 'Active';
      statusIcon = Icons.check_circle_outline;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: isExpiring
            ? Border.all(color: AppColors.warning.withAlpha(77), width: 1.5)
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
        children: [
          // Property image + status
          Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16)),
                child: SizedBox(
                  height: 140,
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
              // Status badge
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(statusText,
                          style: AppTextStyles.labelSmall.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              // "Rented" overlay
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(153),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.key, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                      Text('Rented',
                          style: AppTextStyles.labelSmall.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Property title + rent
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(rental.propertyTitle,
                              style: AppTextStyles.labelLarge,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Row(children: [
                            Icon(Icons.location_on_outlined,
                                size: 14,
                                color: AppColors.textSecondary),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(rental.propertyAddress,
                                  style: AppTextStyles.caption.copyWith(
                                      color: AppColors.textSecondary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(13),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '₦${_formatAmount(rental.rentAmount)}${rental.rentPeriod}',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.primary),
                      ),
                    ),
                  ],
                ),

                // Scheduled rent change from an approved rent review — the new
                // rent applies at the tenant's next renewal (current rent is
                // protected until then).
                if (rental.pendingRentForRenewal != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.info.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.info.withAlpha(60)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.trending_up,
                            size: 16, color: AppColors.info),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'New rent ₦${_formatAmount(rental.pendingRentForRenewal!)} applies when this tenant renews (${_formatDate(rental.leaseEndDate)})',
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.info),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Tenant info
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: AppColors.info.withAlpha(26),
                      child: Text(
                        rental.tenantName.isNotEmpty
                            ? rental.tenantName[0].toUpperCase()
                            : 'T',
                        style: AppTextStyles.labelLarge
                            .copyWith(color: AppColors.info),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(rental.tenantName,
                              style: AppTextStyles.labelMedium),
                          const SizedBox(height: 2),
                          Text('Tenant',
                              style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    // Message tenant
                    IconButton(
                      onPressed:
                          _isMessageLoading ? null : _messageTenant,
                      icon: _isMessageLoading
                          ? SizedBox(
                              width: 36,
                              height: 36,
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primary),
                              ),
                            )
                          : Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withAlpha(26),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.chat_outlined,
                                  color: AppColors.primary, size: 18),
                            ),
                    ),
                  ],
                ),

                // Lease progress (only for active)
                if (widget.isActive) ...[
                  const SizedBox(height: 16),
                  _buildLeaseProgress(daysLeft),
                ],

                // Payment info (only for active)
                if (widget.isActive) ...[
                  const SizedBox(height: 12),
                  _buildPaymentInfo(),
                ],

                // End-tenancy — only when the lease has lapsed (grace_locked).
                if (widget.isActive && rental.isGraceLocked) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _showEndTenancySheet,
                      icon: const Icon(Icons.gavel_outlined, size: 18),
                      label: const Text('End Tenancy'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: BorderSide(color: AppColors.error),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaseProgress(int daysLeft) {
    final totalDays =
        rental.leaseEndDate.difference(rental.leaseStartDate).inDays;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Lease Period',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
              Text(
                '${_formatDate(rental.leaseStartDate)} – ${_formatDate(rental.leaseEndDate)}',
                style: AppTextStyles.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _leaseProgress,
              minHeight: 6,
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation<Color>(
                daysLeft <= 30 ? AppColors.warning : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${((_leaseProgress * 100).toInt())}% elapsed',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textHint, fontSize: 11),
              ),
              Text(
                '$totalDays day lease',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textHint, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentInfo() {
    final isOverdue = rental.isPaymentOverdue;
    final isDueSoon = rental.isPaymentDueSoon;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOverdue
            ? AppColors.error.withAlpha(13)
            : isDueSoon
                ? AppColors.warning.withAlpha(13)
                : AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: isOverdue
            ? Border.all(color: AppColors.error.withAlpha(51))
            : isDueSoon
                ? Border.all(color: AppColors.warning.withAlpha(51))
                : null,
      ),
      child: Row(
        children: [
          Icon(
            isOverdue
                ? Icons.warning_amber_rounded
                : Icons.payment,
            size: 18,
            color: isOverdue
                ? AppColors.error
                : isDueSoon
                    ? AppColors.warning
                    : AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOverdue
                      ? 'Payment overdue'
                      : isDueSoon
                          ? 'Payment due soon'
                          : 'Next payment',
                  style: AppTextStyles.labelSmall.copyWith(
                    color: isOverdue
                        ? AppColors.error
                        : isDueSoon
                            ? AppColors.warning
                            : AppColors.textSecondary,
                  ),
                ),
                Text(
                  _formatDate(rental.nextPaymentDue),
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint),
                ),
              ],
            ),
          ),
          Text(
            '₦${_formatAmount(rental.rentAmount)}',
            style: AppTextStyles.labelMedium.copyWith(
              color: isOverdue
                  ? AppColors.error
                  : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _imagePlaceholder() => Container(
        color: AppColors.background,
        child: Center(
          child: Icon(Icons.home_outlined,
              size: 40, color: AppColors.textHint),
        ),
      );
}