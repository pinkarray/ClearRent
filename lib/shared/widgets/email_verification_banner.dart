import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// A prompt to confirm the email address on the account.
///
/// `sendEmailVerification()` has always been called when an email is linked,
/// but nothing anywhere read `emailVerified` — so a mistyped address failed
/// completely silently. No regex can catch this: `name@gmial.com` and
/// `name@gmail.con` are both perfectly well-formed, and the second even passes
/// a strict TLD check. Only a delivered email proves an address is real.
///
/// That matters more here than on most products, because the email is not
/// decorative: Paystack refuses to initialise a charge without one and sends
/// the receipt there, it is the identity behind phone-to-email sign-in, and it
/// is how anyone would be reached about their money.
///
/// Deliberately NOT a hard gate. Blocking the app on an unconfirmed address
/// would lock out anyone whose mail is merely slow, which is a worse failure
/// than the one being prevented. It nags, it offers a resend, and it can be
/// dismissed — returning on the next launch, because the address is still
/// unconfirmed and that remains worth knowing.
class EmailVerificationBanner extends StatefulWidget {
  const EmailVerificationBanner({super.key});

  @override
  State<EmailVerificationBanner> createState() =>
      _EmailVerificationBannerState();
}

class _EmailVerificationBannerState extends State<EmailVerificationBanner>
    with WidgetsBindingObserver {
  bool _dismissed = false;
  bool _sending = false;
  bool _checking = true;
  bool _verified = true;
  String? _email;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Confirming the email means LEAVING the app — the link opens in a mail
  /// client or browser. Checking only on initState meant coming back to the
  /// same banner still telling you to do the thing you had just done, which
  /// reads as broken. Re-checking on resume is what makes it disappear by
  /// itself, at the exact moment it should.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_verified) {
      _refresh();
    }
  }

  /// `emailVerified` is cached on the client, so a user who confirmed on
  /// another device still reads as unverified until the record is reloaded.
  /// Without this the banner would keep nagging someone who already complied.
  Future<void> _refresh() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      await user.reload();
    } catch (_) {
      // Offline or a transient failure — fall through to the cached values
      // rather than showing a wrong state.
    }
    final fresh = FirebaseAuth.instance.currentUser;
    if (!mounted) return;
    setState(() {
      _email = fresh?.email;
      // An account with no email at all is a different problem and not this
      // banner's business; treat it as nothing to prompt about.
      _verified = (fresh?.email == null) || (fresh?.emailVerified ?? true);
      _checking = false;
    });
  }

  Future<void> _resend() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _sending) return;
    setState(() => _sending = true);
    var message = 'Confirmation email sent. Check your inbox and spam folder.';
    try {
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (e) {
      message = e.code == 'too-many-requests'
          ? 'Too many requests. Wait a few minutes and try again.'
          : 'Could not send the email. Please try again.';
    } catch (_) {
      message = 'Could not send the email. Please try again.';
    }
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_checking || _verified || _dismissed) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mark_email_unread_outlined,
                  size: 20, color: AppColors.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Confirm your email address',
                    style: AppTextStyles.labelMedium),
              ),
              InkWell(
                onTap: () => setState(() => _dismissed = true),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close,
                      size: 18, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _email == null
                ? 'Receipts and account emails are sent to your address.'
                : 'We sent a link to $_email. Receipts and account emails go '
                    'there, so it is worth checking it is right.',
            style:
                AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(
                onPressed: _sending ? null : _resend,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
                ),
                child: Text(_sending ? 'Sending…' : 'Resend email'),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: _checking ? null : _refresh,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('I have confirmed'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
