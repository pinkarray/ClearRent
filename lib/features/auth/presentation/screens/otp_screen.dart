import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/biometric_service.dart';

class OtpScreen extends StatefulWidget {
  final String phoneNumber;
  final String? verificationId;

  const OtpScreen({
    super.key,
    required this.phoneNumber,
    this.verificationId,
  });

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final List<TextEditingController> _controllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  late final AuthService _authService;
  late final BiometricService _biometricService;

  bool _isLoading = false;
  bool _isResending = false;
  int _resendSeconds = 60;
  Timer? _timer;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _biometricService = BiometricService();
    _startResendTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _startResendTimer() {
    _resendSeconds = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendSeconds > 0) {
        setState(() => _resendSeconds--);
      } else {
        timer.cancel();
      }
    });
  }

  String get _otp => _controllers.map((c) => c.text).join();

  /// Format phone for display: +2349012345678 → +234 901 234 5678
  String get _displayPhone {
    final phone = widget.phoneNumber;
    if (phone.startsWith('+234') && phone.length >= 14) {
      final local = phone.substring(4); // remove +234
      if (local.length == 10) {
        return '+234 ${local.substring(0, 3)} ${local.substring(3, 6)} ${local.substring(6)}';
      }
    }
    return phone;
  }

  Future<void> _verifyOtp() async {
    if (_otp.length != 6) return;

    // Hide keyboard first
    FocusScope.of(context).unfocus();

    // Wait for keyboard to close
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    debugPrint('🔑 Verifying OTP: $_otp');

    final result = await _authService.verifyOtpAndSignIn(_otp);

    if (!mounted) return;

    if (result.success) {
      debugPrint('✅ OTP verified successfully. isNew=${result.isNewUser}');

      // Mark onboarding as completed
      await _biometricService.setOnboardingCompleted();

      if (!mounted) return;

      if (result.isNewUser) {
        // New user — go to account type selection
        setState(() => _isLoading = false);
        context.go('/account-type');
      } else {
        // Existing user — navigate to their home
        await _navigateAfterAuth();
      }
    } else {
      debugPrint('❌ OTP verification failed: ${result.error}');
      setState(() {
        _isLoading = false;
        _errorMessage = result.error;
      });
      // Clear the OTP fields so user can re-enter
      _clearOtpFields();
    }
  }

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

  void _clearOtpFields() {
    for (var controller in _controllers) {
      controller.clear();
    }
    // Focus first field
    if (_focusNodes.isNotEmpty) {
      _focusNodes[0].requestFocus();
    }
  }

  Future<void> _resendOtp() async {
    if (_resendSeconds > 0 || _isResending) return;

    setState(() {
      _isResending = true;
      _errorMessage = null;
    });

    debugPrint('📱 Resending OTP to ${widget.phoneNumber}');

    final result = await _authService.sendOtp(phoneNumber: widget.phoneNumber);

    if (!mounted) return;

    setState(() => _isResending = false);

    if (result.success) {
      _startResendTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Verification code resent'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } else {
      setState(() => _errorMessage = result.error);
    }
  }

  void _onOtpChanged(int index, String value) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }

    if (_otp.length == 6) {
      _verifyOtp();
    }
  }

  void _onKeyPressed(int index, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _isLoading ? null : () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),

              // Title
              Text(
                'Verify Phone Number',
                style: AppTextStyles.h2,
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  text: 'Enter the 6-digit code sent to ',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  children: [
                    TextSpan(
                      text: _displayPhone,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

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
                      Icon(Icons.error_outline, color: AppColors.error, size: 20),
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
                const SizedBox(height: 20),
              ],

              // OTP Input boxes
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(6, (index) {
                  return SizedBox(
                    width: 50,
                    height: 56,
                    child: KeyboardListener(
                      focusNode: FocusNode(),
                      onKeyEvent: (event) => _onKeyPressed(index, event),
                      child: TextField(
                        controller: _controllers[index],
                        focusNode: _focusNodes[index],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        maxLength: 1,
                        style: AppTextStyles.h3,
                        decoration: InputDecoration(
                          counterText: '',
                          contentPadding: EdgeInsets.zero,
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
                            borderSide: BorderSide(
                              color: AppColors.primary,
                              width: 2,
                            ),
                          ),
                          filled: true,
                          fillColor: AppColors.surface,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (value) => _onOtpChanged(index, value),
                      ),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 32),

              // Verify button
              AppButton(
                text: 'Verify Code',
                onPressed: _otp.length == 6 ? _verifyOtp : null,
                isLoading: _isLoading,
              ),

              const SizedBox(height: 24),

              // Resend OTP
              Center(
                child: Column(
                  children: [
                    Text(
                      "Didn't receive the code?",
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _resendOtp,
                      child: _isResending
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            )
                          : Text(
                              _resendSeconds > 0
                                  ? 'Resend in ${_resendSeconds}s'
                                  : 'Resend Code',
                              style: AppTextStyles.labelLarge.copyWith(
                                color: _resendSeconds > 0
                                    ? AppColors.textHint
                                    : AppColors.primary,
                              ),
                            ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Change number option
              Center(
                child: TextButton(
                  onPressed: _isLoading ? null : () => context.pop(),
                  child: Text(
                    'Change phone number',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}