import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/utils/app_info.dart';

/// Remote kill-switch / upgrade nudge, read from `config/app_version`.
///
/// Same live-config pattern as `PricingService`'s `config/areas` listener: a
/// value admin can change with no Play release. That matters more here than
/// anywhere else — it lets a bad build be retired without spending another
/// version code, and version codes are a finite resource we have already
/// burned several of.
///
/// **This class fails open, deliberately and at every step.** A missing doc, an
/// unreadable doc, a malformed field, an unparseable local build number — all
/// of them resolve to "not blocked". A typo in `minSupportedBuild` would
/// otherwise brick every install simultaneously, and the only recovery would be
/// shipping a new release to users who can no longer be reached. The failure
/// mode of being too permissive is a user on an old build; the failure mode of
/// being too strict is a dead app.
///
/// Document shape (all fields optional):
/// ```
/// config/app_version {
///   minSupportedBuild: 4,      // below this → hard block
///   latestBuild: 7,            // below this → dismissible nudge
///   message: "…",              // shown in both
///   storeUrl: "https://…",     // where the button goes
/// }
/// ```
class AppVersionService {
  AppVersionService._();
  static final AppVersionService instance = AppVersionService._();

  static const _defaultStoreUrl =
      'https://play.google.com/store/apps/details?id=com.verealtytech.clearrent';

  final _controller = StreamController<AppVersionGate>.broadcast();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  AppVersionGate _current = const AppVersionGate.open();

  /// The last resolved gate. Non-blocking until the config says otherwise.
  AppVersionGate get current => _current;

  /// Emits whenever the remote config changes. Replays nothing on subscribe —
  /// read [current] for the state so far.
  Stream<AppVersionGate> get changes => _controller.stream;

  /// Subscribe to the config. Safe to call more than once.
  void start() {
    _sub ??= FirebaseFirestore.instance
        .collection('config')
        .doc('app_version')
        .snapshots()
        .listen(
      (doc) => _apply(doc.data()),
      onError: (Object e) {
        // Keep whatever we last resolved. An unreadable config must never be
        // able to turn INTO a block.
        developer.log('app_version unreadable - gate left open: $e',
            name: 'AppVersionService');
      },
    );
  }

  void _apply(Map<String, dynamic>? data) {
    final build = int.tryParse(AppInfo.buildNumber);
    if (build == null) {
      // We cannot tell which build this is, so we cannot judge it.
      _emit(const AppVersionGate.open());
      return;
    }

    final minSupported = _readBuild(data?['minSupportedBuild']);
    final latest = _readBuild(data?['latestBuild']);
    final message = data?['message'];
    final storeUrl = data?['storeUrl'];

    _emit(AppVersionGate(
      blocked: build < minSupported,
      updateAvailable: build < latest,
      message: (message is String && message.trim().isNotEmpty)
          ? message.trim()
          : null,
      storeUrl: (storeUrl is String && storeUrl.startsWith('https://'))
          ? storeUrl
          : _defaultStoreUrl,
    ));
  }

  /// Any value that isn't a sane build number reads as 0, which blocks nothing.
  /// Strings are accepted because a number typed into the Firestore console
  /// arrives as one more often than you'd like.
  int _readBuild(Object? value) {
    if (value is int) return value >= 0 ? value : 0;
    if (value is num) return value >= 0 ? value.toInt() : 0;
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  void _emit(AppVersionGate gate) {
    _current = gate;
    if (!_controller.isClosed) _controller.add(gate);
    developer.log(
      'app_version gate: blocked=${gate.blocked} '
      'update=${gate.updateAvailable} build=${AppInfo.buildNumber}',
      name: 'AppVersionService',
    );
  }
}

class AppVersionGate {
  /// This build is below `minSupportedBuild` — the app is unusable.
  final bool blocked;

  /// A newer build exists. Worth a nudge, not a wall.
  final bool updateAvailable;

  /// Admin-authored explanation, if there is one.
  final String? message;

  /// Where the "Update" button goes.
  final String storeUrl;

  const AppVersionGate({
    required this.blocked,
    required this.updateAvailable,
    this.message,
    required this.storeUrl,
  });

  /// The safe state: nothing is wrong with this build.
  const AppVersionGate.open()
      : blocked = false,
        updateAvailable = false,
        message = null,
        storeUrl = AppVersionService._defaultStoreUrl;
}
