import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A reusable widget that displays a label and value with an optional copy button.
/// Used for displaying account numbers, amounts, and other copyable information.
class CopyableField extends StatelessWidget {
  final String label;
  final String value;
  final bool canCopy;
  final String? copySuccessMessage;
  final IconData? prefixIcon;
  final Color? valueColor;
  final bool isLargeValue;

  const CopyableField({
    super.key,
    required this.label,
    required this.value,
    this.canCopy = true,
    this.copySuccessMessage,
    this.prefixIcon,
    this.valueColor,
    this.isLargeValue = false,
  });

  void _copyToClipboard(BuildContext context) {
    // Remove currency symbol and commas for amount copying
    String valueToCopy = value;
    if (value.startsWith('₦')) {
      valueToCopy = value.replaceAll('₦', '').replaceAll(',', '').trim();
    }
    
    Clipboard.setData(ClipboardData(text: valueToCopy));
    
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(copySuccessMessage ?? '$label copied!'),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              if (prefixIcon != null) ...[
                Icon(prefixIcon, size: 20, color: AppColors.textSecondary),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  value,
                  style: isLargeValue
                      ? AppTextStyles.h4.copyWith(
                          color: valueColor ?? AppColors.textPrimary,
                          fontFamily: value.contains('₦') ? 'Roboto' : null,
                        )
                      : AppTextStyles.labelLarge.copyWith(
                          color: valueColor ?? AppColors.textPrimary,
                          letterSpacing: label.toLowerCase().contains('account') ? 1.5 : 0,
                          fontFamily: value.contains('₦') ? 'Roboto' : null,
                        ),
                ),
              ),
              if (canCopy) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _copyToClipboard(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(26),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.copy_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A styled container for displaying bank account details with copy functionality.
/// Groups account number, name, and bank together in a cohesive card.
class BankAccountCard extends StatelessWidget {
  final String accountNumber;
  final String accountName;
  final String bankName;
  final double? amount;
  final String? amountLabel;

  const BankAccountCard({
    super.key,
    required this.accountNumber,
    required this.accountName,
    required this.bankName,
    this.amount,
    this.amountLabel,
  });

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return '₦${result.reversed.join('')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.account_balance,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Transfer to this account',
                  style: AppTextStyles.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 20),
          
          // Account Number (copyable)
          CopyableField(
            label: 'Account Number',
            value: accountNumber,
            canCopy: true,
            copySuccessMessage: 'Account number copied!',
          ),
          
          const SizedBox(height: 14),
          
          // Account Name (not copyable - just for confirmation)
          CopyableField(
            label: 'Account Name',
            value: accountName,
            canCopy: false,
          ),
          
          const SizedBox(height: 14),
          
          // Bank Name (not copyable)
          CopyableField(
            label: 'Bank',
            value: bankName,
            canCopy: false,
            prefixIcon: Icons.business,
          ),
          
          // Amount (if provided)
          if (amount != null) ...[
            const SizedBox(height: 14),
            CopyableField(
              label: amountLabel ?? 'Amount to Pay',
              value: _formatAmount(amount!),
              canCopy: true,
              copySuccessMessage: 'Amount copied!',
              valueColor: AppColors.primary,
              isLargeValue: true,
            ),
          ],
        ],
      ),
    );
  }
}