import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/agent_service.dart';
import '../../../../services/property_service.dart';

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
  final AgentService _agentService = AgentService();
  final PropertyService _propertyService = PropertyService();

  List<AgentModel> _agents = [];
  bool _isLoading = true;
  String? _selectedAgentId;
  AgentModel? _selectedAgent;
  bool _isAssigning = false;

  // Track whether we fell back to all agents (no local agents found)
  bool _isShowingAllAgents = false;

  @override
  void initState() {
    super.initState();
    _loadAgents();
  }

  Future<void> _loadAgents() async {
    setState(() => _isLoading = true);
    try {
      List<AgentModel> agents;
      if (widget.propertyCity != null && widget.propertyCity!.isNotEmpty) {
        agents = await _agentService.getAgentsByArea(widget.propertyCity!);
        if (agents.isEmpty) {
          agents = await _agentService.getVerifiedAgents();
          _isShowingAllAgents = true;
        } else {
          _isShowingAllAgents = false;
        }
      } else {
        agents = await _agentService.getVerifiedAgents();
        _isShowingAllAgents = true;
      }
      setState(() {
        _agents = agents;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading agents: $e');
      setState(() => _isLoading = false);
    }
  }

  void _selectAgent(AgentModel agent) {
    setState(() {
      _selectedAgentId = agent.id;
      _selectedAgent = agent;
    });
  }

  Future<void> _assignAgent() async {
    if (_selectedAgent == null) return;
    setState(() => _isAssigning = true);
    try {
      final success = await _propertyService.assignAgent(
        propertyId: widget.propertyId,
        agentId: _selectedAgent!.id,
        agentName: _selectedAgent!.fullName,
        agentPhone: _selectedAgent!.phone,
      );
      if (!mounted) return;
      if (success) {
        _showSuccessDialog();
      } else {
        _showError('Failed to assign agent. Please try again.');
      }
    } catch (e) {
      _showError('Something went wrong. Please try again.');
    }
    setState(() => _isAssigning = false);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.successLight,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check, size: 40, color: AppColors.success),
            ),
            const SizedBox(height: 24),
            Text('Agent Assigned!', style: AppTextStyles.h3),
            const SizedBox(height: 8),
            Text(
              '${_selectedAgent!.fullName} will now handle inspections for this property.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: 'Done',
                onPressed: () {
                  Navigator.pop(context);
                  context.go('/landlord/home');
                },
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
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
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _agents.isEmpty
              ? _buildEmptyState()
              : _buildAgentList(),
      bottomNavigationBar: _selectedAgent != null ? _buildBottomBar() : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.support_agent_outlined, size: 80, color: AppColors.textSecondary.withAlpha(128)),
            const SizedBox(height: 24),
            Text('No Verified Agents Available', style: AppTextStyles.h4, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'There are no verified agents in your area yet. You can handle inspections yourself for now.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            AppButton(
              text: 'I\'ll Handle Inspections',
              onPressed: () async {
                await _propertyService.updateInspectionHandler(widget.propertyId, 'self');
                if (mounted) context.go('/landlord/home');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentList() {
    return Column(
      children: [
        // Info banner
        Container(
          padding: const EdgeInsets.all(16),
          color: AppColors.surface,
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 20, color: AppColors.info),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _isShowingAllAgents
                      ? widget.propertyCity != null
                          ? 'No agents in ${widget.propertyCity} — showing all verified agents'
                          : 'Showing all verified agents'
                      : 'Showing agents available in ${widget.propertyCity}',
                  style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _agents.length,
            itemBuilder: (context, index) => _buildAgentCard(_agents[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildAgentCard(AgentModel agent) {
    final isSelected = _selectedAgentId == agent.id;

    // Determine if this agent covers the property's city
    final bool coversArea = widget.propertyCity != null &&
        widget.propertyCity!.isNotEmpty &&
        agent.serviceAreas.contains(widget.propertyCity);

    // Only show the out-of-area badge when we have a city to compare against
    final bool showOutOfAreaBadge = widget.propertyCity != null &&
        widget.propertyCity!.isNotEmpty &&
        !coversArea;

    final estimatedFee = _agentService.calculateInspectionFee(
      agentBaseLocation: agent.baseLocation,
      propertyCity: widget.propertyCity ?? '',
    );

    return GestureDetector(
      onTap: () => _selectAgent(agent),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withAlpha(13) : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            // Agent header row
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.support_agent, color: AppColors.primary, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              agent.fullName,
                              style: AppTextStyles.labelLarge.copyWith(
                                color: isSelected ? AppColors.primary : AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.verified, color: AppColors.primary, size: 18),
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.star,
                          size: 16,
                          color: agent.totalRatings > 0 ? AppColors.warning : AppColors.textHint,
                        ),
                        const SizedBox(width: 4),
                        Text(agent.ratingDisplay, style: AppTextStyles.labelMedium),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${agent.totalInspections} inspections',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
                if (isSelected) ...[
                  const SizedBox(width: 12),
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.check, color: Colors.white, size: 16),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 12),

            // Service areas line
            Row(
              children: [
                Text('Covers: ', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                Expanded(
                  child: Text(
                    agent.serviceAreas.take(3).join(', ') +
                        (agent.serviceAreas.length > 3 ? ' +${agent.serviceAreas.length - 3} more' : ''),
                    style: AppTextStyles.caption.copyWith(color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            // Out-of-area warning badge
            if (showOutOfAreaBadge) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.warning.withAlpha(77)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: AppColors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Doesn\'t cover ${widget.propertyCity} — may charge a higher fee',
                        style: AppTextStyles.caption.copyWith(color: AppColors.warning),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Estimated fee row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.infoLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Estimated inspection fee',
                    style: AppTextStyles.naira(AppTextStyles.caption.copyWith(color: AppColors.info)),
                  ),
                  Text(
                    '₦${_formatAmount(estimatedFee)}',
                    style: AppTextStyles.naira(AppTextStyles.labelMedium).copyWith(
                      color: AppColors.info,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    // Check if the selected agent covers the property city
    final bool selectedCoversArea = widget.propertyCity == null ||
        widget.propertyCity!.isEmpty ||
        (_selectedAgent?.serviceAreas.contains(widget.propertyCity) ?? false);

    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(13), blurRadius: 10, offset: const Offset(0, -5)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Out-of-area confirmation notice in bottom bar
          if (!selectedCoversArea) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withAlpha(77)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This agent is outside ${widget.propertyCity}. They may charge an additional travel fee.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.warning),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Selected agent summary
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(13),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.support_agent, color: AppColors.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedAgent!.fullName,
                        style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
                      ),
                      Text(
                        'Based in ${_selectedAgent!.baseLocation}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selectedAgentId = null;
                    _selectedAgent = null;
                  }),
                  child: const Text('Change'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppButton(
            text: 'Assign Agent',
            onPressed: _assignAgent,
            isLoading: _isAssigning,
          ),
        ],
      ),
    );
  }

  String _formatAmount(double amount) {
    final formatted = amount.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final result = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) result.add(',');
      result.add(chars[i]);
    }
    return result.reversed.join('');
  }
}