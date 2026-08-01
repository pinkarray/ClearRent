import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles auto-saving and restoring of Add Property form state.
///
/// Saves all form fields as a single JSON blob to SharedPreferences.
/// Only media *paths* go in the draft, so those files have to outlive the
/// session — see [persistMedia].
///
/// Usage:
///   - Call [saveDraft] after each step transition or on debounced field changes
///   - Call [loadDraft] on initState to check for an existing draft
///   - Call [clearDraft] after successful publish or user discard
class PropertyDraftService {
  static const _key = 'clearrent_property_draft';
  static const _mediaDirName = 'property_draft_media';

  /// Where draft photos live.
  ///
  /// Deliberately NOT `Directory.systemTemp` — on Android that resolves to the
  /// app cache, which the OS evicts under storage pressure and which some
  /// reinstalls wipe. A draft that points into it comes back with its photos
  /// silently gone. The documents directory survives until we delete it.
  static Future<Directory> _mediaDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_mediaDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copies picked/captured media somewhere durable and returns the new file.
  /// Falls back to the temp directory if the documents directory is unavailable
  /// — a short-lived photo still beats no photo.
  static Future<File> persistMedia(Uint8List bytes, {String extension = 'jpg'}) async {
    final name = 'clearrent_${DateTime.now().microsecondsSinceEpoch}.$extension';
    try {
      final dir = await _mediaDir();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    } catch (_) {
      final file = File('${Directory.systemTemp.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }
  }

  /// [persistMedia] for something already on disk. Copies rather than reading
  /// the bytes into memory first, which matters for video (up to 50MB).
  /// Returns [source] unchanged if the copy fails — better a fragile path than
  /// no video at all.
  static Future<File> persistMediaFile(File source) async {
    final ext = source.path.contains('.') ? source.path.split('.').last : 'mp4';
    try {
      final dir = await _mediaDir();
      final target = '${dir.path}/clearrent_${DateTime.now().microsecondsSinceEpoch}.$ext';
      return await source.copy(target);
    } catch (_) {
      return source;
    }
  }

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

  /// Whether a draft holds enough for "resume where you left off" to mean
  /// anything.
  ///
  /// A draft is written as soon as the first photo is added, so a landlord who
  /// opens the form, picks one photo and backs out leaves a step-0 draft with
  /// nothing in it. Offering to resume that is noise — it prompts, then drops
  /// them exactly where they would have started anyway.
  static bool isResumable(Map<String, dynamic> draft) {
    final hasText = [
      'address',
      'title',
      'description',
      'rent',
    ].any((k) => (draft[k] as String?)?.trim().isNotEmpty ?? false);
    if (hasText) return true;

    final images = (draft['imagePaths'] as List?) ?? const [];
    final videoPath = (draft['videoPath'] as String?)?.trim() ?? '';
    // Photos only count if the files are still on the phone; a draft whose
    // media has been evicted is not resumable either.
    final hasMedia = images.any((p) => File(p as String).existsSync()) ||
        (videoPath.isNotEmpty && File(videoPath).existsSync());
    if (hasMedia) return true;

    return ((draft['step'] as int?) ?? 0) > 0;
  }

  /// Clear the saved draft (after publish or discard), including any photos
  /// persisted for it — nothing else references them once the draft is gone.
  static Future<void> clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
    try {
      final dir = await _mediaDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}