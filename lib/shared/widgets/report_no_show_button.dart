import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/inspection_service.dart';
import '../models/inspection_request_model.dart';

/// Lets the handler say the tenant never came, once they have arrived and it
/// is an hour past the start of the slot.
///
/// The only button a waiting handler had was Cancel, which refunds the tenant
/// and forfeits the handler's fee. This sends the viewing to admin review
/// instead, which is where the nightly sweep would have put it the next day.
/// It pays nobody by itself: the admin confirms and the handler is paid then.
class ReportNoShowButton extends StatefulWidget {
  final InspectionRequest request;
  final InspectionService inspectionService;

  const ReportNoShowButton({
    super.key,
    required this.request,
    required this.inspectionService,
  });

  @override
  State<ReportNoShowButton> createState() => _ReportNoShowButtonState();
}

class _ReportNoShowButtonState extends State<ReportNoShowButton> {
  bool _busy = false;

  Future<void> _report() async {
    final r = widget.request;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tenant didn\'t show up'),
        content: Text(
          'Report that ${r.tenantName} didn\'t come to ${r.propertyTitle}? '
          'Our team will confirm it, and you are paid once they do. '
          '${r.tenantName} is told and can dispute it.',
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Keep waiting',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Report'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    final error = await widget.inspectionService.reportTenantNoShow(r.id);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Reported. Our team will confirm it.'),
        backgroundColor: error == null ? AppColors.success : AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _report,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.person_off_outlined,
                size: 18, color: AppColors.warning),
        label: Text(
          'Tenant didn\'t show up',
          style: AppTextStyles.labelMedium.copyWith(color: AppColors.warning),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: AppColors.warning),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          minimumSize: const Size(double.infinity, 0),
        ),
      ),
    );
  }
}
