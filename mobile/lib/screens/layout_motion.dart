import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion.dart';
import 'spring.dart';

/// Where a box is drawn: its unscaled box's global top-left, its scale about
/// its centre, and their velocities (px/s and 1/s).
class MotionVisual {
  const MotionVisual(
    this.topLeft, {
    this.scale = 1,
    this.velocity = Offset.zero,
    this.scaleVelocity = 0,
  });

  final Offset topLeft;
  final double scale;
  final Offset velocity;
  final double scaleVelocity;
}

/// How the box under [key] starts in the next layout change, instead of from
/// where it was.
sealed class MotionStart {
  const MotionStart(this.key);

  /// From [visual], on [Springs.drop].
  const factory MotionStart.visual(Object key, MotionVisual visual) =
      _FromVisual;

  /// Shrunk to [scale] around the global [point], on [Springs.fly].
  const factory MotionStart.point(Object key, Offset point, {double scale}) =
      _FromPoint;

  final Object key;
}

final class _FromVisual extends MotionStart {
  const _FromVisual(super.key, this.visual);

  final MotionVisual visual;
}

final class _FromPoint extends MotionStart {
  const _FromPoint(super.key, this.point, {this.scale = 0.1});

  final Offset point;
  final double scale;
}

typedef _Pass = ({Object? anchor, SpringConfig config, MotionStart? start});

typedef _ScrollRange = ({double pixels, double min, double max});

const _noPass = (anchor: null, config: Springs.layout, start: null);

/// The web's `item-in`: from 12px lower, at 0.96 and transparent.
const _enterDuration = 0.35;
const _ghostDuration = 0.2;

/// motion.ts's layout passes for one [MotionScope]: every [Motion] that moved
/// since the previous layout is drawn where it was and springs to its new
/// place, also when it remounts elsewhere under the same key.
///
/// Changes animate when the scope or a [Motion] in it rebuilt, like the web's
/// pass after a commit; other relayouts (text wrapping) only take note.
class LayoutMotion {
  final _entries = <Object, _Entry>{};

  /// Target key → source key whose last place a newly mounted box starts from.
  final _inherited = <Object, Object>{};
  final _ghosts = <_Ghost>[];
  _Pass? _next;
  _MotionScopeRender? _render;
  SpringLoop? _loop;

  bool get _reduced => _loop?.reducedMotion ?? false;

  /// Options for the next animated layout change only. [anchor] keeps that
  /// box where it is on screen by scrolling (needs [MotionScope.sliver]).
  void prepare({
    Object? anchor,
    SpringConfig config = Springs.layout,
    MotionStart? start,
  }) {
    _next = (anchor: anchor, config: config, start: start);
    _requestPass();
  }

  /// The box mounting under [to] starts from where [from] was, instead of
  /// entering.
  void inherit(Object from, Object to) => _inherited[to] = from;

  /// Springs the box towards [offset] from its layout position.
  void pullTo(Object key, Offset offset, SpringConfig config) {
    final entry = _entries[key];
    if (entry == null) return;
    entry.configure(config);
    entry.x.target = offset.dx;
    entry.y.target = offset.dy;
    _run(entry);
  }

  /// Puts the box back on its layout position at once (its scale is kept).
  void reset(Object key) {
    final entry = _entries[key];
    if (entry == null) return;
    entry.x.jump(0);
    entry.y.jump(0);
    entry.box?.markNeedsCompositedLayerUpdate();
  }

  bool isMounted(Object key) => _entries[key]?.box?.attached ?? false;

  /// The mounted box registered under [key].
  RenderBox? boxOf(Object key) {
    final box = _entries[key]?.box;
    return box != null && box.attached && box.hasSize ? box : null;
  }

  /// The box's global rect as laid out, ignoring its motion; null while it
  /// isn't mounted.
  Rect? layoutRectOf(Object key) {
    final box = _entries[key]?.box;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  MotionVisual? visualOf(Object key) {
    final entry = _entries[key];
    final rect = layoutRectOf(key);
    if (entry == null || rect == null) return null;
    return MotionVisual(
      rect.topLeft + Offset(entry.x.value, entry.y.value),
      scale: entry.scale.value,
      velocity: Offset(entry.x.velocity, entry.y.velocity),
      scaleVelocity: entry.scale.velocity,
    );
  }

  /// Keys of the mounted boxes inside [ancestor], top to bottom.
  List<Object> keysWithin(RenderObject ancestor) {
    final found = <(Object, double)>[];
    for (final MapEntry(:key, value: entry) in _entries.entries) {
      final box = entry.box;
      if (box == null || !box.attached || !box.hasSize) continue;
      for (RenderObject? node = box; node != null; node = node.parent) {
        if (node != ancestor) continue;
        found.add((key, box.localToGlobal(Offset.zero).dy));
        break;
      }
    }
    found.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (key, _) in found) key];
  }

  /// The topmost mounted box whose bottom is below the global [top].
  Object? firstVisibleKey(double top) {
    Object? first;
    var firstTop = double.infinity;
    for (final MapEntry(:key) in _entries.entries) {
      final rect = layoutRectOf(key);
      if (rect == null || rect.bottom <= top || rect.top >= firstTop) continue;
      first = key;
      firstTop = rect.top;
    }
    return first;
  }

  @visibleForTesting
  int get debugGhostCount => _ghosts.length;

  void _requestPass() => _render?._requestPass();

  void _run(SpringAnimation animation) {
    _loop?.run(animation);
    if (animation is _Entry) animation.box?.markNeedsCompositedLayerUpdate();
  }

  _Entry _attach(Object key, RenderMotion box) {
    final entry = _entries.putIfAbsent(key, () => _Entry(this));
    entry.box = box;
    entry.releaseLeft();
    // A remount carries on the old box's motion, so it doesn't enter as well.
    if (box.enter &&
        entry.last == null &&
        !_inherited.containsKey(key) &&
        !_reduced) {
      entry.entering = 0;
      _run(entry);
    }
    return entry;
  }

  /// [layer] is kept for a ghost: by the next pass the box may be disposed.
  void _detach(_Entry entry, RenderMotion box, {TransformLayer? layer}) {
    if (entry.box != box) return;
    entry.box = null;
    if (layer == null) return;
    entry.left = box;
    entry.leftLayer = LayerHandle(layer);
  }

  /// Measures every box in [content]'s coordinates (so scrolling isn't
  /// movement) and, when [animate], springs the moved ones from where they
  /// were. Returns the scroll correction that keeps the anchor in place.
  double _pass(
    RenderBox content, {
    required bool animate,
    _ScrollRange? scroll,
  }) {
    final pass = animate ? _next ?? _noPass : _noPass;
    if (animate) _next = null;

    final boxes = <_Entry, Rect>{};
    for (final entry in _entries.values) {
      final box = entry.box;
      if (box == null || !box.hasSize || box.size == Size.zero) continue;
      final at = _offsetIn(box, content);
      if (at != null) boxes[entry] = at & box.size;
    }

    _inherited.removeWhere((to, from) {
      final entry = _entries[to];
      if (entry?.box == null) return false;
      entry!.last ??= _entries[from]?.last;
      return true;
    });

    var scrolled = 0.0;
    if ((pass.anchor, scroll) case (final Object anchor, final range?)) {
      final entry = _entries[anchor];
      final box = boxes[entry];
      final last = entry?.last;
      if (box != null && last != null) {
        final to = (range.pixels + box.top - last.dy).clamp(
          range.min,
          range.max,
        );
        scrolled = to - range.pixels;
      }
    }

    for (final MapEntry(:key, value: entry) in _entries.entries) {
      final box = boxes[entry];
      if (box == null) continue;
      final last = entry.last;
      if (pass.start case final start? when start.key == key) {
        entry.start = start;
        entry.configure(start is _FromVisual ? Springs.drop : Springs.fly);
        _run(entry);
      } else if (animate && last != null && !_reduced) {
        final dx = last.dx - box.left;
        final dy = last.dy - box.top + scrolled;
        if (dx.abs() >= 0.5 || dy.abs() >= 0.5) {
          entry.x.value += dx;
          entry.y.value += dy;
          entry.configure(pass.config);
          _run(entry);
        }
      }
      entry.last = box.topLeft;
      entry.size = box.size;
    }

    _entries.removeWhere((key, entry) {
      if (entry.box != null) return false;
      final left = entry.left;
      final layer = entry.leftLayer;
      final last = entry.last;
      if (animate &&
          !_reduced &&
          left != null &&
          !left.attached &&
          layer != null &&
          last != null) {
        final ghost = _Ghost(
          this,
          layer.layer!,
          last + Offset(entry.x.value, entry.y.value + scrolled),
          entry.size,
        );
        _ghosts.add(ghost);
        _run(ghost);
      }
      entry.releaseLeft();
      _loop?.remove(entry);
      return true;
    });
    return scrolled;
  }

  void _paintGhosts(PaintingContext context, Offset origin) {
    for (final ghost in _ghosts) {
      ghost.paint(context, origin);
    }
  }

  void _bind(SpringLoop loop) => _loop = loop;

  void _unbind(SpringLoop loop) {
    if (_loop != loop) return;
    _loop = null;
    for (final ghost in _ghosts) {
      ghost.layer.layer = null;
    }
    _ghosts.clear();
    for (final entry in _entries.values) {
      entry.releaseLeft();
    }
  }
}

/// [box]'s layout offset in [ancestor], leaving out every paint transform.
Offset? _offsetIn(RenderObject box, RenderObject ancestor) {
  var offset = Offset.zero;
  RenderObject node = box;
  while (node != ancestor) {
    final parent = node.parent;
    if (parent == null) return null;
    switch (node.parentData) {
      case BoxParentData(offset: final at):
        offset += at;
      // A proxy's child sits on its origin; only paint transforms move it.
      case _ when node is RenderBox && parent is RenderBox:
        break;
      default:
        final transform = Matrix4.identity();
        parent.applyPaintTransform(node, transform);
        offset += MatrixUtils.getAsTranslation(transform) ?? Offset.zero;
    }
    node = parent;
  }
  return offset;
}

/// Translates by [offset] and scales by [scale] about the centre of [size].
Matrix4 _transform(Size size, Offset offset, double scale) {
  final cx = size.width / 2;
  final cy = size.height / 2;
  return Matrix4(
    scale, 0, 0, 0, //
    0, scale, 0, 0, //
    0, 0, 1, 0, //
    offset.dx + cx - scale * cx, offset.dy + cy - scale * cy, 0, 1,
  );
}

class _Entry implements SpringAnimation {
  _Entry(this.owner);

  final LayoutMotion owner;
  RenderMotion? box;

  /// Top-left of the box at the last pass, in the scope's content.
  Offset? last;
  Size size = Size.zero;
  final x = Spring();
  final y = Spring();
  final scale = Spring(1, 0.001);

  /// Waits for the box's paint, where its global place is final.
  MotionStart? start;

  /// Progress of the enter animation while it plays.
  double? entering;

  RenderMotion? left;
  LayerHandle<TransformLayer>? leftLayer;

  void configure(SpringConfig config) {
    x.config = config;
    y.config = config;
    scale.config = config;
  }

  void releaseLeft() {
    left = null;
    leftLayer?.layer = null;
    leftLayer = null;
  }

  double get _enterCurve => switch (entering) {
    final t? => fastSpatial.transform(t),
    null => 1,
  };

  int get alpha => entering == null
      ? 255
      : (_enterCurve.clamp(0.0, 1.0) * 255).round();

  Matrix4? transform(Size size) {
    final enter = _enterCurve;
    final offset = Offset(x.value, y.value + 12 * (1 - enter));
    final s = scale.value * (0.96 + 0.04 * enter);
    if (offset == Offset.zero && s == 1) return null;
    return _transform(size, offset, s);
  }

  void resolveStart(RenderBox box) {
    final start = this.start;
    if (start == null) return;
    this.start = null;
    final origin = box.localToGlobal(Offset.zero);
    switch (start) {
      case _FromVisual(:final visual):
        x.value = visual.topLeft.dx - origin.dx;
        y.value = visual.topLeft.dy - origin.dy;
        scale.value = visual.scale;
        x.velocity = visual.velocity.dx;
        y.velocity = visual.velocity.dy;
        scale.velocity = visual.scaleVelocity;
      case _FromPoint(:final point, scale: final to):
        x.value = point.dx - (origin.dx + box.size.width / 2);
        y.value = point.dy - (origin.dy + box.size.height / 2);
        scale.value = to;
    }
  }

  @override
  bool tick(double dt, {bool settle = false}) {
    final box = this.box;
    if (start != null) {
      if (box != null && box.attached && box.hasSize) {
        resolveStart(box);
      } else {
        start = null;
      }
    }
    final moving = [
      x.step(dt, settle: settle),
      y.step(dt, settle: settle),
      scale.step(dt, settle: settle),
    ].contains(true);
    if (entering case final t?) {
      final next = settle ? 1.0 : t + dt / _enterDuration;
      entering = next >= 1 ? null : next;
      box?.markNeedsPaint();
    }
    box?.markNeedsCompositedLayerUpdate();
    return moving || entering != null;
  }
}

/// A copy of a box that went away for good, fading out where it was drawn.
class _Ghost implements SpringAnimation {
  _Ghost(this.owner, TransformLayer layer, this.at, this.size)
    : layer = LayerHandle(layer);

  final LayoutMotion owner;
  final LayerHandle<TransformLayer> layer;
  final Offset at;
  final Size size;
  double t = 0;

  @override
  bool tick(double dt, {bool settle = false}) {
    t = settle ? 1 : math.min(1, t + dt / _ghostDuration);
    owner._render?.markNeedsPaint();
    if (t < 1) return true;
    owner._ghosts.remove(this);
    layer.layer = null;
    return false;
  }

  void paint(PaintingContext context, Offset origin) {
    final copy = layer.layer;
    if (copy == null) return;
    final e = Curves.easeIn.transform(t);
    context.pushOpacity(origin + at, ((1 - e) * 255).round(), (context, _) {
      copy
        ..offset = Offset.zero
        ..transform = _transform(size, Offset.zero, 1 - 0.06 * e);
      context.addLayer(copy);
    });
  }
}

/// Registers [child] with the nearest [MotionScope] under [motionKey].
///
/// Keys must be unique among a scope's mounted boxes, and boxes must not be
/// nested: a parent's motion would read as the child's movement.
class Motion extends SingleChildRenderObjectWidget {
  const Motion({
    super.key,
    required this.motionKey,
    this.enter = false,
    this.ghost = true,
    super.child,
  });

  /// Null leaves [child] unanimated.
  final Object? motionKey;

  /// Plays the web's `item-in` when mounting without a previous place.
  final bool enter;

  /// Fades out a copy when the box goes away for good; off for boxes that
  /// play their own leave animation.
  final bool ghost;

  @override
  RenderMotion createRenderObject(BuildContext context) {
    final motion = MotionScope.maybeOf(context);
    motion?._requestPass();
    return RenderMotion(
      motion: motion,
      motionKey: motionKey,
      enter: enter,
      ghost: ghost,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderMotion renderObject) {
    final motion = MotionScope.maybeOf(context);
    motion?._requestPass();
    renderObject
      ..motion = motion
      ..motionKey = motionKey
      ..enter = enter
      ..ghost = ghost;
  }

  @override
  void didUnmountRenderObject(RenderMotion renderObject) =>
      renderObject._motion?._requestPass();
}

/// Draws its child where its [LayoutMotion] entry's springs put it. A repaint
/// boundary whose transform lives on its layer, so motion never repaints or
/// relayouts the row.
class RenderMotion extends RenderProxyBox {
  RenderMotion({
    this._motion,
    this._motionKey,
    this.enter = false,
    this.ghost = true,
  });

  LayoutMotion? _motion;
  Object? _motionKey;
  _Entry? _entry;
  bool enter;
  bool ghost;

  set motion(LayoutMotion? value) {
    if (value == _motion) return;
    _unregister();
    _motion = value;
    _register();
  }

  set motionKey(Object? value) {
    if (value == _motionKey) return;
    _unregister();
    _motionKey = value;
    _register();
  }

  void _register() {
    final motion = _motion;
    final key = _motionKey;
    if (!attached || motion == null || key == null) return;
    _entry = motion._attach(key, this);
    markNeedsCompositedLayerUpdate();
  }

  void _unregister({bool detaching = false}) {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    _motion!._detach(
      entry,
      this,
      layer: detaching && ghost ? layer as TransformLayer? : null,
    );
    if (!detaching) markNeedsCompositedLayerUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void detach() {
    _unregister(detaching: true);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  Matrix4? get _paintTransform => _entry?.transform(size);

  @override
  OffsetLayer updateCompositedLayer({
    required covariant TransformLayer? oldLayer,
  }) {
    final layer = oldLayer ?? TransformLayer();
    _entry?.resolveStart(this);
    layer.transform = _paintTransform ?? Matrix4.identity();
    return layer;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final alpha = _entry?.alpha ?? 255;
    if (alpha == 255) {
      super.paint(context, offset);
    } else {
      context.pushOpacity(offset, alpha, super.paint);
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Like RenderTransform: taps land where the box is drawn.
    if (_paintTransform == null) {
      return super.hitTest(result, position: position);
    }
    return hitTestChildren(result, position: position);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final transform = _paintTransform;
    if (transform == null) {
      return super.hitTestChildren(result, position: position);
    }
    return result.addWithPaintTransform(
      transform: transform,
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_paintTransform case final motion?) transform.multiply(motion);
  }
}

/// Where [Motion]s measure and spring. Place it inside the scroll view around
/// the content; [MotionScope.sliver] goes straight into a [CustomScrollView]
/// and can keep a box still while content above it changes.
class MotionScope extends StatefulWidget {
  const MotionScope({super.key, required this.controller, required this.child})
    : _sliver = false;

  const MotionScope.sliver({
    super.key,
    required this.controller,
    required this.child,
  }) : _sliver = true;

  final LayoutMotion controller;

  /// A box widget, also for [MotionScope.sliver].
  final Widget child;
  final bool _sliver;

  static LayoutMotion? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MotionMarker>()?.motion;

  @override
  State<MotionScope> createState() => _MotionScopeState();
}

class _MotionScopeState extends State<MotionScope>
    with SingleTickerProviderStateMixin {
  late final _loop = SpringLoop(this);

  @override
  void initState() {
    super.initState();
    widget.controller._bind(_loop);
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  @override
  void didUpdateWidget(MotionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == oldWidget.controller) return;
    oldWidget.controller._unbind(_loop);
    widget.controller._bind(_loop);
  }

  @override
  void dispose() {
    widget.controller._unbind(_loop);
    _loop.dispose();
    super.dispose();
  }

  // Relayouts that don't reach the scope (a row's text wrapping) move boxes
  // too; their new places are only noted, like the web's layoutPass(false).
  void _afterFrame(Duration _) {
    if (!mounted) return;
    widget.controller._render?._idlePass();
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  @override
  Widget build(BuildContext context) {
    _loop.reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final motion = widget.controller;
    return _MotionMarker(
      motion: motion,
      child: widget._sliver
          ? _SliverScope(
              motion: motion,
              position: Scrollable.maybeOf(context)?.position,
              child: widget.child,
            )
          : _BoxScope(motion: motion, child: widget.child),
    );
  }
}

class _MotionMarker extends InheritedWidget {
  const _MotionMarker({required this.motion, required super.child});

  final LayoutMotion motion;

  @override
  bool updateShouldNotify(_MotionMarker oldWidget) =>
      motion != oldWidget.motion;
}

class _BoxScope extends SingleChildRenderObjectWidget {
  const _BoxScope({required this.motion, super.child});

  final LayoutMotion motion;

  @override
  _RenderMotionScope createRenderObject(BuildContext context) =>
      _RenderMotionScope()..motion = motion;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMotionScope renderObject,
  ) => renderObject
    ..motion = motion
    .._requestPass();
}

class _SliverScope extends SingleChildRenderObjectWidget {
  const _SliverScope({required this.motion, this.position, super.child});

  final LayoutMotion motion;
  final ScrollPosition? position;

  @override
  _RenderSliverMotionScope createRenderObject(BuildContext context) =>
      _RenderSliverMotionScope()
        ..motion = motion
        ..position = position;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverMotionScope renderObject,
  ) => renderObject
    ..motion = motion
    ..position = position
    .._requestPass();
}

mixin _MotionScopeRender on RenderObject {
  LayoutMotion? _motion;
  bool _animate = true;

  RenderBox? get _content;

  set motion(LayoutMotion value) {
    if (value == _motion) return;
    if (_motion?._render == this) _motion!._render = null;
    _motion = value;
    if (attached) value._render = this;
    _requestPass();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion?._render = this;
  }

  @override
  void detach() {
    if (_motion?._render == this) _motion!._render = null;
    super.detach();
  }

  void _requestPass() {
    _animate = true;
    // A Motion mounting inside a layout callback can't dirty its ancestors;
    // the flag waits for the next layout then.
    if (!(owner?.debugDoingLayout ?? false)) markNeedsLayout();
  }

  double _runPass({_ScrollRange? scroll}) {
    final content = _content;
    final motion = _motion;
    if (content == null || motion == null) return 0;
    final animate = _animate;
    _animate = false;
    var correction = 0.0;
    // As a layout callback, so the pass may read descendants' sizes: they
    // only steer the motion, not this layout.
    invokeLayoutCallback<Constraints>((_) {
      correction = motion._pass(content, animate: animate, scroll: scroll);
    });
    return correction;
  }

  void _idlePass() {
    final content = _content;
    if (content == null || !content.hasSize || !attached) return;
    _motion?._pass(content, animate: false);
  }
}

class _RenderMotionScope extends RenderProxyBox with _MotionScopeRender {
  @override
  RenderBox? get _content => child;

  @override
  void performLayout() {
    super.performLayout();
    _runPass();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _motion?._paintGhosts(context, offset);
  }
}

class _RenderSliverMotionScope extends RenderSliverSingleBoxAdapter
    with _MotionScopeRender {
  ScrollPosition? position;
  double? _extent;

  @override
  RenderBox? get _content => child;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    final constraints = this.constraints;
    child.layout(constraints.asBoxConstraints(), parentUsesSize: true);
    final extent = switch (constraints.axis) {
      Axis.horizontal => child.size.width,
      Axis.vertical => child.size.height,
    };
    final previous = _extent ?? extent;
    _extent = extent;
    final position = this.position;
    final scroll =
        position != null &&
            position.hasPixels &&
            position.hasContentDimensions &&
            constraints.axisDirection == AxisDirection.down
        ? (
            pixels: position.pixels,
            min: position.minScrollExtent,
            // The viewport learns the new extent after this layout, so the
            // correction is clamped to the extent this change leads to.
            max: math.max(
              position.minScrollExtent,
              position.maxScrollExtent + extent - previous,
            ),
          )
        : null;
    final correction = _runPass(scroll: scroll);
    if (correction.abs() >= 0.01) {
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
      return;
    }
    final painted = calculatePaintOffset(constraints, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: painted,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: extent),
      maxPaintExtent: extent,
      hitTestExtent: painted,
      hasVisualOverflow:
          extent > constraints.remainingPaintExtent ||
          constraints.scrollOffset > 0,
    );
    setChildParentData(child, constraints, geometry!);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final child = this.child;
    if (child == null || !geometry!.visible) return;
    final data = child.parentData! as SliverPhysicalParentData;
    _motion?._paintGhosts(context, offset + data.paintOffset);
  }
}
