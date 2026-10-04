import 'package:checkcheck/screens/title_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_helpers.dart';

void main() {
  late List<String> saved;
  late int cleared;

  setUp(() {
    saved = [];
    cleared = 0;
  });

  Future<void> pumpField(
    WidgetTester tester,
    String value, {
    ValueChanged<List<String>>? onPasteLines,
  }) => tester.pumpWidget(
    app(
      Scaffold(
        body: Column(
          children: [
            TitleField(
              value: value,
              label: 'Item title',
              onSave: saved.add,
              onClear: () => cleared++,
              onPasteLines: onPasteLines,
            ),
            const TextField(key: Key('other')),
          ],
        ),
      ),
    ),
  );

  Finder field() => find.byType(EditableText).first;

  String shown(WidgetTester tester) =>
      tester.widget<EditableText>(field()).controller.text;

  /// Types [text] after what the field holds, one character at a time.
  Future<void> type(WidgetTester tester, String text) async {
    for (final char in text.split('')) {
      await tester.enterText(field(), shown(tester) + char);
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('saves the trimmed title once typing pauses', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();

    await type(tester, ' oat ');
    // 100ms after the last key.
    await tester.pump(const Duration(milliseconds: 550));
    expect(saved, isEmpty);

    await tester.pump(const Duration(milliseconds: 50));
    expect(saved, ['Milk oat']);
  });

  testWidgets('saves a paste at once', (tester) async {
    await pumpField(tester, 'Read');
    await tester.tap(field());
    await tester.pump();

    await tester.enterText(field(), 'Read https://example.com/post');

    expect(saved, ['Read https://example.com/post']);
    await tester.pump(saveDelay);
    expect(saved, hasLength(1));
  });

  testWidgets('saves on blur without waiting', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();
    await type(tester, 's');

    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();

    expect(saved, ['Milks']);
    await tester.pump(saveDelay);
    expect(saved, hasLength(1));
  });

  testWidgets('never sends an empty or unchanged title', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();

    await tester.enterText(field(), '   ');
    await tester.pump(saveDelay);
    await tester.enterText(field(), ' Milk ');
    await tester.pump(saveDelay);
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();

    expect(saved, isEmpty);
    expect(shown(tester), 'Milk');
  });

  testWidgets('the keyboard shows a return key, not done', (tester) async {
    await pumpField(tester, 'Milk');

    expect(
      tester.widget<EditableText>(field()).textInputAction,
      TextInputAction.newline,
    );
  });

  testWidgets('Enter on the last line leaves the field and saves', (
    tester,
  ) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();
    await type(tester, '!');

    await pressReturn(tester);

    expect(saved, ['Milk!']);
    expect(tester.widget<EditableText>(field()).focusNode.hasFocus, isFalse);
  });

  testWidgets('Escape leaves the field', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(tester.widget<EditableText>(field()).focusNode.hasFocus, isFalse);
  });

  testWidgets('leaving it empty clears it and keeps it empty', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();
    await tester.enterText(field(), ' ');

    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();

    expect(cleared, 1);
    expect(saved, isEmpty);
    expect(shown(tester), ' ');
  });

  testWidgets('Backspace in an empty field with no line above leaves it', (
    tester,
  ) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();
    await tester.enterText(field(), '');

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(tester.widget<EditableText>(field()).focusNode.hasFocus, isFalse);
    expect(cleared, 1);
  });

  testWidgets('line breaks become one space', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();

    await tester.enterText(field(), 'Milk \n\n and eggs');

    expect(shown(tester), 'Milk and eggs');
    expect(saved, ['Milk and eggs']);
  });

  testWidgets('keeps titles to the API limit', (tester) async {
    await pumpField(tester, '');
    await tester.tap(field());
    await tester.pump();

    await tester.enterText(field(), 'a' * 600);

    expect(shown(tester), hasLength(maxItemTitle));
  });

  testWidgets('follows the value while unfocused, not while editing', (
    tester,
  ) async {
    await pumpField(tester, 'Milk');
    await pumpField(tester, 'Oat milk');
    expect(shown(tester), 'Oat milk');

    await tester.tap(field());
    await tester.pump();
    await type(tester, 's');
    await pumpField(tester, 'Soy milk');
    expect(shown(tester), 'Oat milks');

    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(saved, ['Oat milks']);
    // The parent hasn't applied the save yet, so it shows what it has.
    expect(shown(tester), 'Soy milk');
  });

  testWidgets('a field that unmounts mid-edit still saves', (tester) async {
    await pumpField(tester, 'Milk');
    await tester.tap(field());
    await tester.pump();
    await type(tester, 's');

    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump();

    expect(saved, ['Milks']);
  });

  group('pastedLines', () {
    test('trims the lines and leaves out empty ones', () {
      expect(pastedLines(' Milk \r\n\n  \n\tEggs\rBread  '), [
        'Milk',
        'Eggs',
        'Bread',
      ]);
      expect(pastedLines('Milk'), ['Milk']);
      expect(pastedLines(' \n '), isEmpty);
    });

    test('cuts each line to the API limit', () {
      expect(pastedLines('${'a' * 600}\nb'), ['a' * maxItemTitle, 'b']);
    });
  });

  test('withoutDuplicates keeps the first of lines equal but for case', () {
    expect(withoutDuplicates(['Milk', 'Eggs', 'milk', 'Bread', 'EGGS']), [
      'Milk',
      'Eggs',
      'Bread',
    ]);
  });

  group('a paste of several lines', () {
    late List<List<String>> pasted;

    setUp(() => pasted = []);

    Future<void> pumpPasting(WidgetTester tester, String value) async {
      await pumpField(tester, value, onPasteLines: pasted.add);
      await tester.tap(field());
      await tester.pump();
    }

    /// Pastes [text] the way the selection toolbar does, over the selection.
    Future<void> paste(WidgetTester tester, String text) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': text} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester
          .state<EditableTextState>(field())
          .pasteText(SelectionChangedCause.toolbar);
    }

    testWidgets('goes to onPasteLines after the frame and leaves the text', (
      tester,
    ) async {
      await pumpPasting(tester, 'Milk');

      await tester.enterText(field(), 'Milk Eggs \n\n Bread\n');
      expect(pasted, isEmpty);
      await tester.pump();

      expect(pasted, [
        ['Eggs', 'Bread'],
      ]);
      expect(shown(tester), 'Milk');
      await tester.pump(saveDelay);
      expect(saved, isEmpty);
    });

    testWidgets('is only what was pasted, wherever the cursor is', (
      tester,
    ) async {
      await pumpPasting(tester, 'Milk');
      tester.widget<EditableText>(field()).controller.selection =
          const TextSelection.collapsed(offset: 0);

      await paste(tester, 'Milk\nOat milk');
      await tester.pump();

      expect(pasted, [
        ['Milk', 'Oat milk'],
      ]);
      expect(shown(tester), 'Milk');
    });

    testWidgets('with one line left is joined into the title as before', (
      tester,
    ) async {
      await pumpPasting(tester, 'Milk');

      await tester.enterText(field(), 'Milk \n oat\n\n');
      await tester.pump();

      expect(pasted, isEmpty);
      expect(shown(tester), 'Milk oat ');
      expect(saved, ['Milk oat']);
    });

    testWidgets('counts its lines before duplicates are left out', (
      tester,
    ) async {
      await pumpPasting(tester, '');

      await tester.enterText(field(), 'Milk\nmilk');
      await tester.pump();

      expect(pasted, [
        ['Milk', 'milk'],
      ]);
      expect(shown(tester), isEmpty);
    });
  });
}
