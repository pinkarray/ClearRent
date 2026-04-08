import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';
import '../../core/utils/app_logger.dart';
import '../../services/paystack_service.dart';

/// In-app Paystack checkout using WebView.
///
/// Loads the Paystack authorization URL inside the app — no browser switch.
/// Automatically detects payment completion via callback URL interception.
///
/// Usage (unchanged from previous version):
/// ```dart
/// final result = await PaystackCheckoutScreen.launch(
///   context: context,
///   amount: 15000,
///   type: PaystackService.typeVerification,
/// );
/// if (result != null && result.success) { /* payment succeeded */ }
/// ```
class PaystackCheckoutScreen extends StatefulWidget {
  final String authorizationUrl;
  final String reference;
  final String callbackUrl;

  const PaystackCheckoutScreen({
    super.key,
    required this.authorizationUrl,
    required this.reference,
    this.callbackUrl = 'https://verealtytech.com/payment/callback',
  });

  /// Convenience method: initialize transaction, then open checkout.
  ///
  /// Returns [PaystackVerifyResult] if payment completed, null if cancelled.
  static Future<PaystackVerifyResult?> launch({
    required BuildContext context,
    required double amount,
    required String type,
    Map<String, dynamic>? metadata,
  }) async {
    AppLogger.i('PaystackCheckout.launch — amount: $amount, type: $type',
        name: 'Paystack');
    final paystack = PaystackService();

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );

    final initResult = await paystack.initializeTransaction(
      amount: amount,
      type: type,
      metadata: metadata,
    );

    // Dismiss loading
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      return null;
    }

    if (!initResult.success || initResult.authorizationUrl == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(initResult.error ?? 'Failed to initialize payment'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    }

    // Open in-app WebView checkout
    if (!context.mounted) return null;

    final result = await Navigator.push<PaystackVerifyResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PaystackCheckoutScreen(
          authorizationUrl: initResult.authorizationUrl!,
          reference: initResult.reference!,
        ),
      ),
    );

    return result;
  }

  @override
  State<PaystackCheckoutScreen> createState() => _PaystackCheckoutScreenState();
}

class _PaystackCheckoutScreenState extends State<PaystackCheckoutScreen> {
  final PaystackService _paystack = PaystackService();
  late final WebViewController _webController;

  bool _isLoading = true;
  bool _isVerifying = false;
  int _loadProgress = 0;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            AppLogger.i('WebView navigating to: ${request.url}',
                name: 'Paystack');

            // Intercept callback URL — payment is done
            if (request.url.startsWith(widget.callbackUrl)) {
              AppLogger.i('Callback URL intercepted — verifying payment',
                  name: 'Paystack');
              _verifyAndClose();
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _hasError = false;
              });
            }
          },
          onProgress: (int progress) {
            if (mounted) {
              setState(() => _loadProgress = progress);
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() => _isLoading = false);
            }
          },
          onWebResourceError: (WebResourceError error) {
            AppLogger.e(
              'WebView error: ${error.description} (code: ${error.errorCode})',
              name: 'Paystack',
            );
            // Only show error for main frame failures
            if (error.isForMainFrame ?? false) {
              if (mounted) {
                setState(() {
                  _hasError = true;
                  _isLoading = false;
                });
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.authorizationUrl));
  }

  Future<void> _verifyAndClose() async {
    if (_isVerifying) return;

    setState(() => _isVerifying = true);

    final result = await _paystack.verifyTransaction(widget.reference);

    if (!mounted) return;

    if (result.success) {
      // Show brief success feedback before popping
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text('Payment successful!'),
            ],
          ),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.pop(context, result);
    } else {
      setState(() => _isVerifying = false);

      String message;
      if (result.status == 'abandoned') {
        message = 'Payment was not completed. Please try again.';
      } else if (result.status == 'failed') {
        message = 'Payment failed. Please try a different card.';
      } else {
        message = result.error ??
            'Payment not confirmed yet. Please wait a moment and try again.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _handleCancel() {
    if (_isVerifying) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Cancel Payment?', style: AppTextStyles.h4),
        content: Text(
          'Are you sure you want to cancel? Your payment will not be processed.',
          style: AppTextStyles.bodyMedium
              .copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Continue Payment',
              style: AppTextStyles.labelMedium
                  .copyWith(color: AppColors.primary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx); // close dialog
              Navigator.pop(context, null); // close checkout — null = cancelled
            },
            child: Text(
              'Cancel',
              style:
                  AppTextStyles.labelMedium.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isVerifying,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isVerifying) {
          _handleCancel();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          leading: _isVerifying
              ? const SizedBox.shrink()
              : IconButton(
                  icon: Icon(Icons.close, color: AppColors.textPrimary),
                  onPressed: _handleCancel,
                ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 16, color: AppColors.success),
              const SizedBox(width: 6),
              Text(
                'Secure Payment',
                style: AppTextStyles.labelLarge.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          centerTitle: true,
        ),
        body: Stack(
          children: [
            // ── WebView ──
            if (!_hasError)
              WebViewWidget(controller: _webController),

            // ── Error state ──
            if (_hasError) _buildErrorState(),

            // ── Loading progress bar ──
            if (_isLoading && !_hasError)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: _loadProgress / 100,
                  backgroundColor: AppColors.border,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.primary),
                  minHeight: 3,
                ),
              ),

            // ── Verifying overlay ──
            if (_isVerifying)
              Container(
                color: Colors.white.withAlpha(230),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.primary),
                      const SizedBox(height: 24),
                      Text(
                        'Verifying payment...',
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please wait, do not close this screen.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textHint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),

        // ── Bottom bar: test card info + manual verify fallback ──
        bottomNavigationBar: _isVerifying || _hasError
            ? null
            : _buildBottomBar(),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Test mode card info
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(18),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning.withAlpha(51)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: AppColors.warning, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Test card: 4084 0840 8408 4081 · CVV: 408 · OTP: 123456',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Manual verify fallback — in case callback interception fails
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _isVerifying ? null : _verifyAndClose,
                icon: Icon(
                  Icons.check_circle_outline,
                  color: AppColors.success,
                  size: 18,
                ),
                label: Text(
                  'I\'ve completed payment',
                  style: AppTextStyles.labelSmall
                      .copyWith(color: AppColors.success),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 64, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text(
              'Unable to load payment page',
              style: AppTextStyles.h4,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Please check your internet connection and try again.',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _hasError = false;
                  _isLoading = true;
                });
                _webController
                    .loadRequest(Uri.parse(widget.authorizationUrl));
              },
              icon: Icon(Icons.refresh, color: Colors.white),
              label: Text('Retry',
                  style: AppTextStyles.labelLarge
                      .copyWith(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}