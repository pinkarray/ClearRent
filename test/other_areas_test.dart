import 'package:flutter_test/flutter_test.dart';
import 'package:clearrent/core/utils/inspection_pricing.dart';

void main() {
  test('remote out-of-state areas survive applyRemoteAreas and group', () {
    InspectionPricing.applyRemoteAreas({'abeokuta': 'other', 'enugu': 'other'});
    expect(InspectionPricing.getLGAForArea('abeokuta'), 'other');
    expect(InspectionPricing.getLGAForArea('Enugu'), 'other');
    expect(InspectionPricing.getLGALabel('other'), 'Other areas');
    final groups = InspectionPricing.getAreasGroupedByLGA();
    final other = groups.firstWhere((g) => g['cluster'] == 'other');
    expect((other['areas'] as List).contains('Abeokuta'), isTrue);
    // Lagos outskirts must NOT have moved into the new bucket.
    expect(InspectionPricing.getLGAForArea('epe'), 'outer');
  });

  test('an unknown LGA is still dropped', () {
    InspectionPricing.applyRemoteAreas({'abeokuta': 'ogun'});
    expect(InspectionPricing.getLGAForArea('abeokuta'), isNull);
  });
}
