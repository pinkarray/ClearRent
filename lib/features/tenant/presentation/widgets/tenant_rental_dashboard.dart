import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/condition_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../shared/widgets/notification_bell.dart';
import '../../../../shared/models/condition_record.dart';
import '../screens/condition_capture_screen.dart';

/// Minimum notice, in days, between a move-out request and the intended
/// move-out date — the window the handover check has to be booked in.
const int kMoveOutNoticeDays = 3;


class TenantRentalDashboard extends StatefulWidget {
  final ActiveRental rental;
  final String userName;
  final String userInitial;
  final bool isLoadingProfile;
  final VoidCallback onBrowseProperties;

  const TenantRentalDashboard({
    super.key,
    required this.rental,
    required this.userName,
    required this.userInitial,
    required this.isLoadingProfile,
    required this.onBrowseProperties,
  });

  @override
  State<TenantRentalDashboard> createState() => _TenantRentalDashboardState();
}

class _TenantRentalDashboardState extends State<TenantRentalDashboard> {
  final ActiveRentalService _activeRentalService = ActiveRentalService();
  final ConversationService _conversationService = ConversationService();
  bool _isTogglingReminder = false;
  bool _isMessageLoading = false;

  ActiveRental get rental => widget.rental;

  // Cached, but refreshed when the shown rental changes — MultiRentalDashboard
  // reuses this State and swaps widget.rental on switch. Caching stops the
  // pending-confirmation card blinking on unrelated rebuilds; the didUpdateWidget
  // refresh keeps it correct across rental switches.
  late Stream<QuerySnapshot> _pendingConfirmationsStream;

  final ConditionService _conditionService = ConditionService();

  /// The tenant's own move-out recording, if they have made one. Cached the
  /// same way and for the same reason as the stream above.
  late Stream<List<ConditionRecord>> _conditionStream;

  @override
  void initState() {
    super.initState();
    _pendingConfirmationsStream = _buildPendingConfirmationsStream();
    _conditionStream = _conditionService.streamRecords(
        widget.rental.id, ConditionStage.moveOut);
  }

  @override
  void didUpdateWidget(TenantRentalDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rental.id != widget.rental.id) {
      _pendingConfirmationsStream = _buildPendingConfirmationsStream();
      _conditionStream = _conditionService.streamRecords(
          widget.rental.id, ConditionStage.moveOut);
    }
  }

  Stream<QuerySnapshot> _buildPendingConfirmationsStream() =>
      FirebaseFirestore.instance
          .collection('issues')
          .where('tenantId', isEqualTo: widget.rental.tenantId)
          .where('propertyId', isEqualTo: widget.rental.propertyId)
          .where('status', isEqualTo: 'pending_confirmation')
          .snapshots();

  String get _firstName {
    final parts = widget.userName.split(' ');
    return parts.isNotEmpty ? parts.first : widget.userName;
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }

  double get _leaseProgress {
    final total = rental.leaseEndDate.difference(rental.leaseStartDate).inDays;
    final elapsed =
        DateTime.now().difference(rental.leaseStartDate).inDays;
    if (total <= 0) return 1.0;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  Future<void> _toggleReminder() async {
    setState(() => _isTogglingReminder = true);
    final success = await _activeRentalService.togglePaymentReminder(
        rental.id, !rental.hasPaymentReminder);
    if (!mounted) return;
    setState(() => _isTogglingReminder = false);
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Failed to update reminder'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Future<void> _callLandlord() async {
    if (rental.landlordPhone == null || rental.landlordPhone!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Phone number not available'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    final uri = Uri.parse('tel:${rental.landlordPhone}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _messageLandlord() async {
    setState(() => _isMessageLoading = true);
    try {
      // First try to find an existing conversation (no verification check needed)
      final existingQuery = await FirebaseFirestore.instance
          .collection('conversations')
          .where('propertyId', isEqualTo: rental.propertyId)
          .where('tenantId', isEqualTo: rental.tenantId)
          .where('landlordId', isEqualTo: rental.landlordId)
          .limit(1)
          .get();

      if (!mounted) return;

      if (existingQuery.docs.isNotEmpty) {
        // Existing conversation found — go straight to chat
        setState(() => _isMessageLoading = false);
        context.push('/chat', extra: {
          'conversationId': existingQuery.docs.first.id,
          'propertyTitle': rental.propertyTitle,
          'propertyImage':
              rental.propertyImage.isNotEmpty ? rental.propertyImage : null,
        });
        return;
      }

      // No existing conversation — create one via service
      // (This has verification checks, but for an active rental both
      // parties should be verified anyway)
      final conv = await _conversationService.getOrCreateConversation(
        propertyId: rental.propertyId,
        propertyTitle: rental.propertyTitle,
        propertyImage: rental.propertyImage,
        landlordId: rental.landlordId,
        landlordName: rental.landlordName,
        tenantId: rental.tenantId,
        tenantName: rental.tenantName,
      );

      if (!mounted) return;
      setState(() => _isMessageLoading = false);

      if (conv != null) {
        context.push('/chat', extra: {
          'conversationId': conv.id,
          'propertyTitle': rental.propertyTitle,
          'propertyImage':
              rental.propertyImage.isNotEmpty ? rental.propertyImage : null,
        });
      } else {
        // Last resort — create conversation directly without verification
        // since they're in an active rental
        developer.log(
          '⚠️ getOrCreateConversation returned null for active rental, creating directly',
          name: 'RentalDashboard',
        );
        final directConv = await _createRentalConversation();
        if (!mounted) return;
        setState(() => _isMessageLoading = false);

        if (directConv != null) {
          context.push('/chat', extra: {
            'conversationId': directConv,
            'propertyTitle': rental.propertyTitle,
            'propertyImage':
                rental.propertyImage.isNotEmpty ? rental.propertyImage : null,
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Could not start conversation. Please try again.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ));
        }
      }
    } catch (e) {
      developer.log('❌ Message error: $e', name: 'RentalDashboard');
      if (!mounted) return;
      setState(() => _isMessageLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: ${e.toString()}'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  /// Create a conversation directly for an active rental — skips verification
  /// since the rental itself proves both parties went through the full flow.
  Future<String?> _createRentalConversation() async {
    try {
      final participants = [rental.tenantId, rental.landlordId];

      final docRef = await FirebaseFirestore.instance
          .collection('conversations')
          .add({
        'propertyId': rental.propertyId,
        'propertyTitle': rental.propertyTitle,
        'propertyImage': rental.propertyImage,
        'landlordId': rental.landlordId,
        'landlordName': rental.landlordName,
        'tenantId': rental.tenantId,
        'tenantName': rental.tenantName,
        'agentId': '',
        'agentName': '',
        'participants': participants,
        'conversationType': 'property_rental',
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastSenderId': '',
        'createdAt': FieldValue.serverTimestamp(),
        'unreadCount_${rental.tenantId}': 0,
        'unreadCount_${rental.landlordId}': 0,
      });

      developer.log('✅ Created rental conversation directly: ${docRef.id}',
          name: 'RentalDashboard');
      return docRef.id;
    } catch (e) {
      developer.log('❌ Error creating rental conversation: $e',
          name: 'RentalDashboard');
      return null;
    }
  }

  /// Opens the move-out confirmation sheet. Tenant picks a reason, confirms,
  /// and the rental is marked ended_by_tenant server-side; the switcher stream
  /// then drops it from the list so no manual navigation is needed.
  Future<void> _showMoveOutSheet() async {
    // Check before opening the sheet, not after the tenant has filled it in —
    // an unresolved fault has to be closed first, and they deserve to know why
    // up front rather than hitting a generic failure at submit.
    final blocked = await _activeRentalService.hasOpenIssueForRental(
      tenantId: rental.tenantId,
      propertyId: rental.propertyId,
    );
    if (!mounted) return;
    if (blocked) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Unresolved issue'),
          content: const Text(
            'You have a maintenance issue on this property that hasn\'t been '
            'resolved yet. Close it out with your landlord before requesting '
            'to move out.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    const reasons = [
      'Moving to a new area',
      'Found a better place',
      'Cost / affordability',
      'Other',
    ];
    String? selectedReason;
    // Minimum notice: the handover has to be schedulable, so the earliest
    // intended move-out is 3 days out. Must stay in step with the picker's
    // firstDate below — an initialDate before firstDate asserts.
    DateTime selectedDate =
        DateTime.now().add(const Duration(days: kMoveOutNoticeDays));
    final otherController = TextEditingController();

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Request Move-Out', style: AppTextStyles.h4),
                const SizedBox(height: 6),
                Text(
                  'Tell your landlord you\'re moving out. They confirm the '
                  'handover to end the tenancy. If they don\'t respond within '
                  '7 days, it\'s confirmed automatically.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 20),
                ...reasons.map((r) {
                  final isSel = selectedReason == r;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GestureDetector(
                      onTap: () => setSheet(() => selectedReason = r),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppColors.primary.withAlpha(20)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSel ? AppColors.primary : AppColors.border,
                          ),
                        ),
                        child: Row(children: [
                          Icon(
                            isSel
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: isSel
                                ? AppColors.primary
                                : AppColors.textHint,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            r,
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: isSel
                                  ? AppColors.primary
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  );
                }),
                if (selectedReason == 'Other') ...[
                  const SizedBox(height: 4),
                  TextField(
                    controller: otherController,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Tell us a bit more (optional)',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // Intended move-out date
                GestureDetector(
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: sheetCtx,
                      initialDate: selectedDate,
                      firstDate: DateTime(now.year, now.month, now.day)
                          .add(const Duration(days: kMoveOutNoticeDays)),
                      lastDate: now.add(const Duration(days: 90)),
                    );
                    if (picked != null) setSheet(() => selectedDate = picked);
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_outlined,
                          size: 18, color: AppColors.primary),
                      const SizedBox(width: 10),
                      Text('Intended date',
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: AppColors.textSecondary)),
                      const Spacer(),
                      Text(
                        '${selectedDate.day} '
                        '${const [
                          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
                        ][selectedDate.month - 1]} '
                        '${selectedDate.year}',
                        style: AppTextStyles.labelMedium
                            .copyWith(color: AppColors.textPrimary),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right,
                          size: 18, color: AppColors.textHint),
                    ]),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: selectedReason == null
                        ? null
                        : () => Navigator.pop(sheetCtx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.border,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('Request Move-Out',
                        style: AppTextStyles.labelLarge
                            .copyWith(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed != true || selectedReason == null) return;

    final reason = selectedReason == 'Other' &&
            otherController.text.trim().isNotEmpty
        ? otherController.text.trim()
        : selectedReason!;

    final ok = await _activeRentalService.tenantRequestMoveOut(
      rental.id,
      reason,
      selectedDate,
    );

    // Landlord recent-activity entry (the push itself comes from the
    // onActiveRentalUpdated Cloud Function). Field must be `landlordId` — the
    // activity feed only queries that field — matching the issue writes below.
    if (ok) {
      try {
        await FirebaseFirestore.instance.collection('activities').add({
          'landlordId': rental.landlordId,
          'type': 'moveout_requested',
          'title': 'Move-out Requested',
          'message':
              '${rental.tenantName} requested to move out of '
              '${rental.propertyTitle}: "$reason". Confirm handover to end '
              'the tenancy.',
          'propertyId': rental.propertyId,
          'rentalId': rental.id,
          'actorId': rental.tenantId,
          'actorName': rental.tenantName,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        // Non-fatal: the request itself already succeeded and the landlord is
        // notified via the bell regardless.
        developer.log('Move-out activity write failed: $e',
            name: 'TenantRentalDashboard');
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Move-out requested - your landlord will confirm the handover.'
          : 'Could not request move-out. Please try again.'),
      backgroundColor: ok ? AppColors.success : AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
    // On success the rental becomes moveout_pending — still shown as current,
    // now with the pending banner until the landlord confirms.
  }

  Widget _buildMoveOutPendingBanner() {
    final intended = rental.moveOutIntendedDate;
    final dateStr = intended == null
        ? null
        : '${intended.day} '
            '${const [
              'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
              'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
            ][intended.month - 1]} '
            '${intended.year}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.warning.withAlpha(26),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.logout, size: 18, color: AppColors.warning),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  rental.isMoveOutAcknowledged
                      ? 'Move-out acknowledged'
                      : 'Move-out requested',
                  style: AppTextStyles.labelMedium),
              const SizedBox(height: 2),
              // This used to say the landlord's confirmation was awaited and
              // that it auto-confirms "after 7 days". Both were false while
              // the tenant was still living there: the landlord CANNOT confirm
              // before the move-out date, and the 7 days runs from that date —
              // so a 3-day notice resolved on day 10, not day 7. It read as a
              // landlord dragging their feet when they were blocked by design.
              Text(
                dateStr == null
                    ? 'Your landlord will confirm the handover once you have '
                        'moved out.'
                    : rental.isMoveOutAcknowledged
                        ? 'Your landlord knows you are leaving on $dateStr. '
                            'They confirm the handover from that day.'
                        : 'You are moving out on $dateStr. Your landlord can '
                            'confirm the handover from that day, and it '
                            'confirms itself a week later if they don\'t.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
              // The one window where this can honestly be done: they still
              // have keys. Once the tenancy ends and the keys go back, a
              // walkthrough is no longer theirs to record — and it is the only
              // thing a deduction from their deposit can be argued against.
              const SizedBox(height: 10),
              // Once recorded, the record is SEALED and a second attempt is
              // refused by rules. Still inviting one sent the tenant off to
              // shoot a whole walkthrough that could never be accepted, so the
              // link has to say which of the two states they are in.
              StreamBuilder<List<ConditionRecord>>(
                stream: _conditionStream,
                builder: (context, snap) {
                  final mine = (snap.data ?? const <ConditionRecord>[])
                      .where((r) => r.partyId == rental.tenantId)
                      .toList();
                  final done =
                      mine.isNotEmpty && mine.first.capturedAt != null;
                  return GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ConditionCaptureScreen(
                          rentalId: rental.id,
                          propertyTitle: rental.propertyTitle,
                          stage: ConditionStage.moveOut,
                          partyRole: 'tenant',
                        ),
                      ),
                    ),
                    // The label is long and sits inside an already-indented
                    // banner, so it must be free to wrap — an unconstrained
                    // Text in a min-size Row takes its full intrinsic width
                    // and overflows the line instead.
                    child: Row(children: [
                      Icon(
                        done
                            ? Icons.check_circle_outline
                            : Icons.videocam_outlined,
                        size: 15,
                        color: done ? AppColors.success : AppColors.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          done
                              ? 'You recorded the condition - tap to view it'
                              : 'Record the condition you are leaving it in',
                          style: AppTextStyles.caption.copyWith(
                            color:
                                done ? AppColors.success : AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        // Parent will handle refresh
      },
      color: AppColors.primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(),
            const SizedBox(height: 20),

            // Move-out requested — awaiting landlord confirmation
            if (rental.isMoveoutPending) ...[
              _buildMoveOutPendingBanner(),
              const SizedBox(height: 16),
            ],

            // Expiry warning
            if (rental.daysUntilLeaseEnd <= 30 &&
                rental.daysUntilLeaseEnd > 0)
              _buildExpiryWarning(),

            // Property hero card
            _buildPropertyHero(),
            const SizedBox(height: 16),

            // Lease timeline
            _buildLeaseTimeline(),
            const SizedBox(height: 16),

            // Landlord contact
            _buildLandlordCard(),
            const SizedBox(height: 16),

            // Pending fix confirmations — shown when landlord says something is fixed
            _buildPendingConfirmations(),

            // Quick actions
            _buildQuickActions(),
            const SizedBox(height: 16),

            // Payment info
            _buildPaymentCard(),
            const SizedBox(height: 24),

            // Browse more
            _buildBrowseMore(),
            const SizedBox(height: 8),

            // Move out — quiet, low-frequency action. Hidden once a request is
            // already pending (the banner above covers that state).
            if (!rental.isMoveoutPending)
              Center(
                child: TextButton(
                  onPressed: _showMoveOutSheet,
                  child: Text(
                    'Request move-out',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textHint),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.isLoadingProfile
                  ? Container(
                      width: 120, height: 16,
                      
                      decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(4)))
                          
                  : Text('Welcome home, $_firstName',
                      style: AppTextStyles.h3
                          .copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        // Status badge
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: rental.isExpiringSoon
                ? AppColors.warning.withAlpha(26)
                : AppColors.success.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: rental.isExpiringSoon
                    ? AppColors.warning
                    : AppColors.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              rental.statusDisplay,
              style: AppTextStyles.labelSmall.copyWith(
                color: rental.isExpiringSoon
                    ? AppColors.warning
                    : AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        NotificationBell(userId: rental.tenantId),
      ],
    );
  }

  Widget _buildExpiryWarning() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.warning.withAlpha(26),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.timer_outlined,
              color: AppColors.warning, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lease Expiring Soon',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.warning)),
              const SizedBox(height: 2),
              Text(
                '${rental.daysUntilLeaseEnd} days remaining. Start looking for your next home or contact your landlord to renew.',
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildPropertyHero() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(13),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Property image
          ClipRRect(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(16)),
            child: SizedBox(
              height: 180,
              width: double.infinity,
              child: rental.propertyImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: rental.propertyImage,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _imagePlaceholder(),
                    )
                  : _imagePlaceholder(),
            ),
          ),
          // Property info
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rental.propertyTitle,
                    style: AppTextStyles.h4,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Icons.location_on_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(rental.propertyAddress,
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
                const SizedBox(height: 12),
                // Rent amount
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(13),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '₦${_formatAmount(rental.rentAmount)}${rental.rentPeriod}',
                        style: AppTextStyles.naira(AppTextStyles.labelLarge)
                            .copyWith(color: AppColors.primary),
                      ),
                    ),
                    const Spacer(),
                    Text(rental.rentFrequency == 'yearly'
                        ? 'Annual rent'
                        : 'Monthly rent',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textHint)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaseTimeline() {
    final daysLeft = rental.daysUntilLeaseEnd;
    final totalDays = rental.leaseEndDate
        .difference(rental.leaseStartDate)
        .inDays;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.calendar_today_outlined,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 8),
            Text('Lease Timeline', style: AppTextStyles.labelLarge),
            const Spacer(),
            Text(
              daysLeft > 0 ? '$daysLeft days left' : 'Expired',
              style: AppTextStyles.labelMedium.copyWith(
                color: daysLeft <= 30
                    ? AppColors.warning
                    : AppColors.success,
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _leaseProgress,
              minHeight: 8,
              backgroundColor: AppColors.background,
              valueColor: AlwaysStoppedAnimation<Color>(
                daysLeft <= 30
                    ? AppColors.warning
                    : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Date labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  Text(_formatDate(rental.leaseStartDate),
                      style: AppTextStyles.labelSmall),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('End',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  Text(_formatDate(rental.leaseEndDate),
                      style: AppTextStyles.labelSmall),
                ],
              ),
            ],
          ),

          // Total duration
          const SizedBox(height: 8),
          Center(
            child: Text(
              '$totalDays day lease (${rental.rentFrequency})',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandlordCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.primary.withAlpha(26),
          child: Text(
            rental.landlordName.isNotEmpty
                ? rental.landlordName[0].toUpperCase()
                : 'L',
            style: AppTextStyles.h4
                .copyWith(color: AppColors.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rental.landlordName,
                  style: AppTextStyles.labelLarge),
              const SizedBox(height: 2),
              Text('Your Landlord',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        // Message button
        IconButton(
          onPressed: _isMessageLoading ? null : _messageLandlord,
          icon: _isMessageLoading
              ? SizedBox(
                  width: 36,
                  height: 36,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                )
              : Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.chat_outlined,
                      color: AppColors.primary, size: 20),
                ),
        ),
        // Call button
        IconButton(
          onPressed: _callLandlord,
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.phone,
                color: AppColors.success, size: 20),
          ),
        ),
      ]),
    );
  }

  // Streams issues in pending_confirmation state for this tenant's property.
  // Renders a confirmation card for each — tenant confirms or disputes.
  Widget _buildPendingConfirmations() {
    return StreamBuilder<QuerySnapshot>(
      stream: _pendingConfirmationsStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final docs = snapshot.data!.docs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                    color: AppColors.info, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                'Fix${docs.length > 1 ? 'es' : ''} to Confirm (${docs.length})',
                style: AppTextStyles.labelLarge,
              ),
            ]),
            const SizedBox(height: 10),
            ...docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return _PendingConfirmationCard(
                // Keyed by issue id: these cards hold per-card in-flight state
                // (_isActing) that is intentionally left set on success. Without
                // a key, removing a confirmed issue shifts the next one into
                // that slot, where it inherits the finished card's State and
                // renders a stuck spinner with no confirm button.
                key: ValueKey(doc.id),
                issueId: doc.id,
                data: data,
              );
            }),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _QuickActionCard(
            icon: Icons.event_note_outlined,
            label: 'My Inspections',
            color: AppColors.primary,
            onTap: () => context.push('/tenant/inspections'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionCard(
            icon: Icons.description_outlined,
            label: 'Lease Details',
            color: AppColors.info,
            onTap: () =>
              context.push('/tenant/lease-details' , extra: rental),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionCard(
            icon: Icons.report_problem_outlined,
            label: 'Report Issue',
            color: AppColors.warning,
            onTap: () => context.push('/tenant/report-issue', extra: {
              'propertyId': rental.propertyId,
              'propertyTitle': rental.propertyTitle,
              'tenantId': rental.tenantId,
              'tenantName': rental.tenantName,
              'landlordId': rental.landlordId,
              'landlordName': rental.landlordName,
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentCard() {
    final daysUntilPayment = rental.daysUntilPaymentDue;
    final isOverdue = rental.isPaymentOverdue;
    final isDueSoon = rental.isPaymentDueSoon;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOverdue
              ? AppColors.error.withAlpha(77)
              : isDueSoon
                  ? AppColors.warning.withAlpha(77)
                  : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              isOverdue
                  ? Icons.warning_amber_rounded
                  : Icons.payment,
              size: 20,
              color: isOverdue
                  ? AppColors.error
                  : isDueSoon
                      ? AppColors.warning
                      : AppColors.primary,
            ),
            const SizedBox(width: 8),
            Text('Next Payment', style: AppTextStyles.labelLarge),
            const Spacer(),
            // Reminder toggle
            if (_isTogglingReminder)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              )
            else
              Row(children: [
                Text(
                  rental.hasPaymentReminder ? 'Reminder on' : 'Remind me',
                  style: AppTextStyles.caption.copyWith(
                    color: rental.hasPaymentReminder
                        ? AppColors.success
                        : AppColors.textHint,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: _toggleReminder,
                  child: Icon(
                    rental.hasPaymentReminder
                        ? Icons.notifications_active
                        : Icons.notifications_none_outlined,
                    size: 20,
                    color: rental.hasPaymentReminder
                        ? AppColors.success
                        : AppColors.textHint,
                  ),
                ),
              ]),
          ]),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Amount',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 2),
                  Text('₦${_formatAmount(rental.rentAmount)}',
                      style: AppTextStyles.naira(AppTextStyles.h4)
                          .copyWith(color: AppColors.textPrimary)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Due date',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 2),
                  Text(
                    _formatDate(rental.nextPaymentDue),
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isOverdue
                          ? AppColors.error
                          : isDueSoon
                              ? AppColors.warning
                              : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),

          if (isOverdue) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.error_outline,
                    size: 16, color: AppColors.error),
                const SizedBox(width: 8),
                Text(
                  'Payment is ${-daysUntilPayment} days overdue',
                  style: AppTextStyles.labelSmall
                      .copyWith(color: AppColors.error),
                ),
              ]),
            ),
          ] else if (isDueSoon) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.info_outline,
                    size: 16, color: AppColors.warning),
                const SizedBox(width: 8),
                Text(
                  'Due in $daysUntilPayment days',
                  style: AppTextStyles.labelSmall
                      .copyWith(color: AppColors.warning),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBrowseMore() {
    return GestureDetector(
      onTap: widget.onBrowseProperties,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(13),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(38)),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.search,
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Browse Properties',
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.primary)),
                Text(
                  'Looking ahead? Browse for when your lease ends.',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: AppColors.primary),
        ]),
      ),
    );
  }

  Widget _imagePlaceholder() => Container(
        color: AppColors.background,
        child: Center(
          child: Icon(Icons.home_outlined,
              size: 48, color: AppColors.textHint),
        ),
      );
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: AppTextStyles.labelSmall,
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

/// Card shown on the tenant dashboard when a landlord has marked an issue as fixed
/// and is awaiting tenant confirmation. Tenant can confirm or dispute.
class _PendingConfirmationCard extends StatefulWidget {
  final String issueId;
  final Map<String, dynamic> data;

  const _PendingConfirmationCard({
    super.key,
    required this.issueId,
    required this.data,
  });

  @override
  State<_PendingConfirmationCard> createState() =>
      _PendingConfirmationCardState();
}

class _PendingConfirmationCardState extends State<_PendingConfirmationCard> {
  bool _isActing = false;

  String get _title => widget.data['title'] ?? 'Issue';
  String get _category => widget.data['category'] ?? 'other';

  Future<void> _confirm() async {
    setState(() => _isActing = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
        'tenantConfirmedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify landlord
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
        // Landlord recent-activity entry (push itself is sent by the
        // onIssueUpdated Cloud Function). Field must be `landlordId` — the
        // activity feed only queries that field — matching tenant_home's
        // confirm and the dispute case below.
        await FirebaseFirestore.instance.collection('activities').add({
          'landlordId': landlordId,
          'type': 'issue_confirmed',
          'title': 'Fix Confirmed ✓',
          'message':
              '${widget.data['tenantName'] ?? 'Your tenant'} confirmed the $_category issue has been resolved.',
          'propertyId': widget.data['propertyId'],
          'issueId': widget.issueId,
          'actorId': widget.data['tenantId'],
          'actorName': widget.data['tenantName'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('❌ Error confirming fix: $e');
      if (mounted) setState(() => _isActing = false);
    }
  }

  Future<void> _dispute() async {
    // Ask tenant for a reason before disputing
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('What\'s still wrong?'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Describe what hasn\'t been fixed yet...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(ctx, reasonController.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Submit Dispute',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (reason == null || reason.isEmpty) return;

    setState(() => _isActing = true);
    try {
      await FirebaseFirestore.instance
          .collection('issues')
          .doc(widget.issueId)
          .update({
        'status': 'in_progress',
        'disputeReason': reason,
        'disputedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify landlord with dispute reason
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
        await FirebaseFirestore.instance.collection('activities').add({
          'landlordId': landlordId,
          'type': 'issue_disputed',
          'title': 'Fix Disputed',
          'message':
              '${widget.data['tenantName'] ?? 'Your tenant'} says the $_category issue is not fully resolved: "$reason"',
          'propertyId': widget.data['propertyId'],
          'issueId': widget.issueId,
          'actorId': widget.data['tenantId'],
          'actorName': widget.data['tenantName'],
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('❌ Error disputing fix: $e');
      if (mounted) setState(() => _isActing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.info.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.build_outlined,
                  size: 16, color: AppColors.info),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(
                    'Your landlord says this is fixed',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.info),
                  ),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 12),

          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isActing ? null : _dispute,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text('Still Broken',
                    style: TextStyle(
                        color: AppColors.error, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _isActing ? null : _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _isActing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Confirmed Fixed', style: TextStyle(fontSize: 13)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}