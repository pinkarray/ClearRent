import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps an unfinished issue report so leaving the screen does not throw the
/// typing away.
///
/// The form was lost on any back press, with no warning, and a tenant who
/// had described a fault and attached photos started again from nothing. A
/// warning would have been the smaller fix; keeping the work is the right one.
///
/// Drafts are per property, so a tenant with two homes does not see one home's
/// draft on the other. Photos are already uploaded by the time they reach the
/// draft, so only their URLs are kept - nothing local to go stale.
class IssueDraftService {
  static String _key(String propertyId) => 'clearrent_issue_draft_$propertyId';

  /// Saved after each change. Writing an empty draft clears it instead, so an
  /// emptied form does not come back as a "restored" blank.
  static Future<void> save(
    String propertyId, {
    required String title,
    required String description,
    required String category,
    required String priority,
    required List<String> imageUrls,
  }) async {
    if (title.trim().isEmpty &&
        description.trim().isEmpty &&
        imageUrls.isEmpty) {
      await clear(propertyId);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(propertyId),
      jsonEncode({
        'title': title,
        'description': description,
        'category': category,
        'priority': priority,
        'imageUrls': imageUrls,
        'savedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// The saved draft, or null when there is none (or it cannot be read).
  static Future<Map<String, dynamic>?> load(String propertyId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(propertyId));
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear(String propertyId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(propertyId));
  }
}
