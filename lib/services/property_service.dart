import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;
import 'package:cloudinary_public/cloudinary_public.dart';
import '../shared/models/property_model.dart';
import 'activity_service.dart';

class PropertyService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ActivityService _activityService = ActivityService();

  // Cloudinary configuration - same as verification
  final _cloudinary = CloudinaryPublic(
    'den5t1dai',
    'clearrent_uploads',
    cache: false,
  );

  // Collection reference
  CollectionReference get _propertiesRef => _firestore.collection('properties');

  // Get current user ID
  String? get _currentUserId => _auth.currentUser?.uid;

  // ============ CREATE ============

  /// Upload a single image to Cloudinary
  Future<String?> uploadImage(File imageFile) async {
    try {
      final response = await _cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          imageFile.path,
          folder: 'clearrent/properties/$_currentUserId',
          resourceType: CloudinaryResourceType.Image,
        ),
      );
      developer.log(
        '✅ Image uploaded: ${response.secureUrl}',
        name: 'PropertyService',
      );
      return response.secureUrl;
    } catch (e) {
      developer.log(
        '❌ Image upload failed: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return null;
    }
  }

  /// Upload multiple images to Cloudinary
  Future<List<String>> uploadImages(List<File> imageFiles) async {
    final List<String> urls = [];

    for (final file in imageFiles) {
      final url = await uploadImage(file);
      if (url != null) {
        urls.add(url);
      }
    }

    return urls;
  }

  /// Create a new property in Firestore
  Future<String?> createProperty({
    required String title,
    required String description,
    required String propertyType,
    required int bedrooms,
    required int bathrooms,
    required int toilets,
    required List<String> imageUrls,
    required String address,
    required String city,
    required String state,
    double? latitude,
    double? longitude,
    required double rent,
    required String rentFrequency,
    double agentFee = 0,
    String agentFeePaidBy = 'tenant',
    List<String> amenities = const [],
    List<String> rules = const [],
  }) async {
    try {
      if (_currentUserId == null) {
        developer.log('❌ User not authenticated', name: 'PropertyService');
        return null;
      }

      // Get landlord info from users collection
      final userDoc =
          await _firestore.collection('users').doc(_currentUserId).get();
      final userData = userDoc.data();
      final landlordName = userData?['fullName'] ?? 'Landlord';
      final landlordPhone = userData?['phone'] ?? '';
      final isVerified = userData?['verificationStatus'] == 'verified';

      // Create property document
      final propertyData = {
        'landlordId': _currentUserId,
        'title': title,
        'description': description,
        'propertyType': propertyType,
        'bedrooms': bedrooms,
        'bathrooms': bathrooms,
        'toilets': toilets,
        'images': imageUrls,
        'address': address,
        'city': city,
        'state': state,
        'lga': '', // Can be added later
        'latitude': latitude,
        'longitude': longitude,
        'rent': rent,
        'rentFrequency': rentFrequency,
        'agentFee': agentFee,
        'agentFeePaidBy': agentFeePaidBy,
        'isAvailable': true,
        'isVerified': isVerified, // Based on landlord verification status
        'amenities': amenities,
        'rules': rules,
        'landlordName': landlordName,
        'landlordPhone': landlordPhone,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final docRef = await _propertiesRef.add(propertyData);
      developer.log(
        '✅ Property created with ID: ${docRef.id}',
        name: 'PropertyService',
      );

      // Track activity
      await _activityService.trackPropertyAdded(
        landlordId: _currentUserId!,
        propertyId: docRef.id,
        propertyTitle: title,
      );

      return docRef.id;
    } catch (e) {
      developer.log(
        '❌ Failed to create property: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return null;
    }
  }

  // ============ READ ============

  /// Get all available properties (for tenants)
  Future<List<PropertyModel>> getAllProperties() async {
    try {
      final snapshot =
          await _propertiesRef
              .where('isAvailable', isEqualTo: true)
              .orderBy('createdAt', descending: true)
              .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return PropertyModel.fromJson(_convertTimestamps(data));
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get properties: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return [];
    }
  }

  /// Get properties by landlord ID (for landlord dashboard)
  Future<List<PropertyModel>> getLandlordProperties() async {
    try {
      if (_currentUserId == null) return [];

      final snapshot =
          await _propertiesRef
              .where('landlordId', isEqualTo: _currentUserId)
              .orderBy('createdAt', descending: true)
              .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return PropertyModel.fromJson(_convertTimestamps(data));
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get landlord properties: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return [];
    }
  }

  /// Get a single property by ID
  Future<PropertyModel?> getProperty(String propertyId) async {
    try {
      final doc = await _propertiesRef.doc(propertyId).get();

      if (!doc.exists) return null;

      final data = doc.data() as Map<String, dynamic>;
      data['id'] = doc.id;
      return PropertyModel.fromJson(_convertTimestamps(data));
    } catch (e) {
      developer.log(
        '❌ Failed to get property: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return null;
    }
  }

  /// Search properties by city/area
  Future<List<PropertyModel>> searchProperties({
    String? city,
    String? propertyType,
    double? minRent,
    double? maxRent,
  }) async {
    try {
      Query query = _propertiesRef.where('isAvailable', isEqualTo: true);

      if (city != null && city.isNotEmpty && city != 'All Areas') {
        query = query.where('city', isEqualTo: city);
      }

      if (propertyType != null &&
          propertyType.isNotEmpty &&
          propertyType != 'all') {
        query = query.where('propertyType', isEqualTo: propertyType);
      }

      final snapshot = await query.get();

      List<PropertyModel> properties =
          snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return PropertyModel.fromJson(_convertTimestamps(data));
          }).toList();

      // Filter by rent range (done client-side to avoid complex indexes)
      if (minRent != null) {
        properties = properties.where((p) => p.rent >= minRent).toList();
      }
      if (maxRent != null) {
        properties = properties.where((p) => p.rent <= maxRent).toList();
      }

      // Sort by createdAt
      properties.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      return properties;
    } catch (e) {
      developer.log(
        '❌ Failed to search properties: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return [];
    }
  }

  // ============ UPDATE ============

  /// Update property availability
  Future<bool> updateAvailability(String propertyId, bool isAvailable) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'isAvailable': isAvailable,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Property availability updated', name: 'PropertyService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to update availability: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  /// Update property details
  Future<bool> updateProperty(
    String propertyId,
    Map<String, dynamic> updates,
  ) async {
    try {
      updates['updatedAt'] = FieldValue.serverTimestamp();
      await _propertiesRef.doc(propertyId).update(updates);
      developer.log('✅ Property updated', name: 'PropertyService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to update property: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // ============ DELETE ============

  /// Delete a property
  Future<bool> deleteProperty(String propertyId) async {
    try {
      await _propertiesRef.doc(propertyId).delete();
      developer.log('✅ Property deleted', name: 'PropertyService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to delete property: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  // ============ HELPERS ============

  /// Track when a property is viewed
  Future<void> trackPropertyView({
    required String propertyId,
    required String landlordId,
    required String propertyTitle,
  }) async {
    try {
      if (_currentUserId == null) return;

      // Get current user's name
      final userDoc =
          await _firestore.collection('users').doc(_currentUserId).get();
      final userName = userDoc.data()?['fullName'] ?? 'Someone';

      // Track the view
      await _activityService.trackPropertyViewed(
        landlordId: landlordId,
        propertyId: propertyId,
        propertyTitle: propertyTitle,
        viewerId: _currentUserId!,
        viewerName: userName,
      );

      // Increment view count on property (optional)
      await _propertiesRef.doc(propertyId).update({
        'viewCount': FieldValue.increment(1),
      });
    } catch (e) {
      developer.log(
        '❌ Failed to track view: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  /// Convert Firestore Timestamps to DateTime strings
  Map<String, dynamic> _convertTimestamps(Map<String, dynamic> data) {
    final converted = Map<String, dynamic>.from(data);

    if (converted['createdAt'] is Timestamp) {
      converted['createdAt'] =
          (converted['createdAt'] as Timestamp).toDate().toIso8601String();
    } else {
      converted['createdAt'] = DateTime.now().toIso8601String();
    }

    if (converted['updatedAt'] is Timestamp) {
      converted['updatedAt'] =
          (converted['updatedAt'] as Timestamp).toDate().toIso8601String();
    }

    return converted;
  }

  /// Stream of all available properties (real-time updates)
  Stream<List<PropertyModel>> propertiesStream() {
    return _propertiesRef
        .where('isAvailable', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return PropertyModel.fromJson(_convertTimestamps(data));
          }).toList();
        });
  }

  /// Stream of landlord's properties (real-time updates)
  Stream<List<PropertyModel>> landlordPropertiesStream() {
    if (_currentUserId == null) {
      return Stream.value([]);
    }

    return _propertiesRef
        .where('landlordId', isEqualTo: _currentUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return PropertyModel.fromJson(_convertTimestamps(data));
          }).toList();
        });
  }
}
