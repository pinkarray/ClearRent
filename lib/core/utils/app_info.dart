import 'package:package_info_plus/package_info_plus.dart';

/// App version and build number, read once at startup.
///
/// Cached so the screens that display it can stay synchronous — every one of
/// them previously hardcoded "1.0.0", which silently went stale on each release.
class AppInfo {
  static String version = '';
  static String buildNumber = '';

  /// Call before `runApp`.
  static Future<void> load() async {
    final info = await PackageInfo.fromPlatform();
    version = info.version;
    buildNumber = info.buildNumber;
  }
}
