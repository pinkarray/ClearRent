import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles auto-saving and restoring of Add Property form state.
///
/// Saves all form fields as a single JSON blob to SharedPreferences.
/// Image/video file paths are saved (not the files themselves).
///
/// Usage:
///   - Call [saveDraft] after each step transition or on debounced field changes
///   - Call [loadDraft] on initState to check for an existing draft
///   - Call [clearDraft] after successful publish or user discard
class PropertyDraftService {
  static const _key = 'clearrent_property_draft';

  /// Save the current form state to SharedPreferences
  static Future<void> saveDraft(Map<String, dynamic> formState) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(formState);
      await prefs.setString(_key, json);
    } catch (e) {
      // Silently fail — draft saving is best-effort
    }
  }

  /// Load a previously saved draft, or null if none exists
  static Future<Map<String, dynamic>?> loadDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_key);
      if (json == null || json.isEmpty) return null;
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      // Corrupted draft — clear it
      await clearDraft();
      return null;
    }
  }

  /// Check if a draft exists without loading it
  static Future<bool> hasDraft() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key);
  }

  /// Clear the saved draft (after publish or discard)
  static Future<void> clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}