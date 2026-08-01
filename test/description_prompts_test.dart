import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearrent/shared/widgets/description_prompts.dart';

/// Every prompt must insert its starter line, not just the first one.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TextField(controller: controller, focusNode: focusNode),
                DescriptionPrompts(
                  controller: controller,
                  focusNode: focusNode,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tapping every prompt appends its starter', (tester) async {
    await pump(tester);

    const labels = [
      'Nearest landmark',
      'Road access',
      "What's nearby",
      'Who it suits',
      'Not ideal for',
    ];

    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: '$label should be offered');
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text(label), findsNothing,
          reason: '$label should disappear once used');
    }

    // All five starters must be present, each exactly once.
    for (final starter in [
      'Closest landmark:',
      'Getting here:',
      'Nearby:',
      'Best suited to:',
      'Not ideal for:',
    ]) {
      expect(starter.allMatches(controller.text).length, 1,
          reason: '$starter should appear once in: ${controller.text}');
    }
  });

  testWidgets('typed text is never destroyed by a prompt', (tester) async {
    controller.text = 'Lovely 3 bedroom flat.';
    await pump(tester);

    await tester.tap(find.text('Road access'));
    await tester.pumpAndSettle();

    expect(controller.text, startsWith('Lovely 3 bedroom flat.'));
    expect(controller.text, contains('Getting here:'));
  });
}
