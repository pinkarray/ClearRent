import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';

class AgentServiceAreasScreen extends StatefulWidget {
  const AgentServiceAreasScreen({super.key});

  @override
  State<AgentServiceAreasScreen> createState() => _AgentServiceAreasScreenState();
}

class _AgentServiceAreasScreenState extends State<AgentServiceAreasScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  List<String> _selectedAreas = [];
  String _baseLocation = '';
  String _searchQuery = '';

  // Popular Lagos areas (can be expanded)
  final List<String> _lagosAreas = [
    'Ikeja',
    'Lekki',
    'Victoria Island',
    'Ikoyi',
    'Surulere',
    'Yaba',
    'Gbagada',
    'Maryland',
    'Ojodu',
    'Ogba',
    'Magodo',
    'Ajah',
    'Sangotedo',
    'Ikorodu',
    'Festac',
    'Amuwo Odofin',
    'Apapa',
    'Isolo',
    'Oshodi',
    'Mushin',
    'Ikotun',
    'Egbeda',
    'Alimosho',
    'Agege',
    'Ifako-Ijaiye',
    'Berger',
    'Omole',
    'Isheri',
    'Oregun',
    'Alausa',
    'Anthony',
    'Palmgrove',
    'Bariga',
    'Shomolu',
    'Ogudu',
    'Ketu',
    'Mile 12',
    'Ojota',
    'Obalende',
    'Marina',
    'Lagos Island',
    'Epe',
    'Badagry',
  ];

  @override
  void initState() {
    super.initState();
    _loadServiceAreas();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadServiceAreas() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      final data = doc.data();

      if (data != null) {
        setState(() {
          _selectedAreas = List<String>.from(data['serviceAreas'] ?? []);
          _baseLocation = data['baseLocation'] ?? '';
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('❌ Error loading service areas: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveServiceAreas() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    if (_selectedAreas.isEmpty) {
      _showError('Please select at least one service area');
      return;
    }

    setState(() => _isSaving = true);

    try {
      await _firestore.collection('users').doc(userId).update({
        'serviceAreas': _selectedAreas,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Service areas saved successfully!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        context.pop();
      }
    } catch (e) {
      debugPrint('❌ Error saving service areas: $e');
      _showError('Failed to save service areas. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _toggleArea(String area) {
    setState(() {
      if (_selectedAreas.contains(area)) {
        _selectedAreas.remove(area);
      } else {
        _selectedAreas.add(area);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedAreas = List.from(_filteredAreas);
    });
  }

  void _clearAll() {
    setState(() {
      _selectedAreas.clear();
    });
  }

  List<String> get _filteredAreas {
    if (_searchQuery.isEmpty) {
      return _lagosAreas;
    }
    return _lagosAreas
        .where((area) => area.toLowerCase().contains(_searchQuery))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Service Areas', style: AppTextStyles.h4),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveServiceAreas,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  )
                : Text(
                    'Save',
                    style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
                  ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : Column(
              children: [
                // Info and base location
                Container(
                  padding: const EdgeInsets.all(16),
                  color: AppColors.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Info card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.info.withAlpha(26),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.info.withAlpha(77)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, color: AppColors.info, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Select areas you can conduct inspections. Landlords will see you when searching for agents in these areas.',
                                style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Base location
                      if (_baseLocation.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(26),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withAlpha(51),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.home, color: AppColors.primary, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Base Location',
                                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                                    ),
                                    Text(_baseLocation, style: AppTextStyles.labelMedium),
                                  ],
                                ),
                              ),
                              if (!_selectedAreas.contains(_baseLocation))
                                TextButton(
                                  onPressed: () => _toggleArea(_baseLocation),
                                  child: const Text('Add'),
                                ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 12),

                      // Search
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Search areas...',
                          hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
                          prefixIcon: const Icon(Icons.search, color: AppColors.textHint),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  onPressed: () {
                                    _searchController.clear();
                                  },
                                  icon: const Icon(Icons.close, color: AppColors.textHint),
                                )
                              : null,
                          filled: true,
                          fillColor: AppColors.background,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                      ),
                    ],
                  ),
                ),

                // Selection header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Text(
                        '${_selectedAreas.length} selected',
                        style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _selectAll,
                        child: Text(
                          'Select All',
                          style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                      TextButton(
                        onPressed: _clearAll,
                        child: Text(
                          'Clear',
                          style: AppTextStyles.labelSmall.copyWith(color: AppColors.error),
                        ),
                      ),
                    ],
                  ),
                ),

                // Areas grid
                Expanded(
                  child: _filteredAreas.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.search_off, size: 48, color: AppColors.textHint),
                              const SizedBox(height: 16),
                              Text(
                                'No areas found',
                                style: AppTextStyles.labelLarge.copyWith(color: AppColors.textSecondary),
                              ),
                              Text(
                                'Try a different search term',
                                style: AppTextStyles.bodySmall.copyWith(color: AppColors.textHint),
                              ),
                            ],
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 2.8,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: _filteredAreas.length,
                          itemBuilder: (context, index) {
                            final area = _filteredAreas[index];
                            final isSelected = _selectedAreas.contains(area);
                            final isBase = area == _baseLocation;

                            return GestureDetector(
                              onTap: () => _toggleArea(area),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppColors.primary.withAlpha(26)
                                      : AppColors.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected ? AppColors.primary : AppColors.border,
                                    width: isSelected ? 2 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const SizedBox(width: 12),
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: isSelected ? AppColors.primary : Colors.transparent,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: isSelected ? AppColors.primary : AppColors.textHint,
                                          width: 2,
                                        ),
                                      ),
                                      child: isSelected
                                          ? const Icon(Icons.check, color: Colors.white, size: 14)
                                          : null,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              area,
                                              style: AppTextStyles.labelMedium.copyWith(
                                                color: isSelected ? AppColors.primary : AppColors.textPrimary,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (isBase) ...[
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.home,
                                              size: 14,
                                              color: isSelected ? AppColors.primary : AppColors.textHint,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(13),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          child: AppButton(
            text: 'Save Service Areas',
            onPressed: _isSaving ? null : _saveServiceAreas,
            isLoading: _isSaving,
          ),
        ),
      ),
    );
  }
}