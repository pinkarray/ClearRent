import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;

class SavedPropertiesService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Get current user ID
  String? get _currentUserId => _auth.currentUser?.uid;

  // Collection reference for user's saved properties
  CollectionReference? get _savedRef {
    if (_currentUserId == null) return null;
    return _firestore
        .collection('users')
        .doc(_currentUserId)
        .collection('savedProperties');
  }

  // ============ SAVE / UNSAVE ============

  /// Save a property to favorites
  Future<bool> saveProperty(String propertyId) async {
    try {
      if (_savedRef == null) {
        developer.log('❌ User not authenticated', name: 'SavedPropertiesService');
        return false;
      }

      await _savedRef!.doc(propertyId).set({
        'propertyId': propertyId,
        'savedAt': FieldValue.serverTimestamp(),
      });

      developer.log('✅ Property saved: $propertyId', name: 'SavedPropertiesService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to save property: $e',
        name: 'SavedPropertiesService',
        error: e,
      );
      return false;
    }
  }

  /// Remove a property from favorites
  Future<bool> unsaveProperty(String propertyId) async {
    try {
      if (_savedRef == null) {
        developer.log('❌ User not authenticated', name: 'SavedPropertiesService');
        return false;
      }

      await _savedRef!.doc(propertyId).delete();

      developer.log('✅ Property unsaved: $propertyId', name: 'SavedPropertiesService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to unsave property: $e',
        name: 'SavedPropertiesService',
        error: e,
      );
      return false;
    }
  }

  /// Toggle save status
  Future<bool> toggleSave(String propertyId) async {
    final isSaved = await isPropertySaved(propertyId);
    if (isSaved) {
      return await unsaveProperty(propertyId);
    } else {
      return await saveProperty(propertyId);
    }
  }

  // ============ READ ============

  /// Check if a property is saved
  Future<bool> isPropertySaved(String propertyId) async {
    try {
      if (_savedRef == null) return false;

      final doc = await _savedRef!.doc(propertyId).get();
      return doc.exists;
    } catch (e) {
      developer.log(
        '❌ Failed to check saved status: $e',
        name: 'SavedPropertiesService',
        error: e,
      );
      return false;
    }
  }

  /// Get all saved property IDs
  Future<Set<String>> getSavedPropertyIds() async {
    try {
      if (_savedRef == null) return {};

      final snapshot = await _savedRef!.get();
      
      final ids = snapshot.docs.map((doc) => doc.id).toSet();
      developer.log('✅ Loaded ${ids.length} saved properties', name: 'SavedPropertiesService');
      return ids;
    } catch (e) {
      developer.log(
        '❌ Failed to get saved properties: $e',
        name: 'SavedPropertiesService',
        error: e,
      );
      return {};
    }
  }

  /// Stream of saved property IDs (real-time updates)
  Stream<Set<String>> savedPropertyIdsStream() {
    if (_savedRef == null) {
      return Stream.value({});
    }

    return _savedRef!.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) => doc.id).toSet();
    });
  }

  /// Get count of saved properties
  Future<int> getSavedCount() async {
    try {
      if (_savedRef == null) return 0;

      final snapshot = await _savedRef!.count().get();
      return snapshot.count ?? 0;
    } catch (e) {
      developer.log(
        '❌ Failed to get saved count: $e',
        name: 'SavedPropertiesService',
        error: e,
      );
      return 0;
    }
  }
}