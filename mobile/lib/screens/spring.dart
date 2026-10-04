import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

/// Unit mass; [damping] is the ratio to critical damping: below 1 overshoots,
/// lower bounces more.
class SpringConfig {
  const SpringConfig(this.stiffness, this.damping);

  final double stiffness;
  final double damping;
}

/// The web app's SPRINGS (server/web/src/motion.ts).
abstract final class Springs {
  /// Checking, adding, deleting and recategorizing items.
  static const layout = SpringConfig(380, 0.72);

  /// Everything spreading apart when an item is lifted, and closing up again
  /// after the drop.
  static const spread = SpringConfig(400, 0.56);

  /// The held row and its neighbours following the pointer before the row
  /// tears off.
  static const pull = SpringConfig(900, 0.9);

  /// The neighbours letting go of the row when it tears off.
  static const release = SpringConfig(520, 0.4);

  /// The lifted row catching up with, and then following, the pointer.
  static const snap = SpringConfig(620, 0.62);

  /// The row falling into its gap.
  static const drop = SpringConfig(460, 0.56);

  /// A row flying out of the new-category circle: a long way, so less bounce.
  static const fly = SpringConfig(260, 0.8);
}

const _step = 1 / 240;

/// motion.ts's HURRY_MS and HURRY_SPEED: how close together checks and
/// deletes must come to hurry the list, and how long it hurries after the
/// last one.
const hurryWindow = Duration(milliseconds: 500);
const _hurrySpeed = 2.0;

/// Runs for [hurryWindow] after each check or delete.
Timer? _recentAction;

/// motion.ts's `hurry`: call on every check or delete. One within
/// [hurryWindow] of the previous one speeds up all motion until
/// [hurryWindow] passes without another.
void hurry() {
  // Every ticker reads the dilated frame clock, so this speeds up the springs
  // and the implicit animations alike.
  if (_recentAction?.isActive ?? false) timeDilation = 1 / _hurrySpeed;
  _recentAction?.cancel();
  _recentAction = Timer(hurryWindow, () => timeDilation = 1);
}

/// motion.ts's `Spring`, stepped the same way so both apps move alike.
class Spring {
  Spring([this.value = 0, this.precision = 0.1]) : target = value;

  double value;
  double target;
  double velocity = 0;
  SpringConfig config = Springs.layout;
  final double precision;

  bool get atRest =>
      (value - target).abs() < precision && velocity.abs() < precision * 10;

  /// Advances [dt] seconds; false once it rests on the target. [settle] jumps
  /// straight there, for reduced motion.
  bool step(double dt, {bool settle = false}) {
    if (settle || atRest) {
      value = target;
      velocity = 0;
      return false;
    }
    final SpringConfig(:stiffness, :damping) = config;
    final friction = 2 * damping * math.sqrt(stiffness);
    for (var left = dt; left > 0; left -= _step) {
      final h = math.min(left, _step);
      velocity += (-stiffness * (value - target) - friction * velocity) * h;
      value += velocity * h;
    }
    return true;
  }

  /// Puts the spring at rest on [to].
  void jump(double to) {
    value = to;
    target = to;
    velocity = 0;
  }
}

abstract interface class SpringAnimation {
  /// Advances [dt] seconds; false once at rest. [settle] jumps to the end.
  bool tick(double dt, {bool settle = false});
}

/// Ticks running [SpringAnimation]s every frame, like motion.ts's `run`.
class SpringLoop {
  SpringLoop(TickerProvider vsync) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;
  final _running = <SpringAnimation>{};
  Duration? _last;

  /// `MediaQuery.disableAnimationsOf`: every animation jumps to its end.
  bool reducedMotion = false;

  bool get isActive => _ticker.isActive;

  /// Ticks [animation] every frame until its `tick` returns false.
  void run(SpringAnimation animation) {
    _running.add(animation);
    if (_ticker.isActive) return;
    final scheduler = SchedulerBinding.instance;
    // Mid-frame (a layout pass) the next frame is one frame on; from a pointer
    // event there is no frame to measure from.
    _last = scheduler.schedulerPhase == SchedulerPhase.idle
        ? null
        : scheduler.currentFrameTimeStamp;
    _ticker.start();
  }

  void remove(SpringAnimation animation) => _running.remove(animation);

  void _onTick(Duration _) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final last = _last;
    // Capped so a stalled frame resumes the motion instead of skipping to its end.
    final dt = last == null
        ? 1 / 60
        : ((now - last).inMicroseconds / Duration.microsecondsPerSecond).clamp(
            0.0,
            1 / 30,
          );
    _last = now;
    for (final animation in [..._running]) {
      if (!_running.contains(animation)) continue;
      if (!animation.tick(dt, settle: reducedMotion)) _running.remove(animation);
    }
    if (_running.isEmpty) _ticker.stop();
  }

  void dispose() {
    _running.clear();
    _ticker.dispose();
  }
}
