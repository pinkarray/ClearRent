import 'package:flutter/material.dart';
import 'colors.dart';

class AppTextStyles {
  static const String fontFamily = 'Outfit';

  // Outfit has no ₦ (U+20A6) glyph. Roboto is bundled (see pubspec) purely as
  // a glyph fallback so ₦ renders app-wide while everything else stays Outfit.
  // A BUNDLED family is required — the system 'Roboto' name isn't resolved
  // reliably as a fallback on all Android devices (e.g. MIUI).
  static const List<String> fontFamilyFallback = ['Roboto'];

  // ── Headings ────────────────────────────────────────────────────────────

  static TextStyle get h1 => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.2,
  );

  static TextStyle get h2 => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.3,
  );

  static TextStyle get h3 => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.3,
  );

  static TextStyle get h4 => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  // ── Body ────────────────────────────────────────────────────────────────

  static TextStyle get bodyLarge => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.5,
  );

  static TextStyle get bodyMedium => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.5,
  );

  static TextStyle get bodySmall => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.5,
  );

  // ── Labels ──────────────────────────────────────────────────────────────

  static TextStyle get labelLarge => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  static TextStyle get labelMedium => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  static TextStyle get labelSmall => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
    height: 1.4,
  );

  // ── Button ──────────────────────────────────────────────────────────────

  static TextStyle button = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Colors.white,
    height: 1.2,
  );

  // ── Caption ─────────────────────────────────────────────────────────────

  static TextStyle get caption => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.4,
  );

  // ── Price ───────────────────────────────────────────────────────────────

  static TextStyle get price => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: AppColors.primary,
    height: 1.2,
  );

  // ── Naira helper ────────────────────────────────────────────────────────
  // With the bundled Roboto fallback above, ₦ now renders in every
  // AppTextStyles style, so new code rarely needs this. Kept for existing
  // call sites; it just ensures the Roboto fallback is present.
  static TextStyle naira(TextStyle base) =>
      base.copyWith(fontFamilyFallback: fontFamilyFallback);
}
