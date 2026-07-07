import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/colors.dart';

// ─── Preference key ─────────────────────────────────────────────────────────

const _kThemeModeKey = 'clearrent_theme_mode';

// ─── Provider ───────────────────────────────────────────────────────────────

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

// ─── Notifier ───────────────────────────────────────────────────────────────

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  /// Load persisted preference. Falls back to [ThemeMode.system].
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kThemeModeKey);
    switch (stored) {
      case 'light':
        state = ThemeMode.light;
        break;
      case 'dark':
        state = ThemeMode.dark;
        break;
      default:
        state = ThemeMode.system;
    }
    _syncAppColors();
  }

  /// Change theme and persist the choice.
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    _syncAppColors();
    final prefs = await SharedPreferences.getInstance();
    switch (mode) {
      case ThemeMode.light:
        await prefs.setString(_kThemeModeKey, 'light');
        break;
      case ThemeMode.dark:
        await prefs.setString(_kThemeModeKey, 'dark');
        break;
      case ThemeMode.system:
        await prefs.remove(_kThemeModeKey);
        break;
    }
  }

  /// Keep [AppColors] in sync so all static getters return the right palette.
  void _syncAppColors() {
    final isDark = _resolvedIsDark(state);
    AppColors.setDarkMode(isDark);
  }

  /// Resolves [ThemeMode.system] into a concrete light/dark boolean.
  static bool _resolvedIsDark(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return true;
      case ThemeMode.light:
        return false;
      case ThemeMode.system:
        return SchedulerBinding
                .instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    }
  }
}

// ─── Helper: call from didChangePlatformBrightness or MaterialApp builder ──

/// Should be called whenever the effective brightness may have changed
/// (e.g. inside the MaterialApp `builder` or from a
/// `WidgetsBindingObserver.didChangePlatformBrightness` callback).
void syncAppColorsWithBrightness(ThemeMode mode, Brightness platformBrightness) {
  bool isDark;
  switch (mode) {
    case ThemeMode.dark:
      isDark = true;
      break;
    case ThemeMode.light:
      isDark = false;
      break;
    case ThemeMode.system:
      isDark = platformBrightness == Brightness.dark;
      break;
  }
  AppColors.setDarkMode(isDark);
}

// ─── ThemeData factories ────────────────────────────────────────────────────

const _fontFamily = 'Outfit';

// Outfit has no ₦ glyph; the bundled Roboto family (see pubspec) is a
// glyph-only fallback so plain Text widgets render ₦ too.
const _fontFallback = <String>['Roboto'];

ThemeData buildLightTheme() {
  // Ensure AppColors is in light mode for building theme
  AppColors.setDarkMode(false);
  return _buildTheme(Brightness.light);
}

ThemeData buildDarkTheme() {
  // Ensure AppColors is in dark mode for building theme
  AppColors.setDarkMode(true);
  return _buildTheme(Brightness.dark);
}

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  // Temporarily set palette so AppColors getters return correct values
  final prevDark = AppColors.isDark;
  AppColors.setDarkMode(isDark);

  final theme = ThemeData(
    fontFamily: _fontFamily,
    brightness: brightness,
    primaryColor: AppColors.primary,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.secondary,
      onSecondary: Colors.white,
      error: AppColors.error,
      onError: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(color: AppColors.textPrimary),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: AppColors.divider,
      thickness: 1,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.textHint,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
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
        borderSide: BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.error, width: 2),
      ),
      hintStyle: TextStyle(color: AppColors.textHint, fontFamily: _fontFamily),
      labelStyle: TextStyle(color: AppColors.textSecondary, fontFamily: _fontFamily),
      floatingLabelStyle: TextStyle(color: AppColors.primary, fontFamily: _fontFamily),
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: AppColors.textPrimary, fontFamily: _fontFamily),
      bodyMedium: TextStyle(color: AppColors.textPrimary, fontFamily: _fontFamily),
      bodySmall: TextStyle(color: AppColors.textSecondary, fontFamily: _fontFamily),
      titleLarge: TextStyle(color: AppColors.textPrimary, fontFamily: _fontFamily),
      titleMedium: TextStyle(color: AppColors.textPrimary, fontFamily: _fontFamily),
      titleSmall: TextStyle(color: AppColors.textPrimary, fontFamily: _fontFamily),
      labelLarge: TextStyle(color: AppColors.textPrimary, fontFamily: _fontFamily),
      labelMedium: TextStyle(color: AppColors.textSecondary, fontFamily: _fontFamily),
      labelSmall: TextStyle(color: AppColors.textSecondary, fontFamily: _fontFamily),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: AppColors.primary,
      unselectedLabelColor: AppColors.textSecondary,
      indicatorColor: AppColors.primary,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.primary;
        return AppColors.textHint;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.primary.withAlpha(80);
        }
        return AppColors.border;
      }),
    ),
  );

  // Restore previous palette state
  AppColors.setDarkMode(prevDark);

  // Apply the bundled Roboto glyph-fallback across the whole text theme so
  // plain Text widgets (not just AppTextStyles) render ₦ correctly.
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: _fontFallback),
    primaryTextTheme:
        theme.primaryTextTheme.apply(fontFamilyFallback: _fontFallback),
  );
}