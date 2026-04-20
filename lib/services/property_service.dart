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

  /// Upload a video to Cloudinary
  Future<String?> uploadVideo(File videoFile) async {
    try {
      final response = await _cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          videoFile.path,
          folder: 'clearrent/properties/$_currentUserId/videos',
          resourceType: CloudinaryResourceType.Video,
        ),
      );
      developer.log(
        '✅ Video uploaded: ${response.secureUrl}',
        name: 'PropertyService',
      );
      return response.secureUrl;
    } catch (e) {
      developer.log(
        '❌ Video upload failed: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return null;
    }
  }

  /// Create a new property in Firestore
  Future<String?> createProperty({
    required String title,
    required String description,
    required String propertyType,
    required int bedrooms,
    required int bathrooms,
    required int toilets,
    int livingRooms = 1,
    int guestRooms = 0,
    int kitchens = 1,
    required List<String> imageUrls,
    required String address,
    required String city,
    required String state,
    double? latitude,
    double? longitude,
    required double rent,
    required String rentFrequency,
    double agentFee = 0, // Flat Naira amount (e.g. 200000)
    double cautionDeposit = 0, // Caution / damages deposit in Naira
    List<String> amenities = const [],
    List<String> rules = const [],
    String inspectionHandler = 'self', // 'self' or 'agent'
    List<String> inspectionDays = const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ],
    List<String> inspectionTimeSlots = const [
      'morning',
      'afternoon',
      'late_afternoon',
    ],
    int maxTenants = 1,
    bool landlordLivesInProperty = false,
    bool landlordLivesOnPremises = false,
    int currentTenantsCount = 0,
    bool hasCaretaker = false,
    bool caretakerLivesOnPremises = false,
    double? landlordBaseLatitude,
    double? landlordBaseLongitude,
    String? ownershipDocUrl,
    String? ownershipDocType,
    String? listingFeePaymentReference,
    String? assignedAgentId,
    String? assignedAgentName,
    // Pre-calculated inspection fee (stored on property for consistent display)
    double? inspectionFeeTotal,
    double? inspectionTransportFee,
    double? inspectionServiceFee,
    String? inspectionAgentCluster,
    String? inspectionPropertyCluster,
    String? videoUrl,
    String? ceilingType,
    List<Map<String, dynamic>> recurringDues = const [],
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

      // Update landlord's baseLatitude/baseLongitude if they don't live in property and coordinates are provided
      if (!landlordLivesInProperty &&
          landlordBaseLatitude != null &&
          landlordBaseLongitude != null) {
        try {
          // Only update if they don't already have coordinates set
          final currentLat = userData?['baseLatitude'];
          final currentLon = userData?['baseLongitude'];

          if (currentLat == null || currentLon == null) {
            await _firestore.collection('users').doc(_currentUserId).update({
              'baseLatitude': landlordBaseLatitude,
              'baseLongitude': landlordBaseLongitude,
            });
            developer.log(
              '✅ Updated landlord baseLatitude/baseLongitude: ($landlordBaseLatitude, $landlordBaseLongitude)',
              name: 'PropertyService',
            );
          }
        } catch (e) {
          developer.log(
            '⚠️ Failed to update landlord location: $e',
            name: 'PropertyService',
          );
          // Don't fail property creation if this fails
        }
      }

      // Create property document
      final propertyData = {
        'landlordId': _currentUserId,
        'title': title,
        'description': description,
        'propertyType': propertyType,
        'bedrooms': bedrooms,
        'bathrooms': bathrooms,
        'toilets': toilets,
        'livingRooms': livingRooms,
        'guestRooms': guestRooms,
        'kitchens': kitchens,
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
        'cautionDeposit': cautionDeposit,
        'isAvailable': true,
        'isVerified': isVerified, // Based on landlord verification status
        'amenities': amenities,
        'rules': rules,
        'landlordName': landlordName,
        'landlordPhone': landlordPhone,
        'inspectionHandler': inspectionHandler,
        'inspectionDays': inspectionDays,
        'inspectionTimeSlots': inspectionTimeSlots,
        'assignedAgentId': assignedAgentId,
        'assignedAgentName': assignedAgentName,
        'assignedAgentPhone': null,
        'maxTenants': maxTenants,
        'viewCount': 0,
        'inquiryCount': 0,
        'savedCount': 0,
        'landlordLivesInProperty': landlordLivesInProperty,
        if (videoUrl != null) 'videoUrl': videoUrl,
        if (ceilingType != null) 'ceilingType': ceilingType,
        if (recurringDues.isNotEmpty) 'recurringDues': recurringDues,
        'landlordLivesOnPremises': landlordLivesOnPremises,
        'currentTenantsCount': currentTenantsCount,
        'hasCaretaker': hasCaretaker,
        'caretakerLivesOnPremises': caretakerLivesOnPremises,
        // Pre-calculated inspection fee
        'inspectionFeeTotal': inspectionFeeTotal ?? 0,
        'inspectionTransportFee': inspectionTransportFee ?? 0,
        'inspectionServiceFee': inspectionServiceFee ?? 0,
        'inspectionAgentCluster': inspectionAgentCluster,
        'inspectionPropertyCluster': inspectionPropertyCluster,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (ownershipDocUrl != null) 'ownershipDocUrl': ownershipDocUrl,
        if (ownershipDocType != null) 'ownershipDocType': ownershipDocType,
        'ownershipDocStatus': ownershipDocUrl != null ? 'pending' : 'none',
        if (listingFeePaymentReference != null) 'listingFeePaymentReference': listingFeePaymentReference,
      };

      final docRef = await _propertiesRef.add(propertyData);
      developer.log(
        '✅ Property created with ID: ${docRef.id}',
        name: 'PropertyService',
      );

      // Increment lifetime listing count on the user document.
      // This counter only goes up — removing a property doesn't decrease it.
      // Used to determine whether the landlord qualifies for the free first listing.
      try {
        await _firestore.collection('users').doc(_currentUserId).update({
          'totalListingsCreated': FieldValue.increment(1),
        });
      } catch (e) {
        developer.log(
          '⚠️ Failed to increment totalListingsCreated: $e',
          name: 'PropertyService',
        );
        // Don't fail property creation if counter update fails
      }

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
      // Exclude properties whose ownership doc was explicitly rejected
      }).where((p) => p.ownershipDocStatus != 'rejected').toList();
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

  /// Get available properties from VERIFIED landlords only
  Future<List<PropertyModel>> getAvailableProperties({
    String? propertyType,
    String? city,
    int limit = 50,
  }) async {
    try {
      developer.log(
        '🔍 Fetching available properties from verified landlords',
        name: 'PropertyService',
      );

      // First, get all verified landlord IDs from users collection
      final verifiedLandlordsSnapshot =
          await _firestore
              .collection('users')
              .where('verificationStatus', isEqualTo: 'verified')
              .where('accountType', isEqualTo: 'landlord')
              .get();

      // Extract user IDs (the document ID is the userId)
      final verifiedLandlordIds =
          verifiedLandlordsSnapshot.docs.map((doc) => doc.id).toSet();

      developer.log(
        '✅ Found ${verifiedLandlordIds.length} verified landlords',
        name: 'PropertyService',
      );

      if (verifiedLandlordIds.isEmpty) {
        developer.log(
          '⚠️ No verified landlords found, returning empty list',
          name: 'PropertyService',
        );
        return [];
      }

      // Firestore 'whereIn' has a limit of 30 items, so we need to batch
      final List<PropertyModel> allProperties = [];
      final landlordIdsList = verifiedLandlordIds.toList();

      // Process in batches of 30
      for (var i = 0; i < landlordIdsList.length; i += 30) {
        final batchIds = landlordIdsList.skip(i).take(30).toList();

        try {
          Query query = _propertiesRef
              .where('landlordId', whereIn: batchIds)
              .where('isAvailable', isEqualTo: true);

          // Apply optional filters
          if (propertyType != null && propertyType != 'all') {
            query = query.where('propertyType', isEqualTo: propertyType);
          }

          if (city != null && city != 'All Areas') {
            query = query.where('city', isEqualTo: city);
          }

          final snapshot = await query.limit(limit).get();

          final batchProperties =
              snapshot.docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                data['id'] = doc.id;
                return PropertyModel.fromJson(_convertTimestamps(data));
              }).toList();

          allProperties.addAll(batchProperties);
        } catch (e) {
          developer.log('⚠️ Batch query failed: $e', name: 'PropertyService');

          // Fallback: simpler query without all filters
          final snapshot =
              await _propertiesRef.where('landlordId', whereIn: batchIds).get();

          final batchProperties =
              snapshot.docs
                  .map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    data['id'] = doc.id;
                    return PropertyModel.fromJson(_convertTimestamps(data));
                  })
                  .where((p) => p.isAvailable && p.ownershipDocStatus != 'rejected') // Filter client-side
                  .toList();

          allProperties.addAll(batchProperties);
        }
      }

      // Apply filters client-side if they weren't applied in query
      var filteredProperties = allProperties;

      if (propertyType != null && propertyType != 'all') {
        filteredProperties =
            filteredProperties
                .where((p) => p.propertyType == propertyType)
                .toList();
      }

      if (city != null && city != 'All Areas') {
        filteredProperties =
            filteredProperties.where((p) => p.city == city).toList();
      }

      // Sort by createdAt descending (newest first)
      filteredProperties.sort((a, b) {
        final aDate = a.createdAt ?? DateTime(2000);
        final bDate = b.createdAt ?? DateTime(2000);
        return bDate.compareTo(aDate);
      });

      // Remove duplicates (in case of overlapping batches)
      final seenIds = <String>{};
      filteredProperties =
          filteredProperties.where((p) {
            if (seenIds.contains(p.id)) return false;
            seenIds.add(p.id);
            return true;
          }).toList();

      developer.log(
        '✅ Found ${filteredProperties.length} properties from verified landlords',
        name: 'PropertyService',
      );

      return filteredProperties.take(limit).toList();
    } catch (e, stackTrace) {
      developer.log(
        '❌ Failed to get available properties: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: stackTrace,
      );
      return [];
    }
  }

  /// Get the number of properties owned by the current landlord
  /// Returns the landlord's lifetime listing count.
  /// This reads from the user document's `totalListingsCreated` field,
  /// which only increments and never decreases when properties are removed.
  /// This ensures the free first listing is truly a one-time benefit.
  Future<int> getLandlordPropertyCount() async {
    try {
      if (_currentUserId == null) return 0;
      final userDoc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .get();
      final data = userDoc.data();
      return (data?['totalListingsCreated'] ?? 0) as int;
    } catch (e) {
      developer.log(
        '⚠️ Failed to read totalListingsCreated, falling back to query: $e',
        name: 'PropertyService',
      );
      // Fallback: count current properties (less accurate but safe)
      try {
        final snapshot = await _propertiesRef
            .where('landlordId', isEqualTo: _currentUserId)
            .get();
        return snapshot.docs.length;
      } catch (_) {
        return 0;
      }
    }
  }

  /// Get properties by landlord ID (for landlord dashboard)
  Future<List<PropertyModel>> getLandlordProperties() async {
    try {
      if (_currentUserId == null) {
        developer.log(
          '❌ User not authenticated for getLandlordProperties',
          name: 'PropertyService',
        );
        return [];
      }

      developer.log(
        '🔍 Fetching properties for landlord: $_currentUserId',
        name: 'PropertyService',
      );

      // Try the compound query first
      try {
        final snapshot =
            await _propertiesRef
                .where('landlordId', isEqualTo: _currentUserId)
                .orderBy('createdAt', descending: true)
                .get();

        developer.log(
          '✅ Found ${snapshot.docs.length} properties (with orderBy)',
          name: 'PropertyService',
        );

        return snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          data['id'] = doc.id;
          return PropertyModel.fromJson(_convertTimestamps(data));
        }).toList();
      } catch (e) {
        // If compound query fails (missing index), fall back to simple query
        developer.log(
          '⚠️ Compound query failed, trying simple query. Error: $e',
          name: 'PropertyService',
        );

        // Check if it's an index error
        if (e.toString().contains('index') ||
            e.toString().contains('FAILED_PRECONDITION')) {
          developer.log(
            '🔧 MISSING INDEX! Create a composite index in Firebase Console:\n'
            '   Collection: properties\n'
            '   Fields: landlordId (Ascending), createdAt (Descending)\n'
            '   Or click the link in the error message above.',
            name: 'PropertyService',
          );
        }

        // Fallback: simple query without orderBy, then sort client-side
        final snapshot =
            await _propertiesRef
                .where('landlordId', isEqualTo: _currentUserId)
                .get();

        developer.log(
          '✅ Found ${snapshot.docs.length} properties (simple query)',
          name: 'PropertyService',
        );

        final properties =
            snapshot.docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              data['id'] = doc.id;
              return PropertyModel.fromJson(_convertTimestamps(data));
            }).toList();

        // Sort client-side (handle nullable createdAt)
        properties.sort((a, b) {
          final aDate = a.createdAt ?? DateTime(2000);
          final bDate = b.createdAt ?? DateTime(2000);
          return bDate.compareTo(aDate);
        });

        return properties;
      }
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

  /// Search properties by city/area (only from verified landlords)
  Future<List<PropertyModel>> searchProperties({
    String? city,
    String? propertyType,
    double? minRent,
    double? maxRent,
  }) async {
    try {
      // First get verified landlord IDs
      final verifiedLandlordsSnapshot =
          await _firestore
              .collection('users')
              .where('verificationStatus', isEqualTo: 'verified')
              .where('accountType', isEqualTo: 'landlord')
              .get();

      final verifiedLandlordIds =
          verifiedLandlordsSnapshot.docs.map((doc) => doc.id).toSet();

      if (verifiedLandlordIds.isEmpty) {
        return [];
      }

      // Query properties
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

      // Filter to only verified landlords, also exclude rejected docs
      properties =
          properties
              .where((p) => verifiedLandlordIds.contains(p.landlordId))
              .where((p) => p.ownershipDocStatus != 'rejected')
              .toList();

      // Filter by rent range (done client-side to avoid complex indexes)
      if (minRent != null) {
        properties = properties.where((p) => p.rent >= minRent).toList();
      }
      if (maxRent != null) {
        properties = properties.where((p) => p.rent <= maxRent).toList();
      }

      // Sort by createdAt (handle nullable)
      properties.sort((a, b) {
        final aDate = a.createdAt ?? DateTime(2000);
        final bDate = b.createdAt ?? DateTime(2000);
        return bDate.compareTo(aDate);
      });

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

  /// Update property availability.
  /// Returns 'not_approved' if the property hasn't been admin-approved yet.
  Future<String> updateAvailability(String propertyId, bool isAvailable) async {
    try {
      // If trying to make available, check admin approval first
      if (isAvailable) {
        final doc = await _propertiesRef.doc(propertyId).get();
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>?;
          final docStatus = data?['ownershipDocStatus'] ?? 'none';
          if (docStatus != 'verified') {
            developer.log(
              '⚠️ Cannot make property available — ownershipDocStatus: $docStatus',
              name: 'PropertyService',
            );
            return 'not_approved';
          }
        }
      }

      await _propertiesRef.doc(propertyId).update({
        'isAvailable': isAvailable,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Property availability updated', name: 'PropertyService');
      return 'success';
    } catch (e) {
      developer.log(
        '❌ Failed to update availability: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return 'error';
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

  /// Assign an agent to a property
  Future<bool> assignAgent({
    required String propertyId,
    required String agentId,
    required String agentName,
    required String agentPhone,
  }) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'assignedAgentId': agentId,
        'assignedAgentName': agentName,
        'assignedAgentPhone': agentPhone,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Agent assigned to property', name: 'PropertyService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to assign agent: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  /// Remove agent from a property
  Future<bool> removeAgent(String propertyId) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'assignedAgentId': null,
        'assignedAgentName': null,
        'assignedAgentPhone': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Agent removed from property', name: 'PropertyService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to remove agent: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  /// Change inspection handler (self <-> agent)
  Future<bool> updateInspectionHandler(
    String propertyId,
    String handler,
  ) async {
    try {
      final updates = <String, dynamic>{
        'inspectionHandler': handler,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // If switching to self, clear agent assignment
      if (handler == 'self') {
        updates['assignedAgentId'] = null;
        updates['assignedAgentName'] = null;
        updates['assignedAgentPhone'] = null;
      }

      await _propertiesRef.doc(propertyId).update(updates);
      developer.log(
        '✅ Inspection handler updated to: $handler',
        name: 'PropertyService',
      );
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to update inspection handler: $e',
        name: 'PropertyService',
        error: e,
        stackTrace: StackTrace.current,
      );
      return false;
    }
  }

  /// Increment inquiry count
  Future<void> incrementInquiryCount(String propertyId) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'inquiryCount': FieldValue.increment(1),
      });
    } catch (e) {
      developer.log(
        '❌ Failed to increment inquiry count: $e',
        name: 'PropertyService',
      );
    }
  }

  /// Increment saved count
  Future<void> incrementSavedCount(String propertyId) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'savedCount': FieldValue.increment(1),
      });
    } catch (e) {
      developer.log(
        '❌ Failed to increment saved count: $e',
        name: 'PropertyService',
      );
    }
  }

  /// Decrement saved count
  Future<void> decrementSavedCount(String propertyId) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'savedCount': FieldValue.increment(-1),
      });
    } catch (e) {
      developer.log(
        '❌ Failed to decrement saved count: $e',
        name: 'PropertyService',
      );
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

      // Increment view count on property
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
    } else if (converted['createdAt'] == null) {
      converted['createdAt'] = null; // Keep null instead of defaulting
    }

    if (converted['updatedAt'] is Timestamp) {
      converted['updatedAt'] =
          (converted['updatedAt'] as Timestamp).toDate().toIso8601String();
    }

    return converted;
  }

  /// Stream of all available properties (real-time updates) - from verified landlords only
  Stream<List<PropertyModel>> propertiesStream() {
    // Note: For real-time streams with verification filtering,
    // we'd need to implement a more complex solution.
    // For now, this returns all available properties.
    // Consider using getAvailableProperties() for filtered results.
    return _propertiesRef
        .where('isAvailable', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return PropertyModel.fromJson(_convertTimestamps(data));
          // Exclude rejected doc properties from tenant-facing stream
          }).where((p) => p.ownershipDocStatus != 'rejected').toList();
        });
  }

  /// Stream of landlord's properties (real-time updates)
  Stream<List<PropertyModel>> landlordPropertiesStream() {
    if (_currentUserId == null) {
      return Stream.value([]);
    }

    // Use simple query to avoid index issues, sort client-side
    return _propertiesRef
        .where('landlordId', isEqualTo: _currentUserId)
        .snapshots()
        .map((snapshot) {
          final properties =
              snapshot.docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                data['id'] = doc.id;
                return PropertyModel.fromJson(_convertTimestamps(data));
              }).toList();

          // Sort client-side (handle nullable createdAt)
          properties.sort((a, b) {
            final aDate = a.createdAt ?? DateTime(2000);
            final bDate = b.createdAt ?? DateTime(2000);
            return bDate.compareTo(aDate);
          });
          return properties;
        });
  }
}