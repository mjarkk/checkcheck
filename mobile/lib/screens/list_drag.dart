import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'layout_motion.dart';
import 'spring.dart';

// server/web/src/drag.ts's constants.

/// Pointer travel at which a held row lets go of its neighbours and follows
/// the pointer.
const _tearDistance = 56.0;

/// Before tearing off, the row moves this fraction of the pointer's travel,
/// less the further it is pulled.
const _resistance = 0.5;
const _resistanceFalloff = 140.0;

/// How far the 1st, 2nd and 3rd line away from the held row are dragged
/// along, relative to the row.
const _neighbourPull = [0.45, 0.2, 0.08];
const _liftScale = 1.03;

/// Scale of the lifted row while it is drawn into the new-category circle.
const _attractScale = 0.08;

/// Within this distance of the scrolled area's top or bottom edge a drag
/// scrolls it.
const _scrollEdge = 96.0;

/// px/s, reached at the very edge.
const _maxScrollSpeed = 1400.0;

/// The zone of a drop on the new-category circle: the item goes to a
/// category yet to be named.
const newCategoryZone = #newCategory;

/// [index] counts the zone's rows before the drop, not the dragged one.
typedef DropTarget = ({Object zone, int index});

/// A lifted row: render a gap of [height] before the [target]'s row.
typedef Lifted<Id> = ({Id id, double height, DropTarget target});

/// Dragging rows by their handles between the [DragZone]s of one
/// [DragArea], with the motion of server/web/src/drag.ts.
///
/// While [lifted], the host hides that row (still mounted, without its
/// motion key), renders a [DragGap] carrying the row's motion key at the
/// target (see [withGap]) and spreads its lists. [onDrop] runs in the same
/// frame the gap goes away, so the row lands where the gap was.
class ListDrag<Id extends Object> extends ChangeNotifier {
  ListDrag({
    required this.motion,
    required this.motionKeyOf,
    required this.onDrop,
    this.onStart,
    this.onEnd,
  });

  final LayoutMotion motion;
  final Object Function(Id id) motionKeyOf;
  final void Function(Id id, DropTarget target) onDrop;

  /// The row tore off.
  final VoidCallback? onStart;

  /// The row was dropped or the drag cancelled.
  final VoidCallback? onEnd;

  Lifted<Id>? _lifted;
  Lifted<Id>? get lifted => _lifted;

  /// The row that landed in the last 400 ms (its [LandingShadow] plays),
  /// and a count that changes with every landing.
  ({Id id, int count})? get landed => _landed;
  ({Id id, int count})? _landed;
  var _landings = 0;
  Timer? _landedTimer;

  _DragAreaState<Id>? _area;
  _Session<Id>? _session;
  bool _disposed = false;

  bool get active => _session != null;

  /// Starts a drag of [id] from its handle. The handle wins the pointer at
  /// once, so the scroll view never takes it.
  void grab(PointerDownEvent event, Id id) {
    final area = _area;
    if (_session != null || area == null) return;
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryButton) {
      return;
    }
    final key = motionKeyOf(id);
    final row = motion.boxOf(key);
    final zone = row == null ? null : area._zoneOf(row);
    if (row == null || zone == null) return;
    final session = _session = _Session(this, area, id, key, zone, event);
    _GrabRecognizer(session).addPointer(event);
  }

  /// Puts a lifted row back where it came from.
  void cancel() => _session?.finish(cancel: true);

  void _setLifted(Lifted<Id>? lifted) {
    _lifted = lifted;
    if (!_disposed) notifyListeners();
  }

  void _land(Id id) {
    _landed = (id: id, count: ++_landings);
    _landedTimer?.cancel();
    _landedTimer = Timer(
      const Duration(milliseconds: 400),
      () => _landed = null,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _landedTimer?.cancel();
    _session?.dispose();
    super.dispose();
  }
}

/// Wins the arena on pointer down and feeds the session; owned by the
/// session rather than the handle, so hiding the row doesn't end the drag.
class _GrabRecognizer extends OneSequenceGestureRecognizer {
  _GrabRecognizer(this.session);

  final _Session<Object> session;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    switch (event) {
      case PointerMoveEvent():
        session.move(event.position);
      case PointerUpEvent():
        session.finish(cancel: false);
        stopTrackingPointer(event.pointer);
      case PointerCancelEvent():
        session.finish(cancel: true);
        stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    session.finish(cancel: true);
  }

  @override
  void didStopTrackingLastPointer(int pointer) => dispose();

  @override
  String get debugDescription => 'drag handle';
}

typedef _Neighbour = ({Object key, double weight});

class _Session<Id extends Object> {
  _Session(
    this.drag,
    this.area,
    this.id,
    this.key,
    this.zone,
    PointerDownEvent event,
  ) : start = event.position,
      pointer = event.position,
      grabOffset =
          event.position -
          (drag.motion.layoutRectOf(key)?.topLeft ?? Offset.zero) {
    final lines = drag.motion.keysWithin(zone.box!);
    final at = lines.indexOf(key);
    neighbours = [
      for (final (i, line) in lines.indexed)
        if ((i - at).abs() case final d
            when d >= 1 && d <= _neighbourPull.length)
          (key: line, weight: _neighbourPull[d - 1]),
    ];
  }

  final ListDrag<Id> drag;
  final _DragAreaState<Id> area;
  final Id id;
  final Object key;
  final _ZoneState zone;
  final Offset start;
  Offset pointer;

  /// Pointer position within the row, kept while the row follows it.
  final Offset grabOffset;
  late final List<_Neighbour> neighbours;

  _Overlay? overlay;
  DropTarget? origin;
  DropTarget? target;
  bool finished = false;

  /// Whether a frame has laid the board out lifted. Tickers run before
  /// layout, and hit-testing the unspread rows would move the gap off the
  /// origin before the anchor pass has kept it in place.
  bool _spreadLaidOut = false;

  LayoutMotion get motion => drag.motion;

  void move(Offset position) {
    if (finished) return;
    pointer = position;
    if (overlay case final overlay?) {
      overlay.follow(pointer - grabOffset);
    } else {
      _pull();
    }
  }

  void _pull() {
    final delta = pointer - start;
    final distance = delta.distance;
    if (distance >= _tearDistance) {
      _lift();
      return;
    }
    final k = _resistance / (1 + distance / _resistanceFalloff);
    motion.pullTo(key, delta * k, Springs.pull);
    for (final n in neighbours) {
      motion.pullTo(n.key, delta * (k * n.weight), Springs.pull);
    }
  }

  void _lift() {
    final visual = motion.visualOf(key);
    final box = motion.boxOf(key);
    if (visual == null || box == null) {
      finish(cancel: true);
      return;
    }
    overlay = area._lift(id, visual, box.size)..follow(pointer - grabOffset);
    for (final n in neighbours) {
      motion.pullTo(n.key, Offset.zero, Springs.release);
    }
    // The gap takes over this key; it starts where the row's layout box is.
    motion.reset(key);
    final rowTop = motion.layoutRectOf(key)!.top;
    final before = area._rowsOf(zone).where((row) => row.rect.top < rowTop);
    final origin = this.origin = target = (
      zone: zone.widget.zone,
      index: before.length,
    );
    motion.prepare(anchor: key, config: Springs.spread);
    HapticFeedback.selectionClick();
    drag.onStart?.call();
    drag._setLifted((id: id, height: box.size.height, target: origin));
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => _spreadLaidOut = true,
    );
  }

  /// Every frame while lifted, also when the pointer rests: auto-scrolling
  /// moves the rows under it.
  void tick(double dt) {
    final overlay = this.overlay;
    if (finished || overlay == null || !_spreadLaidOut) return;
    // The circle sits in the bottom scroll edge; hovering it must not scroll.
    final circle = area._circleUnder(pointer);
    overlay.attract(circle);
    if (circle == null) _autoScroll(dt);
    final next = circle != null
        ? (zone: newCategoryZone, index: 0)
        : _hitTest();
    if (next != null && next != target) {
      target = next;
      final box = motion.boxOf(key);
      drag._setLifted((
        id: id,
        height: drag.lifted?.height ?? box?.size.height ?? 0,
        target: next,
      ));
    }
  }

  void _autoScroll(double dt) {
    final scroll = area.widget.scroll;
    if (!scroll.hasClients) return;
    final position = scroll.position;
    final viewport = area._viewportRect();
    if (viewport == null) return;
    final edge = math.min(_scrollEdge, viewport.height / 4);
    final y = pointer.dy;
    final depth = y < viewport.top + edge
        ? y - (viewport.top + edge)
        : y > viewport.bottom - edge
        ? y - (viewport.bottom - edge)
        : 0.0;
    if (depth == 0) return;
    final strength = math.pow(math.min(depth.abs() / edge, 1), 2);
    final to = (position.pixels + depth.sign * strength * _maxScrollSpeed * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to != position.pixels) position.jumpTo(to);
  }

  /// The zone nearest the pointer, and how many of its rows lie above it.
  DropTarget? _hitTest() {
    final y = pointer.dy;
    _ZoneState? best;
    var bestDistance = double.infinity;
    for (final zone in area._zones) {
      final rect = zone.rect;
      if (rect == null) continue;
      final distance = y < rect.top
          ? rect.top - y
          : y > rect.bottom
          ? y - rect.bottom
          : 0.0;
      if (distance < bestDistance) {
        best = zone;
        bestDistance = distance;
      }
    }
    if (best == null) return null;
    final above = area._rowsOf(best).where((row) => row.rect.center.dy < y);
    return (zone: best.widget.zone, index: above.length);
  }

  void finish({required bool cancel}) {
    if (finished) return;
    finished = true;
    drag._session = null;
    final overlay = this.overlay;
    if (overlay == null) {
      motion.pullTo(key, Offset.zero, Springs.release);
      for (final n in neighbours) {
        motion.pullTo(n.key, Offset.zero, Springs.release);
      }
      return;
    }
    final to = cancel ? origin! : target!;
    if (to.zone == newCategoryZone) {
      overlay.vanish();
      // The row stays hidden until the category is named, so keep what's
      // on screen still instead.
      final top = area._viewportRect()?.top ?? 0;
      motion.prepare(
        anchor: motion.firstVisibleKey(top),
        config: Springs.spread,
      );
    } else {
      motion.prepare(
        anchor: key,
        config: Springs.spread,
        start: MotionStart.visual(key, overlay.visual),
      );
      area._removeOverlay();
      drag._land(id);
    }
    drag._setLifted(null);
    if (!cancel) {
      HapticFeedback.selectionClick();
      drag.onDrop(id, to);
    }
    drag.onEnd?.call();
  }

  /// Stops without touching the host, for when the area goes away mid-drag.
  void dispose() {
    finished = true;
    drag._session = null;
  }
}

/// [rows] in order with [drag]'s gap where it targets [zone]. Rows for which
/// [hidden] holds stay (mounted, hidden by the host) but aren't counted.
List<R> withGap<T, R>({
  required List<T> rows,
  required Object zone,
  required Lifted<Object>? lifted,
  required bool Function(T row) hidden,
  required R Function(T row) build,
  required R Function() gap,
}) {
  final gapAt = lifted?.target.zone == zone ? lifted!.target.index : -1;
  final out = <R>[];
  var visible = 0;
  for (final row in rows) {
    if (!hidden(row) && visible++ == gapAt) out.add(gap());
    out.add(build(row));
  }
  if (visible == gapAt) out.add(gap());
  return out;
}

/// The room a lifted row's drop opens; it carries the row's motion key, so
/// it moves where the row was and the row lands where it is.
class DragGap extends StatelessWidget {
  const DragGap({super.key, required this.motionKey, required this.height});

  final Object motionKey;
  final double height;

  @override
  Widget build(BuildContext context) => Motion(
    motionKey: motionKey,
    ghost: false,
    child: SizedBox(height: height),
  );
}

/// One list rows can be dropped into. [rows] are the ids of its rows, top to
/// bottom, leaving out ones the host hides.
class DragZone extends StatefulWidget {
  const DragZone({
    super.key,
    required this.zone,
    required this.rows,
    required this.child,
  });

  final Object zone;
  final List<Object> rows;
  final Widget child;

  @override
  State<DragZone> createState() => _ZoneState();
}

class _ZoneState extends State<DragZone> {
  _DragAreaState<Object>? _area;

  RenderBox? get box {
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  Rect? get rect {
    final box = this.box;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final area = context.dependOnInheritedWidgetOfExactType<_DragScope>()?.area;
    if (area == _area) return;
    _area?._zones.remove(this);
    _area = area?.._zones.add(this);
  }

  @override
  void dispose() {
    _area?._zones.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DragScope extends InheritedWidget {
  const _DragScope({required this.area, required super.child});

  final _DragAreaState<Object> area;

  @override
  bool updateShouldNotify(_DragScope oldWidget) => area != oldWidget.area;
}

/// Where [drag]'s rows are dragged: holds the [DragZone]s, scrolls [scroll]
/// near its edges and draws the lifted row over [child], under
/// [foreground]. [circle] is the new-category circle's key, if there is one.
class DragArea<Id extends Object> extends StatefulWidget {
  const DragArea({
    super.key,
    required this.drag,
    required this.scroll,
    required this.liftedBuilder,
    required this.child,
    this.circle,
    this.foreground,
  });

  final ListDrag<Id> drag;
  final ScrollController scroll;
  final Widget Function(BuildContext context, Id id) liftedBuilder;
  final Widget child;
  final GlobalKey? circle;

  /// Drawn above the lifted row, which shrinks into the circle from behind.
  final Widget? foreground;

  @override
  State<DragArea<Id>> createState() => _DragAreaState<Id>();
}

class _DragAreaState<Id extends Object> extends State<DragArea<Id>>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration? _lastTick;
  final _zones = <_ZoneState>{};
  _Overlay? _overlay;
  Id? _overlayId;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    // Not lazily: dispose() would be the first to touch it, creating it on a
    // deactivated element.
    _ticker = createTicker(_tick);
    widget.drag._area = this;
  }

  @override
  void didUpdateWidget(DragArea<Id> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.drag == oldWidget.drag) return;
    if (oldWidget.drag._area == this) oldWidget.drag._area = null;
    widget.drag._area = this;
  }

  @override
  void dispose() {
    widget.drag._session?.dispose();
    if (widget.drag._area == this) widget.drag._area = null;
    _ticker.dispose();
    _overlay?.dispose();
    super.dispose();
  }

  _Overlay _lift(Id id, MotionVisual from, Size size) {
    final overlay = _Overlay(from, size);
    setState(() {
      _overlay?.dispose();
      _overlay = overlay;
      _overlayId = id;
    });
    _lastTick = null;
    if (!_ticker.isActive) _ticker.start();
    return overlay;
  }

  void _removeOverlay() {
    final overlay = _overlay;
    if (overlay == null) return;
    setState(() {
      _overlay = null;
      _overlayId = null;
    });
    // Disposed after the frame that stops listening to it.
    SchedulerBinding.instance.addPostFrameCallback((_) => overlay.dispose());
  }

  void _tick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    // Capped so a stalled frame resumes the motion instead of skipping it.
    final dt = last == null
        ? 1 / 60
        : ((elapsed - last).inMicroseconds / Duration.microsecondsPerSecond)
              .clamp(0.0, 1 / 30);
    widget.drag._session?.tick(dt);
    final overlay = _overlay;
    if (overlay != null) {
      overlay.step(dt, settle: _reduced);
      if (overlay.gone) _removeOverlay();
    }
    if (_overlay == null) _ticker.stop();
  }

  _ZoneState? _zoneOf(RenderBox row) {
    for (final zone in _zones) {
      final box = zone.box;
      if (box == null) continue;
      for (RenderObject? node = row; node != null; node = node.parent) {
        if (node == box) return zone;
      }
    }
    return null;
  }

  /// [zone]'s rows other than the dragged one, with their layout rects.
  List<({Object id, Rect rect})> _rowsOf(_ZoneState zone) {
    final drag = widget.drag;
    final lifted = drag._session?.id;
    final rows = [
      for (final id in zone.widget.rows)
        if (id != lifted)
          if (drag.motion.layoutRectOf(drag.motionKeyOf(id as Id))
              case final rect?)
            (id: id as Object, rect: rect),
    ]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    return rows;
  }

  /// The circle's centre while [pointer] is on it.
  Offset? _circleUnder(Offset pointer) {
    final box = widget.circle?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    final over = (pointer - rect.center).distance <= rect.width / 2 + 16;
    return over ? rect.center : null;
  }

  Rect? _viewportRect() {
    final scroll = widget.scroll;
    if (!scroll.hasClients) return null;
    final box = scroll.position.context.notificationContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final overlay = _overlay;
    final id = _overlayId;
    return _DragScope(
      area: this,
      child: Stack(
        children: [
          widget.child,
          if (overlay != null && id != null)
            Positioned.fill(
              child: IgnorePointer(
                child: _OverlayView(
                  overlay: overlay,
                  child: widget.liftedBuilder(context, id),
                ),
              ),
            ),
          ?widget.foreground,
        ],
      ),
    );
  }
}

/// The lifted row: a copy that springs after the pointer, in global
/// coordinates of its unscaled box's top-left, scaled about its centre.
class _Overlay extends ChangeNotifier {
  _Overlay(MotionVisual from, this.size)
    : x = Spring(from.topLeft.dx),
      y = Spring(from.topLeft.dy) {
    x.velocity = from.velocity.dx;
    y.velocity = from.velocity.dy;
    for (final spring in [x, y, scale]) {
      spring.config = Springs.snap;
    }
    scale.target = _liftScale;
  }

  final Size size;
  final Spring x;
  final Spring y;
  final scale = Spring(1, 0.001);
  double opacity = 1;

  /// Seconds since [vanish].
  double? _vanishing;
  Offset _goal = Offset.zero;
  Offset? _attractor;

  bool get gone => (_vanishing ?? 0) >= 0.32;

  void follow(Offset topLeft) {
    _goal = topLeft;
    _retarget();
  }

  /// Draws the row into the global point [at] instead of following the
  /// pointer, until called with null.
  void attract(Offset? at) {
    if (at == _attractor) return;
    _attractor = at;
    _retarget();
  }

  void _retarget() {
    if (_attractor case final at?) {
      x.target = at.dx - size.width / 2;
      y.target = at.dy - size.height / 2;
      scale.target = _attractScale;
    } else {
      x.target = _goal.dx;
      y.target = _goal.dy;
      scale.target = _liftScale;
    }
  }

  MotionVisual get visual => MotionVisual(
    Offset(x.value, y.value),
    scale: scale.value,
    velocity: Offset(x.velocity, y.velocity),
    scaleVelocity: scale.velocity,
  );

  /// Shrinks the rest of the way into its attractor while fading out (the
  /// web's 240 ms after 80 ms), then [gone].
  void vanish() {
    scale.target = _attractScale / 2;
    _vanishing = 0;
  }

  void step(double dt, {bool settle = false}) {
    x.step(dt, settle: settle);
    y.step(dt, settle: settle);
    scale.step(dt, settle: settle);
    if (_vanishing case final t?) {
      final next = settle ? 1.0 : t + dt;
      _vanishing = next;
      opacity = 1 - Curves.easeIn.transform(((next - 0.08) / 0.24).clamp(0, 1));
    }
    notifyListeners();
  }
}

class _OverlayView extends StatelessWidget {
  const _OverlayView({required this.overlay, required this.child});

  final _Overlay overlay;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: overlay,
    builder: (context, child) {
      final box = context.findRenderObject();
      final origin = box is RenderBox && box.hasSize
          ? box.localToGlobal(Offset.zero)
          : Offset.zero;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: overlay.x.value - origin.dx,
            top: overlay.y.value - origin.dy,
            width: overlay.size.width,
            child: Opacity(
              opacity: overlay.opacity.clamp(0, 1),
              child: Transform.scale(scale: overlay.scale.value, child: child),
            ),
          ),
        ],
      );
    },
    child: RepaintBoundary(child: child),
  );
}

/// The lifted row's shadow fading out after it landed (the web's 400 ms
/// ease-out); plays whenever [landing] changes to a new non-null value.
class LandingShadow extends StatefulWidget {
  const LandingShadow({super.key, required this.landing, required this.child});

  final Object? landing;
  final Widget child;

  @override
  State<LandingShadow> createState() => _LandingShadowState();
}

class _LandingShadowState extends State<LandingShadow>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
    value: widget.landing == null ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.landing != null) _fade.forward();
  }

  @override
  void didUpdateWidget(LandingShadow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.landing != null && widget.landing != oldWidget.landing) {
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fade,
    builder: (context, child) {
      if (_fade.isCompleted) return child!;
      final t = Curves.easeOut.transform(_fade.value);
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: BoxShadow.lerpList(elevation3, const [], t),
        ),
        child: child,
      );
    },
    child: widget.child,
  );
}
