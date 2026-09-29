import 'package:flutter_test/flutter_test.dart';
import 'package:clearrent/core/utils/inspection_pricing.dart';

void main() {
  setUp(() {
    // Each test starts from the compiled baseline.
    InspectionPricing.applyRemoteLGAs(null);
    InspectionPricing.applyRemoteAreas(null);
  });

  group('state comes from the LGA', () {
    test('Lagos areas are Lagos, the Ogun outskirts are Ogun', () {
      expect(InspectionPricing.stateForArea('Ikeja'), 'Lagos');
      expect(InspectionPricing.stateForArea('Mowe'), 'Ogun');
      expect(InspectionPricing.stateForArea('Ibafo'), 'Ogun');
      expect(InspectionPricing.stateForArea('Isheri North'), 'Ogun');
    });

    test('an area in the other bucket claims no state', () {
      InspectionPricing.applyRemoteAreas({'abuja': 'other'});
      expect(InspectionPricing.getLGAForArea('Abuja'), 'other');
      expect(InspectionPricing.stateForArea('Abuja'), isNull);
    });

    test('an unknown area has no state', () {
      expect(InspectionPricing.stateForArea('Nowhere At All'), isNull);
    });
  });

  group('matching stops guessing on part-words', () {
    test('a longer name is not eaten by a shorter one inside it', () {
      expect(InspectionPricing.findMatchingArea('Gbagada Phase 2'),
          'Gbagada Phase 2');
      expect(InspectionPricing.getLGAForArea('Gbagada Phase 2'), 'shomolu');
      expect(InspectionPricing.getLGAForArea('Ebute-Metta'), 'yaba_mainland');
      expect(InspectionPricing.getLGAForArea('Isheri Olowora'), 'kosofe');
      expect(InspectionPricing.getLGAForArea('Isheri Oshun'), 'alimosho');
    });

    test('a state or country name is not an area', () {
      expect(InspectionPricing.getLGAForArea('Lagos'), isNull);
      expect(InspectionPricing.getLGAForArea('Nigeria'), isNull);
    });

    test('diacritics, suffixes and old spellings resolve', () {
      expect(InspectionPricing.findMatchingArea('Ìkòròdú'), 'Ikorodu');
      expect(InspectionPricing.findMatchingArea('Ikorodu LGA'), 'Ikorodu');
      expect(InspectionPricing.findMatchingArea('Somolu'), 'Shomolu');
      // An old short form resolves to the name the pickers show.
      expect(InspectionPricing.findMatchingArea('VI'), 'Victoria Island');
    });

    test('the longest area inside an address wins', () {
      expect(
        InspectionPricing.findMatchingArea('12 Adeniyi Jones Street, Ikeja'),
        'Adeniyi Jones',
      );
    });
  });

  group('the pickers list one row per place', () {
    test('aliases resolve but are not offered', () {
      final areas = InspectionPricing.getAllAreas();
      expect(areas, contains('Shomolu'));
      expect(areas, isNot(contains('Somolu')));
      expect(InspectionPricing.getLGAForArea('Somolu'), 'shomolu');
    });

    test('areas can be listed for one state only', () {
      final lagos = InspectionPricing.getAreasGroupedByLGA(state: 'Lagos');
      final ogun = InspectionPricing.getAreasGroupedByLGA(state: 'Ogun');
      expect(lagos.map((g) => g['cluster']), contains('ikeja'));
      expect(lagos.map((g) => g['cluster']), isNot(contains('obafemi_owode')));
      expect(ogun.map((g) => g['cluster']), ['obafemi_owode']);
    });

    test('display names capitalise after a hyphen', () {
      final areas = InspectionPricing.getAllAreas();
      expect(areas, contains('Isale-Eko'));
      expect(areas, contains('Oke-Afa'));
    });

    test('Badagry, Epe and Ibeju-Lekki are their own LGAs now', () {
      expect(InspectionPricing.getLGAForArea('Epe'), 'epe');
      expect(InspectionPricing.getLGAForArea('Badagry'), 'badagry');
      expect(InspectionPricing.getLGAForArea('Ibeju-Lekki'), 'ibeju_lekki');
      // Still accepted, because inspection docs written before the split carry it.
      InspectionPricing.applyRemoteAreas({'somewhere far': 'outer'});
      expect(InspectionPricing.getLGAForArea('Somewhere Far'), 'outer');
    });
  });

  group('LGAs published live', () {
    test('a remote LGA with a state opens that state, no release needed', () {
      InspectionPricing.applyRemoteLGAs({
        'ado_odo_ota': {'label': 'Ado-Odo/Ota LGA (Ogun)', 'state': 'Ogun'},
      });
      InspectionPricing.applyRemoteAreas({'sango ota': 'ado_odo_ota'});
      expect(InspectionPricing.getLGAForArea('Sango Ota'), 'ado_odo_ota');
      expect(InspectionPricing.stateForArea('Sango Ota'), 'Ogun');
      expect(InspectionPricing.getLGALabel('ado_odo_ota'),
          'Ado-Odo/Ota LGA (Ogun)');
      expect(InspectionPricing.statesWithAreas, contains('Ogun'));
    });

    test('a remote LGA with no state is dropped, and its areas with it', () {
      InspectionPricing.applyRemoteLGAs({
        'ifo': {'label': 'Ifo LGA'},
      });
      InspectionPricing.applyRemoteAreas({'akute': 'ifo'});
      expect(InspectionPricing.getLGAForArea('Akute'), isNull);
    });

    test('a remote LGA cannot redefine a compiled one', () {
      InspectionPricing.applyRemoteLGAs({
        'ikeja': {'label': 'Somewhere Else', 'state': 'Ogun'},
      });
      expect(InspectionPricing.getLGALabel('ikeja'), 'Ikeja LGA');
      expect(InspectionPricing.stateForArea('Allen'), 'Lagos');
    });
  });
}
