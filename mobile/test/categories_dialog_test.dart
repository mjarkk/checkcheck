import 'dart:convert';

import 'package:checkcheck/api/api_client.dart';
import 'package:checkcheck/screens/categories_dialog.dart';
import 'package:checkcheck/screens/controls.dart';
import 'package:checkcheck/state/checklist_model.dart';
import 'package:checkcheck/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Future<void> openDialog(WidgetTester tester) async {
    final model = await ChecklistModel.open(
      api: ApiClient(
        baseUrl: 'http://localhost',
        token: 'dev',
        httpClient: server.client,
        connectWebSocket: server.connect,
      ),
      cache: MemoryChecklistCache(),
      onUnauthorized: () {},
    );
    addTearDown(model.dispose);
    await model.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCategoriesDialog(context, model),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  // The name and count share one paragraph; see _CategoryRow.
  Finder row(String name, String count) =>
      find.text('$name ${count.replaceAll(' ', ' ')}');

  Finder newCategoryField() => find.widgetWithText(TextField, 'New category');

  FilledButton addButton(WidgetTester tester) =>
      tester.widget(find.widgetWithText(FilledButton, 'Add'));

  testWidgets('lists the category order with item counts, Uncategorized '
      'included', (tester) async {
    final work = server.addCategory('Work');
    final groceries = server.addCategory('Groceries');
    server.addCategory('Home');
    server.categoryOrder = [groceries['id'] as int, null, work['id'] as int, 3];
    server.addItem('Milk', categoryId: groceries['id'] as int);
    server.addItem('Eggs', categoryId: groceries['id'] as int);
    server.addItem('Report', categoryId: work['id'] as int);
    server.addItem('Call mum');

    await openDialog(tester);

    expect(find.text('Categories'), findsOneWidget);
    final rows = [
      row('Groceries', '2 items'),
      row('Uncategorized', '1 item'),
      row('Work', '1 item'),
      row('Home', '0 items'),
    ];
    for (final finder in rows) {
      expect(finder, findsOneWidget);
    }
    final tops = rows.map((finder) => tester.getTopLeft(finder).dy).toList();
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('Uncategorized can be moved but not renamed or deleted', (
    tester,
  ) async {
    server.addCategory('Home');

    await openDialog(tester);

    expect(find.bySemanticsLabel('Rename Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Delete Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Rename Uncategorized'), findsNothing);
    expect(find.bySemanticsLabel('Delete Uncategorized'), findsNothing);
    expect(find.byType(DragHandle), findsNWidgets(2));
  });

  testWidgets('the close button closes the dialog', (tester) async {
    await openDialog(tester);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Categories'), findsNothing);
  });

  testWidgets('without categories it lists only Uncategorized', (
    tester,
  ) async {
    await openDialog(tester);

    expect(row('Uncategorized', '0 items'), findsOneWidget);
  });

  testWidgets('adds a category and clears the field', (tester) async {
    await openDialog(tester);
    expect(addButton(tester).onPressed, isNull);

    await tester.enterText(newCategoryField(), '   ');
    await tester.pump();
    expect(addButton(tester).onPressed, isNull);

    await tester.enterText(newCategoryField(), '  Garden ');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(server.categories.single['name'], 'Garden');
    expect(row('Garden', '0 items'), findsOneWidget);
    expect(
      tester.widget<TextField>(newCategoryField()).controller!.text,
      isEmpty,
    );
  });

  testWidgets('a duplicate name shows an inline notice for six seconds', (
    tester,
  ) async {
    server.addCategory('Groceries');
    await openDialog(tester);

    await tester.enterText(newCategoryField(), 'groceries');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(
        ErrorNotice,
        'A category with that name already exists',
      ),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(server.categories, hasLength(1));
    expect(
      tester.widget<TextField>(newCategoryField()).controller!.text,
      'groceries',
    );

    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(ErrorNotice), findsNothing);
  });

  testWidgets('the notice can be dismissed', (tester) async {
    server.addCategory('Groceries');
    await openDialog(tester);
    await tester.enterText(newCategoryField(), 'Groceries');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();

    expect(find.byType(ErrorNotice), findsNothing);
  });

  testWidgets('renames a category inline', (tester) async {
    final home = server.addCategory('Home');
    server.addItem('Vacuum', categoryId: home['id'] as int);
    await openDialog(tester);

    await tester.tap(find.byTooltip('Rename'));
    await tester.pump();
    expect(find.byTooltip('Rename'), findsNothing);
    final field = find.descendant(
      of: find.byType(InlineEdit),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(field).controller.text, 'Home');

    await tester.enterText(field, ' House ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final patch = server.requests.lastWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/api/categories/${home['id']}');
    expect(jsonDecode(patch.body), {'name': 'House'});
    expect(find.byType(InlineEdit), findsNothing);
    expect(row('House', '1 item'), findsOneWidget);
    expect(find.byTooltip('Rename'), findsOneWidget);
  });

  testWidgets('an unchanged rename sends nothing', (tester) async {
    server.addCategory('Home');
    await openDialog(tester);
    final requests = server.requests.length;

    await tester.tap(find.byTooltip('Rename'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(server.requests, hasLength(requests));
    expect(row('Home', '0 items'), findsOneWidget);
  });

  testWidgets('deleting asks first, naming the items it uncategorizes', (
    tester,
  ) async {
    final groceries = server.addCategory('Groceries');
    final work = server.addCategory('Work');
    server.addCategory('Home');
    server.addItem('Milk', categoryId: groceries['id'] as int);
    server.addItem('Eggs', categoryId: groceries['id'] as int);
    server.addItem('Report', categoryId: work['id'] as int);
    await openDialog(tester);

    Future<void> askToDelete(String name, String count) async {
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: row(name, count), matching: find.byType(Row)),
          matching: find.byTooltip('Delete'),
        ),
      );
      await tester.pumpAndSettle();
    }

    await askToDelete('Home', '0 items');
    expect(find.text('Delete “Home”?'), findsOneWidget);
    expect(find.text('Its items become uncategorized.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await askToDelete('Work', '1 item');
    expect(find.text('Its 1 item becomes uncategorized.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.categories, hasLength(3));

    await askToDelete('Groceries', '2 items');
    expect(find.text('Delete “Groceries”?'), findsOneWidget);
    expect(find.text('Its 2 items become uncategorized.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(server.categories.map((c) => c['name']), ['Work', 'Home']);
    expect(find.textContaining('Groceries'), findsNothing);
    expect(find.text('Categories'), findsOneWidget);
  });

  testWidgets('dragging a row by its handle reorders the categories', (
    tester,
  ) async {
    server.addCategory('Groceries');
    server.addCategory('Work');
    await openDialog(tester);

    final handle = find.descendant(
      of: find.ancestor(
        of: row('Work', '0 items'),
        matching: find.byType(CategoryRow),
      ),
      matching: find.byType(DragHandle),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 16; i++) {
      await gesture.moveBy(const Offset(0, -9));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(server.categoryOrder, [2, 1, null]);
    final groceries = tester.getTopLeft(row('Groceries', '0 items')).dy;
    expect(tester.getTopLeft(row('Work', '0 items')).dy, lessThan(groceries));
  });
}
