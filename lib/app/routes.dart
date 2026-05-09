import 'package:go_router/go_router.dart';
import '../features/auth/presentation/screens/splash_screen.dart';
import '../features/auth/presentation/screens/onboarding_screen.dart';
import '../features/auth/presentation/screens/login_screen.dart';
import '../features/auth/presentation/screens/account_type_screen.dart';
import '../features/auth/presentation/screens/profile_setup_screen.dart';
import '../features/tenant/presentation/screens/tenant_home_screen.dart';
import '../features/auth/presentation/screens/otp_screen.dart';
import '../features/tenant/presentation/screens/tenant_inspections_screen.dart';
import '../features/landlord/presentation/screens/landlord_home_screen.dart';
import '../features/landlord/presentation/screens/add_property_screen.dart';
import '../features/landlord/presentation/screens/verification_center_screen.dart';
import '../features/landlord/presentation/screens/admin_verification_screen.dart';
import '../features/notifications/presentation/screens/notifications_screen.dart';
import '../features/property/presentation/screens/property_detail_screen.dart';
import '../features/chat/presentation/screens/chat_screen.dart';
import '../shared/models/property_model.dart';
import '../shared/models/rental_interest_model.dart';
import '../shared/models/inspection_request_model.dart';
import '../shared/models/active_rental_model.dart';
import '../features/landlord/presentation/screens/recent_activities_screen.dart';
import '../shared/screens/edit_profile_screen.dart';
import '../features/landlord/presentation/screens/edit_property_screen.dart';
import '../shared/screens/settings_screen.dart';
import '../features/landlord/presentation/screens/bank_details_screen.dart';
import '../features/landlord/presentation/screens/earnings_screen.dart';
import '../../features/landlord/presentation/screens/landlord_rentals_screen.dart';
import '../shared/screens/help_support_screen.dart';
import '../shared/screens/about_screen.dart';
import '../features/tenant/presentation/screens/rental_payment_screen.dart';
import '../features/tenant/presentation/screens/my_rentals_screen.dart';
// payment_history_screen.dart is deprecated — route redirects to /tenant/documents
import '../features/tenant/presentation/screens/documents_screen.dart';
import '../features/tenant/presentation/screens/inspection_payment_screen.dart';
import '../features/tenant/presentation/screens/lease_details_screen.dart';
import '../features/tenant/presentation/screens/report_issue_screen.dart';
import '../features/tenant/presentation/screens/tenant_issue_history_screen.dart';
import '../features/agent/presentation/screens/agent_home_screen.dart';
import '../features/agent/presentation/screens/agent_availability_screen.dart';
import '../features/agent/presentation/screens/agent_service_areas_screen.dart';
import '../features/agent/presentation/screens/agent_property_detail_screen.dart';
import '../features/agent/presentation/screens/agent_inspections_screen.dart';
import '../features/landlord/presentation/screens/landlord_inspections_screen.dart';
import '../features/landlord/presentation/screens/landlord_issues_screen.dart';
import '../features/landlord/presentation/screens/landlord_agreements_screen.dart';
import '../features/landlord/presentation/screens/property_health_screen.dart';
import '../features/landlord/presentation/screens/select_agent_screen.dart';
import '../core/utils/inspection_pricing.dart';
import '../features/admin/presentation/screens/admin_payment_verification_screen.dart';
import '../features/admin/presentation/screens/admin_rental_verification_screen.dart';
import '../features/admin/presentation/screens/admin_property_docs_screen.dart';
import '../features/admin/presentation/screens/admin_users_screen.dart';
import '../features/tenant/presentation/screens/tenancy_requests_screen.dart';
import '../features/admin/presentation/screens/admin_agent_payouts_screen.dart';
import '../features/admin/presentation/screens/admin_rent_payouts_screen.dart';
import '../services/route_observer_service.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  observers: [RouteObserverService.instance],
  routes: [
    // ============ SPLASH / AUTH CHECK ============
    GoRoute(
      path: '/',
      builder: (context, state) => const SplashScreen(),
    ),
    
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
    GoRoute(
      path: '/otp',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        final phoneNumber = extra['phoneNumber'] as String? ?? '';
        final verificationId = extra['verificationId'] as String?;
        return OtpScreen(
          phoneNumber: phoneNumber,
          verificationId: verificationId,
        );
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
    GoRoute(
      path: '/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),
    GoRoute(
      path: '/notifications',
      builder: (context, state) => const NotificationsScreen(),
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
      redirect: (context, state) => '/tenant/documents',
    ),
    GoRoute(
      path: '/tenant/documents',
      builder: (context, state) => const DocumentsScreen(),
    ),
    GoRoute(
      path: '/tenant/lease-details',
      builder: (context, state) {
        final rental = state.extra as ActiveRental;
        return LeaseDetailsScreen(rental: rental);
      },
    ),
    GoRoute(
      path: '/tenant/report-issue',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return ReportIssueScreen(
          propertyId: extra['propertyId'] as String,
          propertyTitle: extra['propertyTitle'] as String,
          tenantId: extra['tenantId'] as String,
          tenantName: extra['tenantName'] as String,
          landlordId: extra['landlordId'] as String,
          landlordName: extra['landlordName'] as String,
        );
      },
    ),
    GoRoute(
      path: '/tenant/activities',
      builder: (context, state) => const RecentActivitiesScreen(),
    ),
    GoRoute(
      path: '/tenant/issue-history',
      builder: (context, state) => const TenantIssueHistoryScreen(),
    ),
    GoRoute(
      path: '/tenant/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),
    GoRoute(
      path: '/tenant/inspections',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return TenantInspectionsScreen(
          initialTab: extra?['initialTab'] as int?,
        );
      },
    ),
    GoRoute(
      path: '/tenant/tenancy-requests',
      builder: (context, state) => const TenancyRequestsScreen(),
    ),
    GoRoute(
      path: '/tenant/inspection-payment',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return InspectionPaymentScreen(
          property: extra['property'] as PropertyModel,
          selectedDate: extra['selectedDate'] as DateTime,
          selectedTimeSlot: extra['selectedTimeSlot'] as String,
          notes: extra['notes'] as String?,
          feeBreakdown: extra['feeBreakdown'] as InspectionFeeBreakdown?,
        );
      },
    ),
    GoRoute(
      path: '/tenant/rental-payment',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return RentalPaymentScreen(
          rentalInterest: extra['rentalInterest'] as RentalInterest,
          inspectionRequest: extra['inspectionRequest'] as InspectionRequest,
        );
      },
    ),
    GoRoute(
      path: '/tenant/bank-details',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return BankDetailsScreen(
          isOnboarding: extra?['isOnboarding'] as bool? ?? false,
          accountType: extra?['accountType'] as String?,
        );
      },
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
      path: '/landlord/edit-property',
      builder: (context, state) {
        final property = state.extra as PropertyModel;
        return EditPropertyScreen(property: property);
      },
    ),
    GoRoute(
      path: '/landlord/verification',
      builder: (context, state) => const VerificationCenterScreen(),
    ),
    GoRoute(
      path: '/landlord/bank-details',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return BankDetailsScreen(
          isOnboarding: extra?['isOnboarding'] as bool? ?? false,
          accountType: extra?['accountType'] as String?,
        );
      },
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
    GoRoute(
      path: '/landlord/rentals',
      builder: (context, state) => const LandlordRentalsScreen(),
    ),
    GoRoute(
      path: '/landlord/inspections',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return LandlordInspectionsScreen(
          initialTab: extra?['initialTab'] as int?,
        );
      },
    ),
    GoRoute(
      path: '/landlord/issues',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return LandlordIssuesScreen(
          propertyId: extra?['propertyId'] as String?,
          category: extra?['category'] as String?,
          initialTab: extra?['initialTab'] as int? ?? 0,
          propertyTitle: extra?['propertyTitle'] as String?,
        );
      },
    ),
    GoRoute(
      path: '/landlord/property-health',
      builder: (context, state) {
        final property = state.extra as PropertyModel;
        return PropertyHealthScreen(property: property);
      },
    ),
    GoRoute(
      path: '/landlord/agreements',
      builder: (context, state) => const LandlordAgreementsScreen(),
    ),
    GoRoute(
      path: '/landlord/documents',
      builder: (context, state) => const DocumentsScreen(),
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
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return BankDetailsScreen(
          isOnboarding: extra?['isOnboarding'] as bool? ?? false,
          accountType: extra?['accountType'] as String?,
        );
      },
    ),
    GoRoute(
      path: '/agent/availability',
      builder: (context, state) => const AgentAvailabilityScreen(),
    ),
    GoRoute(
      path: '/agent/service-areas',
      builder: (context, state) => const AgentServiceAreasScreen(),
    ),
    GoRoute(
      path: '/agent/property/:id',
      builder: (context, state) {
        final propertyId = state.pathParameters['id'] ?? '';
        return AgentPropertyDetailScreen(propertyId: propertyId);
      },
    ),
    GoRoute(
      path: '/agent/inspections',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return AgentInspectionsScreen(
          initialTab: extra?['initialTab'] as int?,
        );
      },
    ),
    GoRoute(
      path: '/agent/activities',
      builder: (context, state) => const RecentActivitiesScreen(),
    ),
    GoRoute(
      path: '/agent/documents',
      builder: (context, state) => const DocumentsScreen(),
    ),

    // ============ ADMIN ROUTES ============
    GoRoute(
      path: '/admin/verifications',
      builder: (context, state) => const AdminVerificationScreen(),
    ),
    GoRoute(
      path: '/admin/payment-verification',
      builder: (context, state) => const AdminPaymentVerificationScreen(),
    ),
    GoRoute(
      path: '/admin/rental-verification',
      builder: (context, state) => const AdminRentalVerificationScreen(),
    ),
    GoRoute(
      path: '/admin/agent-payouts',
      builder: (context, state) => const AdminAgentPayoutsScreen(),
    ),
    GoRoute(
      path: '/admin/rent-payouts',
      builder: (context, state) => const AdminRentPayoutsScreen(),
    ),
    GoRoute(
      path: '/admin/property-docs',
      builder: (context, state) => const AdminPropertyDocsScreen(),
    ),
    GoRoute(
      path: '/admin/users',
      builder: (context, state) => const AdminUsersScreen(),
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
        final initialDraft = extra['initialDraft'] as String?;
        return ChatScreen(
          conversationId: conversationId,
          propertyTitle: propertyTitle,
          propertyImage: propertyImage,
          initialDraft: initialDraft,
        );
      },
    ),
  ],
);