import 'package:flutter/widgets.dart';

/// Tracks the currently-displayed route and any per-screen params
/// the screen has explicitly registered.
///
/// Wired into GoRouter via the `observers` parameter, this lets other
/// services (notably NotificationService) decide whether a push
/// notification should be visually suppressed because the user is
/// already looking at the screen the notification is about.
///
/// For routes that need parameter-level matching (e.g. chat, where
/// suppression must only fire for the *same* conversation), the
/// screen explicitly registers its params via [setActiveParams] in
/// initState and clears them in dispose. GoRouter's state.extra
/// isn't visible via NavigatorObserver, so this hook is the
/// workaround.
class RouteObserverService extends NavigatorObserver {
  RouteObserverService._();
  static final RouteObserverService instance = RouteObserverService._();

  String? _currentRoute;
  Object? _currentExtra;
  Map<String, dynamic>? _activeParams;

  String? get currentRoute => _currentRoute;
  Object? get currentExtra => _currentExtra;

  /// Called by a screen in initState to register identifying params
  /// (e.g. conversationId for a chat screen). Cleared in dispose.
  void setActiveParams(Map<String, dynamic>? params) {
    _activeParams = params;
  }

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

  /// Returns true if [targetRoute] matches the current screen,
  /// optionally requiring that all entries in [matchParams] match
  /// the active params the current screen has registered.
  bool isOnRoute(String targetRoute, {Map<String, String>? matchParams}) {
    if (_currentRoute != targetRoute) return false;
    if (matchParams == null || matchParams.isEmpty) return true;

    final active = _activeParams;
    if (active == null) return false;
    for (final entry in matchParams.entries) {
      final v = active[entry.key];
      if (v == null || v.toString() != entry.value) return false;
    }
    return true;
  }
}