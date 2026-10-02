import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _LogoPainter(colors.primary, colors.onPrimary),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.background, this.tick);

  final Color background;
  final Color tick;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn in the 32-unit space of server/web/src/favicon.svg.
    canvas.scale(size.width / 32);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 32, 32),
        const Radius.circular(10),
      ),
      Paint()..color = background,
    );
    canvas.drawPath(
      Path()
        ..moveTo(9, 16.5)
        ..lineTo(13.5, 21)
        ..lineTo(23, 11.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = tick,
    );
  }

  @override
  bool shouldRepaint(_LogoPainter old) =>
      old.background != background || old.tick != tick;
}

/// The web's M3 state layer: [color] at 10% while pressed, on a shape whose
/// corners spring from [radius] to [pressedRadius].
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.color,
    required this.radius,
    required this.child,
    double? pressedRadius,
  }) : pressedRadius = pressedRadius ?? radius;

  final VoidCallback? onTap;
  final Color color;
  final double radius;
  final double pressedRadius;
  final Widget child;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final pressed = _pressed && enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: enabled ? (_) => _press(true) : null,
      onTapUp: enabled ? (_) => _press(false) : null,
      onTapCancel: () => _press(false),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: pressed ? widget.pressedRadius : widget.radius),
        duration: fastSpatial.duration,
        curve: fastSpatial,
        builder: (context, radius, child) => TweenAnimationBuilder<double>(
          tween: Tween(end: pressed ? 0.1 : 0),
          duration: effects.duration,
          curve: effects,
          builder: (context, layer, child) => DecoratedBox(
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: layer.clamp(0, 1)),
              borderRadius: BorderRadius.circular(math.max(0, radius)),
            ),
            child: child,
          ),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// The web's `.icon-btn`: 40px, pill-shaped until pressed.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.semanticLabel,
    this.color,
    this.size = 40,
    this.iconSize = 24,
  });

  final Widget icon;
  final String tooltip;

  /// Read out instead of [tooltip] when the button needs more context.
  final String? semanticLabel;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = onPressed == null
        ? colors.onSurface.withValues(alpha: 0.38)
        : color ?? colors.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: semanticLabel != null,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: semanticLabel,
        child: Pressable(
          onTap: onPressed,
          color: foreground,
          radius: 20,
          pressedRadius: 12,
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(color: foreground, size: iconSize),
                child: icon,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The web's `.drag-handle`. Pointer-only, so hidden from assistive tech
/// rather than a button that does nothing.
class DragHandle extends StatefulWidget {
  const DragHandle({super.key, this.onPointerDown});

  final PointerDownEventListener? onPointerDown;

  /// `--handle-width` on touch screens.
  static const width = 36.0;

  @override
  State<DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<DragHandle> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return ExcludeSemantics(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _press(true);
          widget.onPointerDown?.call(event);
        },
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _pressed ? 0.1 : 0),
          duration: effects.duration,
          curve: effects,
          builder: (context, layer, child) => DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: layer.clamp(0, 1)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          ),
          child: SizedBox(
            width: DragHandle.width,
            height: 40,
            child: Icon(Icons.drag_indicator, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}

/// Lays [child] out whole but gives its parent [top] and [bottom] fewer
/// pixels, like CSS negative margins: it reaches over its neighbours, which
/// take the taps there.
class Overhang extends SingleChildRenderObjectWidget {
  const Overhang({super.key, this.top = 0, this.bottom = 0, super.child});

  final double top;
  final double bottom;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderOverhang(top, bottom);

  @override
  void updateRenderObject(BuildContext context, RenderOverhang renderObject) {
    renderObject
      ..top = top
      ..bottom = bottom;
  }
}

class RenderOverhang extends RenderShiftedBox {
  RenderOverhang(this._top, this._bottom) : super(null);

  double _top;
  set top(double value) {
    if (value == _top) return;
    _top = value;
    markNeedsLayout();
  }

  double _bottom;
  set bottom(double value) {
    if (value == _bottom) return;
    _bottom = value;
    markNeedsLayout();
  }

  double get _overlap => _top + _bottom;

  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      constraints.copyWith(
        minHeight: constraints.minHeight + _overlap,
        maxHeight: constraints.maxHeight + _overlap,
      );

  Size _sizeFor(BoxConstraints constraints, Size child) => constraints
      .constrain(Size(child.width, math.max(0, child.height - _overlap)));

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(0, super.computeMinIntrinsicHeight(width) - _overlap);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(0, super.computeMaxIntrinsicHeight(width) - _overlap);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return _sizeFor(
      constraints,
      child.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = _sizeFor(constraints, child.size);
    (child.parentData! as BoxParentData).offset = Offset(0, -_top);
  }
}

/// No look of its own, not even the theme's field borders: what is around
/// the field draws it.
InputDecoration bareDecoration({String? hintText, TextStyle? hintStyle}) =>
    InputDecoration.collapsed(
      hintText: hintText,
      hintStyle: hintStyle,
    ).copyWith(
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
    );

/// Takes focus with the text selected. Enter, the apply button and leaving
/// the field report the text; Escape reports null.
class InlineEdit extends StatefulWidget {
  const InlineEdit({
    super.key,
    required this.initial,
    required this.label,
    required this.maxLength,
    required this.onDone,
  });

  final String initial;
  final String label;
  final int maxLength;
  final ValueChanged<String?> onDone;

  @override
  State<InlineEdit> createState() => _InlineEditState();
}

class _InlineEditState extends State<InlineEdit> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  final _focus = FocusNode();
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _finish(_controller.text);
    });
  }

  // Unfocusing on the way out reports again; only the first one counts.
  void _finish(String? value) {
    if (_finished) return;
    _finished = true;
    widget.onDone(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      spacing: 4,
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  _finish(null),
            },
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
              ),
              // In front, like the web's inset box-shadow: it takes no room.
              foregroundDecoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: colors.primary, width: 3),
                ),
              ),
              child: Semantics(
                label: widget.label,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  style: theme.textTheme.bodyLarge,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(widget.maxLength),
                  ],
                  onSubmitted: _finish,
                  onTapOutside: (_) => _focus.unfocus(),
                  decoration: bareDecoration(),
                ),
              ),
            ),
          ),
        ),
        // Inside the field's tap region, so pressing it doesn't blur the
        // field first.
        TextFieldTapRegion(
          child: AppIconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Apply',
            color: colors.primary,
            onPressed: () => _finish(_controller.text),
          ),
        ),
      ],
    );
  }
}

/// An inline error, for places a SnackBar would be hidden behind (dialogs).
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FadeIn(
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            spacing: 8,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onErrorContainer,
                    ),
                  ),
                ),
              ),
              AppIconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss',
                color: colors.onErrorContainer,
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(
    this.message, {
    super.key,
    this.action,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 56),
  });

  final String message;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
