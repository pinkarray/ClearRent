import 'package:flutter/material.dart';

/// Holds the raw color values for a single theme (light or dark).
class _Palette {
  final Color primary;
  final Color primaryLight;
  final Color primaryDark;

  final Color secondary;
  final Color secondaryLight;
  final Color secondaryDark;

  final Color background;
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final Color textHint;
  final Color border;
  final Color divider;

  final Color success;
  final Color successLight;
  final Color error;
  final Color errorLight;
  final Color warning;
  final Color warningLight;
  final Color info;
  final Color infoLight;

  final Color verified;

  final Color shadowLight;
  final Color shadowMedium;

  const _Palette({
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.secondary,
    required this.secondaryLight,
    required this.secondaryDark,
    required this.background,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.textHint,
    required this.border,
    required this.divider,
    required this.success,
    required this.successLight,
    required this.error,
    required this.errorLight,
    required this.warning,
    required this.warningLight,
    required this.info,
    required this.infoLight,
    required this.verified,
    required this.shadowLight,
    required this.shadowMedium,
  });
}

// ─── Light palette (your current colors, unchanged) ─────────────────────────

const _light = _Palette(
  // Primary - Trust, Clarity
  primary: Color(0xFF0A7B6C),
  primaryLight: Color(0xFF4DA69A),
  primaryDark: Color(0xFF065749),

  // Secondary - Warmth, Action
  secondary: Color(0xFFF4A836),
  secondaryLight: Color(0xFFF7C067),
  secondaryDark: Color(0xFFD4922E),

  // Neutrals
  background: Color(0xFFF8F9FA),
  surface: Color(0xFFFFFFFF),
  textPrimary: Color(0xFF1A1A2E),
  textSecondary: Color(0xFF6B7280),
  textHint: Color(0xFF9CA3AF),
  border: Color(0xFFE5E7EB),
  divider: Color(0xFFF3F4F6),

  // Status. `success` is derived from the brand teal above rather than lifted
  // from a stock palette: the old #10B981 (Tailwind emerald) was a different
  // hue AND far brighter, so any green next to the brand read as a second
  // design system — loudest wherever it filled a button.
  success: Color(0xFF0E8F6B),
  successLight: Color(0xFFD6F0E7),
  error: Color(0xFFEF4444),
  errorLight: Color(0xFFFEE2E2),
  warning: Color(0xFFF59E0B),
  warningLight: Color(0xFFFEF3C7),
  info: Color(0xFF3B82F6),
  infoLight: Color(0xFFDBEAFE),

  // Verified badge
  verified: Color(0xFF0A7B6C),

  // Shadows
  shadowLight: Color(0x0A000000),
  shadowMedium: Color(0x1A000000),
);

// ─── Dark palette ───────────────────────────────────────────────────────────

const _dark = _Palette(
  // Primary - slightly brighter for dark bg readability
  primary: Color(0xFF0FA88F),
  primaryLight: Color(0xFF5CC4B5),
  primaryDark: Color(0xFF087A6A),

  // Secondary
  secondary: Color(0xFFF4A836),
  secondaryLight: Color(0xFFF7C067),
  secondaryDark: Color(0xFFD4922E),

  // Neutrals
  background: Color(0xFF121212),
  surface: Color(0xFF1E1E1E),
  textPrimary: Color(0xFFE8E8EC),
  textSecondary: Color(0xFF9CA3AF),
  textHint: Color(0xFF6B7280),
  border: Color(0xFF2E2E2E),
  divider: Color(0xFF252525),

  // Status – same hues, slightly muted for dark context
  success: Color(0xFF2FB894),
  successLight: Color(0xFF06463A),
  error: Color(0xFFF87171),
  errorLight: Color(0xFF7F1D1D),
  warning: Color(0xFFFBBF24),
  warningLight: Color(0xFF78350F),
  info: Color(0xFF60A5FA),
  infoLight: Color(0xFF1E3A5F),

  // Verified badge
  verified: Color(0xFF0FA88F),

  // Shadows – more pronounced on dark surfaces
  shadowLight: Color(0x33000000),
  shadowMedium: Color(0x66000000),
);

// ─── Public API ─────────────────────────────────────────────────────────────
// Every existing `AppColors.xxx` call keeps working with zero changes.

class AppColors {
  AppColors._();

  /// Call once from `main()` or whenever the theme changes.
  /// [dark] should be `true` when the resolved theme is dark mode.
  static void setDarkMode(bool dark) => _isDark = dark;

  static bool _isDark = false;
  static bool get isDark => _isDark;

  static _Palette get _p => _isDark ? _dark : _light;

  // Primary
  static Color get primary => _p.primary;
  static Color get primaryLight => _p.primaryLight;
  static Color get primaryDark => _p.primaryDark;

  // Secondary
  static Color get secondary => _p.secondary;
  static Color get secondaryLight => _p.secondaryLight;
  static Color get secondaryDark => _p.secondaryDark;

  // Neutrals
  static Color get background => _p.background;
  static Color get surface => _p.surface;
  static Color get textPrimary => _p.textPrimary;
  static Color get textSecondary => _p.textSecondary;
  static Color get textHint => _p.textHint;
  static Color get border => _p.border;
  static Color get divider => _p.divider;

  // Status
  static Color get success => _p.success;
  static Color get successLight => _p.successLight;
  static Color get error => _p.error;
  static Color get errorLight => _p.errorLight;
  static Color get warning => _p.warning;
  static Color get warningLight => _p.warningLight;
  static Color get info => _p.info;
  static Color get infoLight => _p.infoLight;

  // Verified badge
  static Color get verified => _p.verified;

  // Shadows
  static Color get shadowLight => _p.shadowLight;
  static Color get shadowMedium => _p.shadowMedium;
}