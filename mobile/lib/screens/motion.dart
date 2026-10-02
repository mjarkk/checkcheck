import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// A spring from rest to 1, played over [duration] (its settle time), for
/// implicit animations: `duration: fastSpatial.duration, curve: fastSpatial`.
class SpringCurve extends Curve {
  const SpringCurve({
    required this.ratio,
    required this.stiffness,
    required this.duration,
  });

  final double ratio;
  final double stiffness;
  final Duration duration;

  @override
  double transformInternal(double t) {
    final spring = SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: stiffness,
      ratio: ratio,
    );
    return SpringSimulation(
      spring,
      0,
      1,
      0,
    ).x(t * duration.inMicroseconds / Duration.microsecondsPerSecond);
  }

  /// Where the spring is [elapsed] after it was let go.
  double at(Duration elapsed) => transform(
    (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0),
  );
}

// The web app's --md-spring-* tokens.
const fastSpatial = SpringCurve(
  ratio: 0.6,
  stiffness: 800,
  duration: Duration(milliseconds: 350),
);
const defaultSpatial = SpringCurve(
  ratio: 0.8,
  stiffness: 380,
  duration: Duration(milliseconds: 410),
);
const effects = SpringCurve(
  ratio: 1,
  stiffness: 1600,
  duration: Duration(milliseconds: 210),
);

/// motion.ts's SPRINGS.layout, which the web's rows spring to new places with.
const layoutSpring = SpringCurve(
  ratio: 0.72,
  stiffness: 380,
  duration: Duration(milliseconds: 500),
);

/// Runs [builder] from zero to [duration] once, on mount; without [play] it
/// starts at [duration]. Mirrors a CSS animation, which only plays when its
/// element appears.
class PlayOnce extends StatelessWidget {
  const PlayOnce({
    super.key,
    required this.duration,
    required this.builder,
    this.play = true,
    this.child,
  });

  final Duration duration;
  final bool play;
  final Widget Function(BuildContext context, Duration elapsed, Widget? child)
  builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: play ? 0 : 1, end: 1),
    duration: duration,
    builder: (context, t, child) => builder(context, duration * t, child),
    child: child,
  );
}

/// Plays the web app's `rise-in` once, on mount.
class RiseIn extends StatelessWidget {
  const RiseIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: defaultSpatial.duration,
    curve: defaultSpatial,
    builder: (context, t, child) => Opacity(
      opacity: t.clamp(0, 1),
      child: Transform.translate(
        offset: Offset(0, 24 * (1 - t)),
        child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
      ),
    ),
    child: child,
  );
}

/// The web's `fade-in` on mount.
class FadeIn extends StatelessWidget {
  const FadeIn({super.key, required this.child, this.play = true});

  final Widget child;
  final bool play;

  @override
  Widget build(BuildContext context) => PlayOnce(
    duration: effects.duration,
    play: play,
    builder: (context, elapsed, child) =>
        Opacity(opacity: effects.at(elapsed).clamp(0, 1), child: child),
    child: child,
  );
}

/// A row's `item-in` on mount when [animateIn], and its `item-out` once
/// [leaving] turns true; [onLeft] fires when that ends. A leaving row takes
/// no taps, like the web's `inert`.
class RowPresence extends StatefulWidget {
  const RowPresence({
    super.key,
    required this.child,
    this.animateIn = false,
    this.leaving = false,
    this.onLeft,
  });

  final Widget child;
  final bool animateIn;
  final bool leaving;
  final VoidCallback? onLeft;

  @override
  State<RowPresence> createState() => _RowPresenceState();
}

class _RowPresenceState extends State<RowPresence>
    with TickerProviderStateMixin {
  late final _in = AnimationController(
    vsync: this,
    duration: fastSpatial.duration,
    value: widget.animateIn ? 0 : 1,
  );
  late final _out = AnimationController(
    vsync: this,
    duration: effects.duration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animateIn) _in.forward();
    if (widget.leaving) _leave();
  }

  @override
  void didUpdateWidget(RowPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.leaving == oldWidget.leaving) return;
    widget.leaving ? _leave() : _out.reverse();
  }

  void _leave() => _out.forward().then((_) {
    if (mounted && widget.leaving) widget.onLeft?.call();
  });

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_in, _out]),
    builder: (context, child) {
      final t = fastSpatial.transform(_in.value);
      final out = effects.transform(_out.value);
      return Opacity(
        opacity: (t.clamp(0.0, 1.0) * (1 - out)).clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - t)),
          child: Transform.scale(
            scale: (0.96 + 0.04 * t) * (1 - 0.06 * out),
            child: child,
          ),
        ),
      );
    },
    child: IgnorePointer(ignoring: widget.leaving, child: widget.child),
  );
}
