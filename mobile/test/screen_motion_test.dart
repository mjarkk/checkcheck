import 'package:checkcheck/screens/checkbox.dart';
import 'package:checkcheck/screens/spring.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  testWidgets('a checked row springs from its place into the Done list', (
    tester,
  ) async {
    server
      ..addItem('Oat milk')
      ..addItem('Bread')
      ..addItem('Eggs', checked: true);
    await pumpScreen(tester, server);
    final from = tester.getTopLeft(titleFieldOf('Oat milk')).dy;

    await tester.tap(inRow('Oat milk', find.byType(ExpressiveCheckbox)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final early = tester.getTopLeft(titleFieldOf('Oat milk')).dy;
    await tester.pumpAndSettle();
    final to = tester.getTopLeft(titleFieldOf('Oat milk')).dy;

    expect(to, greaterThan(from + 100));
    expect(early, lessThan(from + (to - from) / 2));
  });

  testWidgets('rows below a deleted one close up with a spring', (
    tester,
  ) async {
    server
      ..addItem('Oat milk')
      ..addItem('Bread');
    await pumpScreen(tester, server);
    final from = tester.getTopLeft(titleFieldOf('Bread')).dy;

    await tester.tap(inRow('Oat milk', find.byTooltip('Delete')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 16));
    final early = tester.getTopLeft(titleFieldOf('Bread')).dy;
    await tester.pumpAndSettle();
    final to = tester.getTopLeft(titleFieldOf('Bread')).dy;

    expect(to, lessThan(from - 40));
    expect(early, greaterThan(to + 20));
    expect(server.items.map((i) => i['title']), ['Bread']);
  });

  testWidgets('checks and deletes in quick succession hurry all motion', (
    tester,
  ) async {
    server
      ..addItem('Oat milk')
      ..addItem('Bread')
      ..addItem('Eggs');
    await pumpScreen(tester, server);

    // Bottom up, so each row tapped stays put while the ones below it move.
    await tester.tap(inRow('Eggs', find.byType(ExpressiveCheckbox)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(timeDilation, 1);

    await tester.tap(inRow('Bread', find.byTooltip('Delete')));
    await tester.pump();
    expect(timeDilation, 0.5);

    await tester.pump(hurryWindow - const Duration(milliseconds: 100));
    await tester.tap(inRow('Oat milk', find.byType(ExpressiveCheckbox)));
    await tester.pump(hurryWindow - const Duration(milliseconds: 1));
    expect(timeDilation, 0.5);

    await tester.pump(const Duration(milliseconds: 1));
    expect(timeDilation, 1);
    await tester.pumpAndSettle();
  });
}
