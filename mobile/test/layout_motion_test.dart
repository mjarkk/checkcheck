import 'package:checkcheck/screens/layout_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _frame = Duration(milliseconds: 16);

Widget _app(Widget child, {bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 300, height: 600, child: child),
    ),
  ),
);

Widget _box(String key, {double height = 50, bool enter = false}) => Motion(
  key: ValueKey(key),
  motionKey: key,
  enter: enter,
  child: SizedBox(height: height, child: Text(key)),
);

Widget _column(LayoutMotion motion, List<Widget> children) => MotionScope(
  controller: motion,
  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
);

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('a moved box is drawn where it was, then springs to its place', (
    tester,
  ) async {
    final motion = LayoutMotion();
    await tester.pumpWidget(_app(_column(motion, [_box('b')])));
    expect(_top(tester, 'b'), 0);

    await tester.pumpWidget(_app(_column(motion, [_box('a'), _box('b')])));
    expect(_top(tester, 'b'), 0);
    expect(motion.layoutRectOf('b')!.top, 50);

    await tester.pump(_frame);
    final early = _top(tester, 'b');
    expect(early, greaterThan(0));
    expect(early, lessThan(50));

    await tester.pumpAndSettle();
    expect(_top(tester, 'b'), 50);
  });
}
