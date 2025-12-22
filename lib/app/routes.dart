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
import '../features/messaging/presentation/screens/chat_screen.dart';
import '../shared/models/property_model.dart';
import '../shared/models/conversation_model.dart';
import '../features/landlord/presentation/screens/recent_activities_screen.dart';
import '../shared/screens/edit_profile_screen.dart';
import '../shared/screens/settings_screen.dart';
import '../features/landlord/presentation/screens/bank_details_screen.dart';
import '../features/landlord/presentation/screens/earnings_screen.dart';
import '../shared/screens/help_support_screen.dart';
import '../shared/screens/about_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/onboarding',
  routes: [
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),

    // Auth
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
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

    // Tenant
    GoRoute(
      path: '/tenant/home',
      builder: (context, state) => const TenantHomeScreen(),
    ),

    // Landlord
    GoRoute(
      path: '/landlord/home',
      builder: (context, state) => const LandlordHomeScreen(),
    ),
    GoRoute(
      path: '/landlord/settings',
      builder: (context, state) => const SettingsScreen(),
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
      path: '/landlord/help-support',
      builder: (context, state) => const HelpSupportScreen(),
    ),
    GoRoute(
      path: '/landlord/about',
      builder: (context, state) => const AboutScreen(),
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
      path: '/admin/verifications',
      builder: (context, state) => const AdminVerificationScreen(),
    ),

    // Property Detail (standalone route)
    GoRoute(
      path: '/property-detail',
      builder: (context, state) {
        final property = state.extra as PropertyModel;
        return PropertyDetailScreen(property: property);
      },
    ),

    // Chat
    GoRoute(
      path: '/chat',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        final conversation = extra['conversation'] as ConversationModel;
        final currentUserId = extra['currentUserId'] as String;
        return ChatScreen(
          conversation: conversation,
          currentUserId: currentUserId,
        );
      },
    ),
    GoRoute(
      path: '/landlord/activities',
      builder: (context, state) => const RecentActivitiesScreen(),
    ),
    GoRoute(
      path: '/landlord/edit-profile',
      builder: (context, state) => const EditProfileScreen(),
    ),
  ],
);
