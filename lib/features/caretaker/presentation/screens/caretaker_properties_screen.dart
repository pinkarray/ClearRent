import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/caretaker_service.dart';
import '../../../../shared/models/property_model.dart';
import '../../../landlord/presentation/screens/property_health_screen.dart';

/// Everything a caretaker has: invitations awaiting an answer, and the
/// properties they already manage.
///
/// Deliberately NOT a fourth shell. A caretaker is an existing tenant, landlord
/// or agent — accountType still routes them to their own home at splash — so a
/// caretaker-only shell would strand whoever wasn't a landlord. This is one
/// screen reachable from Settings in every shell and from the invitation push.
class CaretakerPropertiesScreen extends StatefulWidget {
  const CaretakerPropertiesScreen({super.key});

  @override
  State<CaretakerPropertiesScreen> createState() =>
      _CaretakerPropertiesScreenState();
}

class _CaretakerPropertiesScreenState extends State<CaretakerPropertiesScreen> {
  final CaretakerService _service = CaretakerService();
  String? _busyInviteId;

  // Built ONCE. Calling _service.myInvites() inside build() returns a brand new
  // Firestore subscription on every rebuild, so each setState (Accept, Decline,
  // Step back) tore down the whole StreamBuilder subtree and stood up another —
  // which is what trips '_dependents.isEmpty': an inherited element being
  // unmounted while its dependents are still live. Same discipline the property
  // health screen already used; this screen simply didn't follow it.
  late final Stream<List<CaretakerInvite>> _invitesStream = _service.myInvites();
  late final Stream<List<PropertyModel>> _propertiesStream =
      _service.managedProperties();

  Future<void> _respond(CaretakerInvite invite, bool accept) async {
    // Resolved before the await: accepting makes both streams re-emit, which
    // rebuilds this subtree while the call is still in flight.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busyInviteId = invite.id);
    final error = await _service.respond(inviteId: invite.id, accept: accept);
    if (!mounted) return;
    setState(() => _busyInviteId = null);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error ??
              (accept
                  ? 'You now manage this property.'
                  : 'Invitation declined.'),
        ),
        backgroundColor: error != null ? AppColors.error : null,
      ),
    );
  }

  Future<void> _stepBack(CaretakerInvite invite) async {
    // Before BOTH awaits — the dialog is one gap and the revoke is another.
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Step back from this property?'),
        content: Text(
          'You will stop managing '
          '${invite.propertyTitles.isNotEmpty ? invite.propertyTitles.first : 'this property'}'
          '${invite.propertyIds.length > 1 ? ' and ${invite.propertyIds.length - 1} other unit(s)' : ''}. '
          '${invite.landlordName} will be told, and it goes back to them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Step back'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final error = await _service.revoke(inviteId: invite.id);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? 'You no longer manage that property.'),
        backgroundColor: error != null ? AppColors.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Properties you manage', style: AppTextStyles.h4),
        backgroundColor: AppColors.surface,
        elevation: 0,
      ),
      body: StreamBuilder<List<CaretakerInvite>>(
        stream: _invitesStream,
        builder: (context, inviteSnap) {
          final all = inviteSnap.data ?? const <CaretakerInvite>[];
          final invites = all.where((i) => i.isPending).toList();
          // propertyId → the accepted invite that granted it, so stepping back
          // from a unit revokes the right arrangement.
          final grantedBy = <String, CaretakerInvite>{
            for (final i in all.where((i) => i.isActive))
              for (final pid in i.propertyIds) pid: i,
          };
          return StreamBuilder<List<PropertyModel>>(
            stream: _propertiesStream,
            builder: (context, propSnap) {
              if (propSnap.connectionState == ConnectionState.waiting &&
                  !propSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final properties = propSnap.data ?? const <PropertyModel>[];

              if (invites.isEmpty && properties.isEmpty) {
                return _buildEmpty();
              }

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (invites.isNotEmpty) ...[
                    _sectionHeader('Invitations'),
                    const SizedBox(height: 8),
                    ...invites.map(_buildInviteCard),
                    const SizedBox(height: 24),
                  ],
                  if (properties.isNotEmpty) ...[
                    _sectionHeader('You manage'),
                    const SizedBox(height: 8),
                    ...properties
                        .map((p) => _buildPropertyCard(p, grantedBy[p.id])),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.handyman_outlined, size: 56, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text(
              'You don\'t manage any properties',
              style: AppTextStyles.h4,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'When a landlord invites you as caretaker, the invitation shows '
              'up here.',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) => Text(
        text.toUpperCase(),
        style: AppTextStyles.caption.copyWith(
          color: AppColors.textSecondary,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _buildInviteCard(CaretakerInvite invite) {
    final busy = _busyInviteId == invite.id;
    final count = invite.propertyIds.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${invite.landlordName} wants you to manage '
            '${count == 1 ? (invite.propertyTitles.isNotEmpty ? invite.propertyTitles.first : 'their property') : '$count units'}',
            style: AppTextStyles.bodyMedium.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (count > 1 && invite.propertyTitles.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              invite.propertyTitles.join(', '),
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'You would handle issues, maintenance and messages with the '
            'tenant. You cannot change the rent or anything to do with money.',
            style:
                AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => _respond(invite, false),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: busy ? null : () => _respond(invite, true),
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPropertyCard(PropertyModel property, CaretakerInvite? grant) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: AppColors.primary.withAlpha(26),
          child: Icon(Icons.home_work_outlined, color: AppColors.primary),
        ),
        title: Text(property.title, style: AppTextStyles.bodyMedium),
        subtitle: Text(
          '${property.lga}, ${property.city}',
          style:
              AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
        ),
        trailing: grant == null
            ? const Icon(Icons.chevron_right)
            : PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'step_back') _stepBack(grant);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'step_back',
                    child: Text('Step back from this property'),
                  ),
                ],
              ),
        // Property health IS the caretaker's workbench — issues and
        // maintenance for this unit, the same screen the owner sees, with the
        // queries switched to the field the caretaker's rule branch reads.
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PropertyHealthScreen(property: property),
          ),
        ),
      ),
    );
  }
}

/// Landlord-side view: who manages what, and the way to end it. Lives here
/// rather than in edit-property because one invite can span a whole building,
/// so it isn't a property-shaped thing.
class LandlordCaretakersScreen extends StatelessWidget {
  const LandlordCaretakersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = CaretakerService();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Caretakers', style: AppTextStyles.h4),
        backgroundColor: AppColors.surface,
        elevation: 0,
      ),
      body: StreamBuilder<List<CaretakerInvite>>(
        stream: service.invitesForLandlord(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final live = (snap.data ?? const <CaretakerInvite>[])
              .where((i) => i.isPending || i.isActive)
              .toList();
          if (live.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'You haven\'t appointed a caretaker yet. You can invite one '
                  'from any property\'s edit screen.',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: live.length,
            itemBuilder: (context, i) {
              final invite = live[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: ListTile(
                  title: Text(invite.caretakerName,
                      style: AppTextStyles.bodyMedium),
                  subtitle: Text(
                    invite.isPending
                        ? 'Invitation sent — waiting for their answer'
                        : '${invite.propertyIds.length} unit(s)'
                            '${invite.propertyTitles.isNotEmpty ? ' · ${invite.propertyTitles.join(', ')}' : ''}',
                    style: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textSecondary),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      // Resolve the messenger BEFORE the await. `context` here
                      // belongs to this list ITEM, and revoking makes the
                      // stream re-emit and rebuild the list — so by the time
                      // the call returns this element may be deactivated, and
                      // ScaffoldMessenger.of() on it is precisely the
                      // inherited-widget lookup that trips
                      // '_dependents.isEmpty'. mounted alone doesn't save you:
                      // the element can still be alive but no longer able to
                      // serve a dependency.
                      final messenger = ScaffoldMessenger.of(context);
                      final error =
                          await service.revoke(inviteId: invite.id);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(error ??
                              (invite.isPending
                                  ? 'Invitation withdrawn.'
                                  : 'Caretaker removed.')),
                          backgroundColor:
                              error != null ? AppColors.error : null,
                        ),
                      );
                    },
                    style:
                        TextButton.styleFrom(foregroundColor: AppColors.error),
                    child: Text(invite.isPending ? 'Withdraw' : 'Remove'),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
