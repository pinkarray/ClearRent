import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';

class SelectAgentScreen extends StatefulWidget {
  final String propertyId;
  final String? propertyCity;

  const SelectAgentScreen({
    super.key,
    required this.propertyId,
    this.propertyCity,
  });

  @override
  State<SelectAgentScreen> createState() => _SelectAgentScreenState();
}

class _SelectAgentScreenState extends State<SelectAgentScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isLoading = true;
  List<AgentData> _agents = [];
  List<AgentData> _filteredAgents = [];
  String? _selectedAgentId;
  String? _currentAgentId;
  bool _isAssigning = false;

  // Filter options
  String _sortBy = 'rating'; // 'rating', 'inspections', 'distance'
  bool _showOnlyAvailable = true;

  @override
  void initState() {
    super.initState();
    _loadCurrentAgent();
    _loadAgents();
  }

  Future<void> _loadCurrentAgent() async {
    if (widget.propertyId.isEmpty) return;
    
    try {
      final doc = await _firestore.collection('properties').doc(widget.propertyId).get();
      if (doc.exists) {
        final data = doc.data();
        setState(() {
          _currentAgentId = data?['assignedAgentId'];
          _selectedAgentId = _currentAgentId;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading current agent: $e');
    }
  }

  Future<void> _loadAgents() async {
    try {
      // Get all verified agents
      final snapshot = await _firestore
          .collection('users')
          .where('accountType', isEqualTo: 'agent')
          .where('isVerified', isEqualTo: true)
          .get();

      final agents = snapshot.docs.map((doc) {
        final data = doc.data();
        return AgentData(
          id: doc.id,
          fullName: data['fullName'] ?? 'Agent',
          baseLocation: data['baseLocation'] ?? 'Unknown',
          serviceAreas: List<String>.from(data['serviceAreas'] ?? []),
          rating: (data['rating'] ?? 0).toDouble(),
          totalRatings: data['totalRatings'] ?? 0,
          totalInspections: data['totalInspections'] ?? 0,
          completedInspections: data['completedInspections'] ?? 0,
          profileImageUrl: data['profileImageUrl'],
          availableDays: List<String>.from(data['availableDays'] ?? []),
          availableTimeSlots: List<String>.from(data['availableTimeSlots'] ?? []),
          phone: data['phone'],
        );
      }).toList();

      setState(() {
        _agents = agents;
        _applyFilters();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('❌ Error loading agents: $e');
      setState(() => _isLoading = false);
    }
  }

  void _applyFilters() {
    var filtered = List<AgentData>.from(_agents);

    // Filter by service area (agents who cover the property's city)
    final city = widget.propertyCity;
    if (city != null && city.isNotEmpty) {
      filtered = filtered.where((agent) {
        // Check if agent covers this area
        final coversArea = agent.serviceAreas.any(
          (area) => area.toLowerCase() == city.toLowerCase(),
        ) || agent.baseLocation.toLowerCase() == city.toLowerCase();
        
        // If showing only available, check if agent has any availability set
        if (_showOnlyAvailable) {
          final hasAvailability = agent.availableDays.isNotEmpty && 
                                  agent.availableTimeSlots.isNotEmpty;
          return coversArea && hasAvailability;
        }
        
        return coversArea;
      }).toList();
    } else if (_showOnlyAvailable) {
      // No city filter, but still filter by availability
      filtered = filtered.where((agent) {
        return agent.availableDays.isNotEmpty && agent.availableTimeSlots.isNotEmpty;
      }).toList();
    }

    // Sort
    switch (_sortBy) {
      case 'rating':
        filtered.sort((a, b) => b.rating.compareTo(a.rating));
        break;
      case 'inspections':
        filtered.sort((a, b) => b.completedInspections.compareTo(a.completedInspections));
        break;
      default:
        filtered.sort((a, b) => b.rating.compareTo(a.rating));
    }

    _filteredAgents = filtered;
  }

  Future<void> _assignAgent() async {
    if (_selectedAgentId == null) return;

    setState(() => _isAssigning = true);

    try {
      final agent = _agents.firstWhere((a) => a.id == _selectedAgentId);

      // First, get the property details to include in the notification
      final propertyDoc = await _firestore.collection('properties').doc(widget.propertyId).get();
      final propertyData = propertyDoc.data();
      final propertyTitle = propertyData?['title'] ?? 'a property';
      final landlordId = propertyData?['landlordId'];
      final landlordName = propertyData?['landlordName'] ?? 'Landlord';

      // Update the property with agent info
      await _firestore.collection('properties').doc(widget.propertyId).update({
        'inspectionHandler': 'agent',
        'assignedAgentId': agent.id,
        'assignedAgentName': agent.fullName,
        'assignedAgentPhone': agent.phone,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify agent about the assignment with full details
      await _firestore.collection('activities').add({
        'userId': agent.id,
        'agentId': agent.id, // Also add agentId for query flexibility
        'landlordId': landlordId,
        'type': 'property_assigned',
        'title': 'New Property Assignment',
        'message': '$landlordName assigned you to handle inspections for "$propertyTitle"',
        'propertyId': widget.propertyId,
        'propertyTitle': propertyTitle,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${agent.fullName} assigned successfully!'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        context.pop(true); // Return true to indicate success
      }
    } catch (e) {
      debugPrint('❌ Error assigning agent: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to assign agent. Please try again.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isAssigning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Select Agent', style: AppTextStyles.h4),
        centerTitle: true,
        actions: [
          if (_selectedAgentId != null && _selectedAgentId != _currentAgentId)
            TextButton(
              onPressed: _isAssigning ? null : _assignAgent,
              child: _isAssigning
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    )
                  : Text(
                      'Assign',
                      style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
                    ),
            ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : Column(
              children: [
                // Filters
                Container(
                  padding: const EdgeInsets.all(16),
                  color: AppColors.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Location info
                      if (widget.propertyCity != null && widget.propertyCity!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(26),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.location_on, color: AppColors.primary, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Showing agents who cover ${widget.propertyCity}',
                                  style: AppTextStyles.bodySmall.copyWith(color: AppColors.primary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (widget.propertyCity != null && widget.propertyCity!.isNotEmpty)
                        const SizedBox(height: 12),

                      // Filter row
                      Row(
                        children: [
                          // Sort dropdown
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _sortBy,
                                  isExpanded: true,
                                  icon: const Icon(Icons.unfold_more, size: 20),
                                  style: AppTextStyles.bodyMedium,
                                  items: const [
                                    DropdownMenuItem(value: 'rating', child: Text('Highest Rated')),
                                    DropdownMenuItem(value: 'inspections', child: Text('Most Experienced')),
                                  ],
                                  onChanged: (value) {
                                    if (value != null) {
                                      setState(() {
                                        _sortBy = value;
                                        _applyFilters();
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),

                          // Available only toggle
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _showOnlyAvailable = !_showOnlyAvailable;
                                _applyFilters();
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: _showOnlyAvailable ? AppColors.success.withAlpha(26) : AppColors.background,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _showOnlyAvailable ? AppColors.success : AppColors.border,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    _showOnlyAvailable ? Icons.check_circle : Icons.circle_outlined,
                                    color: _showOnlyAvailable ? AppColors.success : AppColors.textHint,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Available',
                                    style: AppTextStyles.labelMedium.copyWith(
                                      color: _showOnlyAvailable ? AppColors.success : AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Results count
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(
                    '${_filteredAgents.length} agent${_filteredAgents.length == 1 ? '' : 's'} found',
                    style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
                  ),
                ),

                // Agent list
                Expanded(
                  child: _filteredAgents.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                          itemCount: _filteredAgents.length,
                          itemBuilder: (context, index) {
                            final agent = _filteredAgents[index];
                            return _AgentCard(
                              agent: agent,
                              isSelected: _selectedAgentId == agent.id,
                              isCurrentAgent: _currentAgentId == agent.id,
                              propertyCity: widget.propertyCity,
                              onSelect: () {
                                setState(() {
                                  _selectedAgentId = agent.id;
                                });
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: _selectedAgentId != null && _selectedAgentId != _currentAgentId
          ? Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(13),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: AppButton(
                  text: 'Assign Selected Agent',
                  onPressed: _isAssigning ? null : _assignAgent,
                  isLoading: _isAssigning,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
    final cityText = widget.propertyCity != null && widget.propertyCity!.isNotEmpty
        ? widget.propertyCity!
        : 'this area';
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.textHint.withAlpha(26),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person_search, size: 40, color: AppColors.textHint),
            ),
            const SizedBox(height: 24),
            Text('No Agents Found', style: AppTextStyles.h4),
            const SizedBox(height: 8),
            Text(
              _showOnlyAvailable
                  ? 'No verified agents with availability set are covering $cityText yet.'
                  : 'No verified agents are covering $cityText yet.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_showOnlyAvailable)
              TextButton(
                onPressed: () {
                  setState(() {
                    _showOnlyAvailable = false;
                    _applyFilters();
                  });
                },
                child: const Text('Show all agents'),
              ),
          ],
        ),
      ),
    );
  }
}

// ============ AGENT DATA MODEL ============

class AgentData {
  final String id;
  final String fullName;
  final String baseLocation;
  final List<String> serviceAreas;
  final double rating;
  final int totalRatings;
  final int totalInspections;
  final int completedInspections;
  final String? profileImageUrl;
  final List<String> availableDays;
  final List<String> availableTimeSlots;
  final String? phone;

  AgentData({
    required this.id,
    required this.fullName,
    required this.baseLocation,
    required this.serviceAreas,
    required this.rating,
    required this.totalRatings,
    required this.totalInspections,
    required this.completedInspections,
    this.profileImageUrl,
    required this.availableDays,
    required this.availableTimeSlots,
    this.phone,
  });

  String get ratingDisplay {
    if (totalRatings == 0) return 'New';
    return rating.toStringAsFixed(1);
  }

  bool get hasAvailability => availableDays.isNotEmpty && availableTimeSlots.isNotEmpty;
}

// ============ AGENT CARD ============

class _AgentCard extends StatelessWidget {
  final AgentData agent;
  final bool isSelected;
  final bool isCurrentAgent;
  final String? propertyCity;
  final VoidCallback onSelect;

  const _AgentCard({
    required this.agent,
    required this.isSelected,
    required this.isCurrentAgent,
    this.propertyCity,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onSelect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
                : isCurrentAgent
                    ? AppColors.success.withAlpha(128)
                    : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withAlpha(26),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Avatar
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                    image: agent.profileImageUrl != null
                        ? DecorationImage(
                            image: NetworkImage(agent.profileImageUrl!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: agent.profileImageUrl == null
                      ? Center(
                          child: Text(
                            agent.fullName.isNotEmpty ? agent.fullName[0].toUpperCase() : 'A',
                            style: AppTextStyles.h4.copyWith(color: AppColors.primary),
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),

                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              agent.fullName,
                              style: AppTextStyles.labelLarge,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isCurrentAgent) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.success.withAlpha(26),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Current',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.location_on_outlined, size: 14, color: AppColors.textSecondary),
                          const SizedBox(width: 4),
                          Text(
                            agent.baseLocation,
                            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Selection indicator
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.textHint,
                      width: 2,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Stats row
            Row(
              children: [
                // Rating
                _buildStat(
                  icon: Icons.star,
                  iconColor: AppColors.warning,
                  value: agent.ratingDisplay,
                  label: agent.totalRatings > 0 ? '(${agent.totalRatings})' : '',
                ),
                const SizedBox(width: 16),

                // Completed inspections
                _buildStat(
                  icon: Icons.check_circle_outline,
                  iconColor: AppColors.success,
                  value: '${agent.completedInspections}',
                  label: 'inspections',
                ),

                const Spacer(),

                // Availability indicator
                if (agent.hasAvailability)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(26),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: AppColors.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Available',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.textHint.withAlpha(26),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'No schedule set',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
                    ),
                  ),
              ],
            ),

            // Service areas
            if (agent.serviceAreas.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: agent.serviceAreas.take(4).map((area) {
                  final isPropertyArea = propertyCity != null && 
                      area.toLowerCase() == propertyCity!.toLowerCase();
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isPropertyArea ? AppColors.primary.withAlpha(26) : AppColors.background,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isPropertyArea ? AppColors.primary.withAlpha(77) : AppColors.border,
                      ),
                    ),
                    child: Text(
                      area,
                      style: AppTextStyles.caption.copyWith(
                        color: isPropertyArea ? AppColors.primary : AppColors.textSecondary,
                        fontWeight: isPropertyArea ? FontWeight.w500 : FontWeight.normal,
                      ),
                    ),
                  );
                }).toList()
                  ..addAll(
                    agent.serviceAreas.length > 4
                        ? [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '+${agent.serviceAreas.length - 4} more',
                                style: AppTextStyles.caption.copyWith(color: AppColors.textHint),
                              ),
                            ),
                          ]
                        : [],
                  ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStat({
    required IconData icon,
    required Color iconColor,
    required String value,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 4),
        Text(value, style: AppTextStyles.labelMedium),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        ],
      ],
    );
  }
}