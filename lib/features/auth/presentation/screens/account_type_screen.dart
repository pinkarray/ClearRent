import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/widgets/app_button.dart';

class AccountTypeScreen extends StatefulWidget {
  const AccountTypeScreen({super.key});

  @override
  State<AccountTypeScreen> createState() => _AccountTypeScreenState();
}

class _AccountTypeScreenState extends State<AccountTypeScreen> {
  String? _selectedType;

  void _selectType(String type) {
    setState(() => _selectedType = type);
  }

  void _continue() {
    if (_selectedType == null) return;

    // Navigate to profile setup with the selected account type
    context.go('/profile-setup', extra: _selectedType);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false, // No back button — user must complete setup
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom -
                  kToolbarHeight,
            ),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),

                  // Title
                  Text(
                    AppStrings.chooseAccountType,
                    style: AppTextStyles.h2,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'How would you like to use ClearRent?',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Landlord option
                  _AccountTypeCard(
                    icon: Icons.apartment_rounded,
                    title: AppStrings.landlord,
                    description: AppStrings.landlordDesc,
                    isSelected: _selectedType == 'landlord',
                    onTap: () => _selectType('landlord'),
                  ),

                  const SizedBox(height: 16),

                  // Tenant option
                  _AccountTypeCard(
                    icon: Icons.person_search_rounded,
                    title: AppStrings.tenant,
                    description: AppStrings.tenantDesc,
                    isSelected: _selectedType == 'tenant',
                    onTap: () => _selectType('tenant'),
                  ),

                  const SizedBox(height: 16),

                  // Agent option
                  _AccountTypeCard(
                    icon: Icons.support_agent_rounded,
                    title: 'Agent',
                    description: 'Help landlords manage property inspections',
                    isSelected: _selectedType == 'agent',
                    onTap: () => _selectType('agent'),
                  ),

                  const Spacer(),

                  const SizedBox(height: 32),

                  // Continue button
                  AppButton(
                    text: AppStrings.continueText,
                    onPressed: _selectedType != null ? _continue : null,
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountTypeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  const _AccountTypeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withAlpha(13) : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            // Icon
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withAlpha(26)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 28,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),

            const SizedBox(width: 16),

            // Text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.h4.copyWith(
                      color: isSelected ? AppColors.primary : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),

            // Checkmark
            if (isSelected)
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  size: 16,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }
}