
/// Normalizes a Nigerian phone number to E.164 format (e.g. "+2348053385667").
///
/// Accepts input in any of these formats:
///   - Local with leading 0:  "08053385667"
///   - International digits:  "2348053385667"
///   - E.164:                 "+2348053385667"
///   - Subscriber-only:       "8053385667"
///
/// Strips whitespace, hyphens, parentheses, and a leading "+" before parsing.
/// Returns null if the input is not a valid Nigerian mobile number.
///
/// Mirrors the server-side normalizeNigerianPhone() in functions/src/index.ts
/// but outputs E.164 (the canonical storage format) rather than local.
String? phoneToE164(String raw) {
  final digits = raw.replaceAll(RegExp(r'[\s\-()+]'), '');
  if (!RegExp(r'^\d+$').hasMatch(digits)) return null;

  String subscriber;
  if (digits.length == 11 && digits.startsWith('0')) {
    subscriber = digits.substring(1);
  } else if (digits.length == 13 && digits.startsWith('234')) {
    subscriber = digits.substring(3);
  } else if (digits.length == 10) {
    subscriber = digits;
  } else {
    return null;
  }

  // Nigerian mobile subscriber numbers start with 7, 8, or 9 (10 digits total).
  if (!RegExp(r'^[789]\d{9}$').hasMatch(subscriber)) return null;

  return '+234$subscriber';
}