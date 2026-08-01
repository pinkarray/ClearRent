import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
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

  // ============ EXACT LOCATION (reveal-on-approval) ============
  //
  // The exact street address + precise coordinates are NEVER stored on the
  // parent property doc (which is world-readable). They live in a gated
  // subdoc `properties/{id}/private/location`, readable only by the owner, the
  // assigned agent, an admin, or a tenant whose inspection was approved (a
  // reveal grant at `properties/{id}/reveals/{tenantId}`). Everyone else sees
  // only the area-level `city`/`state`/`lga` on the parent doc.

  DocumentReference _exactLocationRef(String propertyId) =>
      _propertiesRef.doc(propertyId).collection('private').doc('location');

  /// Reads the exact street address + coordinates for [propertyId]. Returns
  /// null when the caller isn't entitled (rules deny the read) or the subdoc
  /// is absent. Callers that already gate on entitlement (owner/agent screens,
  /// or a tenant with an approved inspection) can safely surface the result.
  Future<({String address, double? latitude, double? longitude})?>
      getExactLocation(String propertyId) async {
    try {
      final snap = await _exactLocationRef(propertyId).get();
      if (!snap.exists) return null;
      final d = snap.data() as Map<String, dynamic>? ?? {};
      return (
        address: d['address'] as String? ?? '',
        latitude: (d['latitude'] as num?)?.toDouble(),
        longitude: (d['longitude'] as num?)?.toDouble(),
      );
    } catch (e) {
      // permission-denied for a tenant without an approved inspection, etc.
      developer.log('ℹ️ Exact location not available for $propertyId: $e',
          name: 'PropertyService');
      return null;
    }
  }

  Map<String, dynamic> _exactLocationData({
    required String address,
    double? latitude,
    double? longitude,
  }) =>
      {
        'address': address,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  // ============ CREATE ============

  /// Upload an ownership document (C of O / deed) to PRIVATE Firebase Storage,
  /// mirroring how verification documents are handled. Returns the storage
  /// PATH (not a public URL) — the admin streams the bytes through an
  /// authenticated route, and Storage rules restrict reads to the owner + admin.
  /// A C of O is title-level PII, so it must never live on a public URL.
  Future<String?> uploadOwnershipDoc(File file) async {
    final uid = _currentUserId;
    if (uid == null) return null;
    try {
      final ext =
          file.path.contains('.') ? file.path.split('.').last : 'jpg';
      final path =
          'ownership/$uid/cofo_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await FirebaseStorage.instance.ref(path).putFile(file);
      developer.log('✅ Ownership doc uploaded: $path', name: 'PropertyService');
      return path;
    } catch (e) {
      developer.log('❌ uploadOwnershipDoc failed: $e', name: 'PropertyService');
      return null;
    }
  }

  /// Upload a tenancy agreement to PRIVATE Firebase Storage under the uploading
  /// landlord's folder (`agreements/{uid}/…`). Returns the storage PATH.
  /// Tenants read it via a short-lived signed URL from the getSignedAgreementUrl
  /// CF (storage rules can't authorize the tenant). A tenancy agreement is
  /// sensitive — it must not live on a public URL.
  Future<String?> uploadAgreementDoc(File file) async {
    final uid = _currentUserId;
    if (uid == null) return null;
    try {
      final ext =
          file.path.contains('.') ? file.path.split('.').last : 'jpg';
      final path =
          'agreements/$uid/agreement_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await FirebaseStorage.instance.ref(path).putFile(file);
      developer.log('✅ Agreement uploaded: $path', name: 'PropertyService');
      return path;
    } catch (e) {
      developer.log('❌ uploadAgreementDoc failed: $e', name: 'PropertyService');
      return null;
    }
  }

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
    // Stated up front so the tenant knows before paying whether this
    // money comes back; the move-out handover is measured against it.
    bool cautionDepositRefundable = true,
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
    // When set, this unit belongs to a building/compound and inherits the
    // building's shared ownership doc — no per-property doc is stored.
    String? buildingId,
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
    List<String> ceilingTypes = const [],
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
            if (kDebugMode) {
              developer.log(
                '✅ Updated landlord baseLatitude/baseLongitude: ($landlordBaseLatitude, $landlordBaseLongitude)',
                name: 'PropertyService',
              );
            }
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
        // Exact street address + precise coords are NOT stored here — they go
        // to the gated `private/location` subdoc below. Only area-level
        // city/state/lga live on the world-readable parent doc.
        'city': city,
        'state': state,
        'lga': '', // Can be added later
        'rent': rent,
        'rentFrequency': rentFrequency,
        'agentFee': agentFee,
        'cautionDeposit': cautionDeposit,
        'cautionDepositRefundable': cautionDepositRefundable,
        'isAvailable': true,
        // A listing is born unreviewed. This is the ADMIN's badge for THIS
        // listing's ownership document (adminReviewPropertyDoc writes it) — not
        // a mirror of the landlord's own verification, which is what it used to
        // copy. Seeding it true let every listing skip the review the rules
        // exist to enforce; firestore.rules now pins it false at create.
        'isVerified': false,
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
        if (ceilingTypes.isNotEmpty) 'ceilingTypes': ceilingTypes,
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
        if (buildingId != null) 'buildingId': buildingId,
        if (ownershipDocUrl != null) 'ownershipDocUrl': ownershipDocUrl,
        if (ownershipDocType != null) 'ownershipDocType': ownershipDocType,
        // Grouped units inherit the building's doc status (resolved at read
        // time via effectiveDocStatus); they carry 'inherited' as a marker.
        'ownershipDocStatus': buildingId != null
            ? 'inherited'
            : (ownershipDocUrl != null ? 'pending' : 'none'),
        if (listingFeePaymentReference != null) 'listingFeePaymentReference': listingFeePaymentReference,
      };

      // Create the parent doc first, then the gated location subdoc. These
      // can't be batched: the subdoc's write rule reads the parent's
      // landlordId via get(), which isn't visible for a doc created in the
      // same batch. Sequential writes let the rule see the committed parent.
      final docRef = await _propertiesRef.add(propertyData);
      await _exactLocationRef(docRef.id).set(
        _exactLocationData(
          address: address,
          latitude: latitude,
          longitude: longitude,
        ),
      );
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

  /// Get properties assigned to the current agent.
  /// Mirrors getLandlordProperties but filters on assignedAgentId, so the
  /// in-chat property picker can offer an agent their assigned listings.
  Future<List<PropertyModel>> getAgentProperties() async {
    try {
      if (_currentUserId == null) {
        developer.log(
          '❌ User not authenticated for getAgentProperties',
          name: 'PropertyService',
        );
        return [];
      }

      try {
        final snapshot = await _propertiesRef
            .where('assignedAgentId', isEqualTo: _currentUserId)
            .orderBy('createdAt', descending: true)
            .get();

        return snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          data['id'] = doc.id;
          return PropertyModel.fromJson(_convertTimestamps(data));
        }).toList();
      } catch (e) {
        final snapshot = await _propertiesRef
            .where('assignedAgentId', isEqualTo: _currentUserId)
            .get();

        final properties = snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          data['id'] = doc.id;
          return PropertyModel.fromJson(_convertTimestamps(data));
        }).toList();

        properties.sort((a, b) {
          final aDate = a.createdAt ?? DateTime(2000);
          final bDate = b.createdAt ?? DateTime(2000);
          return bDate.compareTo(aDate);
        });

        return properties;
      }
    } catch (e) {
      developer.log(
        '❌ Failed to get agent properties: $e',
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
      // Route any exact-location fields to the gated subdoc — they must never
      // be written back onto the world-readable parent doc.
      final hasExact = updates.containsKey('address') ||
          updates.containsKey('latitude') ||
          updates.containsKey('longitude');

      updates['updatedAt'] = FieldValue.serverTimestamp();

      if (hasExact) {
        final batch = _firestore.batch();
        final exact = <String, dynamic>{
          if (updates.containsKey('address')) 'address': updates.remove('address'),
          if (updates.containsKey('latitude')) 'latitude': updates.remove('latitude'),
          if (updates.containsKey('longitude')) 'longitude': updates.remove('longitude'),
          'updatedAt': FieldValue.serverTimestamp(),
        };
        batch.set(_exactLocationRef(propertyId), exact, SetOptions(merge: true));
        // updates always carries updatedAt, so the parent update is never empty.
        batch.update(_propertiesRef.doc(propertyId), updates);
        await batch.commit();
      } else {
        await _propertiesRef.doc(propertyId).update(updates);
      }
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
      final ref = _propertiesRef.doc(propertyId);
      final snap = await ref.get();
      final data = snap.data() as Map<String, dynamic>?;
      final savedFee = (data?['savedAgentFee'] as num?)?.toDouble() ?? 0;

      final updates = <String, dynamic>{
        'assignedAgentId': agentId,
        'assignedAgentName': agentName,
        'assignedAgentPhone': agentPhone,
        // Assigning an agent means the agent handles inspections — keep the
        // handler consistent so it doesn't read back as 'self'.
        'inspectionHandler': 'agent',
        // Readiness gate (Phase 2): the handler changed, so the new agent must
        // re-vet before the property is bookable again.
        'readyForInspections': false,
        'readinessCheckedAt': FieldValue.delete(),
        'readinessCheckedBy': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      // Restore the agent fee preserved when a previous agent stepped away, so
      // the landlord doesn't have to re-enter it.
      if (savedFee > 0) {
        updates['agentFee'] = savedFee;
        updates['savedAgentFee'] = FieldValue.delete();
      }
      await ref.update(updates);
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

  /// Readiness checklist items the handler must affirm before a property
  /// becomes bookable for inspection. Keys are stored on the property as the
  /// attestation trail; labels are shown in the vetting sheet.
  static const Map<String, String> readinessChecklistItems = {
    'visited': "I've visited/inspected this property in person",
    'accurate_media': 'The photos, video and description match the property',
    'accurate_address': 'The address and location are correct',
    'accessible': "It's accessible and ready to show tenants",
  };

  /// The current handler (assigned agent, or the landlord when self-handled)
  /// vets the property against [confirmedItems] and marks it bookable. Returns
  /// null on success, or an error message.
  ///
  /// Writes are handler-scoped by rules: the landlord path rides the owner
  /// update rule; the agent path uses the dedicated readiness clause. Every
  /// checklist item must be confirmed.
  Future<String?> markReadyForInspections({
    required String propertyId,
    required Map<String, bool> confirmedItems,
  }) async {
    final uid = _currentUserId;
    if (uid == null) return 'You must be signed in.';

    final allConfirmed = readinessChecklistItems.keys
        .every((k) => confirmedItems[k] == true);
    if (!allConfirmed) {
      return 'Please confirm every item before marking the property ready.';
    }

    try {
      await _propertiesRef.doc(propertyId).update({
        'readyForInspections': true,
        'readinessCheckedAt': FieldValue.serverTimestamp(),
        'readinessCheckedBy': uid,
        'readinessChecklist':
            readinessChecklistItems.keys.where((k) => confirmedItems[k] == true).toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Property marked ready for inspections',
          name: 'PropertyService');
      return null;
    } catch (e) {
      developer.log('❌ Failed to mark property ready: $e',
          name: 'PropertyService', error: e, stackTrace: StackTrace.current);
      return 'Could not update the property. Please try again.';
    }
  }

  /// Agent steps back from a property they're assigned to, with a [reason].
  /// Runs server-side (the agent isn't the property owner, so rules block a
  /// direct write): the CF reverts the unit to landlord-handled, preserves the
  /// agent fee, and notifies the landlord. Returns null on success, or an error
  /// message to show the agent.
  Future<String?> agentUnassignFromProperty(
    String propertyId,
    String reason,
  ) async {
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('agentUnassignFromProperty');
      await callable.call<Map<String, dynamic>>({
        'propertyId': propertyId,
        'reason': reason,
      });
      return null;
    } on FirebaseFunctionsException catch (e) {
      return e.message ?? 'Could not step back. Please try again.';
    } catch (e) {
      developer.log('❌ agentUnassignFromProperty failed: $e',
          name: 'PropertyService');
      return 'Could not step back. Please try again.';
    }
  }

  /// Remove agent from a property
  Future<bool> removeAgent(String propertyId) async {
    try {
      await _propertiesRef.doc(propertyId).update({
        'assignedAgentId': null,
        'assignedAgentName': null,
        'assignedAgentPhone': null,
        // Handler changed → the landlord must re-vet before it's bookable.
        'readyForInspections': false,
        'readinessCheckedAt': FieldValue.delete(),
        'readinessCheckedBy': FieldValue.delete(),
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
        // Handler changed → reset the readiness gate; the new handler must
        // re-vet before the property is bookable again.
        'readyForInspections': false,
        'readinessCheckedAt': FieldValue.delete(),
        'readinessCheckedBy': FieldValue.delete(),
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

  /// True if the property has a sitting tenant — an occupying active rental or
  /// a confirmed tenancy link. Such a property must not be deleted (doing so
  /// strands the tenant's dashboard with an orphaned rental/link). Uses the
  /// same occupying statuses as the server-side rent-review occupancy check.
  Future<bool> propertyHasSittingTenant(String propertyId) async {
    // Owner-only caller (the delete + rent-change guards). Scope both queries
    // by landlordId so they satisfy the ownership-constrained list rules
    // (active_rentals, and tenancy_links F1.13). The owner's uid is on every
    // rental/link for their property, so this returns the same set as a
    // propertyId-only query.
    final uid = _currentUserId;
    if (uid == null) return false;
    final rentals = await _firestore
        .collection('active_rentals')
        .where('landlordId', isEqualTo: uid)
        .where('propertyId', isEqualTo: propertyId)
        .where('status', whereIn: ['active', 'expiring_soon', 'grace_locked'])
        .limit(1)
        .get();
    if (rentals.docs.isNotEmpty) return true;
    final links = await _firestore
        .collection('tenancy_links')
        .where('landlordId', isEqualTo: uid)
        .where('propertyId', isEqualTo: propertyId)
        .where('status', isEqualTo: 'confirmed')
        .limit(1)
        .get();
    return links.docs.isNotEmpty;
  }

  /// Delete a property. Refuses if it has a sitting tenant (see
  /// [propertyHasSittingTenant]) — returns false without deleting.
  Future<bool> deleteProperty(String propertyId) async {
    try {
      if (await propertyHasSittingTenant(propertyId)) {
        developer.log(
          '⛔ Refusing to delete property with a sitting tenant: $propertyId',
          name: 'PropertyService',
        );
        return false;
      }
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