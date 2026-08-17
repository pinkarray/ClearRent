import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../core/constants/strings.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/biometric_service.dart';
import 'package:flutter_svg/flutter_svg.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Email tab controllers
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFormKey = GlobalKey<FormState>();

  // Phone tab controllers
  final _phoneController = TextEditingController();
  final _phonePasswordController = TextEditingController();
  final _phoneFormKey = GlobalKey<FormState>();

  late final AuthService _authService;
  late final BiometricService _biometricService;

  bool _isLoading = false;
  bool _isSignUp = false;
  bool _obscurePassword = true;
  bool _obscurePhonePassword = true;
  String? _errorMessage;

  // Biometric state
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  String _biometricTypeName = 'Biometric';
  String? _lastUserEmail;
  bool _showBiometricOption = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      setState(() => _errorMessage = null);
    });
    _authService = AuthService();
    _biometricService = BiometricService();
    _initializeBiometric();
  }

  Future<void> _initializeBiometric() async {
    debugPrint('🔐 Initializing biometric...');

    _biometricAvailable = await _biometricService.isBiometricAvailable();
    _biometricEnabled = await _biometricService.isBiometricEnabled();
    _biometricTypeName = await _biometricService.getBiometricTypeName();
    _lastUserEmail = await _biometricService.getLastUserEmail();

    final hasCredentials = await _biometricService.hasStoredCredentials();

    debugPrint(
      '🔐 Biometric init: available=$_biometricAvailable, enabled=$_biometricEnabled, hasCredentials=$hasCredentials, lastEmail=$_lastUserEmail',
    );

    if (mounted) {
      setState(() {
        _showBiometricOption =
            _biometricAvailable &&
            _biometricEnabled &&
            hasCredentials &&
            _lastUserEmail != null;

        if (_lastUserEmail != null && _emailController.text.isEmpty) {
          _emailController.text = _lastUserEmail!;
        }
      });

      debugPrint('🔐 Show biometric option: $_showBiometricOption');

      if (_showBiometricOption) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted && !_isLoading) {
            _authenticateWithBiometric();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    _phonePasswordController.dispose();
    super.dispose();
  }

  // ============ VALIDATION ============

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) return 'Please enter your email';
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value)) return 'Please enter a valid email';
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Please enter your password';
    if (value.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  String? _validatePhone(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your phone number';
    }
    final cleaned = value.replaceAll(RegExp(r'[\s\-]'), '');
    if (!RegExp(r'^\d+$').hasMatch(cleaned)) {
      return 'Phone number should contain only digits';
    }
    // +234 already supplies the country code, so the leading 0 is dropped.
    if (cleaned.startsWith('0')) {
      return 'Enter your number without the leading 0 (e.g. 8012345678)';
    }
    if (cleaned.length != 10) {
      return 'Enter the 10-digit number after +234';
    }
    return null;
  }

  // ============ BIOMETRIC AUTH ============

  Future<void> _authenticateWithBiometric() async {
    debugPrint('🔐 Starting biometric authentication flow...');

    if (!_biometricAvailable || !_biometricEnabled) {
      debugPrint('❌ Biometric not available or not enabled');
      return;
    }

    final authenticated = await _biometricService.authenticate(
      reason: 'Use $_biometricTypeName to sign in to ClearRent',
    );

    if (!authenticated) {
      debugPrint('❌ Biometric authentication failed or cancelled');
      return;
    }

    debugPrint('✅ Biometric passed, getting stored credentials...');

    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final credentials = await _biometricService.getStoredCredentials();

      if (credentials == null) {
        debugPrint('❌ No stored credentials found');
        if (!mounted) return;
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Please sign in with your password'),
            backgroundColor: AppColors.warning,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return;
      }

      debugPrint('✅ Got credentials, signing in...');

      final result = await _authService.signIn(
        email: credentials['email']!,
        password: credentials['password']!,
      );

      if (!mounted) return;

      if (result.success) {
        debugPrint('✅ Sign in successful, navigating...');
        await _navigateAfterAuth();
      } else {
        debugPrint('❌ Sign in failed: ${result.error}');
        setState(() {
          _isLoading = false;
          _errorMessage =
              result.error ?? 'Sign in failed. Please try with password.';
        });
        await _biometricService.clearStoredCredentials();
        await _biometricService.setBiometricEnabled(false);
        if (!mounted) return;
        setState(() => _showBiometricOption = false);
      }
    } catch (e) {
      debugPrint('❌ Biometric sign in error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Sign in failed. Please try with password.';
        });
      }
    }
  }

  // ============ NAVIGATION ============

  Future<void> _navigateAfterAuth() async {
    try {
      final profile = await _authService.getUserProfile();

      if (!mounted) return;

      setState(() => _isLoading = false);

      if (profile == null || profile['profileCompleted'] != true) {
        if (profile != null && profile['accountType'] != null) {
          context.go('/profile-setup', extra: profile['accountType']);
        } else {
          context.go('/account-type');
        }
      } else {
        final accountType =
            (profile['accountType'] ?? 'tenant').toString().toLowerCase();
        debugPrint('🏠 Routing to home for: $accountType');

        switch (accountType) {
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
    } catch (e) {
      debugPrint('❌ Profile check error: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
      context.go('/account-type');
    }
  }

  // ============ EMAIL SUBMIT ============

  Future<void> _submitEmail() async {
    setState(() => _errorMessage = null);

    if (!_emailFormKey.currentState!.validate()) return;

    final focusScope = FocusScope.of(context);
    focusScope.unfocus();
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() => _isLoading = true);

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    // Email tab is sign-in only — sign-up goes through phone OTP
    final result = await _authService.signIn(email: email, password: password);

    if (!mounted) return;

    if (result.success) {
      await _biometricService.setLastUserEmail(email);
      await _biometricService.setOnboardingCompleted();

      // Handle biometric setup
      if (_biometricAvailable) {
        if (!_biometricEnabled) {
          final shouldEnable = await _showBiometricEnableDialog();
          if (shouldEnable) {
            await _biometricService.storeCredentials(email, password);
            await _biometricService.setBiometricEnabled(true);
            debugPrint('✅ Biometric enabled and credentials stored');
          }
        } else {
          await _biometricService.storeCredentials(email, password);
          debugPrint('✅ Updated stored credentials');
        }
      }

      if (!mounted) return;
      await _navigateAfterAuth();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = result.error;
      });
    }
  }

  // ============ PHONE SUBMIT ============

  Future<void> _submitPhone() async {
    setState(() => _errorMessage = null);

    if (!_phoneFormKey.currentState!.validate()) return;

    final focusScope = FocusScope.of(context);
    focusScope.unfocus();
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() => _isLoading = true);

    // Format phone number with country code
    String phone = _phoneController.text.trim().replaceAll(
      RegExp(r'[\s\-]'),
      '',
    );
    if (phone.startsWith('0')) phone = phone.substring(1);
    final fullPhone = '+234$phone';

    if (_isSignUp) {
      if (kDebugMode) debugPrint('📱 Sending OTP to: $fullPhone');
      final result = await _authService.sendOtp(phoneNumber: fullPhone);

      if (!mounted) return;

      if (result.success) {
        if (result.autoVerified && result.credential != null) {
          debugPrint('✅ Auto-verified, signing in...');
          final authResult = await _authService.signInWithCredential(
            result.credential!,
          );
          if (!mounted) return;
          if (authResult.success) {
            await _biometricService.setOnboardingCompleted();
            if (!mounted) return;
            if (authResult.isNewUser) {
              setState(() => _isLoading = false);
              context.go('/account-type');
            } else {
              await _navigateAfterAuth();
            }
          } else {
            setState(() {
              _isLoading = false;
              _errorMessage = authResult.error;
            });
          }
        } else {
          // Code sent — navigate to OTP screen
          setState(() => _isLoading = false);
          if (!mounted) return;
          context.push(
            '/otp',
            extra: {
              'phoneNumber': fullPhone,
              'verificationId': result.verificationId,
            },
          );
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = result.error;
        });
      }
    } else {
      if (kDebugMode) debugPrint('📱 Signing in with phone: $fullPhone');
      final password = _phonePasswordController.text;
      final result = await _authService.signInWithPhone(
        phoneNumber: fullPhone,
        password: password,
      );

      if (!mounted) return;

      if (result.success) {
        await _biometricService.setOnboardingCompleted();

        // Store credentials for biometric (use the looked-up email)
        final profile = await _authService.getUserProfile();
        final email = profile?['email'] as String?;
        if (email != null && email.isNotEmpty && _biometricAvailable) {
          await _biometricService.setLastUserEmail(email);
          if (_biometricEnabled) {
            await _biometricService.storeCredentials(email, password);
          } else {
            final shouldEnable = await _showBiometricEnableDialog();
            if (shouldEnable) {
              await _biometricService.storeCredentials(email, password);
              await _biometricService.setBiometricEnabled(true);
            }
          }
        }

        if (!mounted) return;
        await _navigateAfterAuth();
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = result.error;
        });
      }
    }
  }

  // ============ FORGOT PASSWORD ============

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() => _errorMessage = 'Please enter your email first');
      return;
    }

    setState(() => _isLoading = true);

    bool success = false;
    try {
      success = await _authService.sendPasswordResetEmail(email);
    } catch (e) {
      debugPrint('❌ Forgot password error: $e');
    }

    setState(() => _isLoading = false);

    if (!mounted) return;

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Password reset email sent to $email'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } else {
      setState(
        () =>
            _errorMessage =
                'Failed to send reset email. Please check your email address.',
      );
    }
  }

  /// Phone-tab recovery: send a one-time code instead of a password.
  ///
  /// "Forgot Password?" on the email tab sends a reset EMAIL, which is no use
  /// to someone who signed up by phone and may have no email on file at all —
  /// and sign-up goes through phone OTP, so that is a real slice of users.
  /// Web already treats OTP as the recovery path; this gives the app the same
  /// route instead of a dead end.
  Future<void> _forgotPhonePassword() async {
    setState(() => _errorMessage = null);
    final raw = _phoneController.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorMessage = 'Please enter your phone number first');
      return;
    }
    String phone = raw.replaceAll(RegExp(r'[\s\-]'), '');
    if (phone.startsWith('0')) phone = phone.substring(1);
    final fullPhone = '+234$phone';

    setState(() => _isLoading = true);
    final result = await _authService.sendOtp(phoneNumber: fullPhone);
    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _isLoading = false;
        _errorMessage = result.error ?? 'Could not send a code. Try again.';
      });
      return;
    }

    // Auto-verified (some Android devices retrieve the SMS themselves) — sign
    // straight in rather than showing a code screen with nothing to type.
    if (result.autoVerified && result.credential != null) {
      final authResult =
          await _authService.signInWithCredential(result.credential!);
      if (!mounted) return;
      if (authResult.success) {
        await _biometricService.setOnboardingCompleted();
        if (!mounted) return;
        await _navigateAfterAuth();
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = authResult.error;
      });
      return;
    }

    setState(() => _isLoading = false);
    if (!mounted) return;
    context.push('/otp', extra: {
      'phoneNumber': fullPhone,
      'verificationId': result.verificationId,
    });
  }

  // ============ BIOMETRIC DIALOG ============

  Future<bool> _showBiometricEnableDialog() async {
    final biometricName = await _biometricService.getBiometricTypeName();

    if (!mounted) return false;

    final enable = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            title: Text('Enable $biometricName Login?'),
            content: Text(
              'Would you like to use $biometricName for faster sign-in next time?',
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  'Not Now',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  'Enable',
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
            ],
          ),
    );

    return enable ?? false;
  }

  // ============ BUILD ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

              // Logo / App name
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: SvgPicture.asset(
                          'assets/images/branding/clearrent_mark_white.svg',
                          height: 40,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AppStrings.appName,
                      style: AppTextStyles.h2.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppStrings.tagline,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 36),

              // Welcome text
              Text(
                _isSignUp ? 'Create Account' : 'Welcome Back',
                style: AppTextStyles.h3,
              ),
              const SizedBox(height: 8),
              Text(
                _isSignUp
                    ? 'Sign up with your phone number to get started'
                    : 'Sign in to continue to ClearRent',
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),

              const SizedBox(height: 24),

              // Error message
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.error.withAlpha(77)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: AppColors.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Biometric quick login (only in sign-in mode)
              if (_showBiometricOption && !_isSignUp) ...[
                GestureDetector(
                  onTap: _isLoading ? null : _authenticateWithBiometric,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(13),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.primary.withAlpha(51),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _biometricTypeName == 'Face ID'
                              ? Icons.face
                              : Icons.fingerprint,
                          color: AppColors.primary,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Sign in with $_biometricTypeName',
                              style: AppTextStyles.labelLarge.copyWith(
                                color: AppColors.primary,
                              ),
                            ),
                            Text(
                              _lastUserEmail ?? '',
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'or use password',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textHint,
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 20),
              ],

              // Tab bar — only shown in sign-in mode
              // In sign-up mode, phone is the only option (OTP verification)
              if (!_isSignUp) ...[
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: TabBar(
                    controller: _tabController,
                    indicator: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.shadowLight,
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: Colors.transparent,
                    labelColor: AppColors.textPrimary,
                    unselectedLabelColor: AppColors.textSecondary,
                    labelStyle: AppTextStyles.labelLarge,
                    unselectedLabelStyle: AppTextStyles.labelMedium,
                    tabs: const [
                      Tab(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.email_outlined, size: 18),
                            SizedBox(width: 6),
                            Text('Email'),
                          ],
                        ),
                      ),
                      Tab(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.phone_outlined, size: 18),
                            SizedBox(width: 6),
                            Text('Phone'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // Tab content
              if (_isSignUp)
                _buildSignUpPhoneTab()
              else
                AnimatedBuilder(
                  animation: _tabController,
                  builder: (context, _) {
                    if (_tabController.index == 0) {
                      return _buildEmailTab();
                    } else {
                      return _buildPhoneTab();
                    }
                  },
                ),

              const SizedBox(height: 24),

              // Toggle sign up / sign in
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _isSignUp
                          ? 'Already have an account? '
                          : "Don't have an account? ",
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    GestureDetector(
                      onTap:
                          () => setState(() {
                            _isSignUp = !_isSignUp;
                            _errorMessage = null;
                          }),
                      child: Text(
                        _isSignUp ? 'Sign In' : 'Sign Up',
                        style: AppTextStyles.labelLarge.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Terms text
              Center(
                child: Text.rich(
                  TextSpan(
                    text: 'By continuing, you agree to our ',
                    style: AppTextStyles.caption,
                    children: [
                      TextSpan(
                        text: 'Terms of Service',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const TextSpan(text: ' and '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============ EMAIL TAB (Sign In only) ============

  Widget _buildEmailTab() {
    return Form(
      key: _emailFormKey,
      child: Column(
        children: [
          AppTextField(
            label: 'Email Address',
            hint: 'you@example.com',
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            // Must match what signup saved under, or the manager holds a
            // credential it never offers back here.
            autofillHints: const [AutofillHints.username],
            validator: _validateEmail,
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.email_outlined, color: AppColors.textHint),
            ),
          ),
          const SizedBox(height: 16),

          AppTextField(
            label: 'Password',
            hint: 'Enter your password',
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            validator: _validatePassword,
            onSubmitted: (_) => _submitEmail(),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.lock_outlined, color: AppColors.textHint),
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
                color: AppColors.textHint,
              ),
              onPressed:
                  () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),

          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _isLoading ? null : _forgotPassword,
              child: Text(
                'Forgot Password?',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          AppButton(
            text: 'Sign In',
            onPressed: _submitEmail,
            isLoading: _isLoading,
          ),
        ],
      ),
    );
  }

  // ============ PHONE TAB (Sign In with password) ============

  Widget _buildPhoneTab() {
    return Form(
      key: _phoneFormKey,
      child: Column(
        children: [
          AppTextField(
            label: 'Phone Number',
            hint: '8012345678',
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: _validatePhone,
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🇳🇬', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 6),
                  Text(
                    '+234',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(width: 1, height: 24, color: AppColors.border),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          AppTextField(
            label: 'Password',
            hint: 'Enter your password',
            controller: _phonePasswordController,
            obscureText: _obscurePhonePassword,
            textInputAction: TextInputAction.done,
            validator: _validatePassword,
            onSubmitted: (_) => _submitPhone(),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.lock_outlined, color: AppColors.textHint),
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePhonePassword ? Icons.visibility_off : Icons.visibility,
                color: AppColors.textHint,
              ),
              onPressed:
                  () => setState(
                    () => _obscurePhonePassword = !_obscurePhonePassword,
                  ),
            ),
          ),

          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _isLoading ? null : _forgotPhonePassword,
              child: Text(
                'Forgot Password?',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          AppButton(
            text: 'Sign In',
            onPressed: _submitPhone,
            isLoading: _isLoading,
          ),
        ],
      ),
    );
  }

  // ============ SIGN UP PHONE TAB (OTP verification) ============

  Widget _buildSignUpPhoneTab() {
    return Form(
      key: _phoneFormKey,
      child: Column(
        children: [
          AppTextField(
            label: 'Phone Number',
            hint: '8012345678',
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: _validatePhone,
            onSubmitted: (_) => _submitPhone(),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🇳🇬', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 6),
                  Text(
                    '+234',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(width: 1, height: 24, color: AppColors.border),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: AppColors.info, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'We\'ll send a verification code to confirm your number. You\'ll set up your email and password next.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.info,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          AppButton(
            text: 'Send Verification Code',
            onPressed: _submitPhone,
            isLoading: _isLoading,
          ),
        ],
      ),
    );
  }
}
