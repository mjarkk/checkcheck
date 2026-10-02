import 'package:checkcheck/screens/controls.dart';
import 'package:checkcheck/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  // The name and count share one paragraph, as in the categories dialog.
  Finder target(String name, String count) =>
      find.text('$name ${count.replaceAll(' ', ' ')}');

  Future<void> openMenu(WidgetTester tester, String label) async {
    await tester.tap(find.bySemanticsLabel(label));
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester, String section) async {
    await openMenu(tester, 'Actions for $section');
    await tester.tap(find.text('Move all to…'));
    await tester.pumpAndSettle();
  }

  List<double> topsOf(WidgetTester tester, List<Finder> finders) => [
    for (final finder in finders) tester.getTopLeft(finder).dy,
  ];

  List<(String, int?, bool)> items() => [
    for (final item in server.items)
      (
        item['title'] as String,
        item['category_id'] as int?,
        item['checked'] as bool,
      ),
  ];

  List<String> itemPatches() => [
    for (final request in server.requests)
      if (request.method == 'PATCH') '${request.url.path} ${request.body}',
  ];

  testWidgets('without categories the menu has no Move all to…', (
    tester,
  ) async {
    server.addItem('Milk');
    await pumpScreen(tester, server);

    await openMenu(tester, 'Actions for all items');

    expect(find.text('Mark all as done'), findsOneWidget);
    expect(find.text('Delete all'), findsOneWidget);
    expect(find.text('Move all to…'), findsNothing);
  });

  testWidgets('with categories the section menu has Move all to… between '
      'its other actions; the Done menu does not', (tester) async {
    final groceries = server.addCategory('Groceries')['id'] as int;
    server
      ..addItem('Milk', categoryId: groceries)
      ..addItem('Eggs', categoryId: groceries, checked: true);
    await pumpScreen(tester, server);

    await openMenu(tester, 'Actions for Groceries');

    final actions = [
      find.text('Mark all as done'),
      find.text('Move all to…'),
      find.text('Delete all'),
    ];
    final tops = topsOf(tester, actions);
    expect(tops, orderedEquals([...tops]..sort()));
    expect(find.byIcon(Icons.drive_file_move_outlined), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await openMenu(tester, 'Actions for done items in Groceries');

    expect(find.text('Unmark all as done'), findsOneWidget);
    expect(find.text('Move all to…'), findsNothing);
  });

  testWidgets('the dialog lists the other sections in the category order', (
    tester,
  ) async {
    final work = server.addCategory('Work')['id'] as int;
    final groceries = server.addCategory('Groceries')['id'] as int;
    final chores = server.addCategory('Chores')['id'] as int;
    server.categoryOrder = [chores, null, groceries, work];
    server
      ..addItem('Milk', categoryId: groceries)
      ..addItem('Eggs', categoryId: groceries, checked: true)
      ..addItem('Bread', categoryId: groceries)
      ..addItem('Dishes', categoryId: chores)
      ..addItem('Call mum')
      ..addItem('Water plants');
    await pumpScreen(tester, server);

    await openDialog(tester, 'Groceries');

    expect(find.text('Move all items'), findsOneWidget);
    expect(
      find.text('Choose a category for the 3 items in “Groceries”.'),
      findsOneWidget,
    );
    final rows = [
      target('Chores', '1 item'),
      target('Uncategorized', '2 items'),
      target('Work', '0 items'),
    ];
    for (final row in rows) {
      expect(row, findsOneWidget);
    }
    final tops = topsOf(tester, rows);
    expect(tops, orderedEquals([...tops]..sort()));
    expect(target('Groceries', '3 items'), findsNothing);
    for (final type in [DragHandle, AppIconButton]) {
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.byType(type)),
        findsNothing,
      );
    }
    final colors = buildTheme(Brightness.light).colorScheme;
    expect(
      tester.widget<Text>(target('Uncategorized', '2 items')).style?.color,
      colors.onSurfaceVariant,
    );
    expect(
      tester.widget<Text>(target('Work', '0 items')).style?.color,
      isNot(colors.onSurfaceVariant),
    );
  });

  testWidgets('picking a section moves the open and done items to the end '
      'of its lists, one PATCH each in list order', (tester) async {
    final groceries = server.addCategory('Groceries')['id'] as int;
    final chores = server.addCategory('Chores')['id'] as int;
    server.categoryOrder = [chores, null, groceries];
    final milk = server.addItem('Milk', categoryId: groceries)['id'];
    server.addItem('Dishes', categoryId: chores);
    final eggs = server.addItem(
      'Eggs',
      categoryId: groceries,
      checked: true,
    )['id'];
    server.addItem('Vacuum', categoryId: chores, checked: true);
    final bread = server.addItem('Bread', categoryId: groceries)['id'];
    server
      ..addItem('Sweep', categoryId: chores)
      ..addItem('Call mum');
    await pumpScreen(tester, server);

    await openDialog(tester, 'Groceries');
    await tester.tap(target('Chores', '3 items'));
    await tester.pumpAndSettle();

    expect(find.text('Move all items'), findsNothing);
    expect(itemPatches(), [
      for (final id in [milk, eggs, bread])
        '/api/items/$id {"category_id":$chores,"before_id":null}',
    ]);
    expect(items(), [
      ('Dishes', chores, false),
      ('Vacuum', chores, true),
      ('Sweep', chores, false),
      ('Call mum', null, false),
      ('Milk', chores, false),
      ('Eggs', chores, true),
      ('Bread', chores, false),
    ]);
    final tops = topsOf(tester, [
      find.text('Chores'),
      titleFieldOf('Dishes'),
      titleFieldOf('Sweep'),
      titleFieldOf('Milk'),
      titleFieldOf('Bread'),
      titleFieldOf('Vacuum'),
      titleFieldOf('Eggs'),
      find.text('Uncategorized'),
    ]);
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('the moved rows spring from where they were', (tester) async {
    final groceries = server.addCategory('Groceries')['id'] as int;
    final chores = server.addCategory('Chores')['id'] as int;
    server
      ..addItem('Milk', categoryId: groceries)
      ..addItem('Dishes', categoryId: chores)
      ..addItem('Sweep', categoryId: chores);
    await pumpScreen(tester, server);
    final from = tester.getTopLeft(titleFieldOf('Milk')).dy;

    await openDialog(tester, 'Groceries');
    await tester.tap(target('Chores', '2 items'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final early = tester.getTopLeft(titleFieldOf('Milk')).dy;
    await tester.pumpAndSettle();
    final to = tester.getTopLeft(titleFieldOf('Milk')).dy;

    expect(to, greaterThan(from + 100));
    expect(early, lessThan(from + (to - from) / 2));
  });

  testWidgets('Cancel or the backdrop moves nothing', (tester) async {
    final groceries = server.addCategory('Groceries')['id'] as int;
    server
      ..addCategory('Chores')
      ..addItem('Milk', categoryId: groceries)
      ..addItem('Eggs', categoryId: groceries, checked: true);
    await pumpScreen(tester, server);
    final before = items();

    await openDialog(tester, 'Groceries');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Move all items'), findsNothing);

    await openDialog(tester, 'Groceries');
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('Move all items'), findsNothing);

    expect(itemPatches(), isEmpty);
    expect(items(), before);
  });

  testWidgets('a single item reads “the item” and can go to Uncategorized', (
    tester,
  ) async {
    final groceries = server.addCategory('Groceries')['id'] as int;
    final milk = server.addItem('Milk', categoryId: groceries)['id'];
    server.addItem('Call mum');
    await pumpScreen(tester, server);

    await openDialog(tester, 'Groceries');

    expect(
      find.text('Choose a category for the item in “Groceries”.'),
      findsOneWidget,
    );
    await tester.tap(target('Uncategorized', '1 item'));
    await tester.pumpAndSettle();

    expect(itemPatches(), [
      '/api/items/$milk {"category_id":null,"before_id":null}',
    ]);
    expect(items(), [('Call mum', null, false), ('Milk', null, false)]);
  });
}
