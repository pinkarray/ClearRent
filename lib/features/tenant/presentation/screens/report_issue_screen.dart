import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:developer' as developer;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/property_service.dart';

/// Report an issue screen for tenants.
/// Creates a document in 'issues' collection in Firestore.
/// Landlord can see issues for their properties.
class ReportIssueScreen extends StatefulWidget {
  final String propertyId;
  final String propertyTitle;
  final String tenantId;
  final String tenantName;
  final String landlordId;
  final String landlordName;

  const ReportIssueScreen({
    super.key,
    required this.propertyId,
    required this.propertyTitle,
    required this.tenantId,
    required this.tenantName,
    required this.landlordId,
    required this.landlordName,
  });

  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final AuthService _authService = AuthService();
  final PropertyService _propertyService = PropertyService();

  String _selectedCategory = 'plumbing';
  String _selectedPriority = 'medium';
  final List<String> _imageUrls = [];
  bool _isSubmitting = false;
  bool _isUploadingImage = false;

  final _categories = [
    {'value': 'plumbing', 'label': 'Plumbing', 'icon': Icons.plumbing},
    {'value': 'electrical', 'label': 'Electrical', 'icon': Icons.electrical_services},
    {'value': 'structural', 'label': 'Structural', 'icon': Icons.foundation},
    {'value': 'appliance', 'label': 'Appliance', 'icon': Icons.kitchen},
    {'value': 'pest', 'label': 'Pest Control', 'icon': Icons.bug_report},
    {'value': 'security', 'label': 'Security', 'icon': Icons.security},
    {'value': 'cleaning', 'label': 'Cleaning', 'icon': Icons.cleaning_services},
    {'value': 'other', 'label': 'Other', 'icon': Icons.more_horiz},
  ];

  final _priorities = [
    {'value': 'low', 'label': 'Low', 'color': AppColors.info, 'desc': 'Can wait a few days'},
    {'value': 'medium', 'label': 'Medium', 'color': AppColors.warning, 'desc': 'Needs attention soon'},
    {'value': 'high', 'label': 'High', 'color': AppColors.error, 'desc': 'Urgent, affects daily life'},
  ];

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (_imageUrls.length >= 4) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Maximum 4 images allowed'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    // Let tenant choose camera or gallery
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text('Add Photo', style: AppTextStyles.h4),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildImageSourceOption(
                  ctx: ctx,
                  icon: Icons.camera_alt_rounded,
                  label: 'Camera',
                  source: ImageSource.camera,
                ),
                _buildImageSourceOption(
                  ctx: ctx,
                  icon: Icons.photo_library_rounded,
                  label: 'Gallery',
                  source: ImageSource.gallery,
                ),
              ],
            ),
            SizedBox(height: MediaQuery.of(ctx).padding.bottom + 16),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: source,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      if (image == null) return;

      setState(() => _isUploadingImage = true);

      // Use PropertyService.uploadImage (cloudinary_public)
      final url = await _propertyService.uploadImage(File(image.path));

      if (url != null && mounted) {
        setState(() {
          _imageUrls.add(url);
          _isUploadingImage = false;
        });
      } else {
        if (mounted) {
          setState(() => _isUploadingImage = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Failed to upload image. Try again.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      }
    } catch (e) {
      developer.log('❌ Error picking image: $e', name: 'ReportIssue');
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Widget _buildImageSourceOption({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required ImageSource source,
  }) {
    return GestureDetector(
      onTap: () => Navigator.pop(ctx, source),
      child: Column(
        children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(26),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: AppColors.primary, size: 32),
          ),
          const SizedBox(height: 8),
          Text(label, style: AppTextStyles.labelMedium),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      final currentUserId = _authService.currentUserId;

      await FirebaseFirestore.instance.collection('issues').add({
        'rentalId': '' ,
        'propertyId': widget.propertyId,
        'tenantId': widget.tenantId,
        'landlordId': widget.landlordId,
        'propertyTitle': widget.propertyTitle,
        'tenantName': widget.tenantName,
        'landlordName': widget.landlordName,
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'category': _selectedCategory,
        'priority': _selectedPriority,
        'images': _imageUrls,
        'status': 'open',
        'reportedBy': currentUserId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify landlord
      await FirebaseFirestore.instance.collection('activities').add({
        'landlordId': widget.landlordId,
        'type': 'issue_reported',
        'title': 'New Issue Reported',
        'message':
            '${widget.tenantName} reported a $_selectedCategory issue at ${widget.propertyTitle}.',
        'propertyId': widget.propertyId,
        'actorId': widget.tenantId,
        'actorName': widget.tenantName,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Issue reported! Your landlord has been notified.'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));

      context.pop();
    } catch (e) {
      developer.log('❌ Error submitting issue: $e', name: 'ReportIssue');
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Failed to submit. Please try again.'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
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
        title: Text('Report Issue', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: Form(
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
                      style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),

              const SizedBox(height: 24),

              // ── Category ──
              Text('Category', style: AppTextStyles.labelLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _categories.map((cat) {
                  final selected = _selectedCategory == cat['value'];
                  return ChoiceChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(cat['icon'] as IconData,
                            size: 16,
                            color: selected ? Colors.white : AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(cat['label'] as String),
                      ],
                    ),
                    selected: selected,
                    onSelected: (_) =>
                        setState(() => _selectedCategory = cat['value'] as String),
                    selectedColor: AppColors.primary,
                    backgroundColor: AppColors.surface,
                    labelStyle: AppTextStyles.labelMedium.copyWith(
                      color: selected ? Colors.white : AppColors.textSecondary,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                          color: selected ? AppColors.primary : AppColors.border),
                    ),
                    showCheckmark: false,
                  );
                }).toList(),
              ),

              const SizedBox(height: 24),

              // ── Title ──
              Text('Issue Title', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  hintText: 'e.g. Leaking kitchen faucet',
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
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Please describe the issue' : null,
              ),

              const SizedBox(height: 24),

              // ── Description ──
              Text('Description', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              TextFormField(
                controller: _descriptionController,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText:
                      'Describe the issue in detail. When did it start? How bad is it?',
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
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Please provide details' : null,
              ),

              const SizedBox(height: 24),

              // ── Priority ──
              Text('Priority', style: AppTextStyles.labelLarge),
              const SizedBox(height: 12),
              ...(_priorities.map((p) {
                final selected = _selectedPriority == p['value'];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () => setState(() => _selectedPriority = p['value'] as String),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: selected
                            ? (p['color'] as Color).withAlpha(13)
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? (p['color'] as Color)
                              : AppColors.border,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Row(children: [
                        Icon(
                          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: selected ? p['color'] as Color : AppColors.textHint,
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p['label'] as String,
                                  style: AppTextStyles.labelMedium.copyWith(
                                    color: selected
                                        ? p['color'] as Color
                                        : AppColors.textPrimary,
                                  )),
                              Text(p['desc'] as String,
                                  style: AppTextStyles.caption
                                      .copyWith(color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  ),
                );
              })),

              const SizedBox(height: 24),

              // ── Photos ──
              Text('Photos (optional)', style: AppTextStyles.labelLarge),
              const SizedBox(height: 4),
              Text('Add up to 4 photos to help describe the issue.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  ..._imageUrls.asMap().entries.map((entry) {
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            entry.value,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 80,
                              height: 80,
                              color: AppColors.border,
                              child: const Icon(Icons.broken_image),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: GestureDetector(
                            onTap: () => setState(() => _imageUrls.removeAt(entry.key)),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: AppColors.error,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                  if (_imageUrls.length < 4)
                    GestureDetector(
                      onTap: _isUploadingImage ? null : _pickImage,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppColors.border, style: BorderStyle.solid),
                        ),
                        child: _isUploadingImage
                            ? Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: AppColors.primary),
                                ),
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      size: 28, color: AppColors.textHint),
                                  Text('Add',
                                      style: TextStyle(
                                          fontSize: 12, color: AppColors.textHint)),
                                ],
                              ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 32),

              // ── Submit ──
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    disabledBackgroundColor: AppColors.primary.withAlpha(128),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Submit Report',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}