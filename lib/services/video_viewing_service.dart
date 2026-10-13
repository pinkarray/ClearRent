import 'package:cloud_functions/cloud_functions.dart';
import 'location_service.dart';

/// What the call screen needs to join the Agora channel.
class VideoCallCredentials {
  final String appId;
  final String channel;
  final int uid;
  final String token;

  const VideoCallCredentials({
    required this.appId,
    required this.channel,
    required this.uid,
    required this.token,
  });

  factory VideoCallCredentials.fromMap(Map<String, dynamic> m) =>
      VideoCallCredentials(
        appId: m['appId'] as String,
        channel: m['channel'] as String,
        uid: (m['uid'] as num).toInt(),
        token: m['token'] as String,
      );
}

/// A reason the call can't start or be joined, worded for the user.
class VideoViewingException implements Exception {
  final String message;
  final bool needsSettings;
  const VideoViewingException(this.message, {this.needsSettings = false});

  @override
  String toString() => message;
}

/// Video viewings (functions/src/video_viewing_ops.ts). The host must be at
/// the property: start() sends a GPS reading the server checks against the
/// property's confirmed pin before handing out call credentials.
class VideoViewingService {
  final _location = LocationService();

  HttpsCallable _callable(String name) => FirebaseFunctions.instance
      .httpsCallable(
        name,
        options: HttpsCallableOptions(timeout: const Duration(seconds: 25)),
      );

  /// Host only. Reads GPS, then asks the server to open the call.
  Future<VideoCallCredentials> start(String requestId) async {
    final LocationReading reading;
    try {
      reading = await _location.currentReading();
    } on LocationUnavailable catch (e) {
      throw VideoViewingException(e.message, needsSettings: e.needsSettings);
    }
    return _credentials('startVideoViewing', {
      'requestId': requestId,
      ...reading.toCallableData(),
    });
  }

  /// Tenant, or a host rejoining after a drop.
  Future<VideoCallCredentials> join(String requestId) =>
      _credentials('joinVideoViewing', {'requestId': requestId});

  /// Tenant: "I'm waiting for the call". Recorded with server time; it is what
  /// proves a host no-show (videoViewingNoShowSweep refunds automatically).
  Future<void> markReady(String requestId) async {
    try {
      await _callable('markVideoViewingReady')
          .call<Map<String, dynamic>>({'requestId': requestId});
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'deadline-exceeded' || e.code == 'unavailable') {
        throw const VideoViewingException(
          'Could not reach ClearRent. Check your connection and try again.',
        );
      }
      throw VideoViewingException(
        e.message ?? 'Could not record that. Please try again.',
      );
    }
  }

  /// The host's position during the call, as evidence. Best effort: indoors
  /// there may be no fix, and nothing here may interrupt the call.
  Future<void> reportPresence(String requestId) async {
    Map<String, dynamic> reading = {};
    try {
      reading = (await _location.currentReading()).toCallableData();
    } catch (_) {
      // No fix: the server records that too.
    }
    try {
      await _callable('recordVideoPresence')
          .call<Map<String, dynamic>>({'requestId': requestId, ...reading});
    } catch (_) {}
  }

  Future<VideoCallCredentials> _credentials(
    String name,
    Map<String, dynamic> data,
  ) async {
    try {
      final result = await _callable(name).call<Map<String, dynamic>>(data);
      return VideoCallCredentials.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'deadline-exceeded' || e.code == 'unavailable') {
        throw const VideoViewingException(
          'Could not reach ClearRent. Check your connection and try again.',
        );
      }
      throw VideoViewingException(
        e.message ?? 'Could not open the call. Please try again.',
      );
    }
  }
}
