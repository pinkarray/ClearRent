import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/models/property_model.dart';
import '../../../../services/conversation_service.dart';

/// Unified Discover screen for agents.
/// Two toggle tabs at the top:
///   - Properties: browse unassigned properties from verified landlords
///   - Tenants: select an assigned property, then browse matching verified tenants
class AgentDiscoverPropertiesScreen extends StatefulWidget {
  const AgentDiscoverPropertiesScreen({super.key});

  @override
  State<AgentDiscoverPropertiesScreen> createState() =>
      _AgentDiscoverPropertiesScreenState();
}

class _AgentDiscoverPropertiesScreenState
    extends State<AgentDiscoverPropertiesScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ConversationService _conversationService = ConversationService();

  int _activeTab = 0; // 0 = Properties, 1 = Tenants

  // Properties tab
  List<PropertyModel> _discoverableProperties = [];
  bool _isLoadingProperties = true;
  String? _propertiesError;
  String _selectedCity = 'All Areas';
  String _selectedType = 'all';
  List<String> _cities = ['All Areas'];

  // Tenants tab
  List<PropertyModel> _assignedProperties = [];
  bool _isLoadingAssigned = true;
  PropertyModel? _selectedProperty;
  List<Map<String, dynamic>> _matchingTenants = [];
  bool _isLoadingTenants = false;

  @override
  void initState() {
    super.initState();
    _loadDiscoverableProperties();
    _loadAssignedProperties();
  }

  // ── Properties data ──

  Future<void> _loadDiscoverableProperties() async {
    setState(() { _isLoadingProperties = true; _propertiesError = null; });
    try {
      final currentUid = _auth.currentUser?.uid;
      if (currentUid == null) return;

      final verifiedSnap = await _firestore.collection('users')
          .where('verificationStatus', isEqualTo: 'verified')
          .where('accountType', isEqualTo: 'landlord').get();
      final verifiedIds = verifiedSnap.docs.map((d) => d.id).toSet();
      if (verifiedIds.isEmpty) { setState(() { _discoverableProperties = []; _isLoadingProperties = false; }); return; }

      final List<PropertyModel> allProps = [];
      final idList = verifiedIds.toList();
      for (var i = 0; i < idList.length; i += 30) {
        final batch = idList.skip(i).take(30).toList();
        final snap = await _firestore.collection('properties')
            .where('landlordId', whereIn: batch).where('isAvailable', isEqualTo: true).get();
        for (final doc in snap.docs) {
          final data = doc.data(); data['id'] = doc.id;
          if (data['createdAt'] is Timestamp) data['createdAt'] = (data['createdAt'] as Timestamp).toDate().toIso8601String();
          allProps.add(PropertyModel.fromJson(data));
        }
      }

      final discoverable = allProps
          .where((p) => (p.assignedAgentId == null || p.assignedAgentId!.isEmpty) && p.ownershipDocStatus != 'rejected')
          .toList()..sort((a, b) => (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));

      final citySet = <String>{'All Areas'};
      for (final p in discoverable) { if (p.city.isNotEmpty) citySet.add(p.city); }

      setState(() { _discoverableProperties = discoverable; _cities = citySet.toList()..sort(); _isLoadingProperties = false; });
    } catch (e) {
      debugPrint('❌ Error loading discoverable properties: $e');
      setState(() { _propertiesError = 'Failed to load properties. Pull to retry.'; _isLoadingProperties = false; });
    }
  }

  List<PropertyModel> get _filteredProperties {
    var list = _discoverableProperties;
    if (_selectedCity != 'All Areas') list = list.where((p) => p.city == _selectedCity).toList();
    if (_selectedType != 'all') list = list.where((p) => p.propertyType == _selectedType).toList();
    return list;
  }

  Future<void> _contactLandlord(PropertyModel property) async {
    final agentId = _auth.currentUser?.uid;
    if (agentId == null) return;
    _showLoadingDialog('Starting conversation...');
    try {
      final conversationId = await _conversationService.getOrCreateAgentPitchConversation(landlordId: property.landlordId, agentId: agentId);
      if (!mounted) return; Navigator.pop(context);
      if (conversationId != null) {
        context.push('/chat', extra: { 'conversationId': conversationId, 'propertyTitle': 'Pitch: ${property.title}', 'propertyImage': property.images.isNotEmpty ? property.images.first : null });
      } else { _showSnackBar('Could not start conversation. Make sure both accounts are verified.', isError: true); }
    } catch (e) { if (mounted) Navigator.pop(context); _showSnackBar('Something went wrong.', isError: true); }
  }

  // ── Tenants data ──

  Future<void> _loadAssignedProperties() async {
    final uid = _auth.currentUser?.uid; if (uid == null) return;
    try {
      final snap = await _firestore.collection('properties').where('assignedAgentId', isEqualTo: uid).where('isAvailable', isEqualTo: true).get();
      final props = snap.docs.map((doc) {
        final data = doc.data(); data['id'] = doc.id;
        if (data['createdAt'] is Timestamp) data['createdAt'] = (data['createdAt'] as Timestamp).toDate().toIso8601String();
        return PropertyModel.fromJson(data);
      }).toList();
      setState(() { _assignedProperties = props; _isLoadingAssigned = false; });
    } catch (e) { debugPrint('❌ Error loading assigned properties: $e'); setState(() => _isLoadingAssigned = false); }
  }

  Future<void> _loadMatchingTenants(PropertyModel property) async {
    setState(() { _selectedProperty = property; _isLoadingTenants = true; _matchingTenants = []; });
    try {
      final snap = await _firestore.collection('users').where('accountType', isEqualTo: 'tenant').where('verificationStatus', isEqualTo: 'verified').get();
      final tenants = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        final data = doc.data(); data['uid'] = doc.id;
        final score = _calculateMatchScore(data, property);
        if (score > 0) { data['_matchScore'] = score; data['_matchReasons'] = _getMatchReasons(data, property); tenants.add(data); }
      }
      tenants.sort((a, b) => (b['_matchScore'] as int).compareTo(a['_matchScore'] as int));
      setState(() { _matchingTenants = tenants; _isLoadingTenants = false; });
    } catch (e) { debugPrint('❌ Error loading tenants: $e'); setState(() => _isLoadingTenants = false); }
  }

  int _calculateMatchScore(Map<String, dynamic> t, PropertyModel p) {
    int score = 0;
    final bMin = (t['budgetMin'] as num?)?.toDouble() ?? 0;
    final bMax = (t['budgetMax'] as num?)?.toDouble() ?? 0;
 
    if (bMax > 0 && p.rent <= bMax) {
      score += 40;
    } else if (bMin > 0 && p.rent >= bMin * 0.8) {
      score += 20;
    }
 
    if (bMin == 0 && bMax == 0) {
      score += 10;
    }
 
    final areas = List<String>.from(t['preferredAreas'] ?? []);
    if (areas.isNotEmpty) {
      if (areas.contains(p.city)) {
        score += 30;
      }
    } else {
      score += 5;
    }
 
    final wm = t['workMode'] as String?;
    final wa = t['workplaceArea'] as String?;
 
    if (wm == 'remote') {
      score += 20;
    } else if ((wm == 'commute' || wm == 'hybrid') && wa == p.city) {
      score += 20;
    } else if (wa != null) {
      score += 5;
    }
 
    if ((t['occupation'] as String?)?.isNotEmpty == true) {
      score += 5;
    }
    if (wm != null) {
      score += 5;
    }
 
    return score;
  }

  List<String> _getMatchReasons(Map<String, dynamic> t, PropertyModel p) {
    final r = <String>[];
    final bMax = (t['budgetMax'] as num?)?.toDouble() ?? 0;
    if (bMax > 0 && p.rent <= bMax) r.add('Within budget');
    final areas = List<String>.from(t['preferredAreas'] ?? []);
    if (areas.contains(p.city)) r.add('Prefers ${p.city}');
    final wm = t['workMode'] as String?;
    if (wm == 'remote') {
      r.add('Works remotely');
    } else if ((wm == 'commute' || wm == 'hybrid') && t['workplaceArea'] == p.city) {
      r.add('Works in ${p.city}');
    }
    final occ = t['occupation'] as String?;
    if (occ != null && occ.isNotEmpty) r.add(occ);
    return r;
  }

  Future<void> _contactTenant(Map<String, dynamic> tenant) async {
    final agentId = _auth.currentUser?.uid;
    if (agentId == null || _selectedProperty == null) return;
    _showLoadingDialog('Starting conversation...');
    try {
      final agentDoc = await _firestore.collection('users').doc(agentId).get();
      final conversation = await _conversationService.getOrCreateConversation(
        propertyId: _selectedProperty!.id, propertyTitle: _selectedProperty!.title,
        propertyImage: _selectedProperty!.images.isNotEmpty ? _selectedProperty!.images.first : '',
        landlordId: _selectedProperty!.landlordId, landlordName: _selectedProperty!.landlordName ?? 'Landlord',
        tenantId: tenant['uid'] as String, tenantName: tenant['fullName'] as String? ?? 'Tenant',
        agentId: agentId, agentName: agentDoc.data()?['fullName'] as String? ?? 'Agent',
      );
      if (!mounted) return; Navigator.pop(context);
      if (conversation != null) {
        context.push('/chat', extra: { 'conversationId': conversation.id, 'propertyTitle': _selectedProperty!.title, 'propertyImage': _selectedProperty!.images.isNotEmpty ? _selectedProperty!.images.first : null });
      } else { _showSnackBar('Could not start conversation. Both parties must be verified.', isError: true); }
    } catch (e) { if (mounted) Navigator.pop(context); _showSnackBar('Something went wrong.', isError: true); }
  }

  // ── Helpers ──

  void _showLoadingDialog(String msg) {
    showDialog(context: context, barrierDismissible: false, builder: (_) => Center(
      child: Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(color: AppColors.primary), const SizedBox(height: 16), Text(msg, style: AppTextStyles.bodyMedium)])),
    ));
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: isError ? AppColors.error : AppColors.success, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Discover', style: AppTextStyles.h3),
            const SizedBox(height: 4),
            Text(
              _activeTab == 0
                  ? 'Find properties and pitch your services to landlords.'
                  : _selectedProperty != null
                      ? 'Tenants matching ${_selectedProperty!.title}'
                      : 'Find tenants that match your assigned properties.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            _buildTabToggle(),
          ]),
        ),
        const SizedBox(height: 12),
        Expanded(child: _activeTab == 0 ? _buildPropertiesTab() : _buildTenantsTab()),
      ],
    );
  }

  Widget _buildTabToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: Row(children: [
        _buildToggle(0, Icons.home_work_outlined, 'Properties'),
        _buildToggle(1, Icons.people_outline, 'Tenants'),
      ]),
    );
  }

  Widget _buildToggle(int idx, IconData icon, String label) {
    final active = _activeTab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = idx),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: active ? AppColors.primary : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: active ? Colors.white : AppColors.textSecondary),
            const SizedBox(width: 8),
            Text(label, style: AppTextStyles.labelMedium.copyWith(color: active ? Colors.white : AppColors.textSecondary, fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
          ]),
        ),
      ),
    );
  }

  // ── Properties tab UI ──

  Widget _buildPropertiesTab() {
    return RefreshIndicator(
      onRefresh: _loadDiscoverableProperties, color: AppColors.primary,
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: _buildPropertyFilters()),
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 4), child: Text('${_filteredProperties.length} ${_filteredProperties.length == 1 ? 'property' : 'properties'} available', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)))),
        if (_isLoadingProperties) const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (_propertiesError != null) SliverFillRemaining(child: _emptyState(Icons.error_outline, 'Error', _propertiesError!))
        else if (_filteredProperties.isEmpty) SliverFillRemaining(child: _emptyState(Icons.search_off, 'No unassigned properties', 'Try changing filters or check back later.'))
        else SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
          sliver: SliverList(delegate: SliverChildBuilderDelegate(
            (ctx, i) => Padding(padding: const EdgeInsets.only(bottom: 16), child: _propertyCard(_filteredProperties[i])),
            childCount: _filteredProperties.length,
          )),
        ),
      ]),
    );
  }

  Widget _buildPropertyFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(children: [
        Expanded(child: _dropdown(_selectedCity, _cities.map((c) => DropdownMenuItem(value: c, child: Text(c, style: AppTextStyles.labelMedium))).toList(), (v) => setState(() => _selectedCity = v ?? 'All Areas'))),
        const SizedBox(width: 10),
        Expanded(child: _dropdown(_selectedType, const [
          DropdownMenuItem(value: 'all', child: Text('All Types')),
          DropdownMenuItem(value: 'flat', child: Text('Flat')),
          DropdownMenuItem(value: 'self_contain', child: Text('Self Contain')),
          DropdownMenuItem(value: 'duplex', child: Text('Duplex')),
          DropdownMenuItem(value: 'bungalow', child: Text('Bungalow')),
          DropdownMenuItem(value: 'room', child: Text('Single Room')),
        ], (v) => setState(() => _selectedType = v ?? 'all'))),
      ]),
    );
  }

  Widget _dropdown(String value, List<DropdownMenuItem<String>> items, ValueChanged<String?> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: value, isExpanded: true, icon: Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary, size: 20), style: AppTextStyles.labelMedium, items: items, onChanged: onChanged)),
    );
  }

  Widget _propertyCard(PropertyModel p) {
    return GestureDetector(
      onTap: () => context.push('/agent/property/${p.id}'),
      child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            child: p.images.isNotEmpty
                ? CachedNetworkImage(imageUrl: p.images.first, height: 160, width: double.infinity, fit: BoxFit.cover,
                    placeholder: (_, __) => Container(height: 160, color: AppColors.background, child: Center(child: Icon(Icons.image, color: AppColors.textHint, size: 40))),
                    errorWidget: (_, __, ___) => Container(height: 160, color: AppColors.background, child: Center(child: Icon(Icons.broken_image, color: AppColors.textHint, size: 40))))
                : Container(height: 160, color: AppColors.background, child: Center(child: Icon(Icons.home_work_outlined, color: AppColors.textHint, size: 48))),
          ),
          Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(p.title, style: AppTextStyles.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis)), Text(p.formattedRent, style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary, fontFamily: 'Roboto')), Text(p.rentPeriod, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary))]),
            const SizedBox(height: 6),
            Row(children: [Icon(Icons.location_on_outlined, size: 14, color: AppColors.textSecondary), const SizedBox(width: 4), Expanded(child: Text(p.publicLocation, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis))]),
            const SizedBox(height: 8),
            Row(children: [_spec(Icons.bed_outlined, '${p.bedrooms} Bed'), const SizedBox(width: 12), _spec(Icons.bathtub_outlined, '${p.bathrooms} Bath'), const SizedBox(width: 12), _spec(Icons.home_outlined, p.propertyType)]),
            if (p.totalPackage > p.rent) Padding(padding: const EdgeInsets.only(top: 8), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: AppColors.primary.withAlpha(13), borderRadius: BorderRadius.circular(6)), child: Text('Total Package: ${p.formattedTotalPackage}', style: AppTextStyles.caption.copyWith(color: AppColors.primary, fontWeight: FontWeight.w600, fontFamily: 'Roboto')))),
            const SizedBox(height: 12),
            Row(children: [Icon(Icons.person_outline, size: 16, color: AppColors.textSecondary), const SizedBox(width: 6), Expanded(child: Text(p.landlordName ?? 'Landlord', style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary))),
              SizedBox(height: 36, child: ElevatedButton.icon(onPressed: () => _contactLandlord(p), icon: const Icon(Icons.message_outlined, size: 16), label: const Text('Pitch'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, textStyle: AppTextStyles.labelSmall.copyWith(fontWeight: FontWeight.w600), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 14), elevation: 0)))]),
          ])),
        ]),
      ),
    );
  }

  Widget _spec(IconData icon, String label) => Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: AppColors.textHint), const SizedBox(width: 4), Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary))]);

  // ── Tenants tab UI ──

  Widget _buildTenantsTab() {
    if (_isLoadingAssigned) return const Center(child: CircularProgressIndicator());
    if (_assignedProperties.isEmpty) return _emptyState(Icons.home_work_outlined, 'No assigned properties', 'Switch to the Properties tab to find and pitch on listings. Once a landlord assigns you, come back here to find matching tenants.');
    if (_selectedProperty == null) return _buildPropertyPicker();
    return _buildTenantResults();
  }

  Widget _buildPropertyPicker() {
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('Select a property to find matching tenants', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
      const SizedBox(height: 16),
      ..._assignedProperties.map((p) => Padding(padding: const EdgeInsets.only(bottom: 12), child: _pickerCard(p))),
    ]);
  }

  Widget _pickerCard(PropertyModel p) {
    return GestureDetector(
      onTap: () => _loadMatchingTenants(p),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: Row(children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: p.images.isNotEmpty ? CachedNetworkImage(imageUrl: p.images.first, width: 60, height: 60, fit: BoxFit.cover, errorWidget: (_, __, ___) => _thumb()) : _thumb()),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, style: AppTextStyles.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text('${p.city} · ${p.formattedRent}${p.rentPeriod}', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
            Text('${p.bedrooms} bed · ${p.propertyType}', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
          ])),
          Icon(Icons.chevron_right, color: AppColors.textHint),
        ]),
      ),
    );
  }

  Widget _thumb() => Container(width: 60, height: 60, decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)), child: Icon(Icons.home_outlined, color: AppColors.textHint, size: 28));

  Widget _buildTenantResults() {
    return Column(children: [
      // Back + banner
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 0), child: Row(children: [
        GestureDetector(
          onTap: () => setState(() { _selectedProperty = null; _matchingTenants = []; }),
          child: Container(width: 36, height: 36, decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)), child: Icon(Icons.arrow_back, size: 18, color: AppColors.textSecondary)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: AppColors.primary.withAlpha(13), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.primary.withAlpha(50))),
          child: Row(children: [Icon(Icons.home_work, size: 18, color: AppColors.primary), const SizedBox(width: 8), Expanded(child: Text('${_selectedProperty!.title} · ${_selectedProperty!.city}', style: AppTextStyles.labelSmall.copyWith(color: AppColors.primary), maxLines: 1, overflow: TextOverflow.ellipsis))]),
        )),
      ])),
      const SizedBox(height: 12),
      Expanded(
        child: _isLoadingTenants
            ? const Center(child: CircularProgressIndicator())
            : _matchingTenants.isEmpty
                ? _emptyState(Icons.people_outline, 'No matching tenants yet', 'As more tenants sign up and complete their profiles, matches will appear here.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                    itemCount: _matchingTenants.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == 0) return Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('${_matchingTenants.length} matching ${_matchingTenants.length == 1 ? 'tenant' : 'tenants'}', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)));
                      return Padding(padding: const EdgeInsets.only(bottom: 12), child: _tenantCard(_matchingTenants[i - 1]));
                    },
                  ),
      ),
    ]);
  }

  Widget _tenantCard(Map<String, dynamic> t) {
    final name = t['fullName'] as String? ?? 'Tenant';
    final occ = t['occupation'] as String? ?? '';
    final wm = t['workMode'] as String?;
    final score = t['_matchScore'] as int? ?? 0;
    final reasons = List<String>.from(t['_matchReasons'] ?? []);
    final img = t['profileImageUrl'] as String?;
    final ms = t['maritalStatus'] as String?;

    final matchLabel = score >= 70 ? 'Strong match' : score >= 40 ? 'Good match' : 'Partial match';
    final matchColor = score >= 70 ? AppColors.success : score >= 40 ? AppColors.primary : AppColors.warning;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 22, backgroundColor: AppColors.primary.withAlpha(26),
            backgroundImage: (img != null && img.isNotEmpty) ? NetworkImage(img) : null,
            child: (img == null || img.isEmpty) ? Text(name.isNotEmpty ? name[0].toUpperCase() : 'T', style: AppTextStyles.labelLarge.copyWith(color: AppColors.primary)) : null),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: AppTextStyles.labelLarge), if (occ.isNotEmpty) Text(occ, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary))])),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: matchColor.withAlpha(26), borderRadius: BorderRadius.circular(20)), child: Text(matchLabel, style: AppTextStyles.caption.copyWith(color: matchColor, fontWeight: FontWeight.w600))),
        ]),
        if (reasons.isNotEmpty) ...[const SizedBox(height: 10), Wrap(spacing: 6, runSpacing: 6, children: reasons.map((r) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(6)), child: Text(r, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)))).toList())],
        const SizedBox(height: 10),
        Row(children: [
          if (wm != null) ...[Icon(wm == 'remote' ? Icons.home_outlined : wm == 'hybrid' ? Icons.sync_alt : Icons.directions_car_outlined, size: 14, color: AppColors.textHint), const SizedBox(width: 4), Text(wm == 'remote' ? 'Remote' : wm == 'hybrid' ? 'Hybrid' : 'Commutes', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)), const SizedBox(width: 12)],
          if (ms != null) ...[Icon(Icons.people_outline, size: 14, color: AppColors.textHint), const SizedBox(width: 4), Text(ms == 'single' ? 'Single' : ms == 'married' ? 'Married' : 'Family', style: AppTextStyles.caption.copyWith(color: AppColors.textHint))],
          const Spacer(),
          SizedBox(height: 34, child: ElevatedButton.icon(onPressed: () => _contactTenant(t), icon: const Icon(Icons.message_outlined, size: 14), label: const Text('Message'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, textStyle: AppTextStyles.labelSmall.copyWith(fontWeight: FontWeight.w600), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 12), elevation: 0))),
        ]),
      ]),
    );
  }

  Widget _emptyState(IconData icon, String title, String sub) => Center(child: Padding(padding: const EdgeInsets.all(40), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 48, color: AppColors.textHint), const SizedBox(height: 16), Text(title, style: AppTextStyles.labelLarge, textAlign: TextAlign.center), const SizedBox(height: 8), Text(sub, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary), textAlign: TextAlign.center)])));
}