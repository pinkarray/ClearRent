import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Issue photos: the inside of someone's home.
///
/// They used to be unsigned public Cloudinary links. Now they go to private
/// Storage under the reporter's uid (`issues/{uid}/...`, write-once, see
/// storage.rules) and the issue stores the paths in `photoPaths`. Anyone else
/// who may see them (landlord, caretaker, admin) gets a short-lived link from
/// getIssuePhotoUrl, which checks they are a party to that issue.
///
/// Issues reported before this, or from older app builds, still carry public
/// URLs in `images`; [isLegacyUrl] tells the two apart so both still display.
class IssuePhotoService {
  IssuePhotoService._();
  static final IssuePhotoService instance = IssuePhotoService._();

  final Map<String, String> _signed = {};
  final Map<String, Uint8List> _own = {};

  static bool isLegacyUrl(String ref) => ref.startsWith('http');

  /// Every photo on an issue: legacy public URLs first, then private paths.
  static List<String> photosOf(Map<String, dynamic> issue) => [
        ...List<String>.from(issue['images'] ?? const []),
        ...List<String>.from(issue['photoPaths'] ?? const []),
      ];

  /// Uploads one photo for an issue still being drafted. Returns its path.
  Future<String?> upload(File file) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final path = 'issues/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await FirebaseStorage.instance
        .ref(path)
        .putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    _own[path] = await file.readAsBytes();
    return path;
  }

  /// The reporter's own photo, read directly (storage.rules lets the owner
  /// read their folder). Used while drafting, before an issue id exists.
  /// Not getDownloadURL: that mints a permanent public token link.
  Future<Uint8List?> ownBytes(String path) async {
    final cached = _own[path];
    if (cached != null) return cached;
    final bytes = await FirebaseStorage.instance.ref(path).getData();
    if (bytes != null) _own[path] = bytes;
    return bytes;
  }

  /// A short-lived link for a photo on [issueId]. Cached for the session;
  /// links last 15 minutes, comfortably longer than a screen stays open.
  Future<String?> signedUrl(String issueId, String path) async {
    final key = '$issueId|$path';
    final cached = _signed[key];
    if (cached != null) return cached;
    final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('getIssuePhotoUrl')
        .call({'issueId': issueId, 'path': path});
    final url = (res.data as Map?)?['url'] as String?;
    if (url != null) _signed[key] = url;
    return url;
  }
}
