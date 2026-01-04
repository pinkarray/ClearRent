import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:developer' as developer;

/// Model for Agent data
class AgentModel {
  final String id;
  final String fullName;
  final String email;
  final String phone;
  final String baseLocation;
  final List<String> serviceAreas;
  final bool isVerified;
  final double rating;
  final int totalInspections;
  final int totalRatings;
  final String? profileImageUrl;
  final DateTime createdAt;

  AgentModel({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.baseLocation,
    required this.serviceAreas,
    this.isVerified = false,
    this.rating = 0.0,
    this.totalInspections = 0,
    this.totalRatings = 0,
    this.profileImageUrl,
    required this.createdAt,
  });

  /// Display rating as stars
  String get ratingDisplay {
    if (totalRatings == 0) return 'New';
    return rating.toStringAsFixed(1);
  }

  /// Check if agent covers a specific area
  bool coversArea(String area) {
    return serviceAreas.any(
      (a) => a.toLowerCase() == area.toLowerCase(),
    );
  }

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    return AgentModel(
      id: json['id'] ?? json['uid'] ?? '',
      fullName: json['fullName'] ?? '',
      email: json['email'] ?? '',
      phone: json['phone'] ?? '',
      baseLocation: json['baseLocation'] ?? '',
      serviceAreas: List<String>.from(json['serviceAreas'] ?? []),
      isVerified: json['isVerified'] ?? false,
      rating: (json['rating'] ?? 0.0).toDouble(),
      totalInspections: json['totalInspections'] ?? 0,
      totalRatings: json['totalRatings'] ?? 0,
      profileImageUrl: json['profileImageUrl'],
      createdAt: json['createdAt'] != null
          ? (json['createdAt'] is Timestamp
              ? (json['createdAt'] as Timestamp).toDate()
              : DateTime.parse(json['createdAt']))
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fullName': fullName,
      'email': email,
      'phone': phone,
      'baseLocation': baseLocation,
      'serviceAreas': serviceAreas,
      'isVerified': isVerified,
      'rating': rating,
      'totalInspections': totalInspections,
      'totalRatings': totalRatings,
      'profileImageUrl': profileImageUrl,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

class AgentService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get _currentUserId => _auth.currentUser?.uid;

  /// Get all verified agents
  Future<List<AgentModel>> getVerifiedAgents() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'agent')
          .where('isVerified', isEqualTo: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return AgentModel.fromJson(data);
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get verified agents: $e',
        name: 'AgentService',
        error: e,
      );
      return [];
    }
  }

  /// Get agents that cover a specific area
  Future<List<AgentModel>> getAgentsByArea(String area) async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'agent')
          .where('isVerified', isEqualTo: true)
          .where('serviceAreas', arrayContains: area)
          .get();

      final agents = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return AgentModel.fromJson(data);
      }).toList();

      // Sort by rating (highest first)
      agents.sort((a, b) => b.rating.compareTo(a.rating));

      return agents;
    } catch (e) {
      developer.log(
        '❌ Failed to get agents by area: $e',
        name: 'AgentService',
        error: e,
      );
      return [];
    }
  }

  /// Get a single agent by ID
  Future<AgentModel?> getAgent(String agentId) async {
    try {
      final doc = await _firestore.collection('users').doc(agentId).get();

      if (!doc.exists) return null;

      final data = doc.data()!;
      data['id'] = doc.id;
      return AgentModel.fromJson(data);
    } catch (e) {
      developer.log(
        '❌ Failed to get agent: $e',
        name: 'AgentService',
        error: e,
      );
      return null;
    }
  }

  /// Get properties assigned to current agent
  Future<List<Map<String, dynamic>>> getAgentAssignments() async {
    try {
      if (_currentUserId == null) return [];

      final snapshot = await _firestore
          .collection('properties')
          .where('assignedAgentId', isEqualTo: _currentUserId)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get agent assignments: $e',
        name: 'AgentService',
        error: e,
      );
      return [];
    }
  }

  /// Rate an agent after inspection
  Future<bool> rateAgent({
    required String agentId,
    required double rating,
    required String propertyId,
    String? comment,
  }) async {
    try {
      if (_currentUserId == null) return false;

      // Add rating record
      await _firestore.collection('agent_ratings').add({
        'agentId': agentId,
        'raterId': _currentUserId,
        'propertyId': propertyId,
        'rating': rating,
        'comment': comment,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Update agent's average rating
      final agentDoc = await _firestore.collection('users').doc(agentId).get();
      if (agentDoc.exists) {
        final currentRating = (agentDoc.data()?['rating'] ?? 0.0).toDouble();
        final totalRatings = (agentDoc.data()?['totalRatings'] ?? 0) + 1;
        
        // Calculate new average
        final newRating = ((currentRating * (totalRatings - 1)) + rating) / totalRatings;

        await _firestore.collection('users').doc(agentId).update({
          'rating': newRating,
          'totalRatings': totalRatings,
        });
      }

      developer.log('✅ Agent rated successfully', name: 'AgentService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to rate agent: $e',
        name: 'AgentService',
        error: e,
      );
      return false;
    }
  }

  /// Increment agent's completed inspections count
  Future<bool> incrementInspectionCount(String agentId) async {
    try {
      await _firestore.collection('users').doc(agentId).update({
        'totalInspections': FieldValue.increment(1),
      });
      developer.log('✅ Inspection count incremented', name: 'AgentService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to increment inspection count: $e',
        name: 'AgentService',
        error: e,
      );
      return false;
    }
  }

  /// Calculate estimated inspection fee based on distance
  /// For now, this is a simple calculation. Can be enhanced with actual distance API
  double calculateInspectionFee({
    required String agentBaseLocation,
    required String propertyCity,
  }) {
    // Base fee
    const baseFee = 2000.0; // ₦2,000 minimum (ClearRent cut)
    
    // Simple distance-based calculation
    // Same area = base fee only
    // Different area = base + distance fee
    if (agentBaseLocation.toLowerCase() == propertyCity.toLowerCase()) {
      return baseFee + 1000; // ₦3,000 total for same area
    } else {
      return baseFee + 3000; // ₦5,000 total for different area
    }
  }

  /// Get all agents (for admin)
  Future<List<AgentModel>> getAllAgents() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'agent')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return AgentModel.fromJson(data);
      }).toList();
    } catch (e) {
      developer.log(
        '❌ Failed to get all agents: $e',
        name: 'AgentService',
        error: e,
      );
      return [];
    }
  }

  /// Verify an agent (admin only)
  Future<bool> verifyAgent(String agentId) async {
    try {
      await _firestore.collection('users').doc(agentId).update({
        'isVerified': true,
        'verifiedAt': FieldValue.serverTimestamp(),
      });
      developer.log('✅ Agent verified', name: 'AgentService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to verify agent: $e',
        name: 'AgentService',
        error: e,
      );
      return false;
    }
  }

  /// Reject/Suspend an agent (admin only)
  Future<bool> suspendAgent(String agentId, String reason) async {
    try {
      await _firestore.collection('users').doc(agentId).update({
        'isVerified': false,
        'suspendedAt': FieldValue.serverTimestamp(),
        'suspensionReason': reason,
      });
      developer.log('✅ Agent suspended', name: 'AgentService');
      return true;
    } catch (e) {
      developer.log(
        '❌ Failed to suspend agent: $e',
        name: 'AgentService',
        error: e,
      );
      return false;
    }
  }
}