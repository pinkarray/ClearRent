import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../services/caretaker_service.dart';
import '../models/property_model.dart';

/// The caretaker's way in, shown on the home screen of whichever shell they
/// happen to be in — and shown to nobody else.
///
/// Three states, in order:
///  1. A pending invitation → an action prompt. Someone is waiting on an answer.
///  2. Properties they already manage → a quiet entry to that work.
///  3. Neither → nothing at all.
///
/// State 3 is the point: this is invisible to every user who is not a
/// caretaker, and it disappears again the moment they are removed, because both
/// streams are driven by live Firestore state rather than a stored flag.
///
/// It lives in all three home screens because a caretaker can be a tenant, a
/// landlord or an agent — accountType decides their shell, not this role.
/// The earlier version rendered only state 1, so the entry point evaporated as
/// soon as an invitation was accepted and the work became unreachable.
class CaretakerBanner extends StatefulWidget {
  const CaretakerBanner({super.key});

  @override
  State<CaretakerBanner> createState() => _CaretakerBannerState();
}

class _CaretakerBannerState extends State<CaretakerBanner> {
  final CaretakerService _service = CaretakerService();

  // Built once. A stream created in build() re-subscribes on every rebuild and
  // tears its own subtree down mid-flight — that is what crashed the caretaker
  // screen with '_dependents.isEmpty'.
  late final Stream<List<CaretakerInvite>> _invites = _service.myInvites();
  late final Stream<List<PropertyModel>> _managed = _service.managedProperties();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CaretakerInvite>>(
      stream: _invites,
      builder: (context, inviteSnap) {
        final pending =
            (inviteSnap.data ?? const <CaretakerInvite>[]).where((i) => i.isPending);

        if (pending.isNotEmpty) {
          final invite = pending.first;
          final count = invite.propertyIds.length;
          return _shell(
            icon: Icons.handyman_outlined,
            title: 'Caretaker invitation',
            subtitle: '${invite.landlordName} wants you to manage '
                '${count == 1 ? (invite.propertyTitles.isNotEmpty ? invite.propertyTitles.first : 'their property') : '$count units'}. '
                'Tap to accept or decline.',
            emphasised: true,
          );
        }

        return StreamBuilder<List<PropertyModel>>(
          stream: _managed,
          builder: (context, propSnap) {
            final managed = propSnap.data ?? const <PropertyModel>[];
            if (managed.isEmpty) return const SizedBox.shrink();
            return _shell(
              icon: Icons.handyman_outlined,
              title: 'Properties you manage',
              subtitle: managed.length == 1
                  ? managed.first.title
                  : '${managed.length} properties',
              emphasised: false,
            );
          },
        );
      },
    );
  }

  Widget _shell({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool emphasised,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: GestureDetector(
        onTap: () => context.push('/caretaker/properties'),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: emphasised
                ? AppColors.primary.withAlpha(20)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: emphasised
                  ? AppColors.primary.withAlpha(60)
                  : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.labelMedium.copyWith(
                        color: emphasised
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}
