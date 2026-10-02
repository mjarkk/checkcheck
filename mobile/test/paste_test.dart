import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

void main() {
  late FakeServer server;
  late int groceries;

  setUp(() {
    server = FakeServer();
    groceries = server.addCategory('Groceries')['id'] as int;
    server
      ..addItem('Milk', categoryId: groceries)
      ..addItem('Bread', categoryId: groceries, checked: true)
      ..addItem('Jam', categoryId: groceries, checked: true)
      ..addItem('Soap');
  });

  List<(String, int?, bool)> items() => [
    for (final item in server.items)
      (
        item['title'] as String,
        item['category_id'] as int?,
        item['checked'] as bool,
      ),
  ];

  List<double> topsOf(WidgetTester tester, List<String> titles) => [
    for (final title in titles) tester.getTopLeft(titleFieldOf(title)).dy,
  ];

  testWidgets('lines pasted into an Add item line go at the end of its '
      'section', (tester) async {
    await pumpScreen(tester, server);

    await tester.enterText(
      addField('Add item to Groceries'),
      'Eggs\n\n Butter ',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Choose the lines to add to “Groceries”.'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(items(), [
      ('Milk', groceries, false),
      ('Bread', groceries, true),
      ('Jam', groceries, true),
      ('Soap', null, false),
      ('Eggs', groceries, false),
      ('Butter', groceries, false),
    ]);
    final tops = topsOf(tester, ['Milk', 'Eggs', 'Butter', 'Bread']);
    expect(tops, orderedEquals([...tops]..sort()));
    final field = tester.widget<EditableText>(
      addField('Add item to Groceries'),
    );
    expect(field.controller.text, isEmpty);
    // Coming back doesn't raise the keyboard over the new rows.
    expect(field.focusNode.hasFocus, isFalse);
  });

  testWidgets('two lines that only differ in case add one item', (
    tester,
  ) async {
    await pumpScreen(tester, server);

    await tester.enterText(addField('Add item to Groceries'), 'Eggs\neggs');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Choose the lines to add to “Groceries”. '
        '1\u00a0duplicate line was left out.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(items().last, ('Eggs', groceries, false));
    expect(items(), hasLength(5));
  });

  testWidgets('going back adds nothing', (tester) async {
    await pumpScreen(tester, server);

    await tester.enterText(addField('Add item to Groceries'), 'Eggs\nButter');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(items(), hasLength(4));
    expect(find.text('Add items'), findsNothing);
  });

  testWidgets('the checked lines pasted into a title go under that item, '
      'done like it', (tester) async {
    await pumpScreen(tester, server);

    await tester.enterText(titleFieldOf('Bread'), 'Bread\nRye\nSpelt\nOats');
    await tester.pumpAndSettle();
    expect(find.text('Choose the lines to add below “Bread”.'), findsOneWidget);
    await tester.tap(find.text('Spelt'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(items(), [
      ('Milk', groceries, false),
      ('Bread', groceries, true),
      ('Rye', groceries, true),
      ('Oats', groceries, true),
      ('Jam', groceries, true),
      ('Soap', null, false),
    ]);
    final tops = topsOf(tester, ['Bread', 'Rye', 'Oats', 'Jam']);
    expect(tops, orderedEquals([...tops]..sort()));
    expect(titleFieldOf('Bread'), findsOneWidget);
  });

  testWidgets('the Add items screen names the item by its title as typed', (
    tester,
  ) async {
    await pumpScreen(tester, server);

    await tester.enterText(titleFieldOf('Bread'), 'Breads');
    await tester.pump();
    await tester.enterText(titleFieldOf('Breads'), 'Breads\nRye\nOats');
    await tester.pumpAndSettle();

    expect(
      find.text('Choose the lines to add below “Breads”.'),
      findsOneWidget,
    );
  });

  testWidgets('if that item is gone by then, they go at the end of its '
      'list', (tester) async {
    final model = await pumpScreen(tester, server);

    await tester.enterText(titleFieldOf('Bread'), 'Bread\nRye\nOats');
    await tester.pumpAndSettle();
    model.deleteItems([server.items[1]['id'] as int]);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(items(), [
      ('Milk', groceries, false),
      ('Jam', groceries, true),
      ('Soap', null, false),
      ('Rye', groceries, true),
      ('Oats', groceries, true),
    ]);
  });
}
