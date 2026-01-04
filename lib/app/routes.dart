import 'package:go_router/go_router.dart';
import '../features/auth/presentation/screens/onboarding_screen.dart';
import '../features/auth/presentation/screens/login_screen.dart';
import '../features/auth/presentation/screens/account_type_screen.dart';
import '../features/auth/presentation/screens/profile_setup_screen.dart';
import '../features/tenant/presentation/screens/tenant_home_screen.dart';
import '../features/landlord/presentation/screens/landlord_home_screen.dart';
import '../features/landlord/presentation/screens/add_property_screen.dart';
import '../features/landlord/presentation/screens/verification_center_screen.dart';
import '../features/landlord/presentation/screens/admin_verification_screen.dart';
import '../features/property/presentation/screens/property_detail_screen.dart';
import '../features/messaging/presentation/screens/chat_screen_real.dart';
import '../shared/models/property_model.dart';
import '../features/landlord/presentation/screens/recent_activities_screen.dart';
import '../shared/screens/edit_profile_screen.dart';
import '../shared/screens/settings_screen.dart';
import '../features/landlord/presentation/screens/bank_details_screen.dart';
import '../features/landlord/presentation/screens/earnings_screen.dart';
import '../shared/screens/help_support_screen.dart';
import '../shared/screens/about_screen.dart';
import '../features/tenant/presentation/screens/my_rentals_screen.dart';
import '../features/tenant/presentation/screens/payment_history_screen.dart';
import '../features/tenant/presentation/screens/documents_screen.dart';
import '../features/agent/presentation/screens/agent_home_screen.dart';
import '../features/landlord/presentation/screens/select_agent_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/onboarding',
  routes: [
    // ============ AUTH ROUTES ============
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/account-type',
      builder: (context, state) => const AccountTypeScreen(),
    ),
    GoRoute(
      path: '/profile-setup',
      builder: (context, state) {
        final accountType = state.extra as String? ?? 'tenant';
        return ProfileSetupScreen(accountType: accountType);
      },
    ),

    // ============ SHARED ROUTES ============
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/edit-profile',
      builder: (context, state) => const EditProfileScreen(),
    ),
    GoRoute(
      path: '/help-support',
      builder: (context, state) => const HelpSupportScreen(),
    ),
    GoRoute(
      path: '/about',
      builder: (context, state) => const AboutScreen(),
    ),
    // Shared verification route - works for all user types
    GoRoute(
      path: '/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),

    // ============ TENANT ROUTES ============
    GoRoute(
      path: '/tenant/home',
      builder: (context, state) => const TenantHomeScreen(),
    ),
    GoRoute(
      path: '/tenant/my-rentals',
      builder: (context, state) => const MyRentalsScreen(),
    ),
    GoRoute(
      path: '/tenant/payment-history',
      builder: (context, state) => const PaymentHistoryScreen(),
    ),
    GoRoute(
      path: '/tenant/documents',
      builder: (context, state) => const DocumentsScreen(),
    ),
    // Tenant verification (alias to shared route)
    GoRoute(
      path: '/tenant/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),

    // ============ LANDLORD ROUTES ============
    GoRoute(
      path: '/landlord/home',
      builder: (context, state) => const LandlordHomeScreen(),
    ),
    GoRoute(
      path: '/landlord/add-property',
      builder: (context, state) => const AddPropertyScreen(),
    ),
    GoRoute(
      path: '/landlord/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),
    GoRoute(
      path: '/landlord/bank-details',
      builder: (context, state) => const BankDetailsScreen(),
    ),
    GoRoute(
      path: '/landlord/earnings',
      builder: (context, state) => const EarningsScreen(),
    ),
    GoRoute(
      path: '/landlord/activities',
      builder: (context, state) => const RecentActivitiesScreen(),
    ),
    GoRoute(
      path: '/landlord/select-agent',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final propertyId = extra?['propertyId'] as String? ?? '';
        final propertyCity = extra?['propertyCity'] as String?;
        return SelectAgentScreen(
          propertyId: propertyId,
          propertyCity: propertyCity,
        );
      },
    ),

    // ============ AGENT ROUTES ============
    GoRoute(
      path: '/agent/home',
      builder: (context, state) => const AgentHomeScreen(),
    ),
    GoRoute(
      path: '/agent/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),
    GoRoute(
      path: '/agent/bank-details',
      builder: (context, state) => const BankDetailsScreen(),
    ),

    // ============ ADMIN ROUTES ============
    GoRoute(
      path: '/admin/verifications',
      builder: (context, state) => const AdminVerificationScreen(),
    ),

    // ============ PROPERTY & CHAT ============
    GoRoute(
      path: '/property-detail',
      builder: (context, state) {
        final property = state.extra as PropertyModel;
        return PropertyDetailScreen(property: property);
      },
    ),
        GoRoute(
      path: '/chat',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        final conversationId = extra['conversationId'] as String;
        final propertyTitle = extra['propertyTitle'] as String?;
        final propertyImage = extra['propertyImage'] as String?;
        return ChatScreen(
          conversationId: conversationId,
          propertyTitle: propertyTitle,
          propertyImage: propertyImage,
        );
      },
    ),
  ],
);