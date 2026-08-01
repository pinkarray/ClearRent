import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Hands the pin off to whatever maps app the device has.
///
/// Sends coordinates rather than a place name deliberately: the pin is the one
/// part of the location we know is accurate, and OSM frequently can't name a
/// Nigerian street at all.
Future<void> openMapsDirections(
  BuildContext context,
  double latitude,
  double longitude,
) async {
  final uri = Uri.parse(
    'https://www.google.com/maps/dir/?api=1&destination=$latitude,$longitude',
  );
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open a maps app on this device'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Compact directions affordance for list cards, where a tile-loading map would
/// cost far more than it's worth. Renders nothing without a pin.
class DirectionsLink extends StatelessWidget {
  final double? latitude;
  final double? longitude;
  final String label;

  const DirectionsLink({
    super.key,
    required this.latitude,
    required this.longitude,
    this.label = 'Directions',
  });

  @override
  Widget build(BuildContext context) {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => openMapsDirections(context, lat, lng),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions, size: 13, color: AppColors.primary),
            const SizedBox(width: 3),
            Text(
              label,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only map of a property's exact pin, plus a directions hand-off.
///
/// Coordinates are gated: they come either from `properties/{id}/private/location`
/// (owner / assigned agent / admin / tenant with a reveal grant) or from the
/// `propertyLatitude`/`propertyLongitude` copied onto an inspection request when
/// the tenant pays. This widget renders whatever the caller was entitled to read
/// — it does no gating of its own, so only give it coordinates the viewer is
/// allowed to see.
///
/// The map itself is non-interactive by design: these cards sit inside scrolling
/// screens, where a pannable map would steal the scroll gesture. Tapping it opens
/// the device's maps app, which is what someone travelling to the property
/// actually wants.
class PropertyLocationMap extends StatelessWidget {
  final double? latitude;
  final double? longitude;

  /// Address line shown under the map. Exact where the viewer is entitled,
  /// area-level otherwise.
  final String? addressLabel;

  final double height;

  /// Copy for the empty state, which differs by audience — a landlord can go
  /// and fix a missing pin, an agent can only be told it's missing.
  final String emptyMessage;

  const PropertyLocationMap({
    super.key,
    required this.latitude,
    required this.longitude,
    this.addressLabel,
    this.height = 160,
    this.emptyMessage = 'No map pin was set for this property.',
  });

  bool get _hasPin => latitude != null && longitude != null;

  @override
  Widget build(BuildContext context) {
    if (!_hasPin) return _buildEmpty();

    final point = LatLng(latitude!, longitude!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => openMapsDirections(context, latitude!, longitude!),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter: point,
                    initialZoom: 16,
                    // Static: the parent scrolls, the map doesn't.
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'ng.clearrent.app',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: point,
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
                  ],
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(40),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.directions,
                            size: 14, color: Colors.white),
                        const SizedBox(width: 4),
                        Text(
                          'Directions',
                          style: AppTextStyles.caption.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (addressLabel != null && addressLabel!.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.location_on_outlined,
                    size: 14, color: AppColors.textSecondary),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  addressLabel!,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEmpty() {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_off_outlined,
                  size: 22, color: AppColors.textHint),
              const SizedBox(height: 8),
              Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style:
                    AppTextStyles.caption.copyWith(color: AppColors.textHint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
