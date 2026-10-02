import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'controls.dart';
import 'motion.dart';

class MenuAction {
  const MenuAction({
    required this.label,
    required this.icon,
    required this.onSelect,
    this.danger = false,
    this.disabled = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelect;
  final bool danger;
  final bool disabled;
}

/// The web's MoreMenu button: a ⋯ that pops in when it appears and opens
/// [actions] in a menu below it. [hidden] fades it out, as on a spread
/// board.
class MoreButton extends StatelessWidget {
  const MoreButton({
    super.key,
    required this.label,
    required this.actions,
    this.hidden = false,
  });

  final String label;
  final List<MenuAction> actions;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final button = Builder(
      builder: (context) => AppIconButton(
        icon: const Icon(Icons.more_horiz),
        tooltip: 'More',
        semanticLabel: label,
        color: moreButtonColor(Theme.of(context).colorScheme),
        onPressed: () => showMoreMenu(context, label: label, actions: actions),
      ),
    );
    return PlayOnce(
      duration: fastSpatial.duration,
      builder: (context, elapsed, child) {
        final t = fastSpatial.at(elapsed);
        return Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
        );
      },
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: hidden ? 0 : 1),
        duration: effects.duration,
        curve: effects,
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity.clamp(0, 1), child: child),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: hidden ? 0.85 : 1),
          duration: fastSpatial.duration,
          curve: fastSpatial,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: IgnorePointer(
            ignoring: hidden,
            child: ExcludeSemantics(excluding: hidden, child: button),
          ),
        ),
      ),
    );
  }
}

/// Opens [actions] in a menu at [context]'s box, the way the web's MoreMenu
/// places its popover.
Future<void> showMoreMenu(
  BuildContext context, {
  required String label,
  required List<MenuAction> actions,
}) {
  final navigator = Navigator.of(context);
  final box = context.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final anchor = MatrixUtils.transformRect(
    box.getTransformTo(overlay),
    Offset.zero & box.size,
  );
  return navigator.push(
    _MenuRoute(
      anchor: anchor,
      label: label,
      actions: actions,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
    ),
  );
}

/// px between the button and the menu, and the least the menu keeps from
/// the screen's (safe) edges.
const _gap = 4.0;
const _edge = 8.0;

const _itemHeight = 48.0;

class _MenuRoute extends PopupRoute<void> {
  _MenuRoute({
    required this.anchor,
    required this.label,
    required this.actions,
    required this.themes,
    required this.barrierLabel,
  });

  final Rect anchor;
  final String label;
  final List<MenuAction> actions;
  final CapturedThemes themes;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => fastSpatial.duration;

  @override
  Duration get reverseTransitionDuration => effects.duration;

  // The height is known from the items, so the side is too, before layout:
  // the transition needs it for the corner it grows from.
  double get _height => 8 + actions.length * (_itemHeight + 2) - 2;

  bool _above(Size screen, EdgeInsets padding) =>
      anchor.bottom + _gap + _height > screen.height - padding.bottom - _edge &&
      anchor.top - _gap - _height >= padding.top + _edge;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final padding = MediaQuery.paddingOf(context);
    final above = _above(MediaQuery.sizeOf(context), padding);
    return themes.wrap(
      CustomSingleChildLayout(
        delegate: _MenuLayout(anchor: anchor, padding: padding, above: above),
        child: _Transition(
          animation: animation,
          alignment: above ? Alignment.bottomRight : Alignment.topRight,
          child: _Menu(label: label, actions: actions),
        ),
      ),
    );
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout({
    required this.anchor,
    required this.padding,
    required this.above,
  });

  final Rect anchor;
  final EdgeInsets padding;
  final bool above;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(
        EdgeInsets.fromLTRB(
          padding.left + _edge,
          padding.top + _edge,
          padding.right + _edge,
          padding.bottom + _edge,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final top = above
        ? anchor.top - _gap - childSize.height
        : anchor.bottom + _gap;
    final left = math.max(padding.left + _edge, anchor.right - childSize.width);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      anchor != old.anchor || padding != old.padding || above != old.above;
}

/// Opens with a fade and a spring from 60% at the corner nearest the
/// button; closes with a quicker fade, shrinking a little.
class _Transition extends StatelessWidget {
  const _Transition({
    required this.animation,
    required this.alignment,
    required this.child,
  });

  final Animation<double> animation;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = animation.value;
      final double opacity;
      final double scale;
      if (animation.status == AnimationStatus.reverse) {
        final closed = effects.transform(1 - t);
        opacity = 1 - closed;
        scale = 1 - 0.08 * closed;
      } else {
        final elapsed = fastSpatial.duration * t;
        opacity = effects.at(elapsed);
        scale = 0.6 + 0.4 * fastSpatial.at(elapsed);
      }
      return Opacity(
        opacity: opacity.clamp(0, 1),
        child: Transform.scale(
          scale: scale,
          alignment: alignment,
          child: child,
        ),
      );
    },
    child: child,
  );
}

class _Menu extends StatelessWidget {
  const _Menu({required this.label, required this.actions});

  final String label;
  final List<MenuAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      explicitChildNodes: true,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          constraints: const BoxConstraints(minWidth: 208),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            boxShadow: elevation2,
          ),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 2,
              children: [for (final action in actions) _MenuItem(action)],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.action);

  final MenuAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final disabled = colors.onSurface.withValues(alpha: 0.38);
    final (text, icon) = switch (action) {
      MenuAction(disabled: true) => (disabled, disabled),
      MenuAction(danger: true) => (colors.error, colors.error),
      _ => (colors.onSurface, colors.onSurfaceVariant),
    };
    return Semantics(
      button: true,
      enabled: !action.disabled,
      child: Pressable(
        radius: 12,
        color: text,
        onTap: action.disabled
            ? null
            : () {
                Navigator.pop(context);
                action.onSelect();
              },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _itemHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 20, 0),
            child: Row(
              spacing: 12,
              children: [
                Icon(action.icon, size: 20, color: icon),
                Text(
                  action.label,
                  softWrap: false,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 15,
                    height: 20 / 15,
                    color: text,
                    fontVariations: const [
                      FontVariation.width(100),
                      FontVariation.opticalSize(15),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
