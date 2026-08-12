import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter, TextEditingValue, TextSelection;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/colors.dart';
import '../../../../shared/utils/document_file_picker.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/rent_review_request_model.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/rent_review_service.dart';
import '../../../../services/property_service.dart';

/// Landlord-initiated rent change filing (Block D).
///
/// Branches on occupancy (RentReviewService.propertyHasSittingTenant):
///   - OCCUPIED  → 'scheduled' review. Landlord picks the sitting tenancy,
///     proposes a new rent with ≥6-month notice before lease end, and the
///     change applies at the tenant's renewal once an admin approves.
///   - VACANT    → 'immediate' change. No tenant, no effective date; applies
///     to the property's rent as soon as an admin approves.
///
/// Launched per-property via constructor injection (mirrors ReportIssueScreen).
class RequestRentChangeScreen extends StatefulWidget {
  final String propertyId;
  final String propertyTitle;
  final double currentRent;
  final String landlordId;
  final String landlordName;

  const RequestRentChangeScreen({
    super.key,
    required this.propertyId,
    required this.propertyTitle,
    required this.currentRent,
    required this.landlordId,
    required this.landlordName,
  });

  @override
  State<RequestRentChangeScreen> createState() =>
      _RequestRentChangeScreenState();
}

class _RequestRentChangeScreenState extends State<RequestRentChangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _rentController = TextEditingController();
  final _justificationController = TextEditingController();
  final RentReviewService _service = RentReviewService();
  final PropertyService _propertyService = PropertyService();

  // Cached once — the justification field's onChanged: setState() rebuilds this
  // screen on every keystroke, which would otherwise recreate the tenancy
  // stream and flash the picker.
  late final Stream<List<ActiveRental>> _rentalsStream =
      _service.streamLandlordRentalsForProperty(widget.propertyId);
  final _naira = NumberFormat.decimalPattern('en_NG');

  // Occupancy branch: null = still resolving, true = scheduled, false = immediate.
  bool? _hasSittingTenant;
  bool _isResolving = true;

  // Scheduled-only: the tenancy this review targets.
  ActiveRental? _selectedRental;

  // Scheduled-only: revised tenancy agreement, mandatory at filing. The new
  // rent takes effect at renewal, so the effective date is auto-staged to
  // filing time at submit — the landlord doesn't pick it.
  String? _agreementUrl;
  bool _isUploadingAgreement = false;

  String _reasonType = 'market'; // 'improvements' | 'market' | 'both'
  bool _isSubmitting = false;

  final _reasons = const [
    {
      'value': 'improvements',
      'label': 'Improvements',
      'icon': Icons.handyman_outlined,
      'desc': 'Renovations or upgrades to the property',
    },
    {
      'value': 'market',
      'label': 'Market rate',
      'icon': Icons.trending_up,
      'desc': 'Aligning with current market prices',
    },
    {
      'value': 'both',
      'label': 'Both',
      'icon': Icons.layers_outlined,
      'desc': 'Improvements and market adjustment',
    },
  ];

  @override
  void initState() {
    super.initState();
    _resolveOccupancy();
  }

  @override
  void dispose() {
    _rentController.dispose();
    _justificationController.dispose();
    super.dispose();
  }

  Future<void> _resolveOccupancy() async {
    try {
      final occupied = await _service.propertyHasSittingTenant(widget.propertyId);
      if (!mounted) return;
      setState(() {
        _hasSittingTenant = occupied;
        _isResolving = false;
      });
    } catch (e) {
      AppLogger.e('Failed to resolve occupancy', error: e, name: 'RentChange');
      if (!mounted) return;
      setState(() {
        // Fail safe to the more conservative immediate path is wrong here —
        // surface the error and let the landlord retry instead.
        _isResolving = false;
        _hasSittingTenant = null;
      });
    }
  }

  /// A scheduled review needs ≥6 months between now and the lease end so the
  /// tenant gets proper notice before renewal. Mirrors the CF's auto-reject,
  /// caught client-side first.
  bool _noticeWindowOk(DateTime leaseEnd) {
    final now = DateTime.now();
    final sixMonthsOut = DateTime(now.year, now.month + 6, now.day);
    return !leaseEnd.isBefore(sixMonthsOut);
  }

  /// The numeric rent entered, with thousands separators stripped. Null when
  /// the field is empty or not a valid number.
  double? get _enteredRent {
    final raw = _rentController.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  bool get _isRaise {
    final v = _enteredRent;
    return v != null && v > widget.currentRent;
  }

  /// Submit is enabled only when every required field is complete, so an
  /// incomplete request can't be fired off.
  bool get _canSubmit {
    final rent = _enteredRent;
    final rentOk = rent != null && rent > 0 && rent != widget.currentRent;
    final justificationOk = _justificationController.text.trim().isNotEmpty;
    if (_hasSittingTenant == true) {
      // Scheduled also needs a target tenancy inside the notice window and the
      // mandatory revised agreement attached.
      final rental = _selectedRental;
      return rentOk &&
          justificationOk &&
          rental != null &&
          _noticeWindowOk(rental.leaseEndDate) &&
          _agreementUrl != null;
    }
    return rentOk && justificationOk;
  }

  Future<void> _pickAgreement() async {
    // A revised agreement is a full document, not a single page — pickImage
    // could only ever capture one.
    final file = await DocumentFilePicker.pick(
      context,
      hint: 'A multi-page agreement should be a single PDF.',
    );
    if (file == null || !mounted) return;

    setState(() => _isUploadingAgreement = true);
    try {
      // Private Storage (not Cloudinary) — agreements are sensitive PII.
      final url = await _propertyService.uploadAgreementDoc(file);
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        setState(() => _isUploadingAgreement = false);
        _toast('Failed to upload the agreement. Please try again.',
            isError: true);
        return;
      }
      setState(() {
        _agreementUrl = url;
        _isUploadingAgreement = false;
      });
    } catch (e) {
      AppLogger.e('Agreement upload failed', error: e, name: 'RentChange');
      if (!mounted) return;
      setState(() => _isUploadingAgreement = false);
      _toast('Failed to upload the agreement. Please try again.',
          isError: true);
    }
  }

  String? _validateRent(String? raw) {
    final text = (raw ?? '').replaceAll(',', '').trim();
    if (text.isEmpty) return 'Enter the new rent';
    final value = double.tryParse(text);
    if (value == null || value <= 0) return 'Enter a valid amount';
    if (value == widget.currentRent) {
      return 'New rent matches the current rent';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final scheduled = _hasSittingTenant == true;
    final newRent = _enteredRent!;
    final rental = _selectedRental;

    // Scheduled path needs a target tenancy inside the notice window and the
    // mandatory revised agreement.
    if (scheduled) {
      if (rental == null) {
        _toast('Select the tenancy this review applies to', isError: true);
        return;
      }
      if (!_noticeWindowOk(rental.leaseEndDate)) {
        _toast(
          'This lease ends too soon for a scheduled review - it needs at least '
          '6 months\' notice before renewal.',
          isError: true,
        );
        return;
      }
      if (_agreementUrl == null) {
        _toast('Attach the revised tenancy agreement first', isError: true);
        return;
      }
    }

    setState(() => _isSubmitting = true);

    final request = RentReviewRequest(
      id: '',
      landlordId: widget.landlordId,
      tenantId: scheduled ? (rental?.tenantId ?? '') : '',
      rentalId: scheduled ? (rental?.id ?? '') : '',
      propertyId: widget.propertyId,
      propertyTitle: widget.propertyTitle,
      currentRent: widget.currentRent,
      proposedRent: newRent,
      // Auto-staged to filing time. The increase applies at the tenant's next
      // renewal (completeActiveRenewal); a filing-time date guarantees it has
      // passed by renewal, so the increase is never silently skipped and rent
      // never changes mid-lease.
      effectiveDate: scheduled ? DateTime.now() : null,
      reasonType: _reasonType,
      justification: _justificationController.text.trim(),
      revisedAgreementUrl: scheduled ? (_agreementUrl ?? '') : '',
      changeType: scheduled ? 'scheduled' : 'immediate',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final id = await _service.createRentReviewRequest(request);

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (id == null) {
      _toast('Could not submit your request. Please try again.', isError: true);
      return;
    }

    _toast(
      scheduled
          ? 'Rent review submitted. It takes effect at renewal once approved.'
          : 'Rent change submitted. It applies as soon as admin approves.',
    );
    context.pop();
  }

  void _toast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? AppColors.error : AppColors.success,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

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
        title: Text('Request Rent Change', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isResolving
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _hasSittingTenant == null
              ? _buildErrorState()
              : _buildForm(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text(
              'Could not check this property\'s occupancy.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            AppButton(
              text: 'Try Again',
              isFullWidth: false,
              width: 160,
              height: 48,
              onPressed: () {
                setState(() {
                  _isResolving = true;
                  _hasSittingTenant = null;
                });
                _resolveOccupancy();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    final scheduled = _hasSittingTenant == true;
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Property context
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(13),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Icon(Icons.home_outlined, size: 20, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.propertyTitle,
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),

            const SizedBox(height: 16),

            // Mode banner — clear visual distinction between the two paths.
            _buildModeBanner(scheduled),

            const SizedBox(height: 24),

            // Scheduled-only: pick the tenancy this review targets.
            if (scheduled) ...[
              Text('Tenancy', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              _buildTenancyPicker(),
              const SizedBox(height: 24),
            ],

            // Current rent (read-only reference)
            Text('Current rent', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                '₦${_naira.format(widget.currentRent)}',
                style: AppTextStyles.naira(AppTextStyles.bodyLarge),
              ),
            ),

            const SizedBox(height: 24),

            // New rent
            Text('New rent', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            TextFormField(
              controller: _rentController,
              keyboardType: TextInputType.number,
              inputFormatters: [_ThousandsSeparatorInputFormatter()],
              style: AppTextStyles.naira(AppTextStyles.bodyLarge),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixText: '₦ ',
                prefixStyle: AppTextStyles.naira(AppTextStyles.bodyLarge),
                hintText: 'Enter the proposed rent',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
              validator: _validateRent,
            ),
            if (_enteredRent != null && _enteredRent != widget.currentRent) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _isRaise ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                    color: _isRaise ? AppColors.warning : AppColors.success,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isRaise ? 'This is a rent increase' : 'This is a rent reduction',
                    style: AppTextStyles.caption.copyWith(
                      color: _isRaise ? AppColors.warning : AppColors.success,
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 24),

            // Reason type
            Text('Reason', style: AppTextStyles.labelLarge),
            const SizedBox(height: 12),
            ..._reasons.map(_buildReasonTile),

            const SizedBox(height: 24),

            // When it takes effect (scheduled only) — auto-staged to renewal,
            // not picked. Plus the mandatory revised agreement.
            if (scheduled) ...[
              _buildRenewalInfo(),
              const SizedBox(height: 24),
              Text('Revised tenancy agreement', style: AppTextStyles.labelLarge),
              const SizedBox(height: 4),
              Text(
                'Required. The tenant reviews this when the increase is approved.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              _buildAgreementField(),
              const SizedBox(height: 24),
            ],

            // Justification
            Text('Justification', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            TextFormField(
              controller: _justificationController,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              style: AppTextStyles.bodyLarge,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText:
                    'Explain why the rent is changing. This is shown to the admin reviewer.',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Please add a justification'
                  : null,
            ),

            const SizedBox(height: 32),

            AppButton(
              text: 'Submit Request',
              isLoading: _isSubmitting,
              onPressed: (_canSubmit && !_isSubmitting) ? _submit : null,
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildModeBanner(bool scheduled) {
    final color = scheduled ? AppColors.info : AppColors.secondary;
    final icon = scheduled ? Icons.event_outlined : Icons.bolt_outlined;
    final title = scheduled ? 'Scheduled review' : 'Immediate change';
    final subtitle = scheduled
        ? 'This property is occupied. The new rent takes effect at the tenant\'s renewal, once an admin approves.'
        : 'This property has no sitting tenant. The new rent applies as soon as an admin approves.';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withAlpha(38),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: AppTextStyles.labelMedium.copyWith(color: color)),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTenancyPicker() {
    return StreamBuilder<List<ActiveRental>>(
      stream: _rentalsStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return _pickerShell(
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Text('Loading tenancies…',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: AppColors.textSecondary)),
              ],
            ),
          );
        }

        final rentals = snapshot.data ?? const <ActiveRental>[];

        if (rentals.isEmpty) {
          return _pickerShell(
            child: Text(
              'No occupying tenancy found for this property.',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
            ),
          );
        }

        // Auto-select when there's exactly one tenancy.
        if (rentals.length == 1 && _selectedRental?.id != rentals.first.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedRental = rentals.first);
          });
        }

        return Column(
          children: rentals.map((r) {
            final selected = _selectedRental?.id == r.id;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => setState(() => _selectedRental = r),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primary.withAlpha(13)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? AppColors.primary : AppColors.border,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color:
                            selected ? AppColors.primary : AppColors.textHint,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.tenantName.isNotEmpty ? r.tenantName : 'Tenant',
                              style: AppTextStyles.labelMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Lease ends ${DateFormat('d MMM yyyy').format(r.leaseEndDate)}',
                              style: AppTextStyles.caption
                                  .copyWith(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _pickerShell({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _buildReasonTile(Map<String, dynamic> reason) {
    final selected = _reasonType == reason['value'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => setState(() => _reasonType = reason['value'] as String),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:
                selected ? AppColors.primary.withAlpha(13) : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                reason['icon'] as IconData,
                size: 22,
                color: selected ? AppColors.primary : AppColors.textHint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reason['label'] as String,
                      style: AppTextStyles.labelMedium.copyWith(
                        color:
                            selected ? AppColors.primary : AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      reason['desc'] as String,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tells the landlord when the increase actually takes effect (the tenant's
  /// renewal = lease end), instead of asking them to pick a date. Surfaces the
  /// notice-window block inline when the lease ends in under 6 months.
  Widget _buildRenewalInfo() {
    final rental = _selectedRental;
    if (rental == null) {
      return _infoCard(
        icon: Icons.event_outlined,
        color: AppColors.textSecondary,
        child: Text(
          'Select a tenancy above to see when the new rent takes effect.',
          style: AppTextStyles.bodyMedium
              .copyWith(color: AppColors.textSecondary),
        ),
      );
    }

    final renewal = DateFormat('d MMM yyyy').format(rental.leaseEndDate);
    if (!_noticeWindowOk(rental.leaseEndDate)) {
      return _infoCard(
        icon: Icons.warning_amber_rounded,
        color: AppColors.error,
        child: Text(
          'This lease ends $renewal - too soon for a scheduled review. A rent '
          'increase needs at least 6 months\' notice before renewal.',
          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.error),
        ),
      );
    }

    return _infoCard(
      icon: Icons.event_available_outlined,
      color: AppColors.info,
      child: RichText(
        text: TextSpan(
          style: AppTextStyles.bodyMedium
              .copyWith(color: AppColors.textSecondary),
          children: [
            const TextSpan(text: 'Takes effect at the tenant\'s renewal on '),
            TextSpan(
              text: renewal,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const TextSpan(text: '. The current rent is unchanged until then.'),
          ],
        ),
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required Color color,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildAgreementField() {
    final attached = _agreementUrl != null;
    return InkWell(
      onTap: _isUploadingAgreement ? null : _pickAgreement,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: attached ? AppColors.success : AppColors.border,
            width: attached ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            if (_isUploadingAgreement)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              )
            else
              Icon(
                attached
                    ? Icons.check_circle_outline
                    : Icons.upload_file_outlined,
                size: 20,
                color: attached ? AppColors.success : AppColors.textSecondary,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _isUploadingAgreement
                    ? 'Uploading…'
                    : attached
                        ? 'Agreement attached - tap to replace'
                        : 'Attach revised agreement',
                style: AppTextStyles.bodyLarge.copyWith(
                  color:
                      attached ? AppColors.textPrimary : AppColors.textHint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live thousands-separator formatter for the rent field (e.g. 70000 → 70,000),
/// so the landlord can read tens- vs hundreds-of-thousands at a glance.
/// Integer-only — naira rents are whole numbers, which keeps grouping and the
/// downstream comma-stripping parse simple.
class _ThousandsSeparatorInputFormatter extends TextInputFormatter {
  static final NumberFormat _fmt = NumberFormat.decimalPattern('en_US');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return const TextEditingValue();
    // Guard against absurd input overflowing int parsing.
    if (digits.length > 12) return oldValue;
    final formatted = _fmt.format(int.parse(digits));
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
