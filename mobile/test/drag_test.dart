import 'package:checkcheck/screens/controls.dart';
import 'package:checkcheck/screens/list_drag.dart';
import 'package:checkcheck/screens/new_category.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Finder handleOf(String title) => inRow(title, find.byType(DragHandle));

  Future<_Finger> grab(WidgetTester tester, String title) async {
    final at = tester.getCenter(handleOf(title));
    final finger = _Finger(tester, await tester.startGesture(at), at);
    await tester.pump();
    return finger;
  }

  List<String> titles() => [
    for (final item in server.items) item['title'] as String,
  ];

  testWidgets('a short pull springs back without moving anything', (
    tester,
  ) async {
    server
      ..addItem('Oat milk')
      ..addItem('Bread');
    await pumpScreen(tester, server);

    final finger = await grab(tester, 'Oat milk');
    await finger.moveBy(const Offset(0, 40));
    expect(find.byType(DragGap), findsNothing);
    await finger.up();

    expect(patches(server), isEmpty);
  });

  testWidgets('dragging a row below the next one reorders them', (
    tester,
  ) async {
    server
      ..addItem('Oat milk')
      ..addItem('Bread');
    await pumpScreen(tester, server);

    final finger = await grab(tester, 'Oat milk');
    await finger.moveBy(const Offset(0, 90));
    expect(find.byType(DragGap), findsOneWidget);
    await finger.up();

    expect(patches(server), ['{"before_id":null}']);
    expect(titles(), ['Bread', 'Oat milk']);
    expect(find.byType(DragGap), findsNothing);
  });

  testWidgets('lifting a row keeps the page where it is', (tester) async {
    final groceries = server.addCategory('Groceries')['id'] as int;
    server
      ..addItem('Oat milk', categoryId: groceries)
      ..addItem('Bread', categoryId: groceries)
      ..addItem('Call mum');
    await pumpScreen(tester, server);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );

    final finger = await grab(tester, 'Oat milk');
    await finger.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(DragGap), findsOneWidget);
    expect(scrollable.position.pixels, 0);
    await finger.up();
  });

  testWidgets('dropping into the Done list checks the item', (tester) async {
    server
      ..addItem('Oat milk')
      ..addItem('Eggs', checked: true);
    await pumpScreen(tester, server);

    final finger = await grab(tester, 'Oat milk');
    await finger.moveBy(const Offset(0, 60));
    await finger.moveTo(tester.getCenter(rowOf('Eggs')) + const Offset(0, 40));
    await finger.up();

    expect(server.items.first['checked'], isTrue);
    expect(patches(server).single, contains('"checked":true'));
  });

  testWidgets('dropping into another section changes the category', (
    tester,
  ) async {
    final work = server.addCategory('Work')['id'] as int;
    server
      ..addItem('Report', categoryId: work)
      ..addItem('Call mum');
    await pumpScreen(tester, server);

    final finger = await grab(tester, 'Call mum');
    await finger.moveBy(const Offset(0, -60));
    await finger.moveTo(
      tester.getCenter(rowOf('Report')) + const Offset(0, 20),
    );
    await finger.up();

    expect(server.items.last['category_id'], work);
  });

  testWidgets('dropping on the circle asks for a category and moves the '
      'item into it', (tester) async {
    server
      ..addItem('Oat milk')
      ..addItem('Bread');
    await pumpScreen(tester, server);

    final finger = await grab(tester, 'Oat milk');
    await finger.moveBy(const Offset(0, 60));
    await finger.moveTo(tester.getCenter(find.byType(NewCategoryDrop)));
    await finger.up();

    expect(find.text('“Oat milk” moves into it.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Groceries');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final groceries = server.categories.single;
    expect(groceries['name'], 'Groceries');
    expect(server.items.first['category_id'], groceries['id']);
    expect(find.text('Groceries'), findsOneWidget);
  });
}

/// A pointer that moves in small steps, as a finger does, with frames
/// running in between.
class _Finger {
  _Finger(this.tester, this.gesture, this.at);

  final WidgetTester tester;
  final TestGesture gesture;
  Offset at;

  Future<void> moveTo(Offset to) => moveBy(to - at);

  Future<void> moveBy(Offset by) async {
    const steps = 12;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(by / steps.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    at += by;
  }

  Future<void> up() async {
    await gesture.up();
    await tester.pumpAndSettle();
  }
}
