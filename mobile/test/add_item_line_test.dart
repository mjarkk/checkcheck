import 'package:checkcheck/screens/add_item_line.dart';
import 'package:checkcheck/screens/title_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_helpers.dart';

void main() {
  late List<String> calls;

  setUp(() => calls = []);

  Future<void> pumpLine(WidgetTester tester, {bool shown = true}) {
    var nextId = 1;
    return tester.pumpWidget(
      app(
        Scaffold(
          body: Column(
            children: [
              if (shown)
                AddItemLine(
                  label: 'Add item',
                  onCreate: (title) {
                    calls.add('create $title');
                    return nextId++;
                  },
                  onRename: (id, title) => calls.add('rename $id $title'),
                  onRelease: (id) => calls.add('release $id'),
                  onDiscard: (id) => calls.add('discard $id'),
                  onPasteLines: (lines) => calls.add('paste $lines'),
                ),
              const TextField(key: Key('other')),
            ],
          ),
        ),
      ),
    );
  }

  Finder field() => find.byType(EditableText).first;

  String shown(WidgetTester tester) =>
      tester.widget<EditableText>(field()).controller.text;

  bool focused(WidgetTester tester) =>
      tester.widget<EditableText>(field()).focusNode.hasFocus;

  Future<void> type(WidgetTester tester, String text) async {
    for (final char in text.split('')) {
      await tester.enterText(field(), shown(tester) + char);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('shows the placeholder and the label', (tester) async {
    await pumpLine(tester);

    expect(find.text('Add item'), findsOneWidget);
    expect(addLine('Add item'), findsOneWidget);
  });

  testWidgets('the first pause creates a draft, later ones rename it', (
    tester,
  ) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();

    await type(tester, 'Mil');
    expect(calls, isEmpty);
    await tester.pump(saveDelay);
    expect(calls, ['create Mil']);

    await type(tester, 'k');
    await tester.pump(saveDelay);
    expect(calls, ['create Mil', 'rename 1 Milk']);
  });

  testWidgets('Enter releases the draft and keeps the keyboard up', (
    tester,
  ) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, 'Milk');
    await tester.pump(saveDelay);
    await type(tester, ' ');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(calls, ['create Milk', 'release 1']);
    expect(shown(tester), isEmpty);
    expect(focused(tester), isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await type(tester, 'Eggs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(calls, ['create Milk', 'release 1', 'create Eggs', 'release 2']);
  });

  testWidgets('Enter before the pause sends the final title once', (
    tester,
  ) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, 'Mil');
    await tester.pump(saveDelay);
    await type(tester, 'k');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(saveDelay);

    expect(calls, ['create Mil', 'rename 1 Milk', 'release 1']);
  });

  testWidgets('a paste creates the draft at once', (tester) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();

    await tester.enterText(field(), 'Read https://example.com');

    expect(calls, ['create Read https://example.com']);
  });

  testWidgets('a paste of several lines goes to onPasteLines instead', (
    tester,
  ) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, 'Mil');

    await tester.enterText(field(), 'MilEggs\n\nBread ');
    await tester.pump();

    expect(calls, ['paste [Eggs, Bread]']);
    expect(shown(tester), 'Mil');
  });

  testWidgets('a paste with one line left joins it into the line', (
    tester,
  ) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();

    await tester.enterText(field(), ' \nEggs\n');
    await tester.pump();

    expect(calls, ['create Eggs']);
    expect(shown(tester), ' Eggs ');
  });

  testWidgets('blur finishes the entry too', (tester) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, 'Milk');

    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();

    expect(calls, ['create Milk', 'release 1']);
    expect(shown(tester), isEmpty);
  });

  testWidgets('clearing the text discards the draft', (tester) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, 'Milk');
    await tester.pump(saveDelay);

    await tester.enterText(field(), '');
    await tester.pump(saveDelay);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(calls, ['create Milk', 'discard 1']);
  });

  testWidgets('only spaces create nothing', (tester) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, '  ');
    await tester.pump(saveDelay);

    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();

    expect(calls, isEmpty);
  });

  testWidgets('an entry still typed in is released when the line goes', (
    tester,
  ) async {
    await pumpLine(tester);
    await tester.tap(field());
    await tester.pump();
    await type(tester, 'Milk');
    await tester.pump(saveDelay);

    await pumpLine(tester, shown: false);
    await tester.pump();

    expect(calls, ['create Milk', 'release 1']);
  });
}
