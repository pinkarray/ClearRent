import 'package:flutter/material.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/tenant_rental.dart';
import 'resolve_default_rental.dart';

/// Tenant multi-rental switcher. Holds the list of [TenantRental]s the tenant
/// currently occupies (active + linked, already lifecycle-filtered upstream)
/// and shows ONE at a time. The selection control adapts to count:
///   1   → no control (single rental, rendered directly)
///   2   → segmented icon toggle
///   3+  → dropdown
///
/// Rendering each rental is delegated back to the host screen via builder
/// callbacks ([activeBuilder] / [linkedBuilder]) so the dashboard bodies stay
/// where they already live. A rental in the grace_locked lifecycle renders a
/// greyed shell with a renew CTA ([onRenew]) regardless of origin.
class MultiRentalDashboard extends StatefulWidget {
  final List<TenantRental> rentals;

  /// Renders an active-origin rental's dashboard. Supplied by the host so
  /// `pendingLinks` and other screen state stay in the closure's scope.
  final Widget Function(TenantRental) activeBuilder;

  /// Renders a linked-origin rental's dashboard.
  final Widget Function(TenantRental) linkedBuilder;

  /// Invoked when the tenant taps renew on a grace_locked rental.
  /// (System D wires this to the renewal/promotion payment flow.)
  final void Function(TenantRental) onRenew;

  const MultiRentalDashboard({
    super.key,
    required this.rentals,
    required this.activeBuilder,
    required this.linkedBuilder,
    required this.onRenew,
  });

  @override
  State<MultiRentalDashboard> createState() => _MultiRentalDashboardState();
}

class _MultiRentalDashboardState extends State<MultiRentalDashboard> {
  String? _selectedId;

  /// Resolve the selected rental for the current list. Falls back to the
  /// resolver default when nothing is selected yet or the previously selected
  /// rental has left the list (e.g. moved out, promoted).
  TenantRental? get _selected {
    if (widget.rentals.isEmpty) return null;
    if (_selectedId != null) {
      for (final r in widget.rentals) {
        if (r.sourceId == _selectedId) return r;
      }
    }
    return resolveDefault(widget.rentals);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    if (selected == null) {
      // Caller is responsible for the zero-rental case; defensive only.
      return const SizedBox.shrink();
    }

    final body = _buildBody(selected);

    // Single rental — no switcher control.
    if (widget.rentals.length == 1) {
      return body;
    }

    return Column(
      children: [
        _buildControl(selected),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildBody(TenantRental rental) {
    if (rental.lifecycle == RentalLifecycle.graceLocked) {
      return _buildGraceLockedShell(rental);
    }
    return rental.isLinked
        ? widget.linkedBuilder(rental)
        : widget.activeBuilder(rental);
  }

  // ── Selection control ─────────────────────────────────────────────────────

  Widget _buildControl(TenantRental selected) {
    final useDropdown = widget.rentals.length >= 3;
    return Container(
      width: double.infinity,
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: useDropdown
          ? _buildDropdown(selected)
          : _buildToggle(selected),
    );
  }

  Widget _buildToggle(TenantRental selected) {
    return Row(
      children: widget.rentals.map((r) {
        final isSel = r.sourceId == selected.sourceId;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _selectedId = r.sourceId),
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: isSel ? AppColors.primary.withAlpha(20) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSel ? AppColors.primary : AppColors.border,
                ),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(
                  r.isLinked ? Icons.link : Icons.home_outlined,
                  size: 16,
                  color: isSel ? AppColors.primary : AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    r.rental.propertyTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isSel ? AppColors.primary : AppColors.textSecondary,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDropdown(TenantRental selected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButton<String>(
        value: selected.sourceId,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.keyboard_arrow_down),
        style: AppTextStyles.bodyMedium,
        items: widget.rentals.map((r) {
          return DropdownMenuItem<String>(
            value: r.sourceId,
            child: Row(children: [
              Icon(
                r.isLinked ? Icons.link : Icons.home_outlined,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  r.rental.propertyTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          );
        }).toList(),
        onChanged: (id) {
          if (id != null) setState(() => _selectedId = id);
        },
      ),
    );
  }

  // ── Grace-locked greyed shell ──────────────────────────────────────────────

  Widget _buildGraceLockedShell(TenantRental rental) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.textHint.withAlpha(20),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.lock_clock_outlined, color: AppColors.warning, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Renewal Due', style: AppTextStyles.labelLarge),
                Text(
                  rental.rental.propertyTitle,
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ])),
            ]),
            const SizedBox(height: 16),
            Text(
              'Your lease term has ended. Renew to keep your tenancy active and '
              'restore full access to this rental.',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => widget.onRenew(rental),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Renew Tenancy', style: AppTextStyles.labelLarge.copyWith(color: Colors.white)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}