import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/utils/app_info.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../shared/models/tenancy_link_model.dart';
import '../../../property/presentation/widgets/property_card.dart';
import '../../../chat/presentation/widgets/messages_tab.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/saved_properties_service.dart';
import '../../../../services/conversation_service.dart';
import '../../../../services/property_service.dart';
import '../../../../services/verification_service.dart';
import '../../../../services/tenancy_link_service.dart';
import '../../../../services/agreement_access_service.dart';
import '../../../../services/active_rental_service.dart';
import '../../../../services/inspection_service.dart';
import '../../../../shared/models/active_rental_model.dart';
import '../../../../shared/models/inspection_request_model.dart';
import '../../../../shared/widgets/capsule_nav.dart';
import '../../../../shared/widgets/option_picker_sheet.dart';
import '../../../../shared/widgets/user_avatar.dart';
import '../../../../shared/widgets/verification_badge.dart';
import '../../../../shared/widgets/notification_bell.dart';
import '../widgets/tenant_rental_dashboard.dart';
import '../widgets/multi_rental_dashboard.dart';
import '../widgets/linked_rent_due_card.dart';
import '../../../../shared/models/tenant_rental.dart';
import '../../../../shared/widgets/announcements_banner.dart';
import 'dart:io';
import 'dart:async';
import 'package:image_picker/image_picker.dart';

const List<Map<String, String>> propertyTypes = [
  {'label': 'All', 'value': 'all'},
  {'label': 'Flat', 'value': 'flat'},
  {'label': 'Duplex', 'value': 'duplex'},
  {'label': 'Bungalow', 'value': 'bungalow'},
  {'label': 'Self Contain', 'value': 'self_contain'},
  {'label': 'Room & Parlour', 'value': 'room_and_parlour'},
  {'label': 'Studio', 'value': 'studio'},
  {'label': 'Mansion', 'value': 'mansion'},
];

const List<String> lagosAreas = [
  'All Areas',
  'Ikeja',
  'Victoria Island',
  'Lekki',
  'Ajah',
  'Surulere',
  'Yaba',
  'Maryland',
  'Magodo',
  'GRA Ikeja',
  'Gbagada',
  'Ikoyi',
  'Oniru',
  'Ikorodu',
  'Badagry',
  'Epe',
  'Ojota',
  'Ketu',
  'Mile 12',
  'Agege',
  'Alimosho',
  'Isolo',
  'Mushin',
  'Oshodi',
  'Apapa',
  'Ajegunle',
];

class TenantHomeScreen extends StatefulWidget {
  /// Which bottom-nav tab to open on (0 = Home/dashboard). Lets callers land the
  /// tenant on the dashboard rather than whatever tab a reused home instance was
  /// last on — e.g. "Go to My Home" after paying rent must not land on Profile.
  final int initialTab;
  const TenantHomeScreen({super.key, this.initialTab = 0});

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
  late final TenancyLinkService _tenancyLinkService;
  final AgreementAccessService _agreementAccess = AgreementAccessService();
  final InspectionService _inspectionService = InspectionService();
  StreamSubscription<ActiveRental?>? _activeRentalSub;
  // Approved inspections for the tenant — powers the "inspection today" banner
  // on the home tab. Created once in initState (see cached-streams note below).
  late final Stream<List<InspectionRequest>> _inspectionsStream;

  // Cached streams for the home body. Created ONCE in initState — the many
  // init-time setState() calls (profile, saved, unread, properties, rental
  // count, active rental) rebuild this screen repeatedly, and if these streams
  // were created inside build() each rebuild would hand StreamBuilder a fresh
  // instance, resetting it to ConnectionState.waiting and flashing a spinner.
  // That was the "browse flickers ~3 times on login" bug.
  late final Stream<TenancyLinkModel?> _activeLinkStream;
  late final Stream<List<TenancyLinkModel>> _pendingLinksStream;
  // Tenant rentals are driven by a lifetime subscription (not a StreamBuilder):
  // this branch's widget subtree unmounts/remounts as the tenant switches nav
  // tabs, and a StreamBuilder re-listening to the stored single-subscription
  // stream threw "Stream has already been listened to". Caching the latest list
  // in state survives remounts.
  List<TenantRental> _tenantRentals = const [];
  bool _tenantRentalsLoaded = false;
  StreamSubscription<List<TenantRental>>? _tenantRentalsSub;
  // Saved properties
  Set<String> _savedProperties = {};
  /// Saved properties that browse does not carry — typically because they are
  /// no longer available. Keyed by id; see [_resolveSavedProperties].
  final Map<String, PropertyModel> _savedExtras = {};
  bool _isLoadingSaved = true;

  // Unread messages
  int _unreadCount = 0;

  int _currentNavIndex = 0;
  String _selectedType = 'all';
  String _selectedArea = 'All Areas';
  // "More filters" sheet (opened by the tune button). 0/empty = unset.
  double _minRent = 0;
  double _maxRent = 0; // 0 = no upper cap
  int _minBedrooms = 0;
  int _minBathrooms = 0;
  final Set<String> _filterAmenities = {};

  bool get _hasExtraFilters =>
      _minRent > 0 ||
      _maxRent > 0 ||
      _minBedrooms > 0 ||
      _minBathrooms > 0 ||
      _filterAmenities.isNotEmpty;

  // Properties
  List<PropertyModel> _realProperties = [];
  List<PropertyModel> _allProperties = [];
  List<PropertyModel> _filteredProperties = [];
  bool _isLoadingProperties = true;

  // Active rental (paid/contract-based)
  ActiveRental? _activeRental;
  // Count of the tenant's current active rentals — a tenant can hold more than
  // one (multi-rental), so the profile "Rentals" stat shows the real number.
  int _activeRentalCount = 0;
  bool _browsingFromDashboard =
      false; // true when user tapped "browse" from rental dashboard
  bool _browsingFromLinkedDashboard =
      false; // true when verified linked tenant taps browse

  DateTime? _lastBackPressed;

  // User data
  String _userName = '';
  String? _profileImageUrl;
  File? _localProfileImage;
  bool _isUploadingImage = false;
  bool _isLoadingProfile = true;

  VerificationStatus _verificationStatus = VerificationStatus.none;
  bool _hasBankDetails = false;

  @override
  void initState() {
    super.initState();
    _currentNavIndex = widget.initialTab;
    _authService = AuthService();
    _savedService = SavedPropertiesService();
    _conversationService = ConversationService();
    _propertyService = PropertyService();
    _activeRentalService = ActiveRentalService();
    _tenancyLinkService = TenancyLinkService();
    _activeLinkStream = _tenancyLinkService.tenantActiveLinkStream();
    _pendingLinksStream = _tenancyLinkService.tenantPendingLinksStream();
    _inspectionsStream = _inspectionService.getTenantRequests();
    _tenantRentalsSub = _activeRentalService.streamTenantRentals().listen((
      rentals,
    ) {
      if (mounted) {
        setState(() {
          _tenantRentals = rentals;
          _tenantRentalsLoaded = true;
        });
      }
    });
    _loadUserProfile();
    _loadSavedProperties();
    _loadUnreadCount();
    _loadProperties();
    _activeRentalSub = _activeRentalService.streamTenantActiveRental().listen((
      rental,
    ) {
      if (mounted) setState(() => _activeRental = rental);
    });
    _loadActiveRentalCount();
  }

  /// Counts the tenant's current (non-ended) active rentals for the profile
  /// "Rentals" stat. A tenant may hold several at once.
  Future<void> _loadActiveRentalCount() async {
    final rentals = await _activeRentalService.getTenantRentals();
    if (!mounted) return;
    final count =
        rentals
            .where(
              (r) =>
                  r.isActive ||
                  r.isExpiringSoon ||
                  r.isGraceLocked ||
                  r.isMoveoutPending,
            )
            .length;
    setState(() => _activeRentalCount = count);
  }

  @override
  void dispose() {
    _activeRentalSub?.cancel();
    _tenantRentalsSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ── DATA LOADING ──────────────────────────────────────────────────────────

  Future<void> _loadVerificationStatus() => _loadUserProfile();

  Future<void> _loadUserProfile() async {
    try {
      final profile = await _authService.getUserProfile();
      if (profile != null && mounted) {
        // Parse verification status directly from Firestore — same field admin sets
        final status = profile['verificationStatus'] as String? ?? 'none';
        final isVerified = profile['isVerified'] == true;
        VerificationStatus verStatus;
        if (status == 'verified' || isVerified) {
          verStatus = VerificationStatus.verified;
        } else if (status == 'pending') {
          verStatus = VerificationStatus.pending;
        } else if (status == 'rejected') {
          verStatus = VerificationStatus.rejected;
        } else if (status == 'expired') {
          verStatus = VerificationStatus.expired;
        } else {
          verStatus = VerificationStatus.none;
        }
        setState(() {
          _userName = profile['fullName'] ?? 'Tenant';
          _profileImageUrl = profile['profileImageUrl'];
          _verificationStatus = verStatus;
          _isLoadingProfile = false;
          // Track bank details — C1: moved to the locked private/bank
          // subcollection; the user doc only carries this non-sensitive flag.
          _hasBankDetails = profile['hasBankDetails'] == true;
        });
      } else {
        if (mounted) {
          setState(() {
            _userName = 'Tenant';
            _isLoadingProfile = false;
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Error loading profile: $e');
      if (mounted) {
        setState(() {
          _userName = 'Tenant';
          _isLoadingProfile = false;
        });
      }
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
      await _resolveSavedProperties(savedIds);
    } catch (e) {
      debugPrint('❌ Error loading saved: $e');
      if (mounted) setState(() => _isLoadingSaved = false);
    }
  }

  /// Fetches the saved properties that browse does not carry.
  ///
  /// `_allProperties` holds AVAILABLE listings only, so intersecting the saved
  /// IDs with it silently dropped anything now let, delisted or paused — the
  /// tenant's own bookmark disappeared with no explanation, and the badge and
  /// the list disagreed about how many there were. The saved doc still exists
  /// in `users/{uid}/savedProperties`; only the rendering was lossy.
  ///
  /// A handful of point reads, and only for the ids browse is missing.
  Future<void> _resolveSavedProperties(Set<String> savedIds) async {
    final known = {for (final p in _allProperties) p.id};
    final missing = savedIds.where((id) => !known.contains(id)).toList();
    if (missing.isEmpty) {
      if (mounted && _savedExtras.isNotEmpty) {
        setState(() => _savedExtras.removeWhere((id, _) => !savedIds.contains(id)));
      }
      return;
    }

    final fetched = await Future.wait(missing.map(_propertyService.getProperty));
    if (!mounted) return;
    setState(() {
      _savedExtras.removeWhere((id, _) => !savedIds.contains(id));
      for (final p in fetched) {
        if (p != null) _savedExtras[p.id] = p;
      }
    });
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await _conversationService.getTotalUnreadCount();
      if (mounted) setState(() => _unreadCount = count);
    } catch (e) {
      debugPrint('❌ Error loading unread: $e');
    }
  }

  Future<void> _loadProperties() async {
    setState(() => _isLoadingProperties = true);
    try {
      final realProps = await _propertyService.getAvailableProperties();
      if (mounted) {
        setState(() {
          _realProperties = realProps;
          final seenIds = <String>{};
          _allProperties =
              _realProperties
                  .where((p) => seenIds.add(p.id))
                  .where((p) => p.isAvailable || p.hasAvailableSpots)
                  .toList();
          _isLoadingProperties = false;
        });
        _filterProperties();
      }
    } catch (e) {
      debugPrint('❌ Error loading properties: $e');
      if (mounted) {
        setState(() {
          _allProperties = [];
          _isLoadingProperties = false;
        });
        _filterProperties();
      }
    }
  }

  Future<void> _refreshData() async {
    await Future.wait([
      _loadProperties(),
      _loadSavedProperties(),
      _loadUnreadCount(),
    ]);
  }

  // ── PROFILE IMAGE ─────────────────────────────────────────────────────────

  Future<void> _pickProfileImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Profile Photo', style: AppTextStyles.h4),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildSourceOption(
                        icon: Icons.camera_alt_rounded,
                        label: 'Camera',
                        onTap: () => Navigator.pop(ctx, ImageSource.camera),
                      ),
                      _buildSourceOption(
                        icon: Icons.photo_library_rounded,
                        label: 'Gallery',
                        onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                      ),
                      if (_profileImageUrl != null)
                        _buildSourceOption(
                          icon: Icons.delete_outline,
                          label: 'Remove',
                          onTap: () => Navigator.pop(ctx, null),
                          color: AppColors.error,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
    );

    // Remove photo
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
        if (mounted) setState(() => _isUploadingImage = false);
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Profile photo updated!'),
              backgroundColor: AppColors.success,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error picking profile image: $e');
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Widget _buildSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: (color ?? AppColors.primary).withAlpha(26),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color ?? AppColors.primary, size: 32),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: AppTextStyles.labelMedium.copyWith(
              color: color ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  // ── NAVIGATION ────────────────────────────────────────────────────────────

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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return false;
    }
    return true;
  }

  void _filterProperties() {
    setState(() {
      _filteredProperties =
          _allProperties.where((property) {
            if (_selectedType != 'all' &&
                property.propertyType != _selectedType) {
              return false;
            }
            if (_selectedArea != 'All Areas' &&
                property.city != _selectedArea) {
              return false;
            }
            // More-filters (price / bedrooms / bathrooms / amenities).
            if (_minRent > 0 && property.rent < _minRent) return false;
            if (_maxRent > 0 && property.rent > _maxRent) return false;
            if (_minBedrooms > 0 && property.bedrooms < _minBedrooms) {
              return false;
            }
            if (_minBathrooms > 0 && property.bathrooms < _minBathrooms) {
              return false;
            }
            if (_filterAmenities.isNotEmpty &&
                !_filterAmenities.every(
                  (a) => property.amenities.contains(a),
                )) {
              return false;
            }
            if (_searchController.text.isNotEmpty) {
              final query = _searchController.text.toLowerCase();
              // Exact street address lives in the gated subdoc and isn't available
              // when browsing — match on the area-level fields only.
              return property.title.toLowerCase().contains(query) ||
                  property.city.toLowerCase().contains(query) ||
                  property.state.toLowerCase().contains(query);
            }
            return true;
          }).toList();
    });
  }

  /// Area filter — the shared height-capped bottom-sheet picker instead of a
  /// dropdown menu that balloons to cover the screen.
  void _showAreaPicker() {
    showOptionPicker(
      context,
      title: 'Filter by area',
      options: lagosAreas,
      selected: _selectedArea,
      searchHint: 'Search area...',
      iconBuilder:
          (option, _) =>
              option == 'All Areas' ? Icons.public : Icons.location_on_outlined,
      onSelected: (area) {
        setState(() => _selectedArea = area);
        _filterProperties();
      },
    );
  }

  /// Upper bound for the price slider — the highest rent in view, rounded up to
  /// the nearest ₦100k (with a sensible floor so the slider isn't degenerate).
  double get _rentBound {
    double maxR = 0;
    for (final p in _allProperties) {
      if (p.rent > maxR) maxR = p.rent;
    }
    if (maxR < 500000) return 500000;
    return (maxR / 100000).ceil() * 100000;
  }

  /// Amenities actually present across the listings in view, so the filter
  /// chips never offer an option that can't match anything.
  List<String> get _availableAmenities {
    final set = <String>{};
    for (final p in _allProperties) {
      set.addAll(p.amenities);
    }
    final list = set.toList()..sort();
    return list;
  }

  static String _fmtNaira(double v) {
    if (v >= 1000000) {
      final m = v / 1000000;
      return '₦${m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
    }
    if (v >= 1000) return '₦${(v / 1000).round()}k';
    return '₦${v.round()}';
  }

  /// "More filters" sheet behind the tune button: price range, bedrooms,
  /// bathrooms and amenities. Edits are local until Apply.
  void _showFiltersSheet() {
    final bound = _rentBound;
    final amenities = _availableAmenities;
    double tempMin = _minRent.clamp(0, bound).toDouble();
    double tempMax =
        (_maxRent == 0 ? bound : _maxRent).clamp(0, bound).toDouble();
    if (tempMax < tempMin) tempMax = bound;
    int tempBed = _minBedrooms;
    int tempBath = _minBathrooms;
    final tempAmenities = {..._filterAmenities};
    final divisions = (bound / 100000).round().clamp(1, 200);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            Widget chip(String label, bool selected, VoidCallback onTap) {
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primary : AppColors.background,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  child: Text(
                    label,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: selected ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ),
              );
            }

            Widget group(String title, Widget child) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  const SizedBox(height: 12),
                  child,
                  const SizedBox(height: 24),
                ],
              );
            }

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        Text('Filters', style: AppTextStyles.h4),
                        const Spacer(),
                        TextButton(
                          onPressed:
                              () => setSheet(() {
                                tempMin = 0;
                                tempMax = bound;
                                tempBed = 0;
                                tempBath = 0;
                                tempAmenities.clear();
                              }),
                          child: Text(
                            'Reset',
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          group(
                            'Price (per year)',
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_fmtNaira(tempMin)} — ${tempMax >= bound ? '${_fmtNaira(bound)}+' : _fmtNaira(tempMax)}',
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: AppColors.primary,
                                  ),
                                ),
                                RangeSlider(
                                  values: RangeValues(tempMin, tempMax),
                                  min: 0,
                                  max: bound,
                                  divisions: divisions,
                                  activeColor: AppColors.primary,
                                  labels: RangeLabels(
                                    _fmtNaira(tempMin),
                                    tempMax >= bound
                                        ? '${_fmtNaira(bound)}+'
                                        : _fmtNaira(tempMax),
                                  ),
                                  onChanged:
                                      (v) => setSheet(() {
                                        tempMin = v.start;
                                        tempMax = v.end;
                                      }),
                                ),
                              ],
                            ),
                          ),
                          group(
                            'Bedrooms',
                            Wrap(
                              spacing: 8,
                              children:
                                  [0, 1, 2, 3, 4].map((n) {
                                    return chip(
                                      n == 0 ? 'Any' : '$n+',
                                      tempBed == n,
                                      () => setSheet(() => tempBed = n),
                                    );
                                  }).toList(),
                            ),
                          ),
                          group(
                            'Bathrooms',
                            Wrap(
                              spacing: 8,
                              children:
                                  [0, 1, 2, 3].map((n) {
                                    return chip(
                                      n == 0 ? 'Any' : '$n+',
                                      tempBath == n,
                                      () => setSheet(() => tempBath = n),
                                    );
                                  }).toList(),
                            ),
                          ),
                          if (amenities.isNotEmpty)
                            group(
                              'Amenities',
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    amenities.map((a) {
                                      final on = tempAmenities.contains(a);
                                      return chip(
                                        a,
                                        on,
                                        () => setSheet(() {
                                          if (on) {
                                            tempAmenities.remove(a);
                                          } else {
                                            tempAmenities.add(a);
                                          }
                                        }),
                                      );
                                    }).toList(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      8,
                      20,
                      MediaQuery.of(context).padding.bottom + 16,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _minRent = tempMin;
                            _maxRent = tempMax >= bound ? 0 : tempMax;
                            _minBedrooms = tempBed;
                            _minBathrooms = tempBath;
                            _filterAmenities
                              ..clear()
                              ..addAll(tempAmenities);
                          });
                          _filterProperties();
                          Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Show ${_matchCount(tempMin, tempMax >= bound ? 0 : tempMax, tempBed, tempBath, tempAmenities)} results',
                          style: AppTextStyles.labelLarge.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Live count for the sheet's Apply button — how many listings the pending
  /// (not-yet-applied) filter selection would show.
  int _matchCount(
    double minRent,
    double maxRent,
    int minBed,
    int minBath,
    Set<String> amenities,
  ) {
    return _allProperties.where((property) {
      if (_selectedType != 'all' && property.propertyType != _selectedType) {
        return false;
      }
      if (_selectedArea != 'All Areas' && property.city != _selectedArea) {
        return false;
      }
      if (minRent > 0 && property.rent < minRent) return false;
      if (maxRent > 0 && property.rent > maxRent) return false;
      if (minBed > 0 && property.bedrooms < minBed) return false;
      if (minBath > 0 && property.bathrooms < minBath) return false;
      if (amenities.isNotEmpty &&
          !amenities.every((a) => property.amenities.contains(a))) {
        return false;
      }
      return true;
    }).length;
  }

  Future<void> _toggleSave(String propertyId) async {
    final wasSaved = _savedProperties.contains(propertyId);
    setState(() {
      wasSaved
          ? _savedProperties.remove(propertyId)
          : _savedProperties.add(propertyId);
    });
    final success =
        wasSaved
            ? await _savedService.unsaveProperty(propertyId)
            : await _savedService.saveProperty(propertyId);
    if (!success && mounted) {
      setState(() {
        wasSaved
            ? _savedProperties.add(propertyId)
            : _savedProperties.remove(propertyId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Failed to update saved properties'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  void _openPropertyDetail(PropertyModel property) =>
      context.push('/property-detail', extra: property);

  String get _firstName => _userName.split(' ').first;

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) SystemNavigator.pop();
      },
      child: StreamBuilder<TenancyLinkModel?>(
        stream: _activeLinkStream,
        builder: (context, activeLinkSnap) {
          final activeLink = activeLinkSnap.data;
          return StreamBuilder<List<TenancyLinkModel>>(
            stream: _pendingLinksStream,
            builder: (context, pendingSnap) {
              final pendingLinks = pendingSnap.data ?? [];
              final isVerified =
                  _verificationStatus == VerificationStatus.verified;
              final isLinkedUnverified = activeLink != null && !isVerified;
              final isLinkedVerified = activeLink != null && isVerified;
              return Scaffold(
                backgroundColor: AppColors.background,
                body: _buildCurrentTab(
                  activeLink,
                  pendingLinks,
                  isLinkedUnverified,
                  isLinkedVerified,
                ),
                bottomNavigationBar: _buildBottomNav(
                  isLinkedUnverified,
                  isLinkedVerified,
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildCurrentTab(
    TenancyLinkModel? activeLink,
    List<TenancyLinkModel> pendingLinks,
    bool isLinkedUnverified,
    bool isLinkedVerified,
  ) {
    // ── Loading guard: don't route until profile (verification status) is known ──
    // Without this, _verificationStatus starts as 'none' and verified linked tenants
    // incorrectly fall to Tier 2 or Tier 3 on first build.
    if (_isLoadingProfile) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (isLinkedUnverified && activeLink != null) {
      switch (_currentNavIndex) {
        case 0:
          return SafeArea(
            child: _buildLinkedUnverifiedHome(activeLink, pendingLinks),
          );
        case 1:
          return _buildLinkedUnverifiedProfile();
        default:
          return SafeArea(
            child: _buildLinkedUnverifiedHome(activeLink, pendingLinks),
          );
      }
    }

    // ── Verified tenant — multi-rental switcher (active + linked) ─────────
    // Replaces the old mutually-exclusive Tier 1 (single linked) / Tier 3
    // (single active) routing. The switcher enumerates every occupied rental
    // via streamTenantRentals() and shows one at a time.
    if (_currentNavIndex == 0 &&
        !_browsingFromDashboard &&
        !_browsingFromLinkedDashboard) {
      // First delivery hasn't landed yet — show a spinner rather than flashing
      // the browse home before the real list arrives.
      if (!_tenantRentalsLoaded) {
        return SafeArea(
          child: Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          ),
        );
      }
      if (_tenantRentals.isEmpty) {
        // No occupied rentals — fall through to browse home.
        return SafeArea(child: _buildHomeTab(pendingLinks));
      }
      return SafeArea(
        child: Column(
          children: [
            // This branch returns before _buildHomeTab, where the verification
            // prompt normally lives — so a tenant WITH rentals would otherwise
            // never see that their verification lapsed. Surface it here too.
            if (_verificationStatus != VerificationStatus.verified)
              _buildVerificationPrompt(),
            Expanded(
              child: MultiRentalDashboard(
                rentals: _tenantRentals,
                activeBuilder:
                    (tr) => TenantRentalDashboard(
                      rental: tr.rental,
                      userName: _userName,
                      userInitial:
                          _userName.isNotEmpty
                              ? _userName[0].toUpperCase()
                              : 'T',
                      isLoadingProfile: _isLoadingProfile,
                      onBrowseProperties:
                          () => setState(() => _browsingFromDashboard = true),
                    ),
                linkedBuilder:
                    (tr) =>
                        _buildLinkedVerifiedDashboard(tr.link!, pendingLinks),
                onRenew: (tr) => context.push('/tenant/renew', extra: tr),
              ),
            ),
          ],
        ),
      );
    }
    switch (_currentNavIndex) {
      case 0:
        return SafeArea(child: _buildHomeTab(pendingLinks));
      case 1:
        return SafeArea(child: _buildSavedTab());
      case 2:
        return SafeArea(child: _buildMessagesTab());
      case 3:
        return _buildProfileTab();
      default:
        return SafeArea(child: _buildHomeTab(pendingLinks));
    }
  }

  // ── TIER 2: UNVERIFIED LINKED TENANT HOME ───────────────────────────────
  // Limited dashboard: see rent info + landlord call + verification CTA

  Widget _buildLinkedUnverifiedHome(
    TenancyLinkModel link,
    List<TenancyLinkModel> pendingLinks,
  ) {
    return CustomScrollView(
      slivers: [
        _buildLinkedAppBar(title: 'My Tenancy', subtitle: link.propertyCity),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rent due card
                LinkedRentDueCard(link: link),
                const SizedBox(height: 16),

                // Revised agreement (sent by landlord on a rent review)
                _buildRevisedAgreementCard(link),

                // Property info
                _buildLinkedPropertyCard(link),
                const SizedBox(height: 16),

                // Landlord call (no in-app message for unverified)
                _buildLandlordContactCard(link, canMessage: false),
                const SizedBox(height: 20),

                // Pending link requests
                if (pendingLinks.isNotEmpty) ...[
                  _buildPendingLinksSection(pendingLinks),
                  const SizedBox(height: 20),
                ],

                // ── Unlock full access CTA ────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primary,
                        AppColors.primary.withAlpha(200),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(40),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.lock_open_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Unlock Full Access',
                            style: AppTextStyles.labelLarge.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "You're currently a linked tenant. Pay ₦5,000 to get verified and unlock:",
                        style: AppTextStyles.bodySmall.copyWith(
                          color: Colors.white.withAlpha(220),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...const [
                        _AccessFeature(
                          'Report maintenance issues',
                          Icons.report_problem_outlined,
                        ),
                        _AccessFeature(
                          'View & manage your lease',
                          Icons.description_outlined,
                        ),
                        _AccessFeature(
                          'In-app messaging with landlord',
                          Icons.chat_outlined,
                        ),
                        _AccessFeature(
                          'Browse & save other properties',
                          Icons.search_outlined,
                        ),
                        _AccessFeature(
                          'Request inspections',
                          Icons.event_available_outlined,
                        ),
                      ].map(
                        (f) => Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Icon(f.icon, color: Color(0x33FFFFFF), size: 16),
                              SizedBox(width: 8),
                              Text(
                                f.label,
                                style: TextStyle(
                                  color: Color(0xDCFFFFFF),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              () => context
                                  .push('/tenant/verification')
                                  .then((_) => _loadVerificationStatus()),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Get Verified — ₦5,000',
                            style: AppTextStyles.labelLarge.copyWith(
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── TIER 1: VERIFIED LINKED TENANT DASHBOARD ────────────────────────────
  // Full linked dashboard — report issues, lease details, messaging, browse

  Widget _buildLinkedVerifiedDashboard(
    TenancyLinkModel link,
    List<TenancyLinkModel> pendingLinks,
  ) {
    return CustomScrollView(
      slivers: [
        _buildLinkedAppBar(title: 'My Tenancy', subtitle: link.propertyCity),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rent due card
                LinkedRentDueCard(link: link),
                const SizedBox(height: 16),

                // Revised agreement (sent by landlord on a rent review)
                _buildRevisedAgreementCard(link),

                // Property info
                _buildLinkedPropertyCard(link),
                const SizedBox(height: 16),

                // Landlord contact with messaging
                _buildLandlordContactCard(link, canMessage: true),
                const SizedBox(height: 16),

                // Pending fix confirmations
                _buildLinkedPendingConfirmations(link),

                // Active issues summary (open + in_progress)
                _buildActiveIssuesCard(link),

                // Quick actions — verified tenant only
                Row(
                  children: [
                    Expanded(
                      child: _LinkedActionCard(
                        icon: Icons.description_outlined,
                        label: 'Lease Details',
                        color: AppColors.info,
                        onTap: () => _showLinkedLeaseDetails(link),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _LinkedActionCard(
                        icon: Icons.report_problem_outlined,
                        label: 'Report Issue',
                        color: AppColors.warning,
                        onTap:
                            () => context.push(
                              '/tenant/report-issue',
                              extra: {
                                'propertyId': link.propertyId,
                                'propertyTitle': link.propertyTitle,
                                'tenantId': link.tenantId,
                                'tenantName': link.tenantName,
                                'landlordId': link.landlordId,
                                'landlordName': link.landlordName,
                              },
                            ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _LinkedActionCard(
                        icon: Icons.payment_outlined,
                        label: 'Payments',
                        color: AppColors.success,
                        onTap: () => context.push('/tenant/payment-history'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Pending link requests
                if (pendingLinks.isNotEmpty) ...[
                  _buildPendingLinksSection(pendingLinks),
                  const SizedBox(height: 16),
                ],

                // Browse more (future tenancy)
                GestureDetector(
                  onTap:
                      () => setState(() => _browsingFromLinkedDashboard = true),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(20),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.search_outlined,
                            color: AppColors.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Browse Properties',
                                style: AppTextStyles.labelMedium,
                              ),
                              Text(
                                'Looking ahead? Find your next home.',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Streams pending_confirmation issues for linked tenants — same accountability
  // loop as the inspection-path tenant dashboard.
  Widget _buildLinkedPendingConfirmations(TenancyLinkModel link) {
    return StreamBuilder<QuerySnapshot>(
      stream:
          FirebaseFirestore.instance
              .collection('issues')
              .where('tenantId', isEqualTo: link.tenantId)
              .where('propertyId', isEqualTo: link.propertyId)
              .where('status', isEqualTo: 'pending_confirmation')
              .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }
        final docs = snapshot.data!.docs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.info,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Fix${docs.length > 1 ? 'es' : ''} to Confirm (${docs.length})',
                  style: AppTextStyles.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...docs.map(
              (doc) => _LinkedPendingConfirmationCard(
                issueId: doc.id,
                data: doc.data() as Map<String, dynamic>,
              ),
            ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  /// Active issues card — shows open + in_progress issues for THIS property.
  /// Only visible while the tenancy link is confirmed/active.
  /// Scoped to propertyId so switching properties shows the right data.
  Widget _buildActiveIssuesCard(TenancyLinkModel link) {
    return StreamBuilder<QuerySnapshot>(
      stream:
          FirebaseFirestore.instance
              .collection('issues')
              .where('tenantId', isEqualTo: link.tenantId)
              .where('propertyId', isEqualTo: link.propertyId)
              .where('status', whereIn: ['open', 'in_progress'])
              .orderBy('createdAt', descending: true)
              .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];

        return GestureDetector(
          onTap: () => context.push('/tenant/issue-history'),
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color:
                    docs.isNotEmpty
                        ? AppColors.warning.withAlpha(100)
                        : AppColors.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color:
                            docs.isEmpty
                                ? AppColors.success.withAlpha(26)
                                : AppColors.warning.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        docs.isEmpty
                            ? Icons.check_circle_outline
                            : Icons.report_problem_outlined,
                        color:
                            docs.isEmpty
                                ? AppColors.success
                                : AppColors.warning,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            docs.isEmpty ? 'No Active Issues' : 'Active Issues',
                            style: AppTextStyles.labelMedium,
                          ),
                          Text(
                            docs.isEmpty
                                ? 'All clear at this property'
                                : '${docs.length} issue${docs.length > 1 ? 's' : ''} open or in progress',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'History',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 12,
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ],
                ),

                // Issue rows — up to 3
                if (docs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  ...docs.take(3).map((doc) {
                    final d = doc.data() as Map<String, dynamic>;
                    final status = (d['status'] as String?) ?? 'open';
                    final category = (d['category'] as String?) ?? 'general';
                    final title =
                        (d['title'] as String?)?.trim().isNotEmpty == true
                            ? d['title'] as String
                            : category;
                    final statusColor =
                        status == 'in_progress'
                            ? AppColors.warning
                            : AppColors.error;
                    final statusLabel =
                        status == 'in_progress' ? 'In Progress' : 'Open';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(right: 8, top: 1),
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              title,
                              style: AppTextStyles.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            statusLabel,
                            style: AppTextStyles.caption.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  if (docs.length > 3)
                    Text(
                      '+${docs.length - 3} more — tap to view all',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textHint,
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // Shows a single bottom sheet with key tenancy info for linked tenants.
  // LeaseDetailsScreen requires ActiveRental (inspection-path only) so linked
  // tenants get a purpose-built summary sheet instead.
  void _showLinkedLeaseDetails(TenancyLinkModel link) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final nextDue = link.nextDueDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (_) => Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.description_outlined,
                        color: AppColors.info,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('Tenancy Details', style: AppTextStyles.h4),
                  ],
                ),
                const SizedBox(height: 24),

                _LeaseDetailRow(label: 'Property', value: link.propertyTitle),
                const SizedBox(height: 12),
                _LeaseDetailRow(label: 'Address', value: link.propertyAddress),
                const SizedBox(height: 12),
                _LeaseDetailRow(label: 'Landlord', value: link.landlordName),
                const SizedBox(height: 12),
                _LeaseDetailRow(
                  label: 'Rent',
                  value: '${link.formattedRentAmount} ${link.rentPeriodLabel}',
                ),
                const SizedBox(height: 12),
                _LeaseDetailRow(
                  label: 'Next Due',
                  value:
                      '${months[nextDue.month - 1]} ${nextDue.day}, ${nextDue.year}',
                ),
                const SizedBox(height: 12),
                _LeaseDetailRow(
                  label: 'Linked Since',
                  value:
                      link.acceptedAt != null
                          ? '${months[link.acceptedAt!.month - 1]} ${link.acceptedAt!.day}, ${link.acceptedAt!.year}'
                          : 'N/A',
                ),

                if (link.agreementUrl != null &&
                    link.agreementUrl!.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _openLinkAgreement(link),
                      icon: Icon(
                        Icons.description_outlined,
                        size: 18,
                        color: AppColors.info,
                      ),
                      label: Text(
                        'View Revised Agreement',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.info,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppColors.info.withAlpha(120)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(13),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.info.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: AppColors.info),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your tenancy was set up directly by your landlord through ClearRent.',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
    );
  }

  // ── TIER 2: UNVERIFIED LINKED TENANT PROFILE ─────────────────────────────
  // Mini profile: edit info, verify, help — no saved/inspections/browse

  Widget _buildLinkedUnverifiedProfile() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            color: AppColors.surface,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        GestureDetector(
                          onTap: () => context.push('/settings'),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.settings_outlined,
                              color: AppColors.textPrimary,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        UserAvatar(
                          name: _userName,
                          imageUrl: _profileImageUrl,
                          imageFile: _localProfileImage,
                          size: 72,
                          showEditBadge:
                              !_isLoadingProfile && !_isUploadingImage,
                          onTap: _pickProfileImage,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _isLoadingProfile
                                  ? Container(
                                    width: 90,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      color: AppColors.border,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  )
                                  : Text(_userName, style: AppTextStyles.h4),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.warning.withAlpha(26),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.link,
                                      size: 12,
                                      color: AppColors.warning,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Linked Tenant',
                                      style: AppTextStyles.labelSmall.copyWith(
                                        color: AppColors.warning,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => context.push('/edit-profile'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: AppColors.primary),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Edit',
                              style: AppTextStyles.labelMedium.copyWith(
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Verification upgrade card
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: GestureDetector(
              onTap:
                  () => context
                      .push('/tenant/verification')
                      .then((_) => _loadVerificationStatus()),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(13),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.primary.withAlpha(60)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(26),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.verified_user_outlined,
                        color: AppColors.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Get Verified',
                            style: AppTextStyles.labelLarge.copyWith(
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Pay ₦5,000 to unlock full platform access',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Start',
                        style: AppTextStyles.labelSmall.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Menu items
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TenantProfileSection(
                  title: 'My Account',
                  items: [
                    _TenantProfileMenuItem(
                      icon: Icons.person_outline,
                      title: 'Edit Profile',
                      subtitle: 'Update your name and photo',
                      onTap: () => context.push('/edit-profile'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.payment_outlined,
                      title: 'Payment History',
                      subtitle: 'View your payment records',
                      onTap: () => context.push('/tenant/payment-history'),
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
                      subtitle: 'Version ${AppInfo.version}',
                      onTap: () => context.push('/about'),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Center(
                  child: Column(
                    children: [
                      Text(
                        'ClearRent',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: AppColors.textHint,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Rent Without Regret',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textHint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
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

  // ── SHARED APP BAR (reused across linked dashboard variants) ─────────────

  SliverAppBar _buildLinkedAppBar({
    required String title,
    required String subtitle,
  }) {
    return SliverAppBar(
      expandedHeight: 0,
      floating: true,
      backgroundColor: AppColors.surface,
      elevation: 0,
      automaticallyImplyLeading: false,
      title: Row(
        children: [
          GestureDetector(
            onTap: _pickProfileImage,
            child: Stack(
              children: [
                UserAvatar(
                  imageUrl: _profileImageUrl,
                  imageFile: _localProfileImage,
                  name: _userName,
                  size: 36,
                ),
                if (_isUploadingImage)
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppTextStyles.labelLarge),
                Text(
                  subtitle,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          VerificationBadge(status: _verificationStatus),
          const SizedBox(width: 8),
          NotificationBell(userId: _authService.currentUserId ?? ''),
        ],
      ),
    );
  }

  Widget _buildLinkedPropertyCard(TenancyLinkModel link) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.home_outlined,
                  color: AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(link.propertyTitle, style: AppTextStyles.labelLarge),
                    const SizedBox(height: 2),
                    Text(
                      link.propertyAddress,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.verified_outlined,
                  size: 14,
                  color: AppColors.success,
                ),
                const SizedBox(width: 5),
                Text(
                  'Verified Tenancy',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandlordContactCard(
    TenancyLinkModel link, {
    bool canMessage = true,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your Landlord', style: AppTextStyles.labelLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    link.landlordName.isNotEmpty
                        ? link.landlordName[0].toUpperCase()
                        : 'L',
                    style: AppTextStyles.h4.copyWith(color: AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(link.landlordName, style: AppTextStyles.labelMedium),
                    if (link.landlordPhone.isNotEmpty)
                      Text(
                        link.landlordPhone,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (link.landlordPhone.isNotEmpty) ...[
                GestureDetector(
                  onTap: () => _callLandlord(link.landlordPhone),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(20),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.phone_outlined,
                      size: 20,
                      color: AppColors.success,
                    ),
                  ),
                ),
                if (canMessage) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _openLandlordChat(link),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(20),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.chat_outlined,
                        size: 20,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
          if (!canMessage && link.landlordPhone.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.lock_outline, size: 13, color: AppColors.textHint),
                const SizedBox(width: 5),
                Text(
                  'In-app messaging unlocks after verification',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textHint,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── PENDING LINK REQUESTS ─────────────────────────────────────────────────

  Widget _buildPendingLinksSection(List<TenancyLinkModel> links) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: AppColors.warning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Link Request${links.length > 1 ? 's' : ''} (${links.length})',
              style: AppTextStyles.labelLarge,
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...links.map((link) => _buildPendingLinkCard(link)),
      ],
    );
  }

  Widget _buildPendingLinkCard(TenancyLinkModel link) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    link.landlordName.isNotEmpty
                        ? link.landlordName[0].toUpperCase()
                        : 'L',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(link.landlordName, style: AppTextStyles.labelMedium),
                    Text(
                      'wants to link you to their property',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(link.propertyTitle, style: AppTextStyles.labelMedium),
                const SizedBox(height: 2),
                Text(
                  link.propertyAddress,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      link.formattedRentAmount,
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    Text(
                      '  ${link.rentPeriodLabel}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 13,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Due ${link.rentDueLabel}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _rejectLink(link),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    'Decline',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => _acceptLink(link),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text('Accept', style: AppTextStyles.labelMedium),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── HOME TAB (unlinked browse mode) ───────────────────────────────────────

  Widget _buildHomeTab(List<TenancyLinkModel> pendingLinks) {
    return RefreshIndicator(
      onRefresh: _refreshData,
      color: AppColors.primary,
      child: Column(
        children: [
          _buildHeader(),
          // Announcements banner
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: AnnouncementsBanner(
              userId: _authService.currentUserId ?? '',
              accountType: 'tenant',
              notificationsRoute: '/notifications',
            ),
          ),
          // Back to dashboard banner when browsing from rental dashboard
          if (_browsingFromDashboard && _activeRental != null)
            GestureDetector(
              onTap: () => setState(() => _browsingFromDashboard = false),
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.success.withAlpha(60)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.arrow_back, size: 16, color: AppColors.success),
                    const SizedBox(width: 8),
                    Text(
                      'Back to my rental dashboard',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.success,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Back to tenancy banner when linked tenant is browsing
          if (_browsingFromLinkedDashboard)
            GestureDetector(
              onTap: () => setState(() => _browsingFromLinkedDashboard = false),
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary.withAlpha(60)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.arrow_back, size: 16, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Back to my tenancy',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Pending link requests banner — replaces the old route-based banner
          if (pendingLinks.isNotEmpty) _buildPendingLinksBanner(pendingLinks),
          _buildTodaysInspectionBanner(),
          if (_verificationStatus != VerificationStatus.verified)
            _buildVerificationPrompt(),
          if (!_hasBankDetails &&
              !_isLoadingProfile &&
              _verificationStatus == VerificationStatus.verified)
            _buildBankDetailsBanner(),
          _buildSearchBar(),
          _buildFilters(),
          Expanded(
            child:
                _isLoadingProperties
                    ? Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                    : _filteredProperties.isEmpty
                    ? _buildEmptyState()
                    : _buildPropertyList(),
          ),
        ],
      ),
    );
  }

  /// Compact reminder shown on the day of an approved inspection — the tenant's
  /// lightweight counterpart to the agent's "Today's Inspections" section. A
  /// tenant typically has a single booking, so this stays a one-line banner
  /// rather than a card list. Only renders on the inspection day itself.
  Widget _buildTodaysInspectionBanner() {
    return StreamBuilder<List<InspectionRequest>>(
      stream: _inspectionsStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final todays =
            snapshot.data!.where((r) {
                final day = DateTime(
                  r.requestedDate.year,
                  r.requestedDate.month,
                  r.requestedDate.day,
                );
                return r.isApproved && day.isAtSameMomentAs(today);
              }).toList()
              ..sort(
                (a, b) => a.requestedTimeSlot.compareTo(b.requestedTimeSlot),
              );
        if (todays.isEmpty) return const SizedBox.shrink();
        final r = todays.first;
        final more = todays.length - 1;

        return GestureDetector(
          onTap: () => context.push('/tenant/inspections'),
          child: Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withAlpha(77)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.event_available_outlined,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Inspection today · ${r.requestedTimeDisplay}',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        more > 0
                            ? '${r.propertyTitle} +$more more'
                            : r.propertyTitle,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.primary, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Compact banner shown above property list when there are pending link requests
  Widget _buildPendingLinksBanner(List<TenancyLinkModel> links) {
    final count = links.length;
    return GestureDetector(
      onTap: () => context.push('/tenant/tenancy-requests'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(13),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(77)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.home_outlined,
                size: 18,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count tenancy request${count > 1 ? 's' : ''} pending',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'A landlord wants to link you to their property',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.primary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationPrompt() {
    String title = '';
    String subtitle = '';
    IconData icon = Icons.verified_user_outlined;
    Color color = AppColors.primary;
    Color bgColor = AppColors.primaryLight.withAlpha(26);
    switch (_verificationStatus) {
      case VerificationStatus.none:
        title = 'Get Verified';
        subtitle = 'Verified tenants are preferred by landlords';
        icon = Icons.verified_user_outlined;
        color = AppColors.primary;
        bgColor = AppColors.primaryLight.withAlpha(26);
        break;
      case VerificationStatus.pending:
        title = 'Verification Pending';
        subtitle = 'We\'re reviewing your documents';
        icon = Icons.schedule;
        color = AppColors.warning;
        bgColor = AppColors.warningLight;
        break;
      case VerificationStatus.rejected:
        title = 'Verification Failed';
        subtitle = 'Tap to see why and try again';
        icon = Icons.error_outline;
        color = AppColors.error;
        bgColor = AppColors.error.withAlpha(26);
        break;
      case VerificationStatus.expired:
        title = 'Verification Expired';
        subtitle = 'Renew to keep booking inspections';
        icon = Icons.autorenew;
        color = AppColors.warning;
        bgColor = AppColors.warningLight;
        break;
      case VerificationStatus.verified:
        return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap:
          () => context
              .push('/tenant/verification')
              .then((_) => _loadVerificationStatus()),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(77)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.labelLarge.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: color.withAlpha(204),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildBankDetailsBanner() {
    return GestureDetector(
      onTap:
          () => context
              .push('/tenant/bank-details')
              .then((_) => _loadUserProfile()),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.warning.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.warning.withAlpha(77)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.account_balance_wallet_outlined,
                color: AppColors.warning,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add Bank Details',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Required for receiving refunds and deposits',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.warning.withAlpha(204),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.warning),
          ],
        ),
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
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    )
                    : Text(
                      'Hello, $_firstName ',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
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
          NotificationBell(userId: _authService.currentUserId ?? ''),
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
            hintStyle: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textHint,
            ),
            prefixIcon: Icon(Icons.search, color: AppColors.textHint),
            suffixIcon:
                _searchController.text.isNotEmpty
                    ? IconButton(
                      icon: Icon(Icons.clear, color: AppColors.textHint),
                      onPressed: () {
                        _searchController.clear();
                        _filterProperties();
                      },
                    )
                    : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
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
                    color:
                        isSelected
                            ? AppColors.primary
                            : AppColors.textSecondary,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: isSelected ? AppColors.primary : AppColors.border,
                    ),
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
                child: GestureDetector(
                  onTap: _showAreaPicker,
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _selectedArea,
                            style: AppTextStyles.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          Icons.keyboard_arrow_down,
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _showFiltersSheet,
                child: Container(
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Icon(Icons.tune, color: Colors.white, size: 20),
                      // Little dot to show extra filters are active.
                      if (_hasExtraFilters)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text(
                '${_filteredProperties.length} properties found',
                style: AppTextStyles.bodySmall,
              ),
              if (_realProperties.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_realProperties.length} verified',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Text('Sort by: ', style: AppTextStyles.bodySmall),
              Text(
                'Newest',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: AppColors.primary,
              ),
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
        final isReal = _realProperties.any((p) => p.id == property.id);
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
              if (isReal)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.verified,
                          size: 12,
                          color: Colors.white,
                        ),
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
          Text(
            AppStrings.noProperties,
            style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'Try adjusting your filters',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textHint),
          ),
        ],
      ),
    );
  }

  // ── SAVED TAB ─────────────────────────────────────────────────────────────

  /// Every saved property, whether or not browse still carries it.
  ///
  /// Resolved from `_allProperties` first and `_savedExtras` second, so a place
  /// that has since been let or delisted still appears — it is the tenant's own
  /// bookmark, and silently dropping it is what made the badge and the list
  /// disagree ("1 saved" over an empty list, then 2 after one like).
  List<PropertyModel> get _savedList {
    final byId = {for (final p in _allProperties) p.id: p};
    return _savedProperties
        .map((id) => byId[id] ?? _savedExtras[id])
        .whereType<PropertyModel>()
        .toList();
  }

  Widget _buildSavedTab() {
    final savedList = _savedList;
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${savedList.length}',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child:
              _isLoadingSaved
                  ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
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
                          child: Icon(
                            Icons.favorite_outline,
                            size: 48,
                            color: AppColors.error,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'No saved properties yet',
                          style: AppTextStyles.h4.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tap the heart icon on any property\nto save it for later',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: AppColors.textHint,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        TextButton.icon(
                          onPressed: () => setState(() => _currentNavIndex = 0),
                          icon: const Icon(Icons.search),
                          label: const Text('Browse Properties'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.primary,
                          ),
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

  // ── MESSAGES TAB ──────────────────────────────────────────────────────────

  Widget _buildMessagesTab() {
    return const MessagesTabReal(
      emptyTitle: 'No messages yet',
      emptySubtitle: 'Your conversations with landlords\nwill appear here',
    );
  }

  // ── PROFILE TAB ───────────────────────────────────────────────────────────

  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary,
                  AppColors.primary.withAlpha(204),
                  AppColors.primaryLight,
                ],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        GestureDetector(
                          onTap: () => context.push('/settings'),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(51),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.settings_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    UserAvatarProfile(
                      name: _userName,
                      imageUrl: _profileImageUrl,
                      imageFile: _localProfileImage,
                      size: 90,
                      showEditBadge: true,
                      isLoading: _isLoadingProfile || _isUploadingImage,
                      onTap: _pickProfileImage,
                    ),
                    const SizedBox(height: 16),
                    _isLoadingProfile
                        ? Container(
                          width: 120,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(77),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        )
                        : Text(
                          _userName,
                          style: AppTextStyles.h3.copyWith(color: Colors.white),
                        ),
                    const SizedBox(height: 8),
                    VerificationBadgeLarge(
                      status: _verificationStatus,
                      role: 'Tenant',
                      onTap:
                          () => context
                              .push('/tenant/verification')
                              .then((_) => _loadVerificationStatus()),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -30),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(13),
                      blurRadius: 20,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _ProfileStat(
                        icon: Icons.favorite_outline,
                        value:
                            _isLoadingSaved
                                ? '...'
                                : '${_savedList.length}',
                        label: 'Saved',
                        color: AppColors.error,
                      ),
                    ),
                    Container(width: 1, height: 40, color: AppColors.border),
                    Expanded(
                      child: _ProfileStat(
                        icon: Icons.home_outlined,
                        value: '$_activeRentalCount',
                        label: 'Rentals',
                        color: AppColors.primary,
                      ),
                    ),
                    Container(width: 1, height: 40, color: AppColors.border),
                    Expanded(
                      child: _ProfileStat(
                        icon: Icons.chat_bubble_outline,
                        value: '$_unreadCount',
                        label: 'Unread',
                        color: AppColors.info,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TenantProfileSection(
                  title: 'Account',
                  items: [
                    _TenantProfileMenuItem(
                      icon: Icons.person_outline,
                      title: 'Edit Profile',
                      subtitle: 'Update your personal information',
                      onTap: () => context.push('/edit-profile'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.verified_user_outlined,
                      title: 'Verification',
                      subtitle: 'Verify your identity',
                      onTap:
                          () => context
                              .push('/tenant/verification')
                              .then((_) => _loadVerificationStatus()),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.account_balance_outlined,
                      title: 'Bank Details',
                      subtitle: 'Manage your refund account',
                      onTap:
                          () => context
                              .push('/tenant/bank-details')
                              .then((_) => _loadUserProfile()),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
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
                      icon: Icons.history,
                      title: 'My Rentals',
                      subtitle: 'View your rental history',
                      onTap: () => context.push('/tenant/my-rentals'),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.favorite_outline,
                      title: 'Saved Properties',
                      subtitle: '${_savedList.length} properties saved',
                      onTap: () => setState(() => _currentNavIndex = 1),
                    ),
                    _TenantProfileMenuItem(
                      icon: Icons.report_problem_outlined,
                      title: 'My Issues',
                      subtitle: 'Issues you\'ve reported across all properties',
                      onTap: () => context.push('/tenant/issue-history'),
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
                      subtitle: 'Version ${AppInfo.version}',
                      onTap: () => context.push('/about'),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Center(
                  child: Column(
                    children: [
                      Text(
                        'ClearRent',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: AppColors.textHint,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Rent Without Regret',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textHint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
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

  // ── BOTTOM NAV ────────────────────────────────────────────────────────────

  Widget _buildBottomNav(bool isLinkedUnverified, bool isLinkedVerified) {
    return CapsuleNav(
      items:
          isLinkedUnverified
              // ── Unverified linked: Home + Profile only
              ? [
                CapsuleNavItem(
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home,
                  label: 'Home',
                  isActive: _currentNavIndex == 0,
                  onTap: () => setState(() => _currentNavIndex = 0),
                ),
                CapsuleNavItem(
                  icon: Icons.person_outline,
                  activeIcon: Icons.person,
                  label: 'Profile',
                  isActive: _currentNavIndex == 1,
                  onTap: () => setState(() => _currentNavIndex = 1),
                ),
              ]
              // ── Verified linked or unlinked: full 4 tabs
              : [
                CapsuleNavItem(
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home,
                  label: 'Home',
                  isActive: _currentNavIndex == 0,
                  onTap: () => setState(() => _currentNavIndex = 0),
                ),
                CapsuleNavItem(
                  icon: Icons.favorite_outline,
                  activeIcon: Icons.favorite,
                  label: 'Saved',
                  isActive: _currentNavIndex == 1,
                  onTap: () => setState(() => _currentNavIndex = 1),
                  badge:
                      _savedList.isNotEmpty ? '${_savedList.length}' : null,
                ),
                CapsuleNavItem(
                  icon: Icons.chat_bubble_outline,
                  activeIcon: Icons.chat_bubble,
                  label: 'Messages',
                  isActive: _currentNavIndex == 2,
                  onTap: () {
                    setState(() {
                      _currentNavIndex = 2;
                      _loadUnreadCount();
                    });
                  },
                  badge: _unreadCount > 0 ? '$_unreadCount' : null,
                ),
                CapsuleNavItem(
                  icon: Icons.person_outline,
                  activeIcon: Icons.person,
                  label: 'Profile',
                  isActive: _currentNavIndex == 3,
                  onTap: () => setState(() => _currentNavIndex = 3),
                ),
              ],
    );
  }

  // ── LINK ACTIONS ──────────────────────────────────────────────────────────

  Future<void> _acceptLink(TenancyLinkModel link) async {
    final success = await _tenancyLinkService.acceptLink(link.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'You\'re now linked to ${link.propertyTitle}!'
                : 'Failed to accept. Please try again.',
          ),
          backgroundColor: success ? AppColors.success : AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _rejectLink(TenancyLinkModel link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Decline Request'),
            content: Text(
              'Decline the link request from ${link.landlordName}?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  'Decline',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ],
          ),
    );
    if (confirmed == true) await _tenancyLinkService.rejectLink(link.id);
  }

  /// Opens or creates a direct conversation between the linked tenant and their landlord.
  Future<void> _openLandlordChat(TenancyLinkModel link) async {
    if (link.landlordId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Landlord information not available'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    // Show loading indicator
    final scaffold = ScaffoldMessenger.of(context);
    setState(() {}); // trigger any loading state if needed

    try {
      // Fetch fresh landlord name from Firestore so display is always correct
      String landlordName = link.landlordName;
      String tenantName = _userName.isNotEmpty ? _userName : 'Tenant';
      try {
        final landlordDoc =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(link.landlordId)
                .get();
        if (landlordDoc.exists) {
          landlordName = landlordDoc.data()?['fullName'] ?? link.landlordName;
        }
      } catch (_) {} // fallback to link value on network error

      final conv = await _conversationService.getOrCreateConversation(
        propertyId: link.propertyId,
        propertyTitle: link.propertyTitle,
        propertyImage: '',
        landlordId: link.landlordId,
        landlordName: landlordName,
        tenantId: link.tenantId,
        tenantName: tenantName,
      );

      if (!mounted) return;

      if (conv != null) {
        context.push(
          '/chat',
          extra: {
            'conversationId': conv.id,
            'propertyTitle': link.propertyTitle,
            'propertyImage': null,
          },
        );
      } else {
        scaffold.showSnackBar(
          SnackBar(
            content: const Text(
              'Could not open chat. Both parties must be verified.',
            ),
            backgroundColor: AppColors.warning,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('❌ Error opening landlord chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to open chat. Please try again.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  Future<void> _callLandlord(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  // Agreements live in private storage — resolve a short-lived signed URL via
  // the CF (which authorizes this tenant as a party) before opening.
  Future<void> _openLinkAgreement(TenancyLinkModel link) async {
    final url = await _agreementAccess.resolveUrl(
      collection: 'tenancy_links',
      docId: link.id,
    );
    if (!mounted) return;
    final uri = url != null ? Uri.tryParse(url) : null;
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not open the agreement'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  // Revised tenancy agreement the landlord attached on a rent review. The
  // approveRentReview CF writes link.agreementUrl; nothing else surfaces it for
  // linked tenants, so this card is their only way to see the new terms until
  // the link promotes to an active rental. Renders nothing when absent.
  Widget _buildRevisedAgreementCard(TenancyLinkModel link) {
    final url = link.agreementUrl;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GestureDetector(
        onTap: () => _openLinkAgreement(link),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.info.withAlpha(20),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.info.withAlpha(80)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.description_outlined,
                  color: AppColors.info,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Revised Tenancy Agreement',
                      style: AppTextStyles.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Your landlord updated your agreement. Tap to view.',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.open_in_new, size: 18, color: AppColors.info),
            ],
          ),
        ),
      ),
    );
  }
}

// ── SHARED WIDGETS ────────────────────────────────────────────────────────────

// ── Helper data class for access feature list ────────────────────────────────

class _LinkedActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _LinkedActionCard({
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
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessFeature {
  final String label;
  final IconData icon;
  const _AccessFeature(this.label, this.icon);
}

class _ProfileStat extends StatelessWidget {
  final IconData icon;
  final String value, label;
  final Color color;
  const _ProfileStat({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 8),
        Text(value, style: AppTextStyles.h4),
        const SizedBox(height: 2),
        Text(label, style: AppTextStyles.caption),
      ],
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
          child: Text(
            title,
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children:
                items.asMap().entries.map((entry) {
                  return Column(
                    children: [
                      entry.value,
                      if (entry.key < items.length - 1)
                        const Divider(height: 1, indent: 52),
                    ],
                  );
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

  const _TenantProfileMenuItem({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

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
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: AppColors.textSecondary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: AppTextStyles.caption),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

// Simple label/value row used in the linked lease details bottom sheet
class _LeaseDetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _LeaseDetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
          ),
        ),
        Expanded(child: Text(value, style: AppTextStyles.labelMedium)),
      ],
    );
  }
}

/// Confirmation card for linked tenants — identical accountability loop
/// to the inspection-path version in tenant_rental_dashboard.dart
class _LinkedPendingConfirmationCard extends StatefulWidget {
  final String issueId;
  final Map<String, dynamic> data;

  const _LinkedPendingConfirmationCard({
    required this.issueId,
    required this.data,
  });

  @override
  State<_LinkedPendingConfirmationCard> createState() =>
      _LinkedPendingConfirmationCardState();
}

class _LinkedPendingConfirmationCardState
    extends State<_LinkedPendingConfirmationCard> {
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
      final landlordId = widget.data['landlordId'];
      if (landlordId != null) {
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
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('What\'s still wrong?'),
            content: TextField(
              controller: reasonController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Describe what hasn\'t been fixed yet...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              ElevatedButton(
                onPressed:
                    () => Navigator.pop(ctx, reasonController.text.trim()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  'Submit Dispute',
                  style: TextStyle(color: Colors.white),
                ),
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
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.build_outlined,
                  size: 16,
                  color: AppColors.info,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title,
                      style: AppTextStyles.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Your landlord says this is fixed',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.info,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isActing ? null : _dispute,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    side: BorderSide(color: AppColors.error),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    'Still Broken',
                    style: TextStyle(color: AppColors.error, fontSize: 13),
                  ),
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
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child:
                      _isActing
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : const Text(
                            'Confirmed Fixed',
                            style: TextStyle(fontSize: 13),
                          ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
