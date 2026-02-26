import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';

class AdminPropertyDocsScreen extends StatefulWidget {
  const AdminPropertyDocsScreen({super.key});

  @override
  State<AdminPropertyDocsScreen> createState() => _AdminPropertyDocsScreenState();
}

class _AdminPropertyDocsScreenState extends State<AdminPropertyDocsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
        title: const Text('Property Documents', style: AppTextStyles.h4),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelStyle: AppTextStyles.labelMedium,
          tabs: const [
            Tab(text: 'Pending'),
            Tab(text: 'Verified'),
            Tab(text: 'Rejected'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _DocTab(status: 'pending', firestore: _firestore),
          _DocTab(status: 'verified', firestore: _firestore),
          _DocTab(status: 'rejected', firestore: _firestore),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab — streams properties with a given ownershipDocStatus
// ─────────────────────────────────────────────────────────────────────────────

class _DocTab extends StatelessWidget {
  final String status;
  final FirebaseFirestore firestore;

  const _DocTab({required this.status, required this.firestore});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: firestore
          .collection('properties')
          .where('ownershipDocStatus', isEqualTo: status)
          .orderBy('updatedAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppColors.primary));
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline, color: AppColors.error, size: 40),
                const SizedBox(height: 12),
                Text('Could not load documents', style: AppTextStyles.bodyMedium),
                const SizedBox(height: 8),
                Text('${snapshot.error}', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              ]),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return _EmptyState(status: status);
        }

        final properties = docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          data['id'] = doc.id;
          // Convert Timestamps
          for (final key in ['createdAt', 'updatedAt']) {
            if (data[key] is Timestamp) {
              data[key] = (data[key] as Timestamp).toDate().toIso8601String();
            }
          }
          return PropertyModel.fromJson(data);
        }).toList();

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: properties.length,
          itemBuilder: (context, i) => _PropertyDocCard(
            property: properties[i],
            firestore: firestore,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Card for a single property's document
// ─────────────────────────────────────────────────────────────────────────────

class _PropertyDocCard extends StatelessWidget {
  final PropertyModel property;
  final FirebaseFirestore firestore;

  const _PropertyDocCard({required this.property, required this.firestore});

  String _docTypeLabel(String? type) {
    switch (type) {
      case 'c_of_o': return 'Certificate of Occupancy';
      case 'deed': return 'Deed of Assignment';
      case 'other': return 'Other Document';
      default: return 'Unknown Type';
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending': return AppColors.warning;
      case 'verified': return AppColors.success;
      case 'rejected': return AppColors.error;
      default: return AppColors.textHint;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = property.ownershipDocStatus;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Property title + status badge
        Row(children: [
          Expanded(
            child: Text(property.title, style: AppTextStyles.labelLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _statusColor(status).withAlpha(26),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status[0].toUpperCase() + status.substring(1),
              style: AppTextStyles.labelSmall.copyWith(color: _statusColor(status)),
            ),
          ),
        ]),

        const SizedBox(height: 6),

        // Location
        Row(children: [
          const Icon(Icons.location_on_outlined, size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${property.city}, ${property.state}',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ]),

        const SizedBox(height: 12),

        // Landlord + doc type row
        Row(children: [
          const Icon(Icons.person_outline, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              property.landlordName ?? 'Unknown Landlord',
              style: AppTextStyles.caption,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(20),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _docTypeLabel(property.ownershipDocType),
              style: AppTextStyles.labelSmall.copyWith(color: AppColors.info, fontSize: 10),
            ),
          ),
        ]),

        // Rejection reason if applicable
        if (status == 'rejected' && property.ownershipDocRejectionReason != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.error.withAlpha(13),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.error.withAlpha(50)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 14, color: AppColors.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Rejection reason: ${property.ownershipDocRejectionReason}',
                  style: AppTextStyles.caption.copyWith(color: AppColors.error, height: 1.4),
                ),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // Action buttons
        Row(children: [
          // View document
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _viewDocument(context),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('View Doc'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
                side: const BorderSide(color: AppColors.primary),
                foregroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: AppTextStyles.labelMedium,
              ),
            ),
          ),

          // Show verify/reject only if pending or re-review rejected
          if (status == 'pending' || status == 'rejected') ...[
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _approveDoc(context),
                icon: const Icon(Icons.verified_outlined, size: 16),
                label: const Text('Verify'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: AppTextStyles.labelMedium,
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _rejectDoc(context),
                icon: const Icon(Icons.cancel_outlined, size: 16),
                label: const Text('Reject'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: AppTextStyles.labelMedium,
                  elevation: 0,
                ),
              ),
            ),
          ],

          // Re-review option for verified docs
          if (status == 'verified') ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _rejectDoc(context),
                icon: const Icon(Icons.undo_outlined, size: 16),
                label: const Text('Revoke'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: const BorderSide(color: AppColors.error),
                  foregroundColor: AppColors.error,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: AppTextStyles.labelMedium,
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  Future<void> _viewDocument(BuildContext context) async {
    final url = property.ownershipDocUrl;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No document URL found'), backgroundColor: AppColors.error),
      );
      return;
    }

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open document'), backgroundColor: AppColors.error),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _approveDoc(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Verify Document?'),
        content: Text(
          'This will mark the document for "${property.title}" as verified and show a "Document Verified" badge on the listing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Verify', style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await firestore.collection('properties').doc(property.id).update({
        'ownershipDocStatus': 'verified',
        'ownershipDocRejectionReason': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Document verified successfully'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _rejectDoc(BuildContext context) async {
    final reasonController = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(property.ownershipDocStatus == 'verified' ? 'Revoke Verification?' : 'Reject Document?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Please provide a reason. This will be shown to the landlord so they know what to fix.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: reasonController,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'e.g. Document is not legible, please re-upload a clearer image.',
              hintStyle: AppTextStyles.caption.copyWith(color: AppColors.textHint),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              if (reasonController.text.trim().isEmpty) return;
              Navigator.pop(ctx, reasonController.text.trim());
            },
            child: Text('Confirm', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (reason == null || reason.isEmpty) return;

    try {
      await firestore.collection('properties').doc(property.id).update({
        'ownershipDocStatus': 'rejected',
        'ownershipDocRejectionReason': reason,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Document rejected. Landlord will be notified.'),
            backgroundColor: AppColors.warning,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String status;
  const _EmptyState({required this.status});

  @override
  Widget build(BuildContext context) {
    final config = switch (status) {
      'pending' => (icon: Icons.hourglass_empty_outlined, message: 'No documents awaiting review'),
      'verified' => (icon: Icons.verified_outlined, message: 'No verified documents yet'),
      _ => (icon: Icons.cancel_outlined, message: 'No rejected documents'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(config.icon, size: 48, color: AppColors.textHint),
          const SizedBox(height: 16),
          Text(config.message, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
        ]),
      ),
    );
  }
}