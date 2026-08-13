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
// Three separate concerns — they never overwrite each other:
// - Area (city/state): authoritative once picked from the dropdown.
//   Drives the inspection fee cluster, so a map tap must never
//   change it. Selecting an area recenters the map on that area,
//   which is the only anchor available when OSM doesn't know the
//   street (the normal case in Nigeria).
// - Street address: free text the landlord owns. OSM may suggest,
//   never assign over text that is already there.
// - Pin: coordinates only.
//
// Smart area matching still applies *until* an area is picked
// explicitly: the geocoded city is fuzzy-matched against the known
// area list (diacritics Ìkòròdú → Ikorodu, LGA suffixes). Matched →
// dropdown auto-fills with a "matched from pin" badge. Unmatched →
// orange hint plus onUnknownAreaDetected so admin can add the area.
// ============================================================

class LocationPickerWidget extends StatefulWidget {
  final TextEditingController addressController;
  final TextEditingController cityController;
  final TextEditingController stateController;
  final Function(double lat, double lng)? onLocationSelected;

  /// Fired when the pin/autocomplete returns a city not in the known areas list.
  /// Use this to log to Firestore (e.g. 'admin_requests' collection) so the
  /// admin can review and add the area to the dropdown.
  final Function(String rawAreaName, double lat, double lng)?
  onUnknownAreaDetected;

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

  /// True once the landlord picks an area from the dropdown. From then on the
  /// area is authoritative: no geocode result may rewrite city or state.
  bool _areaExplicitlySet = false;

  /// Centre of the selected area — the map anchor, and what the pin distance
  /// is measured against. Null when the area geocode found nothing.
  LatLng? _areaAnchor;
  bool _isLocatingArea = false;

  /// Street address the last reverse-geocode proposed, awaiting accept/dismiss.
  /// Only set when the address field already has text.
  String? _addressSuggestion;

  static const LatLng _defaultLocation = LatLng(6.5244, 3.3792);
  static const double _defaultZoom = 15.0;
  static const double _areaZoom = 13.0;

  /// Beyond this the pin is almost certainly not in the selected area.
  static const double _farFromAreaKm = 10.0;

  @override
  void initState() {
    super.initState();
    widget.addressController.addListener(_onAddressChanged);
    // Resuming a draft: the area was already chosen, so treat it as
    // authoritative and re-anchor the map on it.
    final restoredArea = widget.cityController.text.trim();
    if (restoredArea.isNotEmpty) {
      _areaExplicitlySet = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _geocodeArea(restoredArea);
      });
    }
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

      final response = await http.get(
        uri,
        headers: {'User-Agent': 'ClearRent/1.0 (info@verealtytech.com)'},
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
        if (mounted) setState(() => _isSearching = false);
      }
    } catch (e) {
      debugPrint('❌ Search error: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _selectPlace(NominatimPlace place) {
    final location = LatLng(place.lat, place.lng);
    // The area, once chosen explicitly, outranks anything OSM returns.
    final matched =
        _areaExplicitlySet
            ? null
            : InspectionPricing.findMatchingArea(place.city);

    setState(() {
      _selectedLocation = location;
      _showSuggestions = false;
      _suggestions = [];
      _addressSuggestion = null;
      if (!_areaExplicitlySet) {
        _geocodedRawCity = place.city;
        _areaMatchedFromPin = matched != null;
        if (matched != null) widget.cityController.text = matched;
      }
    });

    _suppressSearch = true;
    widget.addressController.text = place.streetAddress;
    if (!_areaExplicitlySet) {
      widget.stateController.text =
          place.state.isNotEmpty ? place.state : 'Lagos';
    }
    _suppressSearch = false;

    if (!_areaExplicitlySet && matched == null && place.city.isNotEmpty) {
      widget.onUnknownAreaDetected?.call(place.city, place.lat, place.lng);
    }

    _mapController.move(location, _defaultZoom);
    widget.onLocationSelected?.call(place.lat, place.lng);
    _addressFocusNode.unfocus();
  }

  void _onAreaSelected(String area) {
    setState(() {
      widget.cityController.text = area;
      _areaExplicitlySet = true;
      // Manually selected — clear auto-match state
      _areaMatchedFromPin = false;
      _geocodedRawCity = null;
      if (widget.stateController.text.isEmpty) {
        widget.stateController.text = 'Lagos';
      }
    });
    _geocodeArea(area);
  }

  /// Centres the map on the selected area so there is an anchor even when OSM
  /// has never heard of the street. On a miss the map is left where it is —
  /// never snapped back to the Lagos default.
  Future<void> _geocodeArea(String area) async {
    setState(() => _isLocatingArea = true);

    final state =
        widget.stateController.text.trim().isNotEmpty
            ? widget.stateController.text.trim()
            : 'Lagos';

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent('$area, $state, Nigeria')}'
        '&format=json'
        '&limit=1'
        '&countrycodes=ng',
      );

      final response = await http.get(
        uri,
        headers: {'User-Agent': 'ClearRent/1.0 (info@verealtytech.com)'},
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          final place = NominatimPlace.fromJson(data.first);
          final anchor = LatLng(place.lat, place.lng);
          setState(() => _areaAnchor = anchor);
          // Keep the landlord's own pin; only move the camera.
          _mapController.move(
            anchor,
            _selectedLocation == null ? _areaZoom : _defaultZoom,
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Area geocode error: $e');
    } finally {
      if (mounted) setState(() => _isLocatingArea = false);
    }
  }

  void _onMapTap(TapPosition tapPosition, LatLng location) {
    setState(() => _selectedLocation = location);
    widget.onLocationSelected?.call(location.latitude, location.longitude);
    _reverseGeocode(location);
  }

  /// A tap moves the pin. What OSM thinks is *there* is only ever a suggestion:
  /// it fills the address when the field is empty, otherwise it is offered for
  /// the landlord to accept. City and state are never rewritten once the area
  /// has been picked explicitly — that field decides the inspection fee.
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
        headers: {'User-Agent': 'ClearRent/1.0 (info@verealtytech.com)'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final place = NominatimPlace.fromJson(data);
        if (!mounted) return;

        final matched =
            _areaExplicitlySet
                ? null
                : InspectionPricing.findMatchingArea(place.city);

        final currentAddress = widget.addressController.text.trim();
        final proposed = place.streetAddress.trim();

        setState(() {
          if (!_areaExplicitlySet) {
            _geocodedRawCity = place.city;
            _areaMatchedFromPin = matched != null;
            if (matched != null) widget.cityController.text = matched;
          }
          _addressSuggestion =
              (currentAddress.isEmpty ||
                      proposed.isEmpty ||
                      proposed == currentAddress)
                  ? null
                  : proposed;
        });

        if (currentAddress.isEmpty && proposed.isNotEmpty) {
          _suppressSearch = true;
          widget.addressController.text = proposed;
          _suppressSearch = false;
        }

        if (!_areaExplicitlySet) {
          if (place.state.isNotEmpty) {
            _suppressSearch = true;
            widget.stateController.text = place.state;
            _suppressSearch = false;
          }
          if (matched == null && place.city.isNotEmpty) {
            widget.onUnknownAreaDetected?.call(
              place.city,
              location.latitude,
              location.longitude,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Reverse geocode error: $e');
    }
  }

  void _acceptAddressSuggestion() {
    final suggestion = _addressSuggestion;
    if (suggestion == null) return;
    _suppressSearch = true;
    widget.addressController.text = suggestion;
    _suppressSearch = false;
    setState(() => _addressSuggestion = null);
  }

  /// Straight-line km between the selected area and the pin, or null when
  /// either is missing.
  double? get _pinDistanceFromArea {
    final anchor = _areaAnchor;
    final pin = _selectedLocation;
    if (anchor == null || pin == null) return null;
    return const Distance().as(LengthUnit.Kilometer, anchor, pin);
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

        // 3. State — derived from the pin, never typed. Leaving it editable let
        // a landlord type "Lagos" over an address the geocoder had placed in
        // another state, which is exactly what the admin reviewer needs to be
        // able to trust. ClearRent operates in Lagos today but does not BLOCK
        // elsewhere: the listing is flagged here, and an admin approves or
        // rejects it.
        _buildStateField(),

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
          selectedArea:
              widget.cityController.text.isNotEmpty
                  ? widget.cityController.text
                  : null,
          onSelected: _onAreaSelected,
        ),
        if (_isLocatingArea)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 6),
                Text(
                  'Centring the map on this area...',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
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
            child: Icon(
              Icons.info_outline,
              size: 13,
              color: Colors.orange.shade700,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Pin returned "$_geocodedRawCity" - not in our list yet, please select the closest area',
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
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            suffixIcon:
                _isSearching
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
        if (_addressSuggestion != null) _buildAddressSuggestion(),
      ],
    );
  }

  /// Offered, never applied: the landlord's typed address stands until they
  /// accept this.
  Widget _buildAddressSuggestion() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.place_outlined,
              size: 15,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The map says this pin is at "$_addressSuggestion"',
                  style: AppTextStyles.caption.copyWith(fontSize: 11),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    GestureDetector(
                      onTap: _acceptAddressSuggestion,
                      child: Text(
                        'Use it',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => setState(() => _addressSuggestion = null),
                      child: Text(
                        'Keep mine',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
      constraints: const BoxConstraints(maxHeight: 240),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Explicit way out. Tapping blank space elsewhere also dismisses the
          // panel, but only because the parent unfocuses the field — on its own
          // a tap on non-focusable space leaves a TextField focused.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Text(
                  'Suggestions from the map',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textHint,
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: _dismissSuggestions,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(child: _buildSuggestionList()),
        ],
      ),
    );
  }

  void _dismissSuggestions() {
    setState(() {
      _showSuggestions = false;
      _suggestions = [];
    });
    _addressFocusNode.unfocus();
  }

  Widget _buildSuggestionList() {
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _suggestions.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.border),
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
    );
  }

  /// Read-only State row. Shows whatever the pin resolved to — including a
  /// state ClearRent doesn't operate in yet, flagged here as a warning rather
  /// than quietly overwritten with 'Lagos'. Not a blocker: an admin reviews
  /// every listing before it can be browsed, and that is where the call is made.
  Widget _buildStateField() {
    // The controller is written outside setState (in _selectPlace), so this
    // listens rather than relying on a rebuild happening to occur.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.stateController,
      builder: (context, value, _) => _buildStateRow(value.text.trim()),
    );
  }

  Widget _buildStateRow(String state) {
    final resolved = state.isEmpty ? 'Lagos' : state;
    final outsideLagos =
        state.isNotEmpty && state.toLowerCase() != 'lagos';
    final warn = Colors.orange.shade700;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('State', style: AppTextStyles.labelMedium),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: outsideLagos ? warn : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                outsideLagos
                    ? Icons.warning_amber_rounded
                    : Icons.lock_outline,
                size: 16,
                color: outsideLagos ? warn : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                resolved,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: outsideLagos ? warn : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          outsideLagos
              ? 'ClearRent operates in Lagos today. You can still submit this, '
                  'but our team reviews every listing and may not approve one '
                  'outside Lagos yet. If the state is wrong, move the pin.'
              : 'Set from your pin, so it always matches the real address.',
          style: AppTextStyles.caption.copyWith(
            color: outsideLagos ? warn : AppColors.textSecondary,
            height: 1.4,
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
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
        _buildPinDistanceWarning(),
      ],
    );
  }

  Widget _buildPinDistanceWarning() {
    final distance = _pinDistanceFromArea;
    if (distance == null || distance <= _farFromAreaKm) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 14,
              color: Colors.orange.shade700,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Your pin is about ${distance.round()}km from '
              '${widget.cityController.text}. Move the pin or change the area - '
              'the area you pick sets the inspection fee.',
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
    final city =
        address['city'] ??
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
      streetAddress:
          streetAddress.isNotEmpty
              ? streetAddress
              : json['display_name']?.split(',').first ?? '',
      city: city,
      state: state,
    );
  }
}
