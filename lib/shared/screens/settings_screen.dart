import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/constants/colors.dart';
import '../../core/utils/app_info.dart';
import '../../core/constants/text_styles.dart';
import '../../services/auth_service.dart';
import '../../services/biometric_service.dart';
import '../../shared/widgets/theme_selector.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _privacyUrl = 'https://www.verealtytech.com/privacy';
  static const String _termsUrl = 'https://www.verealtytech.com/terms';

  final AuthService _authService = AuthService();
  final BiometricService _biometricService = BiometricService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isSendingReset = false;
  String? _userEmail;
  String? _accountType;
  
  // Biometric state
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  String _biometricTypeName = 'Biometric';
  bool _isLoadingBiometric = true;
  
  // Call permission state (for landlords only)
  bool _allowsCalls = false;
  bool _isUpdatingCallPermission = false;

  @override
  void initState() {
    super.initState();
    _userEmail = FirebaseAuth.instance.currentUser?.email;
    _loadBiometricStatus();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    try {
      final userId = _authService.currentUser?.uid;
      if (userId == null) return;

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (userDoc.exists) {
        final userData = userDoc.data();
        if (mounted) {
          setState(() {
            _accountType = userData?['accountType'];
            _allowsCalls = userData?['allowsCalls'] ?? false;
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Error loading user profile: $e');
    }
  }

  Future<void> _loadBiometricStatus() async {
    final available = await _biometricService.isBiometricAvailable();
    final enabled = await _biometricService.isBiometricEnabled();
    final typeName = await _biometricService.getBiometricTypeName();
    
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _biometricEnabled = enabled;
        _biometricTypeName = typeName;
        _isLoadingBiometric = false;
      });
    }
  }

  Future<void> _toggleBiometric(bool enable) async {
    if (enable) {
      // Verify biometric before enabling
      final authenticated = await _biometricService.authenticate(
        reason: 'Verify to enable $_biometricTypeName login',
      );
      
      if (authenticated) {
        await _biometricService.setBiometricEnabled(true);
        // Also save current email for biometric login
        if (_userEmail != null) {
          await _biometricService.setLastUserEmail(_userEmail!);
        }
        if (mounted) {
          setState(() => _biometricEnabled = true);
          _showSuccess('$_biometricTypeName login enabled');
        }
      }
    } else {
      await _biometricService.setBiometricEnabled(false);
      if (mounted) {
        setState(() => _biometricEnabled = false);
        _showSuccess('$_biometricTypeName login disabled');
      }
    }
  }

  Future<void> _toggleCallPermission(bool value) async {
    setState(() => _isUpdatingCallPermission = true);

    try {
      final userId = _authService.currentUser?.uid;
      if (userId == null) return;

      await _firestore.collection('users').doc(userId).update({
        'allowsCalls': value,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _allowsCalls = value;
        _isUpdatingCallPermission = false;
      });

      if (mounted) {
        _showSuccess(
          value 
              ? 'Phone calls enabled. Tenants can now call you directly.'
              : 'Phone calls disabled. Tenants can only message you.',
        );
      }
    } catch (e) {
      debugPrint('❌ Error updating call permission: $e');
      setState(() => _isUpdatingCallPermission = false);
      
      if (mounted) {
        _showError('Failed to update settings');
      }
    }
  }

  void _showLogoutConfirmation() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _performLogout();
            },
            child: Text('Logout', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  Future<void> _performLogout() async {
    // If biometric is enabled, ask if they want to keep it
    if (_biometricEnabled) {
      final keepBiometric = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Keep $_biometricTypeName Login?'),
          content: Text(
            'Do you want to keep $_biometricTypeName login enabled for faster sign-in next time?',
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false), // Disable
              child: Text('Disable', style: TextStyle(color: AppColors.error)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true), // Keep
              child: Text('Keep', style: TextStyle(color: AppColors.primary)),
            ),
          ],
        ),
      );

      if (keepBiometric == false) {
        await _biometricService.setBiometricEnabled(false);
        await _biometricService.clearLastUserEmail();
      }
    }

    await _authService.signOut();
    if (mounted) {
      context.go('/login');
    }
  }

  Future<void> _sendPasswordReset() async {
    if (_userEmail == null) {
      _showError('No email found for this account');
      return;
    }

    setState(() => _isSendingReset = true);

    final success = await _authService.sendPasswordResetEmail(_userEmail!);

    if (!mounted) return;

    setState(() => _isSendingReset = false);

    if (success) {
      _showSuccess('Password reset email sent to $_userEmail');
    } else {
      _showError('Failed to send reset email. Please try again.');
    }
  }

  void _showChangePasswordDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'We\'ll send a password reset link to:',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _userEmail ?? 'Unknown',
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _sendPasswordReset();
            },
            child: Text(
              'Send Link',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  bool _isDeletingAccount = false;

  void _showDeleteAccountDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.error),
            const SizedBox(width: 8),
            const Text('Delete Account'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This action cannot be undone. All your data will be permanently deleted, including:',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: 12),
            _buildDeleteItem('Your profile information'),
            _buildDeleteItem('Your properties and listings'),
            _buildDeleteItem('Your rental history'),
            _buildDeleteItem('Inspection requests'),
            _buildDeleteItem('Message history'),
            _buildDeleteItem('Payment records'),
            const SizedBox(height: 16),
            Text(
              'Are you sure you want to permanently delete your account?',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _confirmDeleteAccount();
            },
            child: Text(
              'Delete My Account',
              style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount() {
    // Second confirmation with typed input
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Type DELETE to confirm', style: AppTextStyles.h4.copyWith(color: AppColors.error)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This is your last chance. Type DELETE below to permanently remove your account.',
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: confirmController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'Type DELETE',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.error),
                ),
              ),
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              if (confirmController.text.trim().toUpperCase() == 'DELETE') {
                Navigator.pop(ctx);
                _executeDeleteAccount();
              }
            },
            child: Text('Delete Forever', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<void> _executeDeleteAccount() async {
    if (_isDeletingAccount) return;
    setState(() => _isDeletingAccount = true);

    // Save context refs before async
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Show loading overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.error),
                const SizedBox(height: 20),
                Text('Deleting your account...', style: AppTextStyles.labelLarge),
                const SizedBox(height: 8),
                Text('This may take a moment', style: AppTextStyles.caption.copyWith(color: AppColors.textHint)),
              ],
            ),
          ),
        ),
      ),
    );

    final error = await _authService.deleteAccount();

    if (!mounted) return;

    // Dismiss loading overlay
    Navigator.of(context, rootNavigator: true).pop();
    setState(() => _isDeletingAccount = false);

    if (error == null) {
      // Success — navigate to login
      router.go('/');
    } else {
      messenger.showSnackBar(SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(error)),
          ],
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Widget _buildDeleteItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(Icons.circle, size: 6, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
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
        duration: const Duration(seconds: 3),
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

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        _showError('Could not open link');
      }
    } catch (_) {
      if (mounted) _showError('Could not open link');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check if user is a landlord
    final isLandlord = _accountType == 'landlord';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Settings', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Security Section
            _buildSectionHeader('Security'),
            const SizedBox(height: 12),
            _buildSettingsCard([
              _SettingsItem(
                icon: Icons.lock_outline,
                title: 'Change Password',
                subtitle: 'Send a password reset link to your email',
                onTap: _showChangePasswordDialog,
                trailing: _isSendingReset
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      )
                    : null,
              ),
              // Biometric toggle - only show if available
              if (_biometricAvailable || _isLoadingBiometric)
                _SettingsItem(
                  icon: _biometricTypeName == 'Face ID' 
                      ? Icons.face 
                      : Icons.fingerprint,
                  title: '$_biometricTypeName Login',
                  subtitle: _isLoadingBiometric 
                      ? 'Loading...'
                      : _biometricEnabled 
                          ? 'Enabled - sign in faster' 
                          : 'Disabled',
                  onTap: null,
                  showChevron: false,
                  trailing: _isLoadingBiometric
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        )
                      : Switch(
                          value: _biometricEnabled,
                          onChanged: _toggleBiometric,
                          activeThumbColor: AppColors.primary,
                        ),
              ),
            ]),

            // ── Appearance Section (Theme Selector) ──
            const SizedBox(height: 24),
            const ThemeSelector(),

            // Communication Section (Landlords only)
            if (isLandlord) ...[
              const SizedBox(height: 24),
              _buildSectionHeader('Communication'),
              const SizedBox(height: 12),
              _buildSettingsCard([
                _SettingsItem(
                  icon: Icons.phone,
                  title: 'Allow Phone Calls',
                  subtitle: _allowsCalls 
                      ? 'Tenants can call you directly' 
                      : 'Tenants can only message you',
                  onTap: null,
                  showChevron: false,
                  trailing: _isUpdatingCallPermission
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        )
                      : Switch(
                          value: _allowsCalls,
                          onChanged: _toggleCallPermission,
                          activeThumbColor: AppColors.primary,
                        ),
                ),
              ]),
              const SizedBox(height: 12),
              // Info banner about call permissions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.info.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.info.withAlpha(77)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 20,
                      color: AppColors.info,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Only verified tenants who have messaged you can see your contact information. You can disable calls at any time.',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textPrimary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // App Section
            _buildSectionHeader('App'),
            const SizedBox(height: 12),
            _buildSettingsCard([
              _SettingsItem(
                icon: Icons.info_outline,
                title: 'App Version',
                subtitle: AppInfo.version,
                onTap: null,
                showChevron: false,
              ),
              _SettingsItem(
                icon: Icons.description_outlined,
                title: 'Terms of Service',
                subtitle: 'Read our terms and conditions',
                onTap: () => _openUrl(_termsUrl),
              ),
              _SettingsItem(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy Policy',
                subtitle: 'How we handle your data',
                onTap: () => _openUrl(_privacyUrl),
              ),
            ]),

            const SizedBox(height: 24),

            // Danger Zone
            _buildSectionHeader('Danger Zone', isDestructive: true),
            const SizedBox(height: 12),
            _buildSettingsCard([
              _SettingsItem(
                icon: Icons.delete_outline,
                title: 'Delete Account',
                subtitle: 'Permanently remove your account and data',
                onTap: _showDeleteAccountDialog,
                isDestructive: true,
              ),
            ]),

            const SizedBox(height: 32),

            // Logout Button
            GestureDetector(
              onTap: _showLogoutConfirmation,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.error.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.error.withAlpha(77)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout, color: AppColors.error, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Logout',
                      style: AppTextStyles.labelLarge.copyWith(
                        color: AppColors.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Footer
            Center(
              child: Column(
                children: [
                  Text(
                    'ClearRent',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textHint,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Rent Without Regret',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {bool isDestructive = false}) {
    return Text(
      title,
      style: AppTextStyles.labelLarge.copyWith(
        color: isDestructive ? AppColors.error : AppColors.textSecondary,
      ),
    );
  }

  Widget _buildSettingsCard(List<Widget> items) {
    // Filter out any null items (in case biometric is not available)
    final filteredItems = items.whereType<Widget>().toList();
    
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: filteredItems.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          return Column(
            children: [
              item,
              if (index < filteredItems.length - 1)
                Divider(height: 1, indent: 56, color: AppColors.border),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _SettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showChevron;
  final bool isDestructive;

  const _SettingsItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.showChevron = true,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? AppColors.error : AppColors.textPrimary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isDestructive
                    ? AppColors.error.withAlpha(26)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.labelLarge.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.caption),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (showChevron && onTap != null)
              Icon(Icons.chevron_right, color: AppColors.textHint, size: 20),
          ],
        ),
      ),
    );
  }
}