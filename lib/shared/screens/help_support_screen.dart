import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key});

  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  // Contact details
  static const String _phoneNumber = '09060237734';
  static const String _email = 'info@verealtytech.com';
  static const String _whatsappNumber = '2349060237734';

  // Track expanded FAQ
  int? _expandedIndex;

  // FAQ data
  final List<FAQItem> _faqs = [
    // Getting Started
    FAQItem(
      category: 'Getting Started',
      question: 'How do I list my property?',
      answer: 'Tap the "Add Property" button on your dashboard or properties tab. You\'ll be guided through 5 simple steps:\n\n1. Upload photos of your property\n2. Enter the location details\n3. Add property details (type, bedrooms, amenities)\n4. Set your price\n5. Review and publish\n\nYour listing will be live immediately after publishing.',
    ),
    FAQItem(
      category: 'Getting Started',
      question: 'How do I get verified?',
      answer: 'Verification helps build trust with tenants. To get verified:\n\n1. Go to Profile → Verification\n2. Upload a clear photo of your valid government ID (NIN, Driver\'s License, Voter\'s Card, or International Passport)\n3. Take a selfie for identity confirmation\n4. Submit for review\n\nVerification is usually completed within 24-48 hours. Verified landlords get 3x more inquiries!',
    ),
    FAQItem(
      category: 'Getting Started',
      question: 'Is ClearRent free to use?',
      answer: 'Listing your property on ClearRent is completely FREE. We only charge a small service fee when rent is successfully paid through our platform. This means you only pay when you earn!',
    ),
    FAQItem(
      category: 'Getting Started',
      question: 'How do I find properties as a tenant?',
      answer: 'Finding your perfect home is easy:\n\n1. Use the search bar to enter your preferred location\n2. Filter by property type (flat, self-contain, etc.)\n3. Set your budget range\n4. Browse listings and save your favorites\n5. Message landlords directly through the app\n\nAll landlords on ClearRent are verified for your safety.',
    ),

    // Managing Properties
    FAQItem(
      category: 'Managing Properties',
      question: 'How do I edit my property listing?',
      answer: 'To edit a listing:\n\n1. Go to the Properties tab\n2. Find the property you want to edit\n3. Tap the three dots (⋮) menu\n4. Select "Edit"\n\nYou can update photos, price, description, amenities, and other details at any time.',
    ),
    FAQItem(
      category: 'Managing Properties',
      question: 'How do I mark a property as occupied?',
      answer: 'When your property is rented out:\n\n1. Go to the Properties tab\n2. Find the property\n3. Tap the three dots (⋮) menu\n4. Select "Mark Occupied"\n\nThis hides the property from search results while keeping your listing data saved. You can mark it available again anytime.',
    ),
    FAQItem(
      category: 'Managing Properties',
      question: 'Can I delete a property listing?',
      answer: 'Yes. Go to Properties → tap the three dots menu → select "Delete". Note that this action is permanent and cannot be undone. If you just want to temporarily hide the listing, use "Mark Occupied" instead.',
    ),
    FAQItem(
      category: 'Managing Properties',
      question: 'How many properties can I list?',
      answer: 'There\'s no limit! You can list as many properties as you own or manage. Each property will have its own listing with separate photos, details, and inquiries.',
    ),

    // Payments & Earnings
    FAQItem(
      category: 'Payments & Earnings',
      question: 'How do I receive rent payments?',
      answer: 'When a tenant pays rent through ClearRent:\n\n1. The payment is processed securely via Paystack\n2. Funds are held briefly for verification\n3. Money is transferred to your registered bank account\n4. You\'ll receive a notification when payment is complete\n\nMake sure your bank details are up to date in Profile → Bank Details.',
    ),
    FAQItem(
      category: 'Payments & Earnings',
      question: 'How do I pay rent as a tenant?',
      answer: 'Paying rent is simple and secure:\n\n1. Go to your rental details\n2. Tap "Pay Rent"\n3. Review the payment breakdown\n4. Choose your payment method (card, bank transfer, USSD)\n5. Complete the payment\n\nYou\'ll receive a receipt and the landlord will be notified automatically.',
    ),
    FAQItem(
      category: 'Payments & Earnings',
      question: 'When will I receive my payment?',
      answer: 'After a tenant makes a payment:\n\n• Pending: Payment received, being processed (1-2 business days)\n• Completed: Money has been sent to your bank account\n\nBank transfers typically reflect within 24 hours after status changes to "Completed".',
    ),
    FAQItem(
      category: 'Payments & Earnings',
      question: 'What fees does ClearRent charge?',
      answer: 'ClearRent charges a small service fee only when rent is paid through our platform. Listing properties is completely free. The exact fee percentage is shown in the payment breakdown before any transaction is confirmed.',
    ),

    // Communication
    FAQItem(
      category: 'Communication',
      question: 'How do I contact a landlord/tenant?',
      answer: 'You can send messages directly through the app:\n\n1. Open the property listing or rental details\n2. Tap "Message" or the chat icon\n3. Type your message and send\n\nYou\'ll receive notifications for new messages. All conversations are saved in the Messages tab.',
    ),
    FAQItem(
      category: 'Communication',
      question: 'Is my phone number shared?',
      answer: 'Your phone number is only shared after you choose to share it in a conversation. Initial communication happens through the app\'s messaging system for your privacy and security.',
    ),
    FAQItem(
      category: 'Communication',
      question: 'How do I know if someone viewed my property?',
      answer: 'Check your Dashboard for recent activity. You\'ll see:\n\n• Property views: When tenants view your listing\n• Inquiries: When tenants send you a message\n\nYou can also see total views and inquiries in your stats.',
    ),

    // Account & Security
    FAQItem(
      category: 'Account & Security',
      question: 'How do I change my password?',
      answer: 'Go to Profile → Settings (gear icon) → Change Password. We\'ll send a password reset link to your registered email address. Click the link to set a new password.',
    ),
    FAQItem(
      category: 'Account & Security',
      question: 'How do I update my profile information?',
      // Kept honest against edit_profile_screen: name, email AND phone are all
      // read-only there. This entry used to say you could change your phone
      // number in Edit Profile, which sent people to a locked field.
      answer: 'Go to Profile → Edit Profile. You can change your profile photo (verified users only), and tenants can update their work area and preferred areas.\n\nYour name, email and phone number are tied to your account and its verification, so they cannot be edited there. Email info@verealtytech.com and our team will update them for you.',
    ),
    FAQItem(
      category: 'Account & Security',
      question: 'I have lost my phone number - can I still sign in?',
      answer: 'Yes. Your number is only one of two ways in.\n\nOn the sign-in screen, switch to the Email tab and sign in with the email address and password you registered with. If you have forgotten the password, tap Forgot Password on that tab and we will email you a reset link.\n\nThen email info@verealtytech.com so we can put your new number on the account. This matters even after you are back in: your number is what landlords, tenants and agents use to reach you, and it is shown on your listings.',
    ),
    FAQItem(
      category: 'Account & Security',
      question: 'How do I delete my account?',
      answer: 'To delete your account, go to Profile → Settings → Delete Account. You\'ll need to contact our support team to confirm the deletion. Please note that this action is permanent and will remove all your data including property listings, rental history, and transaction records.',
    ),
    FAQItem(
      category: 'Account & Security',
      question: 'Is my information secure?',
      answer: 'Yes! ClearRent takes security seriously:\n\n• All data is encrypted in transit and at rest\n• Payments are processed securely via Paystack\n• We never share your personal information with third parties\n• Bank details are only used for payouts',
    ),
  ];

  // Group FAQs by category
  Map<String, List<FAQItem>> get _groupedFaqs {
    final Map<String, List<FAQItem>> grouped = {};
    for (final faq in _faqs) {
      if (!grouped.containsKey(faq.category)) {
        grouped[faq.category] = [];
      }
      grouped[faq.category]!.add(faq);
    }
    return grouped;
  }

  Future<void> _makePhoneCall() async {
    final Uri uri = Uri(scheme: 'tel', path: _phoneNumber);
    try {
      final bool launched = await launchUrl(uri);
      if (!launched && mounted) {
        _showError('Could not open phone app');
      }
    } catch (e) {
      if (mounted) {
        _showError('Could not open phone app');
      }
    }
  }

  Future<void> _sendEmail() async {
    final Uri uri = Uri(
      scheme: 'mailto',
      path: _email,
      query: 'subject=ClearRent Support Request',
    );
    try {
      final bool launched = await launchUrl(uri);
      if (!launched && mounted) {
        _showError('Could not open email app');
      }
    } catch (e) {
      if (mounted) {
        _showError('Could not open email app');
      }
    }
  }

  Future<void> _openWhatsApp() async {
    final Uri uri = Uri.parse('https://wa.me/$_whatsappNumber?text=Hello, I need help with ClearRent');
    try {
      final bool launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        _showError('Could not open WhatsApp');
      }
    } catch (e) {
      if (mounted) {
        _showError('Could not open WhatsApp');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
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
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text('Help & Support', style: AppTextStyles.h4),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: AppColors.primaryLight.withAlpha(26),
              child: Column(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(26),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.support_agent,
                      color: AppColors.primary,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'How can we help you?',
                    style: AppTextStyles.h4,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Browse FAQs or contact us directly',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),

            // FAQs
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Frequently Asked Questions',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // FAQ categories
                  ..._groupedFaqs.entries.map((entry) {
                    return _buildFAQCategory(entry.key, entry.value);
                  }),
                ],
              ),
            ),

            // Contact section
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  const SizedBox(height: 16),
                  Text(
                    'Still need help?',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Our support team is here for you',
                    style: AppTextStyles.caption,
                  ),
                  const SizedBox(height: 16),

                  // Contact options
                  Row(
                    children: [
                      Expanded(
                        child: _buildContactOption(
                          icon: Icons.phone_outlined,
                          label: 'Call',
                          color: AppColors.success,
                          onTap: _makePhoneCall,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildContactOption(
                          icon: Icons.email_outlined,
                          label: 'Email',
                          color: AppColors.info,
                          onTap: _sendEmail,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildContactOption(
                          icon: Icons.chat_outlined,
                          label: 'WhatsApp',
                          color: const Color(0xFF25D366),
                          onTap: _openWhatsApp,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Support hours
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.access_time, color: AppColors.textHint, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Support Hours',
                                style: AppTextStyles.labelMedium,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Monday - Friday: 9AM - 6PM\nSaturday: 10AM - 4PM',
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

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildFAQCategory(String category, List<FAQItem> faqs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 8),
          child: Text(
            category,
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.primary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: faqs.asMap().entries.map((entry) {
              final index = _faqs.indexOf(entry.value);
              final isLast = entry.key == faqs.length - 1;
              return _buildFAQItem(entry.value, index, isLast);
            }).toList(),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildFAQItem(FAQItem faq, int index, bool isLast) {
    final isExpanded = _expandedIndex == index;

    return Column(
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              _expandedIndex = isExpanded ? null : index;
            });
          },
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    faq.question,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isExpanded ? AppColors.primary : AppColors.textPrimary,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    color: isExpanded ? AppColors.primary : AppColors.textHint,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              faq.answer,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
          crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
        if (!isLast) Divider(height: 1, color: AppColors.border, indent: 16, endIndent: 16),
      ],
    );
  }

  Widget _buildContactOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withAlpha(26),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(77)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(
              label,
              style: AppTextStyles.labelMedium.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class FAQItem {
  final String category;
  final String question;
  final String answer;

  FAQItem({
    required this.category,
    required this.question,
    required this.answer,
  });
}