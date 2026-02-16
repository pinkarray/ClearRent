import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/conversation_service.dart';

class MyRentalsScreen extends StatefulWidget {
  const MyRentalsScreen({super.key});

  @override
  State<MyRentalsScreen> createState() => _MyRentalsScreenState();
}

class _MyRentalsScreenState extends State<MyRentalsScreen> {
  final ActiveRentalService _rentalService = ActiveRentalService();

  List<ActiveRental> _activeRentals = [];
  List<ActiveRental> _pastRentals = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRentals();
  }

  Future<void> _loadRentals() async {
    try {
      final rentals = await _rentalService.getTenantRentals();
      if (mounted) {
        setState(() {
          _activeRentals =
              rentals.where((r) => r.isActive || r.isExpiringSoon).toList();
          _pastRentals =
              rentals.where((r) => !r.isActive && !r.isExpiringSoon).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading rentals: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatAmount(double amount) {
    return NumberFormat('#,###').format(amount);
  }

  String _formatDate(DateTime date) {
    return DateFormat('MMM d, y').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final hasActiveRental = _activeRentals.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('My Rentals', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : !hasActiveRental && _pastRentals.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadRentals,
                  color: AppColors.primary,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Quick Stats
                        if (hasActiveRental) ...[
                          _buildQuickStats(_activeRentals.first),
                          const SizedBox(height: 8),
                          _buildPaymentAlert(_activeRentals.first),
                        ],

                        // Current Rentals
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                          child: Text('Current Rental',
                              style: AppTextStyles.labelLarge
                                  .copyWith(color: AppColors.textSecondary)),
                        ),
                        if (_activeRentals.isEmpty)
                          _buildNoActiveCard()
                        else
                          ..._activeRentals
                              .map((r) => _buildRentalCard(r)),

                        // Past Rentals
                        if (_pastRentals.isNotEmpty) ...[
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(20, 24, 20, 12),
                            child: Text('Rental History',
                                style: AppTextStyles.labelLarge.copyWith(
                                    color: AppColors.textSecondary)),
                          ),
                          ..._pastRentals
                              .map((r) => _buildRentalCard(r, isPast: true)),
                        ],

                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildQuickStats(ActiveRental rental) {
    final daysLeft = rental.daysUntilLeaseEnd;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryLight],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(77),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(51),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.home_outlined,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Active Rental',
                      style: AppTextStyles.caption
                          .copyWith(color: Colors.white.withAlpha(204))),
                  const SizedBox(height: 2),
                  Text(rental.propertyTitle,
                      style: AppTextStyles.labelLarge
                          .copyWith(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: _buildStatItem(
                icon: Icons.calendar_today_outlined,
                value: '$daysLeft',
                label: 'Days Left\non Lease',
              ),
            ),
            Container(
                width: 1,
                height: 50,
                color: Colors.white.withAlpha(51)),
            Expanded(
              child: _buildStatItem(
                icon: Icons.payments_outlined,
                value: '₦${_formatAmount(rental.rentAmount)}',
                label: rental.rentPeriod.isNotEmpty
                    ? rental.rentPeriod.replaceAll('/', 'Per ')
                    : 'Per Year',
              ),
            ),
            Container(
                width: 1,
                height: 50,
                color: Colors.white.withAlpha(51)),
            Expanded(
              child: _buildStatItem(
                icon: Icons.history,
                value: '${_activeRentals.length + _pastRentals.length}',
                label: 'Total\nRentals',
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Column(children: [
      Icon(icon, color: Colors.white.withAlpha(204), size: 18),
      const SizedBox(height: 6),
      Text(value,
          style: AppTextStyles.h4
              .copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      Text(label,
          style: AppTextStyles.caption
              .copyWith(color: Colors.white.withAlpha(179), height: 1.2),
          textAlign: TextAlign.center),
    ]);
  }

  Widget _buildPaymentAlert(ActiveRental rental) {
    final daysLeft = rental.daysUntilLeaseEnd;
    final isUrgent = daysLeft <= 30;
    final alertColor = isUrgent ? AppColors.error : AppColors.warning;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: alertColor.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: alertColor.withAlpha(77)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: alertColor.withAlpha(51),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isUrgent
                ? Icons.warning_amber_rounded
                : Icons.notifications_active_outlined,
            color: alertColor,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUrgent ? 'Lease Ending Soon!' : 'Lease Reminder',
                style:
                    AppTextStyles.labelMedium.copyWith(color: alertColor),
              ),
              const SizedBox(height: 2),
              Text(
                isUrgent
                    ? 'Your lease ends in $daysLeft days. Contact your landlord about renewal.'
                    : 'Your lease for ${rental.propertyTitle} has $daysLeft days remaining.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildRentalCard(ActiveRental rental, {bool isPast = false}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Image + status
        Stack(children: [
          ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            child: rental.propertyImage.isNotEmpty
                ? Image.network(
                    rental.propertyImage,
                    height: 140,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _imagePlaceholder(),
                  )
                : _imagePlaceholder(),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: rental.isActive
                    ? AppColors.success
                    : AppColors.textHint,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                rental.isActive ? 'Active' : 'Ended',
                style: AppTextStyles.caption.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ]),

        // Details
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rental.propertyTitle,
                  style: AppTextStyles.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.location_on_outlined,
                    size: 14, color: AppColors.textHint),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(rental.propertyAddress,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),

              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),

              Row(children: [
                Expanded(
                  child: _buildInfoItem(
                    icon: Icons.person_outline,
                    label: 'Landlord',
                    value: rental.landlordName,
                  ),
                ),
                Expanded(
                  child: _buildInfoItem(
                    icon: Icons.payments_outlined,
                    label: 'Rent',
                    value:
                        '₦${_formatAmount(rental.rentAmount)}${rental.rentPeriod}',
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _buildInfoItem(
                    icon: Icons.calendar_today_outlined,
                    label: 'Lease Period',
                    value:
                        '${_formatDate(rental.leaseStartDate)} - ${_formatDate(rental.leaseEndDate)}',
                  ),
                ),
              ]),

              if (!isPast) ...[
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _messageLandlord(rental),
                      icon:
                          const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Message'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          context.push('/tenant/lease-details', extra: rental),
                      icon: const Icon(Icons.description_outlined,
                          size: 18),
                      label: const Text('Lease Details'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(color: AppColors.primary),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: AppColors.textHint),
      const SizedBox(width: 6),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textHint)),
          Text(value,
              style:
                  AppTextStyles.bodySmall.copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    ]);
  }

  Future<void> _messageLandlord(ActiveRental rental) async {
    try {
      final conv =
          await ConversationService().getOrCreateConversation(
        propertyId: rental.propertyId,
        propertyTitle: rental.propertyTitle,
        propertyImage: rental.propertyImage,
        landlordId: rental.landlordId,
        landlordName: rental.landlordName,
        tenantId: rental.tenantId,
        tenantName: rental.tenantName,
      );
      if (!mounted) return;
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': rental.propertyTitle,
          'propertyImage': rental.propertyImage.isNotEmpty
              ? rental.propertyImage
              : null,
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Could not open chat'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.home_outlined,
                size: 48, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          Text('No Rentals Yet', style: AppTextStyles.h4),
          const SizedBox(height: 8),
          Text(
            'When you rent a property through ClearRent, it will appear here.',
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.go('/tenant/home'),
            icon: const Icon(Icons.search, size: 18),
            label: const Text('Browse Properties'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildNoActiveCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        Icon(Icons.home_outlined, size: 40, color: AppColors.textHint),
        const SizedBox(height: 12),
        Text('No active rental',
            style: AppTextStyles.bodyMedium
                .copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Text('Browse properties and find your next home!',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textHint),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => context.go('/tenant/home'),
          icon: const Icon(Icons.search, size: 16),
          label: const Text('Find Properties'),
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
        ),
      ]),
    );
  }

  Widget _imagePlaceholder() {
    return Container(
      height: 140,
      color: AppColors.border,
      child: const Center(
        child: Icon(Icons.image_not_supported, color: AppColors.textHint),
      ),
    );
  }
}