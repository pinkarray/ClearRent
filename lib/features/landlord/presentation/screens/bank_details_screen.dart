import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';

class BankDetailsScreen extends StatefulWidget {
  const BankDetailsScreen({super.key});

  @override
  State<BankDetailsScreen> createState() => _BankDetailsScreenState();
}

class _BankDetailsScreenState extends State<BankDetailsScreen> {
  final AuthService _authService = AuthService();
  
  final _accountNumberController = TextEditingController();
  final _accountNameController = TextEditingController();
  
  final _accountNumberFocusNode = FocusNode();
  final _accountNameFocusNode = FocusNode();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasExistingDetails = false;
  
  String? _selectedBank;
  
  // Nigerian banks list
  final List<Map<String, String>> _banks = [
    {'name': 'Access Bank', 'code': '044'},
    {'name': 'Citibank Nigeria', 'code': '023'},
    {'name': 'Ecobank Nigeria', 'code': '050'},
    {'name': 'Fidelity Bank', 'code': '070'},
    {'name': 'First Bank of Nigeria', 'code': '011'},
    {'name': 'First City Monument Bank (FCMB)', 'code': '214'},
    {'name': 'Guaranty Trust Bank (GTBank)', 'code': '058'},
    {'name': 'Heritage Bank', 'code': '030'},
    {'name': 'Keystone Bank', 'code': '082'},
    {'name': 'Kuda Bank', 'code': '090267'},
    {'name': 'Moniepoint MFB', 'code': '50515'},
    {'name': 'Opay', 'code': '999992'},
    {'name': 'Palmpay', 'code': '999991'},
    {'name': 'Polaris Bank', 'code': '076'},
    {'name': 'Providus Bank', 'code': '101'},
    {'name': 'Stanbic IBTC Bank', 'code': '221'},
    {'name': 'Standard Chartered Bank', 'code': '068'},
    {'name': 'Sterling Bank', 'code': '232'},
    {'name': 'Union Bank of Nigeria', 'code': '032'},
    {'name': 'United Bank for Africa (UBA)', 'code': '033'},
    {'name': 'Unity Bank', 'code': '215'},
    {'name': 'Wema Bank', 'code': '035'},
    {'name': 'Zenith Bank', 'code': '057'},
  ];

  @override
  void initState() {
    super.initState();
    _loadBankDetails();
  }

  @override
  void dispose() {
    _accountNumberController.dispose();
    _accountNameController.dispose();
    _accountNumberFocusNode.dispose();
    _accountNameFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadBankDetails() async {
    try {
      final profile = await _authService.getUserProfile();
      
      if (mounted && profile != null) {
        final bankDetails = profile['bankDetails'] as Map<String, dynamic>?;
        
        if (bankDetails != null) {
          setState(() {
            _selectedBank = bankDetails['bankName'];
            _accountNumberController.text = bankDetails['accountNumber'] ?? '';
            _accountNameController.text = bankDetails['accountName'] ?? '';
            _hasExistingDetails = true;
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Error loading bank details: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveBankDetails() async {
    // Validate
    if (_selectedBank == null) {
      _showError('Please select a bank');
      return;
    }
    
    if (_accountNumberController.text.trim().isEmpty) {
      _showError('Please enter your account number');
      _accountNumberFocusNode.requestFocus();
      return;
    }
    
    if (_accountNumberController.text.trim().length < 10) {
      _showError('Account number must be 10 digits');
      _accountNumberFocusNode.requestFocus();
      return;
    }
    
    if (_accountNameController.text.trim().isEmpty) {
      _showError('Please enter the account name');
      _accountNameFocusNode.requestFocus();
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Find bank code
      final bank = _banks.firstWhere((b) => b['name'] == _selectedBank);
      
      final success = await _authService.updateUserProfile({
        'bankDetails': {
          'bankName': _selectedBank,
          'bankCode': bank['code'],
          'accountNumber': _accountNumberController.text.trim(),
          'accountName': _accountNameController.text.trim(),
          'updatedAt': DateTime.now().toIso8601String(),
        },
      });

      if (mounted) {
        setState(() => _isSaving = false);

        if (success) {
          setState(() => _hasExistingDetails = true);
          _showSuccess('Bank details saved successfully');
        } else {
          _showError('Failed to save bank details');
        }
      }
    } catch (e) {
      debugPrint('❌ Error saving bank details: $e');
      if (mounted) {
        setState(() => _isSaving = false);
        _showError('Something went wrong. Please try again.');
      }
    }
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Bank Details', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header info
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primary.withAlpha(51)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(26),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.account_balance,
                            color: AppColors.primary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Payout Account',
                                style: AppTextStyles.labelLarge,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Rent payments will be sent to this account',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Bank Selection
                  Text(
                    'Bank Name',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildBankDropdown(),

                  const SizedBox(height: 24),

                  // Account Number
                  Text(
                    'Account Number',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accountNumberController,
                    focusNode: _accountNumberFocusNode,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    decoration: InputDecoration(
                      hintText: 'Enter 10-digit account number',
                      hintStyle: TextStyle(color: AppColors.textHint),
                      prefixIcon: Icon(Icons.numbers, color: AppColors.textHint),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Account Name
                  Text(
                    'Account Name',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accountNameController,
                    focusNode: _accountNameFocusNode,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      hintText: 'Enter account holder name',
                      hintStyle: TextStyle(color: AppColors.textHint),
                      prefixIcon: Icon(Icons.person_outline, color: AppColors.textHint),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Note about verification
                  Text(
                    'Please ensure the account name matches your registered name for successful payouts.',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint,
                      fontStyle: FontStyle.italic,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Save Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveBankDetails,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        disabledBackgroundColor: AppColors.primary.withAlpha(128),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _hasExistingDetails ? 'Update Bank Details' : 'Save Bank Details',
                              style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
                            ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Security note
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.security,
                          color: AppColors.success,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Your information is secure',
                                style: AppTextStyles.labelMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Bank details are encrypted and only used for rent payouts through our secure payment partner.',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
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

  Widget _buildBankDropdown() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButton<String>(
          underline: const SizedBox.shrink(),
          value: _selectedBank,
          hint: Row(
            children: [
              Icon(Icons.account_balance_outlined, color: AppColors.textHint),
              const SizedBox(width: 12),
              Text(
                'Select your bank',
                style: TextStyle(color: AppColors.textHint),
              ),
            ],
          ),
          isExpanded: true,
          icon: Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
          items: _banks.map((bank) {
            return DropdownMenuItem<String>(
              value: bank['name'],
              child: Text(bank['name']!),
            );
          }).toList(),
          onChanged: (value) {
            setState(() => _selectedBank = value);
          },
          dropdownColor: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
      );
  }
}