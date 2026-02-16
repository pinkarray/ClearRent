import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:developer' as developer;

/// Monitors network connectivity and provides real-time status.
/// Uses connectivity_plus for connection type detection + actual
/// internet reachability check via DNS lookup.
class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._();
  factory ConnectivityService() => _instance;
  ConnectivityService._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  final _controller = StreamController<bool>.broadcast();

  /// Stream of connectivity status (true = online, false = offline)
  Stream<bool> get onConnectivityChanged => _controller.stream;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  /// Initialize — call once at app startup
  Future<void> initialize() async {
    // Check initial state
    await checkConnection();

    // Listen for changes
    _subscription = _connectivity.onConnectivityChanged.listen((results) async {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);

      if (!hasConnection) {
        _updateStatus(false);
      } else {
        // Has WiFi/mobile but verify actual internet
        await checkConnection();
      }
    });
  }

  /// Check actual internet reachability (not just WiFi connected)
  Future<bool> checkConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      final online = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      _updateStatus(online);
      return online;
    } on SocketException catch (_) {
      _updateStatus(false);
      return false;
    } on TimeoutException catch (_) {
      _updateStatus(false);
      return false;
    } catch (e) {
      developer.log('❌ Connection check error: $e',
          name: 'ConnectivityService');
      _updateStatus(false);
      return false;
    }
  }

  void _updateStatus(bool online) {
    if (_isOnline != online) {
      _isOnline = online;
      _controller.add(online);
      developer.log(
        online ? '🟢 Online' : '🔴 Offline',
        name: 'ConnectivityService',
      );
    }
  }

  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}