
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../shared/utils/agreement_file_picker.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/property_model.dart';

/// One property in the landlord's "My properties" agreements tab: whatever
/// agreement is on file for it, and the controls to put one there.
///
/// The point of this card is that it needs NO tenant. An agreement attached
/// here is copied onto the tenancy automatically the moment someone is
/// accepted, so acceptance stops being blocked on finding and uploading a
/// document.
class PropertyAgreementCard extends StatefulWidget {
  final PropertyModel property;
  final PropertyAgreement? agreement;
  final VoidCallback onUpdated;

  const PropertyAgreementCard({
    super.key,
    required this.property,
    required this.agreement,
    required this.onUpdated,
  });

  @override
  State<PropertyAgreementCard> createState() => _PropertyAgreementCardState();
}

class _PropertyAgreementCardState extends State<PropertyAgreementCard> {
  final PropertyService _propertyService = PropertyService();
  bool _busy = false;

  bool get _hasAgreement => widget.agreement != null;

  /// The rent moved on after this document was written, so it quotes a price
  /// the property no longer asks. Acceptance refuses to attach it.
  bool get _isStale =>
      widget.agreement?.isStaleFor(widget.property.rent) ?? false;

  Future<void> _pickAndUpload() async {
    // Replacing is not obviously safe from the outside, so say what it does
    // before the file picker opens rather than after the write.
    if (_hasAgreement) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Replace this agreement?'),
          // Talks about the NEXT tenant, singular. "Future tenants" read as
          // though the unit could hold several tenancies at once.
          content: const Text(
            'This is the blank copy kept for whoever rents next. Replacing it '
            'changes nothing for a tenant who has already signed — their '
            'agreement stays exactly as it is.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              // foregroundColor is not optional: without it the label takes the
              // theme's default and disappears into the fill.
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Choose file'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }

    if (!mounted) return;
    final file = await AgreementFilePicker.pick(context);
    if (file == null || !mounted) return;

    setState(() => _busy = true);
    final path = await _propertyService.uploadAgreementDoc(file);
    if (path == null || path.isEmpty) {
      if (mounted) {
        setState(() => _busy = false);
        _toast('Could not upload that document. Please try again.',
            isError: true);
      }
      return;
    }

    // Stamped with the rent it was written for, so a later rent review is
    // detectable rather than silently binding a new tenant to the old price.
    final ok = await _propertyService.savePropertyAgreement(
      propertyId: widget.property.id,
      storagePath: path,
      rentAtUpload: widget.property.rent,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _toast('Agreement saved for ${widget.property.title}');
      widget.onUpdated();
    } else {
      _toast('Could not save that agreement. Please try again.', isError: true);
    }
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove agreement?'),
        content: const Text(
          'New tenants will no longer get this automatically. Tenancies that '
          'already have it keep their copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final ok =
        await _propertyService.deletePropertyAgreement(widget.property.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      widget.onUpdated();
    } else {
      _toast('Could not remove that agreement.', isError: true);
    }
  }

  void _toast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : null,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.property;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: p.images.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: p.images.first,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _thumbFallback(),
                      )
                    : _thumbFallback(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.title,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${p.formattedRent}/'
                      '${p.rentFrequency == 'yearly' ? 'yr' : 'mo'}',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildStatusStrip(),
          const SizedBox(height: 12),
          if (_busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickAndUpload,
                    icon: Icon(
                      _hasAgreement ? Icons.swap_horiz : Icons.upload_file,
                      size: 16,
                    ),
                    label: Text(
                        _hasAgreement ? 'Replace' : 'Upload signed agreement'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: BorderSide(color: AppColors.primary),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                if (_hasAgreement) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _remove,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) => DateFormat('d MMM y').format(d);

  Widget _thumbFallback() => Container(
        width: 52,
        height: 52,
        color: AppColors.background,
        child: Icon(Icons.home, color: AppColors.textHint),
      );

  Widget _buildStatusStrip() {
    final IconData icon;
    final Color color;
    final String text;

    if (!_hasAgreement) {
      icon = Icons.info_outline;
      color = AppColors.textSecondary;
      // Deliberately says "reusable", and names the current tenancy when there
      // is one. A landlord whose sitting tenant already signed an agreement
      // reads a bare "no agreement on file" as data loss — this is about the
      // blank copy kept for FUTURE tenants, which is a different document.
      // Says "signed" up front: the landlord signs once here, and the tenant
      // returns that same page signed. Skip it and the executed agreement
      // carries only the tenant's hand.
      text = (widget.property.currentTenantsCount ?? 0) > 0
          ? 'No signed copy saved for future tenants. Your current tenancy '
              'agreement is unaffected — see the Tenancies tab.'
          : 'Sign your agreement, then upload it here. Every tenant you accept '
              'gets that signed copy to print, sign and send back.';
    } else if (_isStale) {
      icon = Icons.warning_amber_outlined;
      color = AppColors.warning;
      text = 'Rent has changed since this was uploaded, so it will NOT be sent '
          'automatically. Replace it with one showing the new rent.';
    } else {
      icon = Icons.check_circle_outline;
      color = AppColors.success;
      // Says what Replace does, because the answer is not obvious and the
      // wrong guess ("it will change my tenant's signed lease") would stop a
      // landlord keeping the copy current.
      final on = widget.agreement?.uploadedAt;
      text = 'Saved${on == null ? '' : ' ${_formatDate(on)}'} — the next tenant '
          'you accept gets this to sign and return. Replacing only affects '
          'future tenants; anyone who already signed keeps their copy.';
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.caption.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
