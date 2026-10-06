import 'package:flutter_test/flutter_test.dart';
import 'package:clearrent/services/inspection_service.dart';

void main() {
  test('every slot has a start hour', () {
    for (final slot in InspectionService.timeSlotLabels.keys) {
      expect(InspectionService.timeSlotStartHour[slot], isNotNull,
          reason: '$slot has a label but no start hour, so it would sort last');
    }
  });

  test('start hours run in the order the labels read', () {
    // Guards the mapping itself: a wrong hour here would sort the picker
    // wrongly even though the sort is correct.
    expect(InspectionService.timeSlotStartHour['morning'], 9);
    expect(InspectionService.timeSlotStartHour['afternoon'], 12);
    expect(InspectionService.timeSlotStartHour['late_afternoon'], 15);
    expect(InspectionService.timeSlotStartHour['evening'], 18);
  });
}
