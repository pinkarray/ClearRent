import 'dart:developer' as developer;
import 'package:cloud_functions/cloud_functions.dart';

/// Resolves a viewable URL for a tenancy agreement.
///
/// New agreements live in PRIVATE Firebase Storage and are served via a
/// short-lived signed URL minted by the `getSignedAgreementUrl` CF, which
/// authorizes the caller as a party (landlord/tenant) or admin before signing.
/// Legacy Cloudinary agreements are returned as-is by the same CF. Returns null
/// on failure (not a party, no agreement, or network error).
class AgreementAccessService {
  /// [collection] is 'active_rentals' or 'tenancy_links'; [docId] is that
  /// rental/link's id.
  ///
  /// [which] picks which copy: `original` (what the landlord sent),
  /// `tenantSigned` (the tenant's signed upload) or `executed` (counter-signed,
  /// the agreement of record). Each party uploads under their own uid, so
  /// Storage denies the counterparty a direct read — this callable checks
  /// membership server-side and signs, which storage rules cannot do.
  Future<String?> resolveUrl({
    required String collection,
    required String docId,
    String which = 'original',
  }) async {
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getSignedAgreementUrl');
      final res = await callable.call<Map<String, dynamic>>({
        'collection': collection,
        'docId': docId,
        'which': which,
      });
      final url = res.data['url'] as String?;
      return (url != null && url.isNotEmpty) ? url : null;
    } catch (e) {
      developer.log('❌ resolveUrl failed: $e',
          name: 'AgreementAccessService');
      return null;
    }
  }
}
