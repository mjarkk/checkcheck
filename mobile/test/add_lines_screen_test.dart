import 'package:checkcheck/screens/add_lines_screen.dart';
import 'package:checkcheck/screens/checkbox.dart';
import 'package:checkcheck/screens/item_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'screen_helpers.dart';

const _message = 'Choose the lines to add to “Groceries”.';

void main() {
  late bool closed;
  late List<String>? result;

  Future<void> openScreen(WidgetTester tester, List<String> lines) async {
    tester.view
      ..physicalSize = const Size(402, 874) * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final model = await openModel(FakeServer());
    closed = false;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.push(
                context,
                MaterialPageRoute<List<String>>(
                  builder: (_) => AddLinesScreen(
                    model: model,
                    onDisconnect: () {},
                    lines: lines,
                    message: _message,
                  ),
                ),
              );
              closed = true;
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Finder checkboxOf(String line) => find.byWidgetPredicate(
    (widget) => widget is ExpressiveCheckbox && widget.semanticLabel == line,
  );

  bool checked(WidgetTester tester, String line) =>
      tester.widget<ExpressiveCheckbox>(checkboxOf(line)).value;

  Finder ok() => find.widgetWithText(FilledButton, 'OK');

  double top(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder).dy;

  testWidgets('lists the lines in order under the message, all checked', (
    tester,
  ) async {
    await openScreen(tester, ['Eggs', 'Bread', 'Jam']);

    expect(find.text('Add items'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text(_message), findsOneWidget);
    final tops = [
      for (final line in ['Eggs', 'Bread', 'Jam']) top(tester, find.text(line)),
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(
      ['Eggs', 'Bread', 'Jam'].map((line) => checked(tester, line)),
      everyElement(isTrue),
    );
    // As wide as the checklist's rows.
    expect(tester.getSize(find.byType(RowSurface).first).width, 402 - 32);
  });

  testWidgets('a tap anywhere on a row toggles it', (tester) async {
    await openScreen(tester, ['Eggs', 'Bread']);

    await tester.tap(find.text('Eggs'));
    await tester.pumpAndSettle();
    expect(checked(tester, 'Eggs'), isFalse);

    await tester.tap(checkboxOf('Eggs'));
    await tester.pumpAndSettle();
    expect(checked(tester, 'Eggs'), isTrue);

    final row = find.ancestor(
      of: find.text('Bread'),
      matching: find.byType(RowSurface),
    );
    await tester.tapAt(tester.getRect(row).centerRight - const Offset(4, 0));
    await tester.pumpAndSettle();
    expect(checked(tester, 'Bread'), isFalse);
  });

  testWidgets('OK is disabled while nothing is checked', (tester) async {
    await openScreen(tester, ['Eggs', 'Bread']);

    await tester.tap(find.text('Eggs'));
    await tester.tap(find.text('Bread'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(ok()).onPressed, isNull);

    await tester.tap(find.text('Bread'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(ok()).onPressed, isNotNull);
  });

  testWidgets('OK goes back with the checked lines in order', (tester) async {
    await openScreen(tester, ['Eggs', 'Bread', 'Jam']);

    await tester.tap(find.text('Bread'));
    await tester.tap(ok());
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, ['Eggs', 'Jam']);
    expect(find.text('Add items'), findsNothing);
  });

  testWidgets('Cancel and the back button go back with nothing', (
    tester,
  ) async {
    await openScreen(tester, ['Eggs', 'Bread']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);

    await openScreen(tester, ['Eggs', 'Bread']);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets(
    'the back swipe goes back with nothing',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await openScreen(tester, ['Eggs', 'Bread']);

      await tester.dragFrom(const Offset(4, 400), const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result, isNull);
      expect(find.text('Add items'), findsNothing);
    },
  );

  testWidgets('the bar stays put while the lines scroll, clearing the last', (
    tester,
  ) async {
    await openScreen(tester, [for (var i = 1; i <= 40; i++) 'Line $i']);
    final okTop = top(tester, ok());
    expect(tester.getBottomLeft(ok()).dy, lessThan(874));

    await tester.drag(find.text('Line 5'), const Offset(0, -5000));
    await tester.pumpAndSettle();

    expect(top(tester, ok()), okTop);
    expect(tester.getBottomLeft(find.text('Line 40')).dy, lessThan(okTop - 12));
    await tester.tap(ok());
    await tester.pumpAndSettle();
    expect(result, hasLength(40));
  });

  testWidgets('leaves out duplicates, ignoring case, and says how many', (
    tester,
  ) async {
    await openScreen(tester, ['Milk', 'Eggs', 'milk', 'EGGS', 'Bread']);

    expect(
      find.text('$_message 2\u00a0duplicate lines were left out.'),
      findsOneWidget,
    );
    expect(find.byType(ExpressiveCheckbox), findsNWidgets(3));
    await tester.tap(ok());
    await tester.pumpAndSettle();
    expect(result, ['Milk', 'Eggs', 'Bread']);

    await openScreen(tester, ['Milk', 'milk']);
    expect(
      find.text('$_message 1\u00a0duplicate line was left out.'),
      findsOneWidget,
    );
    expect(find.byType(ExpressiveCheckbox), findsOneWidget);
  });
}
