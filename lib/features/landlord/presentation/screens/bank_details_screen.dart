import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/paystack_service.dart';

class BankDetailsScreen extends StatefulWidget {
  final bool isOnboarding;
  final String? accountType;

  const BankDetailsScreen({
    super.key,
    this.isOnboarding = false,
    this.accountType,
  });

  @override
  State<BankDetailsScreen> createState() => _BankDetailsScreenState();
}

class _BankDetailsScreenState extends State<BankDetailsScreen> {
  final AuthService _authService = AuthService();
  final PaystackService _paystackService = PaystackService();

  final _accountNumberController = TextEditingController();
  final _accountNameController = TextEditingController();
  final _accountNumberFocusNode = FocusNode();
  final _accountNameFocusNode = FocusNode();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasExistingDetails = false;
  bool _isResolvingAccount = false;
  bool _resolvedSuccessfully = false;

  String? _selectedBank;
  String? _selectedBankCode;

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
    _accountNumberController.addListener(_onAccountNumberChanged);
  }

  @override
  void dispose() {
    _accountNumberController.removeListener(_onAccountNumberChanged);
    _accountNumberController.dispose();
    _accountNameController.dispose();
    _accountNumberFocusNode.dispose();
    _accountNameFocusNode.dispose();
    super.dispose();
  }

  void _onAccountNumberChanged() {
    final digits = _accountNumberController.text.trim();
    if (digits.length == 10 && _selectedBankCode != null) {
      _resolveAccountName();
    } else {
      if (_resolvedSuccessfully) {
        setState(() {
          _resolvedSuccessfully = false;
          _accountNameController.clear();
        });
      }
    }
  }

  Future<void> _resolveAccountName() async {
    if (_selectedBankCode == null) return;
    final accountNumber = _accountNumberController.text.trim();
    if (accountNumber.length != 10) return;

    setState(() {
      _isResolvingAccount = true;
      _resolvedSuccessfully = false;
    });

    try {
      final result = await _paystackService.resolveAccount(
        accountNumber: accountNumber,
        bankCode: _selectedBankCode!,
      );

      if (!mounted) return;

      if (result != null) {
        setState(() {
          _accountNameController.text = result;
          _resolvedSuccessfully = true;
          _isResolvingAccount = false;
        });
      } else {
        setState(() {
          _isResolvingAccount = false;
          _resolvedSuccessfully = false;
        });
      }
    } catch (e) {
      AppLogger.e('Error resolving account', error: e, name: 'BankDetails');
      if (mounted) {
        setState(() {
          _isResolvingAccount = false;
          _resolvedSuccessfully = false;
        });
      }
    }
  }

  Future<void> _loadBankDetails() async {
    try {
      // C1: bank details now live in the locked users/{uid}/private/bank
      // subcollection, not on the user doc.
      final bankDetails = await _authService.getBankDetails();

      if (mounted) {
        if (bankDetails != null) {
          setState(() {
            _selectedBank = bankDetails['bankName'];
            _selectedBankCode = bankDetails['bankCode'];
            _accountNumberController.text = bankDetails['accountNumber'] ?? '';
            _accountNameController.text = bankDetails['accountName'] ?? '';
            _hasExistingDetails = true;
            if (_accountNameController.text.isNotEmpty) {
              _resolvedSuccessfully = true;
            }
          });
        }
      }
    } catch (e) {
      AppLogger.e('Error loading bank details', error: e, name: 'BankDetails');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveBankDetails() async {
    if (_selectedBank == null || _selectedBankCode == null) {
      _showError('Please select a bank');
      return;
    }
    if (_accountNumberController.text.trim().length < 10) {
      _showError('Account number must be 10 digits');
      _accountNumberFocusNode.requestFocus();
      return;
    }
    if (_accountNameController.text.trim().isEmpty) {
      _showError('Please wait for account name to resolve or enter it manually');
      _accountNameFocusNode.requestFocus();
      return;
    }

    setState(() => _isSaving = true);

    try {
      final success = await _authService.saveBankDetails({
        'bankName': _selectedBank,
        'bankCode': _selectedBankCode,
        'accountNumber': _accountNumberController.text.trim(),
        'accountName': _accountNameController.text.trim(),
      });

      if (mounted) {
        setState(() => _isSaving = false);
        if (success) {
          setState(() => _hasExistingDetails = true);
          if (widget.isOnboarding) {
            _showSuccess('Bank details saved! Welcome to ClearRent');
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) _navigateToHome();
          } else {
            _showSuccess('Bank details saved successfully');
          }
        } else {
          _showError('Failed to save bank details');
        }
      }
    } catch (e) {
      AppLogger.e('Error saving bank details', error: e, name: 'BankDetails');
      if (mounted) {
        setState(() => _isSaving = false);
        _showError('Something went wrong. Please try again.');
      }
    }
  }

  void _navigateToHome() {
    final type = widget.accountType ?? 'tenant';
    switch (type) {
      case 'landlord':
        context.go('/landlord/home');
        break;
      case 'agent':
        context.go('/agent/home');
        break;
      default:
        context.go('/tenant/home');
    }
  }

  void _showBankPicker() {
    final searchController = TextEditingController();
    List<Map<String, String>> filtered = List.from(_banks);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Select Bank', style: AppTextStyles.h4),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search bank...',
                        hintStyle: TextStyle(color: AppColors.textHint),
                        prefixIcon: Icon(Icons.search, color: AppColors.textHint),
                        filled: true,
                        fillColor: AppColors.background,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      onChanged: (query) {
                        setSheetState(() {
                          filtered = _banks.where((b) =>
                              b['name']!.toLowerCase().contains(
                                  query.toLowerCase())).toList();
                        });
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, index) {
                    final bank = filtered[index];
                    final isSelected = bank['name'] == _selectedBank;
                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary.withAlpha(26)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.account_balance,
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        bank['name']!,
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.textPrimary,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check_circle, color: AppColors.primary, size: 20)
                          : null,
                      onTap: () {
                        setState(() {
                          _selectedBank = bank['name'];
                          _selectedBankCode = bank['code'];
                          _resolvedSuccessfully = false;
                          _accountNameController.clear();
                        });
                        Navigator.pop(ctx);
                        // Trigger resolve if account number already entered
                        if (_accountNumberController.text.trim().length == 10) {
                          _resolveAccountName();
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
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
        title: Text('Bank Details', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isOnboarding
                        ? 'Add your bank details'
                        : (_hasExistingDetails ? 'Update your bank details' : 'Add your bank details'),
                    style: AppTextStyles.h3,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This is where rent payments and payouts will be sent.',
                    style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 32),

                  // Bank Selection (searchable)
                  Text('Bank', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _showBankPicker,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.account_balance_outlined, color: _selectedBank != null ? AppColors.textPrimary : AppColors.textHint),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedBank ?? 'Select your bank',
                              style: TextStyle(
                                color: _selectedBank != null ? AppColors.textPrimary : AppColors.textHint,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Account Number
                  Text('Account Number', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
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
                      suffixIcon: _isResolvingAccount
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : _resolvedSuccessfully
                              ? Icon(Icons.check_circle, color: AppColors.success)
                              : null,
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
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Account Name (auto-resolved or manual)
                  Text('Account Name', style: AppTextStyles.labelMedium.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accountNameController,
                    focusNode: _accountNameFocusNode,
                    textCapitalization: TextCapitalization.words,
                    readOnly: _resolvedSuccessfully,
                    decoration: InputDecoration(
                      hintText: _isResolvingAccount ? 'Resolving...' : 'Auto-filled from bank',
                      hintStyle: TextStyle(color: AppColors.textHint),
                      prefixIcon: Icon(Icons.person_outline, color: AppColors.textHint),
                      suffixIcon: _resolvedSuccessfully
                          ? Icon(Icons.verified, color: AppColors.success, size: 20)
                          : null,
                      filled: true,
                      fillColor: _resolvedSuccessfully
                          ? AppColors.success.withAlpha(13)
                          : AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _resolvedSuccessfully ? AppColors.success : AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _resolvedSuccessfully ? AppColors.success : AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    ),
                  ),

                  const SizedBox(height: 12),
                  Text(
                    _resolvedSuccessfully
                        ? 'Account name verified by your bank'
                        : 'Select a bank and enter your account number to auto-resolve',
                    style: AppTextStyles.caption.copyWith(
                      color: _resolvedSuccessfully ? AppColors.success : AppColors.textHint,
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        disabledBackgroundColor: AppColors.primary.withAlpha(128),
                      ),
                      child: _isSaving
                          ? const SizedBox(width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(
                              widget.isOnboarding
                                  ? 'Save & Continue'
                                  : (_hasExistingDetails ? 'Update Bank Details' : 'Save Bank Details'),
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
                        Icon(Icons.security, color: AppColors.success, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Your information is secure', style: AppTextStyles.labelMedium),
                              const SizedBox(height: 4),
                              Text(
                                'Bank details are encrypted and only used for rent payouts through our secure payment partner.',
                                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
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
}