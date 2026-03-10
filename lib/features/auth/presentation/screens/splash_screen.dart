import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/biometric_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  final AuthService _authService = AuthService();
  final BiometricService _biometricService = BiometricService();

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    _animationController.forward();
    
    // Start auth check after a brief delay for splash effect
    Future.delayed(const Duration(milliseconds: 1500), _checkAuthAndNavigate);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _checkAuthAndNavigate() async {
    if (!mounted) return;

    try {
      // Check if user has completed onboarding before
      final hasCompletedOnboarding = await _biometricService.hasCompletedOnboarding();
      
      // Check if user is currently logged in
      final currentUser = FirebaseAuth.instance.currentUser;
      
      debugPrint('🔍 Auth check: hasOnboarding=$hasCompletedOnboarding, isLoggedIn=${currentUser != null}');

      if (currentUser != null) {
        // User is logged in - check if they have a complete profile
        final profile = await _authService.getUserProfile();
        
        if (profile != null && profile['profileCompleted'] == true) {
          // Check if biometric is enabled for quick login
          final biometricEnabled = await _biometricService.isBiometricEnabled();
          final biometricAvailable = await _biometricService.isBiometricAvailable();
          
          if (biometricEnabled && biometricAvailable) {
            // Try biometric authentication
            final authenticated = await _biometricService.authenticate(
              reason: 'Verify your identity to continue',
            );
            
            if (!authenticated) {
              // Biometric failed - go to login screen
              if (mounted) context.go('/login');
              return;
            }
          }
          
          // Navigate to appropriate home screen
          _navigateToHome(profile['accountType'] ?? 'tenant');
        } else if (profile != null && profile['accountType'] != null) {
          // Has account type but incomplete profile
          if (mounted) context.go('/profile-setup', extra: profile['accountType']);
        } else {
          // No profile at all
          if (mounted) context.go('/account-type');
        }
      } else {
        // User not logged in
        if (hasCompletedOnboarding) {
          // Returning user - skip onboarding, go to login
          if (mounted) context.go('/login');
        } else {
          // New user - show onboarding
          if (mounted) context.go('/onboarding');
        }
      }
    } catch (e) {
      debugPrint('❌ Auth check error: $e');
      // On error, check onboarding status and go to appropriate screen
      final hasOnboarding = await _biometricService.hasCompletedOnboarding();
      if (mounted) {
        context.go(hasOnboarding ? '/login' : '/onboarding');
      }
    }
  }

  void _navigateToHome(String accountType) {
    if (!mounted) return;
    
    final type = accountType.toLowerCase();
    debugPrint('🏠 Navigating to home for: $type');
    
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(51),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.home_rounded,
                        size: 50,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // App name
                    Text(
                      'ClearRent',
                      style: AppTextStyles.h1.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    
                    // Tagline
                    Text(
                      'Rent Without Regret',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: Colors.white.withAlpha(204),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    
                    const SizedBox(height: 48),
                    
                    // Loading indicator
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white.withAlpha(179),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}