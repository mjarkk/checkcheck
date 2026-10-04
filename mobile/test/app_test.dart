import 'dart:convert';

import 'package:checkcheck/main.dart';
import 'package:checkcheck/screens/checkbox.dart';
import 'package:checkcheck/screens/title_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

void main() {
  late FakeServer server;
  late FakeSettingsStore store;
  late MemoryChecklistCache cache;

  setUp(() {
    server = FakeServer(token: 'dev');
    store = FakeSettingsStore(url: 'http://localhost:8081', token: 'dev');
    cache = MemoryChecklistCache();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      CheckcheckApp(
        store: store,
        cache: cache,
        httpClient: server.client,
        connectWebSocket: server.connect,
      ),
    );
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder).dy;

  testWidgets('without settings it shows the setup screen', (tester) async {
    store = FakeSettingsStore();

    await pumpApp(tester);

    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('one section per category, then Uncategorized, empty ones too', (
    tester,
  ) async {
    final groceries = server.addCategory('Groceries');
    server.addCategory('Empty');
    server.addItem('Milk', categoryId: groceries['id'] as int);
    server.addItem('Call mum');

    await pumpApp(tester);

    expect(find.text('2 to do · 0 done'), findsOneWidget);
    for (final label in [
      'Add item to Empty',
      'Add item to Groceries',
      'Add item to Uncategorized',
    ]) {
      expect(addLine(label), findsOneWidget);
    }
    // The heading nearest above each row is its section's.
    String sectionOf(String title) {
      final at = top(tester, titleFieldOf(title));
      final above =
          [
            for (final heading in ['Empty', 'Groceries', 'Uncategorized'])
              if (top(tester, find.text(heading)) < at) heading,
          ]..sort(
            (a, b) =>
                top(tester, find.text(a)).compareTo(top(tester, find.text(b))),
          );
      return above.last;
    }

    expect(sectionOf('Milk'), 'Groceries');
    expect(sectionOf('Call mum'), 'Uncategorized');
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('checking an item sends only "checked" and moves it to Done', (
    tester,
  ) async {
    server.addItem('Milk');
    server.addItem('Eggs');
    await pumpApp(tester);

    await tester.tap(inRow('Milk', find.byType(ExpressiveCheckbox)));
    await tester.pumpAndSettle();

    expect(jsonDecode(patches(server).single), {'checked': true});
    expect(server.items.first['checked'], isTrue);
    expect(find.text('Done'), findsOneWidget);
    expect(
      top(tester, find.text('Done')),
      lessThan(top(tester, titleFieldOf('Milk'))),
    );
    expect(
      top(tester, titleFieldOf('Eggs')),
      lessThan(top(tester, find.text('Done'))),
    );
    expect(find.text('1 to do · 1 done'), findsOneWidget);
  });

  testWidgets('an Add item line adds to its section and stays ready', (
    tester,
  ) async {
    final groceries = server.addCategory('Groceries');
    await pumpApp(tester);

    await tester.enterText(addField('Add item to Groceries'), 'Eggs');
    await pressReturn(tester);
    await tester.pumpAndSettle();

    expect(server.items.single['title'], 'Eggs');
    expect(server.items.single['category_id'], groceries['id']);
    expect(rowOf('Eggs'), findsOneWidget);
    expect(find.text('1 to do · 0 done'), findsOneWidget);
    final field = tester.widget<EditableText>(
      addField('Add item to Groceries'),
    );
    expect(field.controller.text, isEmpty);
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('a title saves itself after a typing pause', (tester) async {
    server.addItem('Milk');
    await pumpApp(tester);

    await tester.enterText(titleFieldOf('Milk'), 'Milks');
    await tester.pump(saveDelay);
    await tester.pumpAndSettle();

    expect(jsonDecode(patches(server).single), {'title': 'Milks'});
    expect(server.items.single['title'], 'Milks');
  });

  testWidgets('the delete button removes the item after its exit', (
    tester,
  ) async {
    server.addItem('Milk');
    await pumpApp(tester);

    await tester.tap(inRow('Milk', find.byTooltip('Delete')));
    await tester.pump();
    expect(server.requests.where((r) => r.method == 'DELETE'), isEmpty);
    await tester.pumpAndSettle();

    expect(server.requests.last.method, 'DELETE');
    expect(server.items, isEmpty);
    expect(rowOf('Milk'), findsNothing);
    expect(find.text('Nothing to do'), findsOneWidget);
  });

  testWidgets('Manage categories opens the categories dialog', (tester) async {
    await pumpApp(tester);

    await tester.ensureVisible(find.text('Manage categories'));
    await tester.tap(find.text('Manage categories'));
    await tester.pumpAndSettle();

    expect(find.text('Categories'), findsOneWidget);
  });

  testWidgets('Connect phone shows the connected server', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Connect phone'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, 'http://localhost:8081'),
      findsOneWidget,
    );
    expect(find.text('Copy link'), findsOneWidget);
  });

  testWidgets('opens on the saved list when the server is unreachable', (
    tester,
  ) async {
    server.addItem('Milk');
    await pumpApp(tester);
    await tester.tap(find.byType(ExpressiveCheckbox));
    await tester.pumpWidget(const SizedBox());
    server.offline = true;

    await pumpApp(tester);

    expect(rowOf('Milk'), findsOneWidget);
    expect(find.text('All 1 done'), findsOneWidget);
    expect(find.text("Can't reach the server"), findsOneWidget);
  });

  testWidgets('without a saved list a failed load offers to try again', (
    tester,
  ) async {
    server.offline = true;
    await pumpApp(tester);

    expect(find.text("Couldn't load your checklist."), findsOneWidget);

    server.offline = false;
    server.addItem('Milk');
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(rowOf('Milk'), findsOneWidget);
  });

  testWidgets('disconnecting asks, then deletes the saved list', (
    tester,
  ) async {
    server.addItem('Milk');
    await pumpApp(tester);
    expect(cache.data, isNotNull);

    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Connect'), findsOneWidget);
    expect(cache.data, isNull);
  });

  testWidgets('a 401 returns to setup with the URL kept and token cleared', (
    tester,
  ) async {
    store = FakeSettingsStore(url: 'http://localhost:8081', token: 'stale');

    await pumpApp(tester);

    expect(find.text('Token rejected — please sign in again'), findsOneWidget);
    expect(find.text('http://localhost:8081'), findsOneWidget);
    expect(store.token, isNull);
    expect(store.url, 'http://localhost:8081');
  });
}
