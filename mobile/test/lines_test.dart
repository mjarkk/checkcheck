import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  /// The focused field's text, with `|` at its caret.
  String caret(WidgetTester tester) {
    final TextEditingValue(:text, :selection) = focusedField(
      tester,
    ).controller.value;
    expect(selection.isCollapsed, isTrue);
    return text.replaceRange(selection.start, selection.start, '|');
  }

  Future<void> focus(WidgetTester tester, Finder field, int offset) async {
    await tester.showKeyboard(field);
    tester.widget<EditableText>(field).controller.selection =
        TextSelection.collapsed(offset: offset);
    await tester.pump();
  }

  bool anyFocused(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .any((field) => field.focusNode.hasFocus);

  testWidgets('Enter moves to the end of the line below, down to Add item', (
    tester,
  ) async {
    server
      ..addItem('Milk')
      ..addItem('Eggs');
    await pumpScreen(tester, server);
    await focus(tester, titleFieldOf('Milk'), 0);

    await pressReturn(tester);
    expect(caret(tester), 'Eggs|');

    await pressReturn(tester);
    expect(caret(tester), '|');
    expect(
      tester.widget<EditableText>(addField('Add item')).focusNode.hasFocus,
      isTrue,
    );
    expect(server.items.map((i) => i['title']), ['Milk', 'Eggs']);
  });

  testWidgets('Enter on the last Done line leaves it', (tester) async {
    server
      ..addItem('Milk')
      ..addItem('Bread', checked: true);
    await pumpScreen(tester, server);
    await focus(tester, titleFieldOf('Bread'), 5);

    await pressReturn(tester);

    expect(anyFocused(tester), isFalse);
  });

  testWidgets('Backspace in an emptied title deletes it and moves up', (
    tester,
  ) async {
    server
      ..addItem('Milk')
      ..addItem('Eggs');
    await pumpScreen(tester, server);
    await focus(tester, titleFieldOf('Eggs'), 4);
    await tester.enterText(titleFieldOf('Eggs'), '');

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(caret(tester), 'Milk|');

    await tester.pumpAndSettle();
    expect(server.items.map((i) => i['title']), ['Milk']);
    expect(caret(tester), 'Milk|');
  });

  testWidgets('Backspace in an empty Add item line moves to the last row', (
    tester,
  ) async {
    server
      ..addItem('Milk')
      ..addItem('Eggs');
    await pumpScreen(tester, server);
    await focus(tester, addField('Add item'), 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(caret(tester), 'Eggs|');
    expect(server.items, hasLength(2));
  });

  testWidgets('the arrow keys leave a line only from its edges', (
    tester,
  ) async {
    server
      ..addItem('Milk')
      ..addItem('Eggs');
    await pumpScreen(tester, server);
    await focus(tester, titleFieldOf('Milk'), 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedField(tester).controller.text, 'Milk');

    await focus(tester, titleFieldOf('Milk'), 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(caret(tester), 'Eggs|');

    await focus(tester, titleFieldOf('Eggs'), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(caret(tester), '|Milk');
  });

  testWidgets('lines stay within their list', (tester) async {
    server
      ..addItem('Milk')
      ..addItem('Bread', checked: true);
    await pumpScreen(tester, server);
    await focus(tester, titleFieldOf('Bread'), 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(caret(tester), '|Bread');
  });

  testWidgets('a row on its way out is skipped', (tester) async {
    server
      ..addItem('Milk')
      ..addItem('Eggs')
      ..addItem('Bread');
    await pumpScreen(tester, server);
    await tester.tap(inRow('Eggs', find.byTooltip('Delete')));
    await tester.pump();
    await focus(tester, titleFieldOf('Milk'), 4);

    await pressReturn(tester);

    expect(caret(tester), 'Bread|');
    await tester.pumpAndSettle();
  });
}
