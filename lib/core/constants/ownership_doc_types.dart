/// The title documents a Nigerian landlord actually holds, each with a line
/// saying what it is.
///
/// Single source of truth for add-property, edit-property and the label shown
/// back to the landlord. Both screens previously carried their own copy of the
/// list AND their own copy of the chip widget, which is how they came to offer
/// the same three bare options with nothing explaining any of them.
///
/// `c_of_o`, `deed` and `other` are the ORIGINAL stored values and must keep
/// their spelling — existing listings and the admin dashboard already read
/// them. The rest are new: they used to be forced into "Other", which told the
/// reviewer nothing and made every unusual title look identical.
class OwnershipDocTypes {
  const OwnershipDocTypes._();

  static const List<({String value, String label, String description})> all = [
    (
      value: 'c_of_o',
      label: 'Certificate of Occupancy (C of O)',
      description: 'Issued by the state government, usually for 99 years.',
    ),
    (
      value: 'deed',
      label: 'Deed of Assignment',
      description: 'Transfers the title from the seller to you. The most '
          'common document for a bought property.',
    ),
    (
      value: 'governors_consent',
      label: "Governor's Consent",
      description: 'The state approving a transfer that already happened.',
    ),
    (
      value: 'conveyance',
      label: 'Deed of Conveyance',
      description: 'An older form of transfer document, common on land held '
          'for a long time.',
    ),
    (
      value: 'excision_gazette',
      label: 'Excision / Gazette',
      description:
          'Land officially released by the state to a community or family.',
    ),
    (
      value: 'other',
      label: 'Other',
      description: 'Any other document that proves you own this property.',
    ),
  ];

  /// Human label for a stored value. Falls back to a neutral phrase rather
  /// than the raw key, so an old or unknown value never leaks into the UI.
  static String label(String? value) {
    for (final t in all) {
      if (t.value == value) return t.label;
    }
    return 'property document';
  }
}
