import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';

class MyRentalsScreen extends StatefulWidget {
  const MyRentalsScreen({super.key});

  @override
  State<MyRentalsScreen> createState() => _MyRentalsScreenState();
}

class _MyRentalsScreenState extends State<MyRentalsScreen> {
  // Demo rental data
  final List<RentalModel> _rentals = [
    RentalModel(
      id: '1',
      propertyTitle: '3 Bedroom Flat in Lekki Phase 1',
      propertyImage: 'https://images.unsplash.com/photo-1560448204-e02f11c3d0e2?w=800',
      address: '15 Admiralty Way, Lekki Phase 1',
      landlordName: 'Mr. Adebayo Johnson',
      rentAmount: 2500000,
      rentFrequency: 'yearly',
      nextDueDate: DateTime.now().add(const Duration(days: 45)),
      leaseStart: DateTime(2024, 1, 15),
      leaseEnd: DateTime(2025, 1, 14),
      status: RentalStatus.active,
      hasReminder: true,
    ),
  ];

  // Demo past rentals
  final List<RentalModel> _pastRentals = [
    RentalModel(
      id: '2',
      propertyTitle: '2 Bedroom Apartment in Yaba',
      propertyImage: 'https://images.unsplash.com/photo-1502672260266-1c1ef2d93688?w=800',
      address: '8 Herbert Macaulay Way, Yaba',
      landlordName: 'Mrs. Chioma Okafor',
      rentAmount: 1200000,
      rentFrequency: 'yearly',
      nextDueDate: DateTime(2023, 12, 31),
      leaseStart: DateTime(2023, 1, 1),
      leaseEnd: DateTime(2023, 12, 31),
      status: RentalStatus.completed,
      hasReminder: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final hasActiveRental = _rentals.isNotEmpty;

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
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quick Stats
            if (hasActiveRental) ...[
              _buildQuickStats(),
              const SizedBox(height: 8),
            ],

            // Upcoming Payment Alert
            if (hasActiveRental) ...[
              _buildPaymentAlert(_rentals.first),
              const SizedBox(height: 8),
            ],

            // Current Rentals Section
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text(
                'Current Rental',
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),

            if (_rentals.isEmpty)
              _buildEmptyState()
            else
              ..._rentals.map((rental) => _buildRentalCard(rental)),

            // Past Rentals Section
            if (_pastRentals.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Text(
                  'Rental History',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              ..._pastRentals.map((rental) => _buildRentalCard(rental, isPast: true)),
            ],

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickStats() {
    final activeRental = _rentals.first;
    final daysUntilDue = activeRental.nextDueDate.difference(DateTime.now()).inDays;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary,
            AppColors.primaryLight,
          ],
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
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(51),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.home_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active Rental',
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.white.withAlpha(204),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      activeRental.propertyTitle,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Stats Row
          Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  icon: Icons.calendar_today_outlined,
                  value: '$daysUntilDue',
                  label: 'Days to\nNext Rent',
                ),
              ),
              Container(
                width: 1,
                height: 50,
                color: Colors.white.withAlpha(51),
              ),
              Expanded(
                child: _buildStatItem(
                  icon: Icons.payments_outlined,
                  value: '₦${_formatAmount(activeRental.rentAmount)}',
                  label: activeRental.rentFrequency == 'yearly' ? 'Per Year' : 'Per Month',
                ),
              ),
              Container(
                width: 1,
                height: 50,
                color: Colors.white.withAlpha(51),
              ),
              Expanded(
                child: _buildStatItem(
                  icon: Icons.history,
                  value: '${_pastRentals.length + 1}',
                  label: 'Total\nRentals',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withAlpha(204), size: 18),
        const SizedBox(height: 6),
        Text(
          value,
          style: AppTextStyles.h4.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: Colors.white.withAlpha(179),
            height: 1.2,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildPaymentAlert(RentalModel rental) {
    final daysUntilDue = rental.nextDueDate.difference(DateTime.now()).inDays;
    final isUrgent = daysUntilDue <= 7;
    final alertColor = isUrgent ? AppColors.error : AppColors.warning;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: alertColor.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: alertColor.withAlpha(77)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: alertColor.withAlpha(51),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isUrgent ? Icons.warning_amber_rounded : Icons.notifications_active_outlined,
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
                  isUrgent ? 'Rent Due Soon!' : 'Upcoming Payment',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: alertColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Next payment of ₦${_formatAmount(rental.rentAmount)} due in $daysUntilDue days',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildReminderToggle(rental),
        ],
      ),
    );
  }

  Widget _buildReminderToggle(RentalModel rental) {
    return GestureDetector(
      onTap: () {
        setState(() {
          final index = _rentals.indexOf(rental);
          if (index != -1) {
            _rentals[index] = rental.copyWith(hasReminder: !rental.hasReminder);
          }
        });
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              rental.hasReminder 
                  ? 'Reminder turned off' 
                  : 'Reminder set for 7 days before due date',
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: rental.hasReminder ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: rental.hasReminder ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              rental.hasReminder ? Icons.notifications_active : Icons.notifications_off_outlined,
              size: 14,
              color: rental.hasReminder ? Colors.white : AppColors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              rental.hasReminder ? 'On' : 'Off',
              style: AppTextStyles.caption.copyWith(
                color: rental.hasReminder ? Colors.white : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRentalCard(RentalModel rental, {bool isPast = false}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Property Image & Status
          Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                child: Image.network(
                  rental.propertyImage,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 140,
                    color: AppColors.border,
                    child: const Center(
                      child: Icon(Icons.image_not_supported, color: AppColors.textHint),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: rental.status == RentalStatus.active 
                        ? AppColors.success 
                        : AppColors.textHint,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    rental.status == RentalStatus.active ? 'Active' : 'Completed',
                    style: AppTextStyles.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Details
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rental.propertyTitle,
                  style: AppTextStyles.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.location_on_outlined, size: 14, color: AppColors.textHint),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        rental.address,
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // Info Grid
                Row(
                  children: [
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
                        value: '₦${_formatAmount(rental.rentAmount)}/${rental.rentFrequency == 'yearly' ? 'yr' : 'mo'}',
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: _buildInfoItem(
                        icon: Icons.calendar_today_outlined,
                        label: 'Lease Period',
                        value: '${_formatDate(rental.leaseStart)} - ${_formatDate(rental.leaseEnd)}',
                      ),
                    ),
                  ],
                ),

                if (!isPast) ...[
                  const SizedBox(height: 16),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Messaging coming soon!'),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.chat_bubble_outline, size: 18),
                          label: const Text('Message'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.border),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Payment integration coming soon!'),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.payment, size: 18),
                          label: const Text('Pay Rent'),
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
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.textHint),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textHint,
                ),
              ),
              Text(
                value,
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.home_outlined,
              size: 48,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'No Active Rentals',
            style: AppTextStyles.h4,
          ),
          const SizedBox(height: 8),
          Text(
            'When you rent a property through ClearRent,\nit will appear here.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.go('/tenant/home'),
            icon: const Icon(Icons.search, size: 18),
            label: const Text('Find Properties'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatAmount(double amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(1)}M';
    } else if (amount >= 1000) {
      return '${(amount / 1000).toStringAsFixed(0)}K';
    }
    return amount.toStringAsFixed(0);
  }

  String _formatDate(DateTime date) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.year}';
  }
}

// ============ MODELS ============

enum RentalStatus { active, completed, cancelled }

class RentalModel {
  final String id;
  final String propertyTitle;
  final String propertyImage;
  final String address;
  final String landlordName;
  final double rentAmount;
  final String rentFrequency;
  final DateTime nextDueDate;
  final DateTime leaseStart;
  final DateTime leaseEnd;
  final RentalStatus status;
  final bool hasReminder;

  RentalModel({
    required this.id,
    required this.propertyTitle,
    required this.propertyImage,
    required this.address,
    required this.landlordName,
    required this.rentAmount,
    required this.rentFrequency,
    required this.nextDueDate,
    required this.leaseStart,
    required this.leaseEnd,
    required this.status,
    required this.hasReminder,
  });

  RentalModel copyWith({
    String? id,
    String? propertyTitle,
    String? propertyImage,
    String? address,
    String? landlordName,
    double? rentAmount,
    String? rentFrequency,
    DateTime? nextDueDate,
    DateTime? leaseStart,
    DateTime? leaseEnd,
    RentalStatus? status,
    bool? hasReminder,
  }) {
    return RentalModel(
      id: id ?? this.id,
      propertyTitle: propertyTitle ?? this.propertyTitle,
      propertyImage: propertyImage ?? this.propertyImage,
      address: address ?? this.address,
      landlordName: landlordName ?? this.landlordName,
      rentAmount: rentAmount ?? this.rentAmount,
      rentFrequency: rentFrequency ?? this.rentFrequency,
      nextDueDate: nextDueDate ?? this.nextDueDate,
      leaseStart: leaseStart ?? this.leaseStart,
      leaseEnd: leaseEnd ?? this.leaseEnd,
      status: status ?? this.status,
      hasReminder: hasReminder ?? this.hasReminder,
    );
  }
}