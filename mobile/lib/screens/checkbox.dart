import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'motion.dart';

/// The web app's checkbox: a rounded square that springs into a filled
/// circle while the tick draws itself in.
class ExpressiveCheckbox extends StatefulWidget {
  const ExpressiveCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String? semanticLabel;

  @override
  State<ExpressiveCheckbox> createState() => _ExpressiveCheckboxState();
}

class _ExpressiveCheckboxState extends State<ExpressiveCheckbox>
    with TickerProviderStateMixin {
  late final _shape = _controller(fastSpatial);
  late final _fill = _controller(effects);
  late final _tick = _controller(defaultSpatial);
  bool _pressed = false;

  // Unbounded, or the springs' overshoot would be clamped away.
  AnimationController _controller(SpringCurve spring) =>
      AnimationController.unbounded(
        vsync: this,
        duration: spring.duration,
        value: widget.value ? 1 : 0,
      );

  @override
  void didUpdateWidget(ExpressiveCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    final target = widget.value ? 1.0 : 0.0;
    _shape.animateTo(target, curve: fastSpatial);
    _fill.animateTo(target, curve: effects);
    _tick.animateTo(target, curve: defaultSpatial);
  }

  @override
  void dispose() {
    _shape.dispose();
    _fill.dispose();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final layer = widget.value ? colors.primary : colors.onSurface;
    return Semantics(
      checked: widget.value,
      label: widget.semanticLabel,
      child: InkResponse(
        onTap: () => widget.onChanged(!widget.value),
        onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
        radius: 20,
        highlightShape: BoxShape.circle,
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? layer.withValues(alpha: 0.1)
              : Colors.transparent,
        ),
        child: SizedBox.square(
          dimension: 40,
          child: Center(
            child: AnimatedScale(
              scale: _pressed ? 0.8 : 1,
              duration: fastSpatial.duration,
              curve: fastSpatial,
              child: CustomPaint(
                size: const Size.square(20),
                painter: _BoxPainter(
                  shape: _shape,
                  fill: _fill,
                  tick: _tick,
                  outline: colors.onSurfaceVariant,
                  color: colors.primary,
                  tickColor: colors.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.shape,
    required this.fill,
    required this.tick,
    required this.outline,
    required this.color,
    required this.tickColor,
  }) : super(repaint: Listenable.merge([shape, fill, tick]));

  final Animation<double> shape;
  final Animation<double> fill;
  final Animation<double> tick;
  final Color outline;
  final Color color;
  final Color tickColor;

  // The web checkmark's path, in its 24-unit viewBox.
  static final _tickPath = Path()
    ..moveTo(5.5, 12.5)
    ..lineTo(9.7, 16.7)
    ..lineTo(18.5, 7.3);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = 1 + 0.1 * shape.value;
    canvas
      ..translate(center.dx, center.dy)
      ..scale(scale)
      ..translate(-center.dx, -center.dy);

    final half = size.width / 2;
    final radius = Radius.circular(
      lerpDouble(6, half, shape.value)!.clamp(0, half),
    );
    final box = RRect.fromRectAndRadius(Offset.zero & size, radius);
    final f = fill.value.clamp(0.0, 1.0);
    canvas
      ..drawRRect(box, Paint()..color = color.withValues(alpha: f))
      ..drawRRect(
        box.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Color.lerp(outline, color, f)!,
      );

    final t = tick.value.clamp(0.0, 1.0);
    if (t == 0) return;
    // The tick's 16px box sits centred in the 20px box, as on the web.
    const unit = 16 / 24;
    canvas
      ..translate(2, 2)
      ..scale(unit);
    final metric = _tickPath.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * t),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = tickColor,
    );
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.outline != outline ||
      old.color != color ||
      old.tickColor != tickColor;
}
