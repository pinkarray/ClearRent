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

    debugPrint('🔑 Verifying OTP');

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
    // A pasted code, an autofill suggestion, or a keyboard that commits the
    // whole SMS at once all arrive as several characters in ONE box. Spread
    // them across the row instead of dropping all but the first.
    if (value.length > 1) {
      _applyWholeCode(value);
      return;
    }

    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }

    if (_otp.length == 6) {
      _verifyOtp();
    }
  }

  /// Pull the code out of the clipboard.
  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted) return;
    final digits = text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No code found on your clipboard'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    _applyWholeCode(digits);
  }

  /// Fill the boxes from a whole code, however it arrived.
  ///
  /// Non-digits are stripped, so a code copied with surrounding text from the
  /// SMS ("Your code is 123456") still works — that is exactly how someone
  /// copying from their messages tends to select it.
  void _applyWholeCode(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return;

    for (var i = 0; i < _controllers.length; i++) {
      _controllers[i].text = i < digits.length ? digits[i] : '';
    }

    final landing = digits.length >= _controllers.length
        ? _controllers.length - 1
        : digits.length;
    _focusNodes[landing.clamp(0, _controllers.length - 1)].requestFocus();

    setState(() {});
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
                        // NO maxLength. It capped input at one character, so a
                        // pasted or autofilled six-digit code was truncated to
                        // its first digit before onChanged ever saw it — which
                        // is why pasting silently did nothing and the code had
                        // to be memorised from the SMS and typed back in.
                        // _onOtpChanged spreads anything longer across the
                        // boxes and leaves one digit here.
                        autofillHints: const [AutofillHints.oneTimeCode],
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
                          // Bounds a paste to the length of the code; the
                          // handler then distributes it across the boxes.
                          LengthLimitingTextInputFormatter(6),
                        ],
                        onChanged: (value) => _onOtpChanged(index, value),
                      ),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 12),

              // One-tap paste. Auto-retrieval only fires once the app is
              // reviewed on Play (the SMS carries no app hash before then), so
              // until that lands this is the difference between copying the
              // code and memorising it.
              Align(
                alignment: Alignment.center,
                child: TextButton.icon(
                  onPressed: _pasteCode,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('Paste code'),
                ),
              ),

              const SizedBox(height: 20),

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