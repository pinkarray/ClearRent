import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/data/mock_properties.dart';
import '../../../../shared/models/property_model.dart';
import '../../../property/presentation/widgets/property_card.dart';
import '../../../chat/presentation/widgets/messages_tab.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/saved_properties_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/widgets/connectivity_wrapper.dart';
import '../../../../services/active_rental_service.dart';
import '../widgets/tenant_rental_dashboard.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../../../../shared/widgets/user_avatar.dart';


class TenantHomeScreen extends StatefulWidget {
  const TenantHomeScreen({super.key});

  @override
  State<TenantHomeScreen> createState() => _TenantHomeScreenState();
}

class _TenantHomeScreenState extends State<TenantHomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  
  // Services
  late final AuthService _authService;
  late final SavedPropertiesService _savedService;
  late final ConversationService _conversationService;
  late final PropertyService _propertyService;
  late final ActiveRentalService _activeRentalService;

  // Saved properties - from Firebase
  Set<String> _savedProperties = {};
  bool _isLoadingSaved = true;

  // Unread messages count
  int _unreadCount = 0;

  int _currentNavIndex = 0;
  String _selectedType = 'all';
  String _selectedArea = 'All Areas';
  
  // Properties - combined real + mock
  List<PropertyModel> _realProperties = [];
  List<PropertyModel> _allProperties = [];
  List<PropertyModel> _filteredProperties = [];
  bool _isLoadingProperties = true;

  // Active rental
  ActiveRental? _activeRental;
  bool _isLoadingRental = true;
  
  DateTime? _lastBackPressed;

  // User data
  String _userName = '';
  String? _profileImageUrl;
  File? _localProfileImage;
  bool _isUploadingImage = false;
  bool _isLoadingProfile = true;

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _savedService = SavedPropertiesService();
    _conversationService = ConversationService();
    _propertyService = PropertyService();
    _activeRentalService = ActiveRentalService();
    _loadUserProfile();
    _loadSavedProperties();
    _loadUnreadCount();
    _loadProperties();
    _loadActiveRental();
  }

  Future<void> _loadUserProfile() async {
    try {
      final profile = await _authService.getUserProfile();
      if (profile != null && mounted) {
        setState(() {
          _userName = profile['fullName'] ?? 'Tenant';
          _profileImageUrl = profile['profileImageUrl'];
          _isLoadingProfile = false;
        });
      } else {
        setState(() {
          _userName = 'Tenant';
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading profile: $e');
      setState(() {
        _userName = 'Tenant';
        _isLoadingProfile = false;
      });
    }
  }

  Future<void> _loadSavedProperties() async {
    try {
      final savedIds = await _savedService.getSavedPropertyIds();
      if (mounted) {
        setState(() {
          _savedProperties = savedIds;
          _isLoadingSaved = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading saved properties: $e');
      setState(() => _isLoadingSaved = false);
    }
  }

  Future<void> _pickProfileImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              Text('Profile Photo', style: AppTextStyles.h4),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _buildSourceOption(
                  icon: Icons.camera_alt_rounded, label: 'Camera',
                  onTap: () => Navigator.pop(ctx, ImageSource.camera),
                ),
                _buildSourceOption(
                  icon: Icons.photo_library_rounded, label: 'Gallery',
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
                if (_profileImageUrl != null)
                  _buildSourceOption(
                    icon: Icons.delete_outline, label: 'Remove',
                    onTap: () => Navigator.pop(ctx, null),
                    color: AppColors.error,
                  ),
              ]),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );

    if (source == null && _profileImageUrl != null) {
      setState(() => _isUploadingImage = true);
      final removed = await _authService.removeProfileImage();
      if (mounted && removed) {
        setState(() {
          _profileImageUrl = null;
          _localProfileImage = null;
          _isUploadingImage = false;
        });
      } else {
        setState(() => _isUploadingImage = false);
      }
      return;
    }

    if (source == null) return;

    try {
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;

      final file = File(image.path);
      setState(() {
        _localProfileImage = file;
        _isUploadingImage = true;
      });

      final url = await _authService.uploadProfileImage(file);
      if (mounted) {
        setState(() {
          if (url != null) {
            _profileImageUrl = url;
            _localProfileImage = null;
          }
          _isUploadingImage = false;
        });
        if (url != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Profile photo updated!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      }
    } catch (e) {
      debugPrint('❌ Error picking profile image: $e');
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Widget _buildSourceOption({required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: (color ?? AppColors.primary).withAlpha(26),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: color ?? AppColors.primary, size: 32),
        ),
        const SizedBox(height: 8),
        Text(label, style: AppTextStyles.labelMedium.copyWith(
          color: color ?? AppColors.textPrimary)),
      ]),
    );
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await _conversationService.getTotalUnreadCount();
      if (mounted) {
        setState(() => _unreadCount = count);
      }
    } catch (e) {
      debugPrint('❌ Error loading unread count: $e');
    }
  }

  /// Load properties from verified landlords + mock data
  Future<void> _loadProperties() async {
    setState(() => _isLoadingProperties = true);
    
    try {
      // Fetch real properties from verified landlords
      final realProps = await _propertyService.getAvailableProperties();
      
      if (mounted) {
        setState(() {
          _realProperties = realProps;
          
          // Combine real properties with mock data
          // Real properties come first, then mock data
          _allProperties = [
            ..._realProperties,
            ...mockProperties,
          ];
          
          // Remove any duplicates by ID (in case mock data overlaps)
          final seenIds = <String>{};
          _allProperties = _allProperties.where((p) {
            if (seenIds.contains(p.id)) {
              return false;
            }
            seenIds.add(p.id);
            return true;
          }).toList();
          
          _isLoadingProperties = false;
        });
        
        // Apply initial filters
        _filterProperties();
      }
    } catch (e) {
      debugPrint('❌ Error loading properties: $e');
      if (mounted) {
        setState(() {
          // Fall back to mock data only
          _allProperties = mockProperties;
          _isLoadingProperties = false;
        });
        _filterProperties();
      }
    }
  }
  Future<void> _loadActiveRental() async {
     try {
       final rental = await _activeRentalService.getTenantActiveRental();
       if (mounted) {
         setState(() {
           _activeRental = rental;
           _isLoadingRental = false;
         });
       }
     } catch (e) {
       debugPrint('❌ Error loading active rental: $e');
       if (mounted) setState(() => _isLoadingRental = false);
    }
  }

  String get _firstName {
    final parts = _userName.split(' ');
    return parts.isNotEmpty ? parts.first : _userName;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    if (_currentNavIndex != 0) {
      setState(() => _currentNavIndex = 0);
      return false;
    }
    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Press back again to exit'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return false;
    }
    return true;
  }

  void _filterProperties() {
    setState(() {
      _filteredProperties = _allProperties.where((property) {
        // Type filter
        if (_selectedType != 'all' && property.propertyType != _selectedType) {
          return false;
        }
        // Area filter
        if (_selectedArea != 'All Areas' && property.city != _selectedArea) {
          return false;
        }
        // Search filter
        if (_searchController.text.isNotEmpty) {
          final query = _searchController.text.toLowerCase();
          return property.title.toLowerCase().contains(query) ||
              property.city.toLowerCase().contains(query) ||
              property.address.toLowerCase().contains(query);
        }
        return true;
      }).toList();
    });
  }

  Future<void> _toggleSave(String propertyId) async {
    // Optimistic update
    final wasSaved = _savedProperties.contains(propertyId);
    setState(() {
      if (wasSaved) {
        _savedProperties.remove(propertyId);
      } else {
        _savedProperties.add(propertyId);
      }
    });

    // Persist to Firebase
    bool success;
    if (wasSaved) {
      success = await _savedService.unsaveProperty(propertyId);
    } else {
      success = await _savedService.saveProperty(propertyId);
    }

    // Revert if failed
    if (!success && mounted) {
      setState(() {
        if (wasSaved) {
          _savedProperties.add(propertyId);
        } else {
          _savedProperties.remove(propertyId);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Failed to update saved properties'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  void _openPropertyDetail(PropertyModel property) {
    context.push('/property-detail', extra: property);
  }

  Future<void> _refreshData() async {
    await Future.wait([
      _loadProperties(),
      _loadSavedProperties(),
      _loadUnreadCount(),
      _loadActiveRental(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: ConnectivityWrapper(
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: _currentNavIndex == 0
              ? SafeArea(child: _buildHomeTab())
              : _currentNavIndex == 1
                  ? SafeArea(child: _buildSavedTab())
                  : _currentNavIndex == 2
                      ? SafeArea(child: _buildMessagesTab())
                      : _buildProfileTab(),
          bottomNavigationBar: _buildBottomNav(),
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
   // Show rental dashboard if tenant has active rental
   if (!_isLoadingRental && _activeRental != null) {
     return TenantRentalDashboard(
       rental: _activeRental!,
       userName: _userName,
       userInitial: _userName.isNotEmpty ? _userName[0].toUpperCase() : 'T',
       isLoadingProfile: _isLoadingProfile,
       onBrowseProperties: () {
         // Switch to a "browse mode" — for now just show snackbar
         // Later you could add a toggle or separate screen
         setState(() => _activeRental = null); // Temporarily show browse
        },
      );
    }

     // Default: property browsing
    return RefreshIndicator(
     onRefresh: _refreshData,
     color: AppColors.primary,
     child: Column(
       children: [
         _buildHeader(),
         _buildSearchBar(),
         _buildFilters(),
         Expanded(
           child: _isLoadingProperties
               ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
               : _filteredProperties.isEmpty
                   ? _buildEmptyState()
                   : _buildPropertyList(),
         ),
        ],
      ),
    );
  }

  Widget _buildSavedTab() {
    // Combine real and mock properties to find saved ones
    final allPropsMap = {for (var p in _allProperties) p.id: p};
    final savedList = _savedProperties
        .where((id) => allPropsMap.containsKey(id))
        .map((id) => allPropsMap[id]!)
        .toList();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Text('Saved Properties', style: AppTextStyles.h2),
              const Spacer(),
              if (!_isLoadingSaved && savedList.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${savedList.length}',
                    style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _isLoadingSaved
              ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
              : savedList.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: AppColors.error.withAlpha(26),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.favorite_outline, size: 48, color: AppColors.error),
                          ),
                          const SizedBox(height: 20),
                          Text('No saved properties yet',
                              style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary)),
                          const SizedBox(height: 8),
                          Text('Tap the heart icon on any property\nto save it for later',
                              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
                              textAlign: TextAlign.center),
                          const SizedBox(height: 24),
                          TextButton.icon(
                            onPressed: () => setState(() => _currentNavIndex = 0),
                            icon: const Icon(Icons.search),
                            label: const Text('Browse Properties'),
                            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadSavedProperties,
                      color: AppColors.primary,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        itemCount: savedList.length,
                        itemBuilder: (context, index) {
                          final property = savedList[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: PropertyCard(
                              property: property,
                              isSaved: true,
                              onTap: () => _openPropertyDetail(property),
                              onSave: () => _toggleSave(property.id),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  /// UPDATED: Now uses real Firestore messages
  Widget _buildMessagesTab() {
    return const MessagesTabReal(
      emptyTitle: 'No messages yet',
      emptySubtitle: 'Your conversations with landlords\nwill appear here',
    );
  }

  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: AppColors.surface,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Profile', style: AppTextStyles.h3),
                        GestureDetector(
                          onTap: () => context.push('/settings'),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.settings_outlined, color: AppColors.textPrimary, size: 20),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    Row(
                      children: [
                        UserAvatar(
                          name: _userName,
                          imageUrl: _profileImageUrl,
                          imageFile: _localProfileImage,
                          size: 80,
                          showEditBadge: !_isLoadingProfile && !_isUploadingImage,
                          onTap: _pickProfileImage,
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _isLoadingProfile
                                  ? Container(
                                      width: 100,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: AppColors.border,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    )
                                  : Text(_userName, style: AppTextStyles.h3),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withAlpha(26),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.person, size: 14, color: AppColors.primary),
                                    const SizedBox(width: 4),
                                    Text('Tenant', style: AppTextStyles.labelSmall.copyWith(color: AppColors.primary)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => context.push('/edit-profile'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              border: Border.all(color: AppColors.primary),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('Edit', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: _TenantStatCard(
                    icon: Icons.favorite_outline,
                    value: _isLoadingSaved ? '...' : '${_savedProperties.length}',
                    label: 'Saved',
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TenantStatCard(
                    icon: Icons.home_outlined,
                    value: _activeRental != null ? '1' : '0',
                    label: 'Rentals',
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TenantStatCard(
                    icon: Icons.chat_bubble_outline,
                    value: '$_unreadCount',
                    label: 'Unread',
                    color: AppColors.info,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TenantProfileSection(
                  title: 'Activity',
                  items: [
                    _TenantProfileMenuItem(
                      icon: Icons.event_note_outlined,
                      title: 'My Inspections',
                      subtitle: 'Track your inspection requests',
                      onTap: () => context.push('/tenant/inspections'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.favorite_outline,
                      title: 'Saved Properties',
                      subtitle: '${_savedProperties.length} properties saved',
                      onTap: () => setState(() => _currentNavIndex = 1),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.verified_user_outlined,
                      title: 'Verification',
                      subtitle: 'Verify your identity',
                      onTap: () => context.push('/tenant/verification'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.history,
                      title: 'My Rentals',
                      subtitle: 'View your rental history',
                      onTap: () => context.push('/tenant/my-rentals'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.payment_outlined,
                      title: 'Payment History',
                      subtitle: 'View all your payments',
                      onTap: () => context.push('/tenant/payment-history'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.description_outlined,
                      title: 'Documents',
                      subtitle: 'Rental agreements and receipts',
                      onTap: () => context.push('/tenant/documents'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _TenantProfileSection(
                  title: 'Support',
                  items: [
                    _TenantProfileMenuItem(
                      icon: Icons.help_outline,
                      title: 'Help & Support',
                      subtitle: 'FAQs and contact us',
                      onTap: () => context.push('/help-support'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.info_outline,
                      title: 'About ClearRent',
                      subtitle: 'Version 1.0.0',
                      onTap: () => context.push('/about'),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Center(
                  child: Column(
                    children: [
                      Text('ClearRent', style: AppTextStyles.labelLarge.copyWith(color: AppColors.textHint)),
                      const SizedBox(height: 4),
                      Text('Rent Without Regret',
                          style: AppTextStyles.caption.copyWith(color: AppColors.textHint, fontStyle: FontStyle.italic)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _isLoadingProfile
                    ? Container(
                        width: 120,
                        height: 16,
                        decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(4)),
                      )
                    : Text('Hello, $_firstName 👋',
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text(
                  _activeRental != null
                      ? 'Browse more properties'
                      : 'Find your perfect space',
                  style: AppTextStyles.h3,
                ),
              ],
            ),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Stack(
              children: [
                const Center(child: Icon(Icons.notifications_outlined, color: AppColors.textPrimary)),
                if (_unreadCount > 0)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (_) => _filterProperties(),
          decoration: InputDecoration(
            hintText: AppStrings.searchProperties,
            hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
            prefixIcon: const Icon(Icons.search, color: AppColors.textHint),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, color: AppColors.textHint),
                    onPressed: () {
                      _searchController.clear();
                      _filterProperties();
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: propertyTypes.length,
            itemBuilder: (context, index) {
              final type = propertyTypes[index];
              final isSelected = _selectedType == type['value'];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(type['label']!),
                  selected: isSelected,
                  onSelected: (_) {
                    setState(() => _selectedType = type['value']!);
                    _filterProperties();
                  },
                  backgroundColor: AppColors.surface,
                  selectedColor: AppColors.primary.withAlpha(26),
                  checkmarkColor: AppColors.primary,
                  labelStyle: AppTextStyles.labelMedium.copyWith(
                    color: isSelected ? AppColors.primary : AppColors.textSecondary,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButton<String>(
                    underline: const SizedBox.shrink(),
                    value: _selectedArea,
                    isExpanded: true,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    style: AppTextStyles.bodyMedium,
                    items: lagosAreas.map((area) {
                      return DropdownMenuItem(value: area, child: Text(area));
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedArea = value);
                        _filterProperties();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                height: 44,
                width: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.tune, color: Colors.white, size: 20),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text('${_filteredProperties.length} properties found', style: AppTextStyles.bodySmall),
              // Show badge if real properties are available
              if (_realProperties.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_realProperties.length} verified',
                    style: AppTextStyles.caption.copyWith(color: AppColors.success),
                  ),
                ),
              ],
              const Spacer(),
              Text('Sort by: ', style: AppTextStyles.bodySmall),
              Text('Newest', style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary)),
              const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.primary),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildPropertyList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: _filteredProperties.length,
      itemBuilder: (context, index) {
        final property = _filteredProperties[index];
        final isRealProperty = _realProperties.any((p) => p.id == property.id);
        
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Stack(
            children: [
              PropertyCard(
                property: property,
                isSaved: _savedProperties.contains(property.id),
                onTap: () => _openPropertyDetail(property),
                onSave: () => _toggleSave(property.id),
              ),
              // Show "Verified" badge for real properties
              if (isRealProperty)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.verified, size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                        Text(
                          'Verified',
                          style: AppTextStyles.labelSmall.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: AppColors.textHint),
          const SizedBox(height: 16),
          Text(AppStrings.noProperties, style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Text('Try adjusting your filters', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint)),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(13), blurRadius: 10, offset: const Offset(0, -5))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
                label: 'Home',
                isActive: _currentNavIndex == 0,
                onTap: () => setState(() => _currentNavIndex = 0),
              ),
              _NavItem(
                icon: Icons.favorite_outline,
                activeIcon: Icons.favorite,
                label: 'Saved',
                isActive: _currentNavIndex == 1,
                onTap: () => setState(() => _currentNavIndex = 1),
                badge: _savedProperties.isNotEmpty ? '${_savedProperties.length}' : null,
              ),
              _NavItem(
                icon: Icons.chat_bubble_outline,
                activeIcon: Icons.chat_bubble,
                label: 'Messages',
                isActive: _currentNavIndex == 2,
                onTap: () {
                  setState(() {
                    _currentNavIndex = 2;
                    // Refresh unread count when opening messages
                    _loadUnreadCount();
                  });
                },
                badge: _unreadCount > 0 ? '$_unreadCount' : null,
              ),
              _NavItem(
                icon: Icons.person_outline,
                activeIcon: Icons.person,
                label: 'Profile',
                isActive: _currentNavIndex == 3,
                onTap: () => setState(() => _currentNavIndex = 3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final String? badge;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(isActive ? activeIcon : icon, color: isActive ? AppColors.primary : AppColors.textHint, size: 24),
                if (badge != null)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                      child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(label,
                style: AppTextStyles.labelSmall.copyWith(
                  color: isActive ? AppColors.primary : AppColors.textHint,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                )),
          ],
        ),
      ),
    );
  }
}

class _TenantStatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _TenantStatCard({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withAlpha(26), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(value, style: AppTextStyles.h4),
          const SizedBox(height: 2),
          Text(label, style: AppTextStyles.caption),
        ],
      ),
    );
  }
}

class _TenantProfileSection extends StatelessWidget {
  final String title;
  final List<Widget> items;

  const _TenantProfileSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(title, style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: items.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              return Column(children: [item, if (index < items.length - 1) const Divider(height: 1, indent: 52)]);
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _TenantProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _TenantProfileMenuItem({required this.icon, required this.title, this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: AppColors.textSecondary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppTextStyles.caption)],
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textHint, size: 20),
          ],
        ),
      ),
    );
  }
}