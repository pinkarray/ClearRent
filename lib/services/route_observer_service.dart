import 'package:flutter/widgets.dart';

/// Tracks the currently-displayed route and its extra data.
///
/// Wired into GoRouter via the `observers` parameter, this lets other
/// services (notably NotificationService) decide whether a push notification
/// should be visually suppressed because the user is already looking at
/// the screen the notification is about.
class RouteObserverService extends NavigatorObserver {
  RouteObserverService._();
  static final RouteObserverService instance = RouteObserverService._();

  String? _currentRoute;
  Object? _currentExtra;

  String? get currentRoute => _currentRoute;
  Object? get currentExtra => _currentExtra;

  void _update(Route<dynamic>? route) {
    if (route == null) {
      _currentRoute = null;
      _currentExtra = null;
      return;
    }
    final settings = route.settings;
    _currentRoute = settings.name;
    _currentExtra = settings.arguments;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _update(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(previousRoute);
  }

  /// Returns true if [targetRoute] matches the current screen, optionally
  /// requiring that all entries in [matchParams] match the current extra map.
  bool isOnRoute(String targetRoute, {Map<String, String>? matchParams}) {
    if (_currentRoute != targetRoute) return false;
    if (matchParams == null || matchParams.isEmpty) return true;

    final extra = _currentExtra;
    if (extra is! Map) return false;
    for (final entry in matchParams.entries) {
      final v = extra[entry.key];
      if (v == null || v.toString() != entry.value) return false;
    }
    return true;
  }
}