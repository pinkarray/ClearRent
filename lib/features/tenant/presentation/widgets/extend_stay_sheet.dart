import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/paystack_service.dart';
import '../../../../services/pricing_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/screens/paystack_checkout_screen.dart';
import '../../../../shared/utils/sheet_insets.dart';

/// Extends a furnished stay: pick how many more months (up to the listing's
/// longest stay), pay rent only, and the server moves the end date. The server
/// prices it itself from the rental; the total here is what it will charge.
Future<void> showExtendStaySheet(
  BuildContext context,
  ActiveRental rental,
  int maxStay,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ExtendStaySheet(rental: rental, maxStay: maxStay),
  );
}

class _ExtendStaySheet extends StatefulWidget {
  final ActiveRental rental;
  final int maxStay;
  const _ExtendStaySheet({required this.rental, required this.maxStay});

  @override
  State<_ExtendStaySheet> createState() => _ExtendStaySheetState();
}

class _ExtendStaySheetState extends State<_ExtendStaySheet> {
  int _months = 1;
  bool _busy = false;
  String? _error;

  int get _room => (widget.maxStay - widget.rental.stayMonths).clamp(0, 11);
  double get _rent => widget.rental.monthlyRent * _months;
  double get _fee => PricingService().current.extensionFee;
  double get _total => _rent + _fee;

  Future<void> _pay() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = widget.rental;
    final result = await PaystackCheckoutScreen.launch(
      context: context,
      amount: _total,
      type: PaystackService.typeExtension,
      metadata: {
        'sourceId': r.id,
        'months': _months,
        'propertyTitle': r.propertyTitle,
        'description': 'Stay extension for ${r.propertyTitle}',
      },
    );
    if (!mounted) return;
    if (result == null || !result.success) {
      setState(() {
        _busy = false;
        if (result != null) _error = 'Payment was not completed. Try again.';
      });
      return;
    }
    final err = await ActiveRentalService()
        .completeStayExtension(r.id, result.reference, _months);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Stay extended by $_months '
            'month${_months == 1 ? '' : 's'}.'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } else {
      // Paid but not recorded: the reference is what support needs.
      setState(() {
        _busy = false;
        _error = '$err Your payment reference is ${result.reference}; '
            'contact support with it if this does not clear.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rental;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + sheetBottomInset(context)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Extend your stay', style: AppTextStyles.h4),
          const SizedBox(height: 4),
          Text(
            _room == 0
                ? 'This stay is already as long as the landlord allows.'
                : 'You pay the rent for the extra months, which all goes to '
                    'the landlord, plus a small processing fee. The landlord '
                    'allows up to ${widget.maxStay} months in all; you have '
                    '${r.stayMonths}.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          if (_room > 0) ...[
            const SizedBox(height: 16),
            Row(children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: !_busy && _months > 1
                    ? () => setState(() => _months--)
                    : null,
              ),
              Text('$_months', style: AppTextStyles.h4),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: !_busy && _months < _room
                    ? () => setState(() => _months++)
                    : null,
              ),
              const SizedBox(width: 8),
              Text('more month${_months == 1 ? '' : 's'}',
                  style: AppTextStyles.bodyMedium),
            ]),
            const SizedBox(height: 8),
            Text(
              'Total: ${InspectionPricing.formatNaira(_total)} '
              '(${InspectionPricing.formatNaira(r.monthlyRent)} x $_months '
              '+ ${InspectionPricing.formatNaira(_fee)} processing)',
              style: AppTextStyles.labelMedium,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _pay,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  _busy ? 'Working…' : 'Pay and extend',
                  style:
                      AppTextStyles.labelLarge.copyWith(color: Colors.white),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
