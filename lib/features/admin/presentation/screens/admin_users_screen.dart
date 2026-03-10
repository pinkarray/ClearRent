import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/conversation_service.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _firestore = FirebaseFirestore.instance;
  final _conversationService = ConversationService();
  String? _adminId;
  String _adminName = 'ClearRent Admin';

  // Status filter: 'all' | 'verified' | 'unverified'
  String _statusFilter = 'all';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _adminId = FirebaseAuth.instance.currentUser?.uid;
    _loadAdminName();
  }

  Future<void> _loadAdminName() async {
    if (_adminId == null) return;
    final doc = await _firestore.collection('users').doc(_adminId).get();
    if (doc.exists && mounted) {
      setState(() => _adminName = doc.data()?['fullName'] ?? 'ClearRent Admin');
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text('Users Directory', style: AppTextStyles.h4),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(children: [
            TabBar(
              controller: _tabController,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              indicatorWeight: 3,
              labelStyle: AppTextStyles.labelMedium,
              tabs: const [
                Tab(text: 'All'),
                Tab(text: 'Landlords'),
                Tab(text: 'Agents'),
                Tab(text: 'Tenants'),
              ],
            ),
            // Status filter chips
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(children: [
                _FilterChip(label: 'All', value: 'all', selected: _statusFilter == 'all', onTap: () => setState(() => _statusFilter = 'all')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Verified', value: 'verified', selected: _statusFilter == 'verified', onTap: () => setState(() => _statusFilter = 'verified')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Unverified', value: 'unverified', selected: _statusFilter == 'unverified', onTap: () => setState(() => _statusFilter = 'unverified')),
              ]),
            ),
          ]),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _UsersTab(accountType: null, statusFilter: _statusFilter, firestore: _firestore, adminId: _adminId, adminName: _adminName, conversationService: _conversationService),
          _UsersTab(accountType: 'landlord', statusFilter: _statusFilter, firestore: _firestore, adminId: _adminId, adminName: _adminName, conversationService: _conversationService),
          _UsersTab(accountType: 'agent', statusFilter: _statusFilter, firestore: _firestore, adminId: _adminId, adminName: _adminName, conversationService: _conversationService),
          _UsersTab(accountType: 'tenant', statusFilter: _statusFilter, firestore: _firestore, adminId: _adminId, adminName: _adminName, conversationService: _conversationService),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab — streams users filtered by accountType and status
// ─────────────────────────────────────────────────────────────────────────────

class _UsersTab extends StatelessWidget {
  final String? accountType; // null = all types
  final String statusFilter;
  final FirebaseFirestore firestore;
  final String? adminId;
  final String adminName;
  final ConversationService conversationService;

  const _UsersTab({
    required this.accountType,
    required this.statusFilter,
    required this.firestore,
    required this.adminId,
    required this.adminName,
    required this.conversationService,
  });

  Query<Map<String, dynamic>> get _query {
    Query<Map<String, dynamic>> q = firestore.collection('users')
        .orderBy('createdAt', descending: true);

    if (accountType != null) {
      q = q.where('accountType', isEqualTo: accountType);
    }

    if (statusFilter == 'verified') {
      q = q.where('verificationStatus', isEqualTo: 'verified');
    } else if (statusFilter == 'unverified') {
      // unverified = anything that isn't 'verified'
      // Firestore doesn't support != on indexed fields cleanly so we filter in memory
    }

    return q;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(child: CircularProgressIndicator(color: AppColors.primary));
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}', style: AppTextStyles.bodyMedium));
        }

        var docs = snapshot.data?.docs ?? [];

        // In-memory filter for unverified (status != 'verified')
        if (statusFilter == 'unverified') {
          docs = docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return data['verificationStatus'] != 'verified';
          }).toList();
        }

        // Filter out the admin's own account
        if (adminId != null) {
          docs = docs.where((doc) => doc.id != adminId).toList();
        }

        if (docs.isEmpty) {
          return _EmptyState(statusFilter: statusFilter, accountType: accountType);
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            data['id'] = docs[i].id;
            return _UserCard(
              userId: docs[i].id,
              data: data,
              adminId: adminId,
              adminName: adminName,
              conversationService: conversationService,
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual user card
// ─────────────────────────────────────────────────────────────────────────────

class _UserCard extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> data;
  final String? adminId;
  final String adminName;
  final ConversationService conversationService;

  const _UserCard({
    required this.userId,
    required this.data,
    required this.adminId,
    required this.adminName,
    required this.conversationService,
  });

  @override
  State<_UserCard> createState() => _UserCardState();
}

class _UserCardState extends State<_UserCard> {
  bool _isOpeningChat = false;
  bool _isSendingReminder = false;

  String get _fullName => widget.data['fullName'] ?? 'Unknown User';
  String get _phone => widget.data['phone'] ?? '';
  String get _accountType => widget.data['accountType'] ?? 'tenant';
  String get _status => widget.data['verificationStatus'] ?? 'none';
  bool get _isVerified => _status == 'verified';

  String get _initials {
    final parts = _fullName.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return _fullName.isNotEmpty ? _fullName[0].toUpperCase() : '?';
  }

  Color get _typeColor {
    switch (_accountType) {
      case 'landlord': return AppColors.primary;
      case 'agent': return AppColors.warning;
      case 'tenant': return AppColors.info;
      default: return AppColors.textHint;
    }
  }

  String get _typeLabel {
    return _accountType[0].toUpperCase() + _accountType.substring(1);
  }

  String get _statusLabel {
    switch (_status) {
      case 'verified': return 'Verified';
      case 'pending': return 'Pending';
      case 'rejected': return 'Rejected';
      default: return 'Unverified';
    }
  }

  Color get _statusColor {
    switch (_status) {
      case 'verified': return AppColors.success;
      case 'pending': return AppColors.warning;
      case 'rejected': return AppColors.error;
      default: return AppColors.textHint;
    }
  }

  IconData get _statusIcon {
    switch (_status) {
      case 'verified': return Icons.verified_outlined;
      case 'pending': return Icons.hourglass_top_outlined;
      case 'rejected': return Icons.cancel_outlined;
      default: return Icons.help_outline;
    }
  }

  Future<void> _openWhatsApp() async {
    if (_phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No phone number on file'), backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating),
      );
      return;
    }

    // Normalise Nigerian number for WhatsApp
    String normalized = _phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (normalized.startsWith('0')) normalized = '234${normalized.substring(1)}';
    if (!normalized.startsWith('+')) normalized = '+$normalized';
    normalized = normalized.replaceAll('+', '');

    final url = Uri.parse('https://wa.me/$normalized');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open WhatsApp'), backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _copyPhone() async {
    if (_phone.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _phone));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$_phone copied'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openInAppChat() async {
    if (widget.adminId == null) return;
    setState(() => _isOpeningChat = true);

    final conv = await widget.conversationService.getOrCreateAdminConversation(
      adminId: widget.adminId!,
      adminName: widget.adminName,
      userId: widget.userId,
      userName: _fullName,
    );

    if (!mounted) return;
    setState(() => _isOpeningChat = false);

    if (conv != null) {
      context.push('/chat', extra: {
        'conversation': conv,
        'currentUserId': widget.adminId,
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open chat. Please try again.'), backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _sendVerificationReminder() async {
    if (widget.adminId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Send Verification Reminder?'),
        content: Text('This will send $_fullName a notification prompting them to complete verification.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Send', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600))),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSendingReminder = true);

    final success = await widget.conversationService.sendVerificationReminder(
      adminId: widget.adminId!,
      userId: widget.userId,
      userName: _fullName,
      userType: _accountType,
    );

    if (!mounted) return;
    setState(() => _isSendingReminder = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? 'Reminder sent to $_fullName' : 'Failed to send reminder'),
        backgroundColor: success ? AppColors.success : AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _isVerified ? AppColors.border : AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Header row — avatar, name, badges
        Row(children: [
          // Avatar
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: _typeColor.withAlpha(26),
              shape: BoxShape.circle,
              border: Border.all(color: _typeColor.withAlpha(60)),
            ),
            child: Center(child: Text(_initials, style: AppTextStyles.labelLarge.copyWith(color: _typeColor))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_fullName, style: AppTextStyles.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                // Account type badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: _typeColor.withAlpha(20), borderRadius: BorderRadius.circular(4)),
                  child: Text(_typeLabel, style: AppTextStyles.labelSmall.copyWith(color: _typeColor, fontSize: 10)),
                ),
                const SizedBox(width: 6),
                // Verification status badge
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_statusIcon, size: 12, color: _statusColor),
                  const SizedBox(width: 3),
                  Text(_statusLabel, style: AppTextStyles.caption.copyWith(color: _statusColor, fontSize: 11)),
                ]),
              ]),
            ]),
          ),
        ]),

        // Phone row (if available)
        if (_phone.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _copyPhone,
            child: Row(children: [
              Icon(Icons.phone_outlined, size: 13, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(_phone, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              const SizedBox(width: 6),
              Icon(Icons.copy_outlined, size: 11, color: AppColors.textHint),
            ]),
          ),
        ],

        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // Action buttons
        if (_isVerified) ...[
          // Verified user — phone + WhatsApp + in-app chat
          Row(children: [
            if (_phone.isNotEmpty) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openWhatsApp,
                  icon: const Icon(Icons.chat_outlined, size: 15),
                  label: const Text('WhatsApp'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    side: BorderSide(color: AppColors.success),
                    foregroundColor: AppColors.success,
                    textStyle: AppTextStyles.labelSmall,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isOpeningChat ? null : _openInAppChat,
                icon: _isOpeningChat
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.forum_outlined, size: 15),
                label: const Text('Message'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  textStyle: AppTextStyles.labelSmall,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ]),
        ] else ...[
          // Unverified user — show verification status context + remind button
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(13),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withAlpha(50)),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 14, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _status == 'pending'
                      ? 'Verification pending admin review.'
                      : _status == 'rejected'
                          ? 'Verification was rejected. User needs to resubmit.'
                          : 'This user has not started verification yet.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.warning, height: 1.4),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            if (_phone.isNotEmpty) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openWhatsApp,
                  icon: const Icon(Icons.chat_outlined, size: 15),
                  label: const Text('WhatsApp'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    side: BorderSide(color: AppColors.border),
                    foregroundColor: AppColors.textSecondary,
                    textStyle: AppTextStyles.labelSmall,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: ElevatedButton.icon(
                onPressed: (_isSendingReminder || _status == 'pending') ? null : _sendVerificationReminder,
                icon: _isSendingReminder
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.notifications_outlined, size: 15),
                label: Text(_status == 'pending' ? 'Under Review' : 'Send Reminder'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  backgroundColor: _status == 'pending' ? AppColors.textHint : AppColors.warning,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  textStyle: AppTextStyles.labelSmall,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label, value;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.value, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border),
        ),
        child: Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: selected ? Colors.white : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String statusFilter;
  final String? accountType;
  const _EmptyState({required this.statusFilter, required this.accountType});

  @override
  Widget build(BuildContext context) {
    final typeLabel = accountType != null
        ? '${accountType![0].toUpperCase()}${accountType!.substring(1)}s'
        : 'users';

    final message = switch (statusFilter) {
      'verified' => 'No verified $typeLabel yet',
      'unverified' => 'No unverified $typeLabel',
      _ => 'No $typeLabel found',
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.people_outline, size: 48, color: AppColors.textHint),
          const SizedBox(height: 16),
          Text(message, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
        ]),
      ),
    );
  }
}