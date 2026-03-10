import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';

// ============================================================
// LOCATION PICKER WIDGET FOR CLEARRENT
// ============================================================
// This widget provides:
// - Address autocomplete using Nominatim (OpenStreetMap's free geocoding)
// - Auto-fill of city and state fields
// - Compact map display with tap-to-adjust pin
// ============================================================

class LocationPickerWidget extends StatefulWidget {
  final TextEditingController addressController;
  final TextEditingController cityController;
  final TextEditingController stateController;
  final Function(double lat, double lng)? onLocationSelected;

  const LocationPickerWidget({
    super.key,
    required this.addressController,
    required this.cityController,
    required this.stateController,
    this.onLocationSelected,
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

  // Default to Lagos, Nigeria
  static const LatLng _defaultLocation = LatLng(6.5244, 3.3792);
  static const double _defaultZoom = 15.0;

  @override
  void initState() {
    super.initState();
    widget.addressController.addListener(_onAddressChanged);
    _addressFocusNode.addListener(() {
      if (!_addressFocusNode.hasFocus) {
        // Delay hiding to allow tap on suggestion
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
      // Nominatim API - free, but respect usage policy (1 req/sec, include app name)
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}, Nigeria'
        '&format=json'
        '&addressdetails=1'
        '&limit=5'
        '&countrycodes=ng',
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'ClearRent/1.0 (contact@clearrent.ng)', // Required by Nominatim
        },
      );

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
        debugPrint('❌ Nominatim error: ${response.statusCode}');
        if (mounted) setState(() => _isSearching = false);
      }
    } catch (e) {
      debugPrint('❌ Search error: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _selectPlace(NominatimPlace place) {
    final location = LatLng(place.lat, place.lng);
    
    setState(() {
      _selectedLocation = location;
      _showSuggestions = false;
      _suggestions = [];
    });

    // Update text fields
    widget.addressController.text = place.streetAddress;
    widget.cityController.text = place.city;
    widget.stateController.text = place.state;

    // Move map to location
    _mapController.move(location, _defaultZoom);

    // Notify parent
    widget.onLocationSelected?.call(place.lat, place.lng);

    // Unfocus to dismiss keyboard
    _addressFocusNode.unfocus();
  }

  void _onMapTap(TapPosition tapPosition, LatLng location) {
    setState(() => _selectedLocation = location);
    widget.onLocationSelected?.call(location.latitude, location.longitude);
    
    // Reverse geocode to update address fields
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

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'ClearRent/1.0 (contact@clearrent.ng)',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final place = NominatimPlace.fromJson(data);
        
        if (mounted) {
          widget.addressController.text = place.streetAddress;
          widget.cityController.text = place.city;
          widget.stateController.text = place.state;
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
        // Address field with autocomplete
        _buildAddressField(),
        
        // Suggestions dropdown
        if (_showSuggestions) _buildSuggestions(),
        
        const SizedBox(height: 20),

        // City field
        _buildTextField(
          label: 'City / Area',
          hint: 'e.g. Lekki Phase 1',
          controller: widget.cityController,
        ),
        
        const SizedBox(height: 20),

        // State field
        _buildTextField(
          label: 'State',
          hint: 'e.g. Lagos',
          controller: widget.stateController,
        ),
        
        const SizedBox(height: 24),

        // Map
        _buildMap(),
      ],
    );
  }

  Widget _buildAddressField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Street Address',
          style: AppTextStyles.labelLarge,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: widget.addressController,
          focusNode: _addressFocusNode,
          textCapitalization: TextCapitalization.words,
          style: AppTextStyles.bodyLarge,
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
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.primary),
                    ),
                  )
                : Icon(Icons.search, color: AppColors.textHint),
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
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowMedium,
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
        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.divider),
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
              style: AppTextStyles.bodyMedium,
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
        Text(
          label,
          style: AppTextStyles.labelLarge,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          style: AppTextStyles.bodyLarge,
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
            Text(
              'Pin Location',
              style: AppTextStyles.labelLarge,
            ),
            const SizedBox(width: 8),
            Icon(Icons.touch_app, size: 16, color: AppColors.textHint),
            const SizedBox(width: 4),
            Text(
              'Tap to adjust',
              style: AppTextStyles.caption.copyWith(fontStyle: FontStyle.italic),
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
              // OpenStreetMap tile layer
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ng.clearrent.app',
              ),
              
              // Pin marker
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
              
              // Placeholder when no location selected
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
                      style: AppTextStyles.caption,
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
    
    // Extract street address components
    final houseNumber = address['house_number'] ?? '';
    final road = address['road'] ?? address['street'] ?? '';
    final streetAddress = '$houseNumber $road'.trim();
    
    // Extract city (Nominatim uses various fields)
    final city = address['city'] ??
        address['town'] ??
        address['suburb'] ??
        address['neighbourhood'] ??
        address['locality'] ??
        address['county'] ??
        '';
    
    // Extract state
    final state = address['state'] ?? '';

    return NominatimPlace(
      lat: double.tryParse(json['lat'].toString()) ?? 0.0,
      lng: double.tryParse(json['lon'].toString()) ?? 0.0,
      displayName: json['display_name'] ?? '',
      streetAddress: streetAddress.isNotEmpty ? streetAddress : json['display_name']?.split(',').first ?? '',
      city: city,
      state: state,
    );
  }
}