import 'package:checkcheck/screens/deleted_screen.dart';
import 'package:checkcheck/screens/item_row.dart';
import 'package:checkcheck/state/days.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

/// Noon local time [days] days ago.
DateTime _daysAgo(int days) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - days, 12);
}

Finder _deletedRow(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(RowSurface));

Finder _restore(String title) => find.descendant(
  of: _deletedRow(title),
  matching: find.byTooltip('Restore'),
);

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

/// How opaque [text] is drawn, through every [Opacity] above it.
double _opacityOf(WidgetTester tester, String text) => tester
    .widgetList<Opacity>(
      find.ancestor(of: find.text(text), matching: find.byType(Opacity)),
    )
    .fold(1, (opacity, widget) => opacity * widget.opacity);

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Future<void> openDeleted(WidgetTester tester) async {
    await pumpScreen(tester, server);
    await tester.tap(find.text('Recently deleted'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens from below the sections and goes back', (tester) async {
    server.addItem('Milk');
    await pumpScreen(tester, server);
    expect(
      _top(tester, 'Recently deleted'),
      greaterThan(_top(tester, 'Manage categories') - 1),
    );

    await tester.tap(find.text('Recently deleted'));
    await tester.pumpAndSettle();

    expect(find.byType(DeletedScreen), findsOneWidget);
    expect(find.text('Deleted items are kept for 30 days'), findsOneWidget);
    expect(find.text('Nothing deleted in the last 30 days'), findsOneWidget);
    expect(find.byTooltip('Connect phone'), findsOneWidget);
    expect(find.byTooltip('Disconnect'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(DeletedScreen), findsNothing);
    expect(rowOf('Milk'), findsOneWidget);
  });

  testWidgets('groups items by the day they were deleted, newest first', (
    tester,
  ) async {
    server
      ..addDeleted('Old', deletedAt: _daysAgo(3))
      ..addDeleted('Bread', deletedAt: _daysAgo(1))
      ..addDeleted('Milk')
      ..addDeleted('Eggs', checked: true);
    final dated = dayLabel(_daysAgo(3), now: DateTime.now());

    await openDeleted(tester);

    final order = ['Today', 'Milk', 'Eggs', 'Yesterday', 'Bread', dated, 'Old'];
    final tops = [for (final text in order) _top(tester, text)];
    expect(tops, [...tops]..sort());
    expect(tops.toSet(), hasLength(order.length));

    final colors = Theme.of(tester.element(find.text('Milk'))).colorScheme;
    Color? colorOf(String title) =>
        tester.widget<Text>(find.text(title)).style?.color;
    expect(colorOf('Milk'), colors.onSurface);
    expect(colorOf('Eggs'), colors.onSurfaceVariant);
    expect(
      tester.widget<Text>(find.text('Today')).style?.color,
      colors.primary,
    );
  });

  testWidgets('restoring springs the row out and the rows below up', (
    tester,
  ) async {
    server
      ..addDeleted('Milk')
      ..addDeleted('Eggs');
    await openDeleted(tester);
    final from = _top(tester, 'Eggs');

    await tester.tap(_restore('Milk'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_opacityOf(tester, 'Milk'), lessThan(1));
    expect(_top(tester, 'Eggs'), from);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 16));
    final early = _top(tester, 'Eggs');
    await tester.pumpAndSettle();
    final to = _top(tester, 'Eggs');

    expect(find.text('Milk'), findsNothing);
    expect(to, lessThan(from - 40));
    expect(early, greaterThan(to + 20));
    expect(server.deleted.map((i) => i['title']), ['Eggs']);
  });

  testWidgets('a group heading leaves with its last row', (tester) async {
    server
      ..addDeleted('Bread', deletedAt: _daysAgo(1))
      ..addDeleted('Milk');
    await openDeleted(tester);

    await tester.tap(_restore('Bread'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_opacityOf(tester, 'Yesterday'), lessThan(0.5));
    expect(_opacityOf(tester, 'Today'), 1);
    await tester.pumpAndSettle();

    expect(find.text('Yesterday'), findsNothing);
    expect(find.text('Bread'), findsNothing);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('a restored item is in Uncategorized at once, even offline', (
    tester,
  ) async {
    final groceries = server.addCategory('Groceries');
    server
      ..addItem('Eggs', categoryId: groceries['id'] as int)
      ..addItem('Milk')
      ..addDeleted('Bread', checked: true);
    await openDeleted(tester);
    server.offline = true;

    await tester.tap(_restore('Bread'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing deleted in the last 30 days'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(rowOf('Bread'), findsOneWidget);
    expect(
      tester.getTopLeft(rowOf('Bread')).dy,
      greaterThan(tester.getTopLeft(find.text('Uncategorized')).dy),
    );
    expect(
      tester.getTopLeft(rowOf('Bread')).dy,
      greaterThan(tester.getTopLeft(rowOf('Milk')).dy),
    );
    expect(server.items.map((i) => i['title']), ['Eggs', 'Milk']);

    server.offline = false;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(server.items.map((i) => i['title']), ['Eggs', 'Milk', 'Bread']);
    expect(server.deleted, isEmpty);
  });

  testWidgets('an item deleted offline is on the page at once', (tester) async {
    server
      ..addItem('Milk')
      ..addItem('Eggs');
    await pumpScreen(tester, server);
    server.offline = true;

    await tester.tap(inRow('Milk', find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recently deleted'));
    await tester.pumpAndSettle();

    expect(find.text('Today'), findsOneWidget);
    expect(_deletedRow('Milk'), findsOneWidget);
    expect(find.text('Eggs'), findsNothing);
    expect(server.deleted, isEmpty);

    server.offline = false;
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(server.deleted.map((i) => i['title']), ['Milk']);
    expect(_deletedRow('Milk'), findsOneWidget);
  });
}
