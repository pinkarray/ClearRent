import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/inspection_pricing.dart';
import '../../../../shared/widgets/area_dropdown.dart';

// ============================================================
// LOCATION PICKER WIDGET FOR CLEARRENT
// ============================================================
// Field order: Street Address → Area/City → State → Pin Location
//
// Smart area matching:
// - When a pin is placed or address autocompleted, the geocoded
//   city is fuzzy-matched against the known area dropdown list,
//   handling diacritics (Ìkòròdú → Ikorodu) and LGA suffixes.
// - If matched: dropdown auto-updates, "Matched from pin" badge shown.
// - If unrecognised: orange hint shown, onUnknownAreaDetected fires
//   so the parent can log it to admin for future inclusion.
// ============================================================

class LocationPickerWidget extends StatefulWidget {
  final TextEditingController addressController;
  final TextEditingController cityController;
  final TextEditingController stateController;
  final Function(double lat, double lng)? onLocationSelected;

  /// Fired when the pin/autocomplete returns a city not in the known areas list.
  /// Use this to log to Firestore (e.g. 'admin_requests' collection) so the
  /// admin can review and add the area to the dropdown.
  final Function(String rawAreaName, double lat, double lng)? onUnknownAreaDetected;

  const LocationPickerWidget({
    super.key,
    required this.addressController,
    required this.cityController,
    required this.stateController,
    this.onLocationSelected,
    this.onUnknownAreaDetected,
  });

  @override
  State<LocationPickerWidget> createState() => _LocationPickerWidgetState();
}

class _LocationPickerWidgetState extends State<LocationPickerWidget> {
  final MapController _mapController = MapController();
  final FocusNode _addressFocusNode = FocusNode();

  LatLng? _selectedLocation;
  List<NominatimPlace> _suggestions = [];
  bool _isSearching = false;
  bool _showSuggestions = false;
  Timer? _debounceTimer;
  bool _suppressSearch = false;

  /// Raw city string returned by the last geocode call (may have diacritics).
  String? _geocodedRawCity;

  /// True when the area dropdown was auto-filled from pin/autocomplete.
  bool _areaMatchedFromPin = false;

  static const LatLng _defaultLocation = LatLng(6.5244, 3.3792);
  static const double _defaultZoom = 15.0;

  @override
  void initState() {
    super.initState();
    widget.addressController.addListener(_onAddressChanged);
    _addressFocusNode.addListener(() {
      if (!_addressFocusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) setState(() => _showSuggestions = false);
        });
      }
    });
  }

  @override
  void dispose() {
    widget.addressController.removeListener(_onAddressChanged);
    _addressFocusNode.dispose();
    _debounceTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _onAddressChanged() {
    // Skip search when address was set programmatically (from selection or reverse geocode)
    if (_suppressSearch) return;

    final query = widget.addressController.text.trim();
    
    // Cancel previous timer
    _debounceTimer?.cancel();
    
    if (query.length < 3) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }

    // Debounce API calls (500ms delay)
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _searchAddress(query);
    });
  }

  Future<void> _searchAddress(String query) async {
    if (!mounted) return;
    setState(() => _isSearching = true);

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}, Nigeria'
        '&format=json'
        '&addressdetails=1'
        '&limit=5'
        '&countrycodes=ng',
      );

      final response = await http.get(uri, headers: {
        'User-Agent': 'ClearRent/1.0 (info@verealtytech.com)',
      });

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        final places = data.map((e) => NominatimPlace.fromJson(e)).toList();
        if (mounted) {
          setState(() {
            _suggestions = places;
            _showSuggestions = places.isNotEmpty;
            _isSearching = false;
          });
        }
      } else {
        if (mounted) setState(() => _isSearching = false);
      }
    } catch (e) {
      debugPrint('❌ Search error: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _selectPlace(NominatimPlace place) {
    final location = LatLng(place.lat, place.lng);
    final matched = InspectionPricing.findMatchingArea(place.city);

    setState(() {
      _selectedLocation = location;
      _showSuggestions = false;
      _suggestions = [];
      _geocodedRawCity = place.city;
      _areaMatchedFromPin = matched != null;
      if (matched != null) widget.cityController.text = matched;
    });

    _suppressSearch = true;
    widget.addressController.text = place.streetAddress;
    widget.stateController.text = place.state.isNotEmpty ? place.state : 'Lagos';
    _suppressSearch = false;

    if (matched == null && place.city.isNotEmpty) {
      widget.onUnknownAreaDetected?.call(place.city, place.lat, place.lng);
    }

    _mapController.move(location, _defaultZoom);
    widget.onLocationSelected?.call(place.lat, place.lng);
    _addressFocusNode.unfocus();
  }

  void _onMapTap(TapPosition tapPosition, LatLng location) {
    setState(() => _selectedLocation = location);
    widget.onLocationSelected?.call(location.latitude, location.longitude);
    _reverseGeocode(location);
  }

  Future<void> _reverseGeocode(LatLng location) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=${location.latitude}'
        '&lon=${location.longitude}'
        '&format=json'
        '&addressdetails=1',
      );

      final response = await http.get(uri, headers: {
        'User-Agent': 'ClearRent/1.0 (info@verealtytech.com)',
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final place = NominatimPlace.fromJson(data);
        if (!mounted) return;

        final matched = InspectionPricing.findMatchingArea(place.city);

        setState(() {
          _geocodedRawCity = place.city;
          _areaMatchedFromPin = matched != null;
          if (matched != null) widget.cityController.text = matched;
        });

        _suppressSearch = true;
        widget.addressController.text = place.streetAddress;
        if (place.state.isNotEmpty) widget.stateController.text = place.state;
        _suppressSearch = false;

        if (matched == null && place.city.isNotEmpty) {
          widget.onUnknownAreaDetected?.call(
            place.city,
            location.latitude,
            location.longitude,
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Reverse geocode error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Street address with autocomplete
        _buildAddressField(),
        if (_showSuggestions) _buildSuggestions(),

        const SizedBox(height: 20),

        // 2. Area / City dropdown (with smart-match indicator)
        _buildAreaSection(),

        const SizedBox(height: 20),

        // 3. State
        _buildTextField(
          label: 'State',
          hint: 'e.g. Lagos',
          controller: widget.stateController,
        ),

        const SizedBox(height: 24),

        // 4. Pin location map
        _buildMap(),
      ],
    );
  }

  Widget _buildAreaSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AreaDropdown(
          label: 'Area / City',
          hint: 'Select area',
          helperText: 'Choose the area where this property is located',
          selectedArea: widget.cityController.text.isNotEmpty
              ? widget.cityController.text
              : null,
          onSelected: (area) {
            setState(() {
              widget.cityController.text = area;
              // User manually selected — clear auto-match state
              _areaMatchedFromPin = false;
              _geocodedRawCity = null;
              if (widget.stateController.text.isEmpty) {
                widget.stateController.text = 'Lagos';
              }
            });
          },
        ),
        _buildAreaMatchIndicator(),
      ],
    );
  }

  Widget _buildAreaMatchIndicator() {
    if (_geocodedRawCity == null) return const SizedBox.shrink();

    if (_areaMatchedFromPin) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Icon(Icons.gps_fixed, size: 13, color: AppColors.primary),
            const SizedBox(width: 4),
            Text(
              'Area matched from pin location',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.primary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    // Unknown area — prompt user to select manually
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline, size: 13, color: Colors.orange.shade700),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Pin returned "$_geocodedRawCity" — not in our list yet, please select the closest area',
              style: AppTextStyles.caption.copyWith(
                color: Colors.orange.shade700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Street Address', style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        TextField(
          controller: widget.addressController,
          focusNode: _addressFocusNode,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: 'Start typing to search...',
            hintStyle: TextStyle(color: AppColors.textHint),
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
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            suffixIcon: _isSearching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.search, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestions() {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(26),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      constraints: const BoxConstraints(maxHeight: 200),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border),
        itemBuilder: (context, index) {
          final place = _suggestions[index];
          return ListTile(
            dense: true,
            leading: Icon(
              Icons.location_on_outlined,
              color: AppColors.textSecondary,
              size: 20,
            ),
            title: Text(
              place.displayName,
              style: const TextStyle(fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _selectPlace(place),
          );
        },
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required String hint,
    required TextEditingController controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: AppColors.textHint),
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
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildMap() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Pin Location', style: AppTextStyles.labelMedium),
            const SizedBox(width: 8),
            Icon(Icons.touch_app, size: 16, color: AppColors.textHint),
            const SizedBox(width: 4),
            Text(
              'Tap to adjust',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textHint,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 180,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _selectedLocation ?? _defaultLocation,
              initialZoom: _selectedLocation != null ? _defaultZoom : 11.0,
              onTap: _onMapTap,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ng.clearrent.app',
              ),
              if (_selectedLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _selectedLocation!,
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.location_pin,
                        color: AppColors.primary,
                        size: 40,
                      ),
                    ),
                  ],
                ),
              if (_selectedLocation == null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surface.withAlpha(230),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Search address or tap to place pin',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// NOMINATIM PLACE MODEL
// ============================================================

class NominatimPlace {
  final double lat;
  final double lng;
  final String displayName;
  final String streetAddress;
  final String city;
  final String state;

  NominatimPlace({
    required this.lat,
    required this.lng,
    required this.displayName,
    required this.streetAddress,
    required this.city,
    required this.state,
  });

  factory NominatimPlace.fromJson(Map<String, dynamic> json) {
    final address = json['address'] as Map<String, dynamic>? ?? {};

    final houseNumber = address['house_number'] ?? '';
    final road = address['road'] ?? address['street'] ?? '';
    final streetAddress = '$houseNumber $road'.trim();

    // Nominatim uses various fields for the city/area name
    final city = address['city'] ??
        address['town'] ??
        address['suburb'] ??
        address['neighbourhood'] ??
        address['locality'] ??
        address['county'] ??
        '';

    final state = address['state'] ?? '';

    return NominatimPlace(
      lat: double.tryParse(json['lat'].toString()) ?? 0.0,
      lng: double.tryParse(json['lon'].toString()) ?? 0.0,
      displayName: json['display_name'] ?? '',
      streetAddress: streetAddress.isNotEmpty
          ? streetAddress
          : json['display_name']?.split(',').first ?? '',
      city: city,
      state: state,
    );
  }
}