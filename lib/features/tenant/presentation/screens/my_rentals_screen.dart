import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/tenancy_link_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/tenancy_link_service.dart';
import '../../../../services/agreement_access_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/widgets/guidance_empty_state.dart';

class MyRentalsScreen extends StatefulWidget {
  const MyRentalsScreen({super.key});

  @override
  State<MyRentalsScreen> createState() => _MyRentalsScreenState();
}

class _MyRentalsScreenState extends State<MyRentalsScreen> {
  final ActiveRentalService _rentalService = ActiveRentalService();
  final TenancyLinkService _linkService = TenancyLinkService();
  final AgreementAccessService _agreementAccess = AgreementAccessService();

  List<ActiveRental> _activeRentals = [];
  List<ActiveRental> _pastRentals = [];
  // A landlord-linked tenancy (no active_rental). Surfaced alongside rentals so
  // linked tenants see their tenancy here too, not an empty "browse" state.
  TenancyLinkModel? _link;
  bool _isLoading = true;
  StreamSubscription<List<ActiveRental>>? _rentalsSub;

  @override
  void initState() {
    super.initState();
    _loadRentals();
  }

  @override
  void dispose() {
    _rentalsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadRentals() async {
    // Live-subscribe so the screen can't go stale — e.g. after paying rent, the
    // rental flips pending_payment → active server-side and the card updates on
    // its own instead of still showing "Review Agreement & Pay Rent".
    _rentalsSub ??= _rentalService.streamAllTenantRentals().listen((rentals) {
      if (!mounted) return;
      setState(() {
        // A pending_payment rental (accepted, awaiting rent) is a CURRENT
        // rental — it must show in the current section with a working Lease
        // Details button so the tenant can accept + pay. It was falling into
        // "past", which labelled it "Ended" and hid the Lease Details button.
        _activeRentals = rentals.where((r) => r.isCurrent).toList();
        _pastRentals = rentals.where((r) => !r.isCurrent).toList();
        _isLoading = false;
      });
    }, onError: (e) {
      debugPrint('❌ Error streaming rentals: $e');
      if (mounted) setState(() => _isLoading = false);
    });
    try {
      final link = await _linkService.getTenantActiveLink();
      if (mounted) setState(() => _link = link);
    } catch (e) {
      debugPrint('❌ Error loading tenancy link: $e');
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
    final hasCurrent = _activeRentals.isNotEmpty;
    // The lease-summary banner + "days left" reminder only make sense for a
    // genuinely active (paid) lease — not a pending_payment one that's still in
    // the agreement/pay stage.
    final activeLeases = _activeRentals.where((r) => r.isActive).toList();
    final hasActiveLease = activeLeases.isNotEmpty;
    final hasLink = _link != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : !hasCurrent && _pastRentals.isEmpty && !hasLink
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadRentals,
                  color: AppColors.primary,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Quick Stats — only for a genuinely active (paid) lease
                        if (hasActiveLease) ...[
                          _buildQuickStats(activeLeases.first),
                          const SizedBox(height: 8),
                          _buildPaymentAlert(activeLeases.first),
                        ],

                        // Current Rentals
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                          child: Text('Current Rental',
                              style: AppTextStyles.labelLarge
                                  .copyWith(color: AppColors.textSecondary)),
                        ),
                        if (_activeRentals.isNotEmpty)
                          ..._activeRentals
                              .map((r) => _buildRentalCard(r))
                        else if (hasLink)
                          _buildLinkedRentalCard(_link!)
                        else
                          _buildNoActiveCard(),

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
                ? CachedNetworkImage(
                    imageUrl: rental.propertyImage,
                    height: 140,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    memCacheWidth: 800,
                    errorWidget: (_, __, ___) => _imagePlaceholder(),
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
                    : rental.isPendingPayment
                        ? AppColors.warning
                        : AppColors.textHint,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                rental.isActive
                    ? 'Active'
                    : rental.isPendingPayment
                        ? 'Awaiting Payment'
                        : 'Ended',
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

              // Landlord-ended tenancy — tenant can add their account (contest).
              if (rental.isEndedByLandlord) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withAlpha(13),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.warning.withAlpha(77)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.gavel_outlined,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Text('Ended by Landlord',
                            style: AppTextStyles.labelMedium
                                .copyWith(color: AppColors.warning)),
                      ]),
                      if ((rental.endReason ?? '').isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Reason: ${rental.endReason}',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (rental.tenantContested) ...[
                        Text('Your account',
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.textHint)),
                        const SizedBox(height: 4),
                        Text(
                          rental.tenantContestStatement ?? '',
                          style: AppTextStyles.bodySmall,
                        ),
                      ] else
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _showContestSheet(rental),
                            icon: const Icon(Icons.edit_note, size: 18),
                            label: const Text('Add your account'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.warning,
                              side: BorderSide(color: AppColors.warning),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],

              // Pay-after-accept: a pending_payment rental needs an OBVIOUS
              // path to review the agreement + pay — the outlined "Lease
              // Details" button below wasn't reading as "this is how you pay".
              if (rental.isPendingPayment) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () =>
                        context.push('/tenant/lease-details', extra: rental),
                    icon: const Icon(Icons.assignment_turned_in_outlined,
                        size: 18, color: Colors.white),
                    label: const Text('Review Agreement & Pay Rent'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],

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
                        side: BorderSide(color: AppColors.border),
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
                        side: BorderSide(color: AppColors.primary),
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

  Future<void> _showContestSheet(ActiveRental rental) async {
    final controller = TextEditingController();
    final submitted = await showModalBottomSheet<bool>(
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
              Text('Add Your Account', style: AppTextStyles.h4),
              const SizedBox(height: 6),
              Text(
                'Your landlord marked this tenancy as ended. You can record '
                'your side of what happened. Both of you will see it; ClearRent '
                'does not decide the outcome.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Describe what happened from your perspective...',
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
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('Submit',
                      style: AppTextStyles.labelLarge
                          .copyWith(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (submitted != true) return;
    final statement = controller.text.trim();
    if (statement.isEmpty) return;

    final ok = await _rentalService.tenantContest(rental.id, statement);
    if (!mounted) return;
    if (ok) {
      _loadRentals(); // reload so the card flips to the read-only account
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Could not submit. Please try again.'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
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
    return GuidanceEmptyState(
      icon: Icons.home_outlined,
      title: 'No Rentals Yet',
      subtitle:
          'When you rent a property through ClearRent, it will appear here. '
          'Find a place to get started.',
      actionLabel: 'Browse Properties',
      actionIcon: Icons.search,
      onAction: () => context.go('/tenant/home'),
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

  // Card for a landlord-linked tenancy (no active_rental). Mirrors the rental
  // card's key info using the link's protected rentAmount, plus the revised
  // agreement when the landlord has attached one.
  Widget _buildLinkedRentalCard(TenancyLinkModel link) {
    final hasAgreement =
        link.agreementUrl != null && link.agreementUrl!.isNotEmpty;
    final hasLeaseTerm = link.leaseStartDate != null && link.leaseEndDate != null;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.home_outlined, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(link.propertyTitle,
                  style: AppTextStyles.labelLarge,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(link.propertyAddress,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(26),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('Linked',
                style: AppTextStyles.caption.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600, fontSize: 10)),
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
              value: link.landlordName,
            ),
          ),
          Expanded(
            child: _buildInfoItem(
              icon: Icons.payments_outlined,
              label: 'Rent',
              value:
                  '₦${_formatAmount(link.rentAmount)}/${link.rentFrequency == 'yearly' ? 'yr' : 'mo'}',
            ),
          ),
        ]),
        if (hasLeaseTerm) ...[
          const SizedBox(height: 12),
          _buildInfoItem(
            icon: Icons.calendar_today_outlined,
            label: 'Lease Period',
            value:
                '${_formatDate(link.leaseStartDate!)} - ${_formatDate(link.leaseEndDate!)}',
          ),
        ],

        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _messageLandlordForLink(link),
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Message'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          if (hasAgreement) ...[
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openLinkAgreement(link),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Agreement'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  // Agreements are private — resolve a short-lived signed URL via the CF
  // (which authorizes this tenant) before opening.
  Future<void> _openLinkAgreement(TenancyLinkModel link) async {
    final url = await _agreementAccess.resolveUrl(
      collection: 'tenancy_links',
      docId: link.id,
    );
    if (!mounted) return;
    final uri = url != null ? Uri.tryParse(url) : null;
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Could not open the agreement'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Future<void> _messageLandlordForLink(TenancyLinkModel link) async {
    try {
      final conv = await ConversationService().getOrCreateConversation(
        propertyId: link.propertyId,
        propertyTitle: link.propertyTitle,
        propertyImage: '',
        landlordId: link.landlordId,
        landlordName: link.landlordName,
        tenantId: link.tenantId,
        tenantName: link.tenantName,
      );
      if (!mounted) return;
      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': link.propertyTitle,
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Could not open chat'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Widget _imagePlaceholder() {
    return Container(
      height: 140,
      color: AppColors.border,
      child: Center(
        child: Icon(Icons.image_not_supported, color: AppColors.textHint),
      ),
    );
  }
}