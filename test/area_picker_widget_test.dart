import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearrent/core/utils/inspection_pricing.dart';
import 'package:clearrent/shared/widgets/area_dropdown.dart';
import 'package:clearrent/shared/widgets/state_dropdown.dart';

/// The residence screen and the add-property location step have to offer areas
/// the same way. These drive the two shared pickers directly, which is the part
/// a device pass cannot check quickly: that the groups are LGA headers, and that
/// a state filter really filters.
void main() {
  setUp(() {
    InspectionPricing.applyRemoteLGAs(null);
    InspectionPricing.applyRemoteAreas(null);
  });

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('the area sheet groups by LGA', (tester) async {
    await tester.pumpWidget(host(AreaDropdown(onSelected: (_) {})));
    await tester.tap(find.text('Select area'));
    await tester.pumpAndSettle();

    expect(find.text('Ikeja LGA'), findsOneWidget);
    expect(find.text('Allen'), findsOneWidget);

    // Further down the list, so reach it the way a user would. The header comes
    // with it, which is the point: every row sits under its LGA.
    await tester.enterText(find.byType(TextField).first, 'ejirin');
    await tester.pumpAndSettle();
    expect(find.text('Epe LGA'), findsOneWidget);
    expect(find.text('Ejirin'), findsOneWidget);

    // An alias is never its own row.
    await tester.enterText(find.byType(TextField).first, 'somolu');
    await tester.pumpAndSettle();
    expect(find.text('Shomolu'), findsOneWidget);
    expect(find.text('Somolu'), findsNothing);
  });

  testWidgets('a state filter shows only that state', (tester) async {
    await tester.pumpWidget(host(AreaDropdown(state: 'Ogun', onSelected: (_) {})));
    await tester.tap(find.text('Select area'));
    await tester.pumpAndSettle();

    expect(find.text('Lagos outskirts: Obafemi-Owode (Ogun)'), findsOneWidget);
    expect(find.text('Mowe'), findsOneWidget);
    expect(find.text('Ikeja LGA'), findsNothing);
  });

  testWidgets('picking an area reports it, searching finds an added area',
      (tester) async {
    String? picked;
    await tester.pumpWidget(host(AreaDropdown(onSelected: (a) => picked = a)));
    await tester.tap(find.text('Select area'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'ishaga');
    await tester.pumpAndSettle();
    expect(find.text('Ishagatedo'), findsOneWidget);
    await tester.tap(find.text('Ishagatedo'));
    await tester.pumpAndSettle();
    expect(picked, 'Ishagatedo');
  });

  testWidgets('the state sheet leads with the states we cover', (tester) async {
    String? picked;
    await tester.pumpWidget(host(StateDropdown(onSelected: (s) => picked = s)));
    await tester.tap(find.text('Select state'));
    await tester.pumpAndSettle();

    expect(find.text('Where ClearRent operates'), findsOneWidget);
    expect(find.text('All other states'), findsOneWidget);
    await tester.tap(find.text('Ogun'));
    await tester.pumpAndSettle();
    expect(picked, 'Ogun');
  });

  testWidgets('an LGA published live appears in both pickers', (tester) async {
    InspectionPricing.applyRemoteLGAs({
      'ado_odo_ota': {'label': 'Ado-Odo/Ota LGA (Ogun)', 'state': 'Ogun'},
    });
    InspectionPricing.applyRemoteAreas({'sango ota': 'ado_odo_ota'});

    await tester.pumpWidget(host(AreaDropdown(state: 'Ogun', onSelected: (_) {})));
    await tester.tap(find.text('Select area'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'sango');
    await tester.pumpAndSettle();
    expect(find.text('Ado-Odo/Ota LGA (Ogun)'), findsOneWidget);
    expect(find.text('Sango Ota'), findsOneWidget);
  });
}
