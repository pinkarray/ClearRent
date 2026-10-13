import 'dart:async';
import 'package:geolocator/geolocator.dart';

/// One GPS reading, as the server needs it to confirm a pin or check that a
/// video-viewing handler is at the property.
class LocationReading {
  final double latitude;
  final double longitude;
  final double accuracyM;

  /// Android reports a reading from a mock-location app as mocked. The server
  /// refuses those.
  final bool isMocked;

  const LocationReading({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.isMocked,
  });

  Map<String, dynamic> toCallableData() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracyM': accuracyM,
        'isMocked': isMocked,
      };
}

/// Why a reading could not be taken, worded for the user.
class LocationUnavailable implements Exception {
  final String message;

  /// True when the user must change a setting (location off, or permission
  /// refused for good), so the UI can offer to open Settings.
  final bool needsSettings;

  const LocationUnavailable(this.message, {this.needsSettings = false});

  @override
  String toString() => message;
}

/// Foreground location only. Nothing here runs in the background.
class LocationService {
  /// A fix this good ends the wait early.
  static const double _goodEnoughM = 15;
  // A cold GPS start (no fix for days) can need 30s+ even outdoors; tested
  // 2026-10-13, 15s indoors returned nothing at all.
  static const Duration _maxWait = Duration(seconds: 45);

  /// Ask for permission if needed, then return the most accurate reading seen
  /// within [_maxWait]. Throws [LocationUnavailable].
  Future<LocationReading> currentReading() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationUnavailable(
        'Location is turned off. Turn it on and try again.',
        needsSettings: true,
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationUnavailable(
        'Location permission is blocked for ClearRent. Allow it in Settings.',
        needsSettings: true,
      );
    }
    if (permission == LocationPermission.denied) {
      throw const LocationUnavailable(
        'ClearRent needs your location for this. Please allow it.',
      );
    }

    Position? best;
    final done = Completer<void>();
    final sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
      ),
    ).listen(
      (p) {
        if (best == null || p.accuracy < best!.accuracy) best = p;
        if (p.accuracy <= _goodEnoughM && !done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future.timeout(_maxWait, onTimeout: () {});
    await sub.cancel();

    final p = best;
    if (p == null) {
      throw const LocationUnavailable(
        'Could not get your location. Step outside or near a window and '
        'try again.',
      );
    }
    return LocationReading(
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyM: p.accuracy,
      isMocked: p.isMocked,
    );
  }

  Future<void> openSettings() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}
