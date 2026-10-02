import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import 'controls.dart';
import 'motion.dart';

/// Opens [link] in the browser.
Future<void> openLink(String link) async {
  final uri = Uri.tryParse(link);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on PlatformException {
    // Nothing on the device can open it; there is nothing else to offer.
  }
}

/// What the line says: the site, then the page's title when it has one.
({String site, String? title}) previewLabel(String link, Preview preview) =>
    (site: preview.siteName ?? _hostOf(link), title: preview.title);

/// The link's host without `www.`, or the whole link if it doesn't parse.
String _hostOf(String link) {
  final host = Uri.tryParse(link)?.host ?? '';
  return host.isEmpty ? link : host.replaceFirst(RegExp(r'^www\.'), '');
}

/// The web's LinkPreview: one line that links to the page, and a chevron
/// that expands its image and description when it has them.
class LinkPreview extends StatefulWidget {
  const LinkPreview({
    super.key,
    required this.link,
    required this.preview,
    required this.expanded,
    required this.springIn,
    required this.dimmed,
    required this.brokenImages,
    required this.onToggle,
    required this.onImageError,
  });

  final String link;
  final Preview preview;
  final bool expanded;

  /// Plays the arrival once, on mount: the preview came while the row was
  /// already shown.
  final bool springIn;
  final bool dimmed;

  /// Image and icon URLs that failed to load, which are left out.
  final Set<String> brokenImages;
  final VoidCallback onToggle;
  final ValueChanged<String> onImageError;

  @override
  State<LinkPreview> createState() => _LinkPreviewState();
}

/// The preview's width from which the image goes beside the text: the
/// web's `@container (min-width: 24rem)`.
const _sideBySideWidth = 384.0;

class _LinkPreviewState extends State<LinkPreview>
    with SingleTickerProviderStateMixin {
  // Only a tap springs the details open, not a remount that finds them open.
  bool _toggled = false;

  // An arriving preview is laid out at zero height first, so the row grows.
  late bool _grown = !widget.springIn;

  /// Fades the closing details out where they were while the row shrinks
  /// over them.
  late final _ghost =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 150),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) setState(() {});
      });

  @override
  void initState() {
    super.initState();
    if (!_grown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _grown = true);
      });
    }
  }

  @override
  void dispose() {
    _ghost.dispose();
    super.dispose();
  }

  String? _loadable(String? src) =>
      src != null && !widget.brokenImages.contains(src) ? src : null;

  bool get _open =>
      widget.expanded &&
      (_loadable(widget.preview.image) != null ||
          widget.preview.description != null);

  void _toggle() {
    setState(() => _toggled = true);
    if (_open && !MediaQuery.disableAnimationsOf(context)) {
      _ghost.forward(from: 0);
    }
    widget.onToggle();
  }

  void _failed(String src) {
    // Reported by the image's build; the parent rebuilds without it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onImageError(src);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium!.copyWith(
      fontWeight: FontWeight.w400,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final open = _open;
    final ghosting = _ghost.isAnimating;
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final current = _body(open: open, width: width);
        if (!ghosting) return current;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            current,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: FadeTransition(
                    opacity: ReverseAnimation(
                      CurvedAnimation(parent: _ghost, curve: Curves.easeOut),
                    ),
                    child: _body(open: true, width: width, ghost: true),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    return PlayOnce(
      duration: fastSpatial.duration,
      play: widget.springIn,
      builder: (context, elapsed, child) {
        final t = fastSpatial.at(elapsed);
        return Opacity(
          opacity: effects.at(elapsed).clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, -8 * (1 - t)),
            child: Transform.scale(
              scale: 0.9 + 0.1 * t,
              alignment: Alignment.topLeft,
              child: child,
            ),
          ),
        );
      },
      child: DefaultTextStyle(
        style: style,
        child: AnimatedSize(
          duration: layoutSpring.duration,
          curve: layoutSpring,
          alignment: Alignment.topLeft,
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: _grown ? null : 0,
            child: body,
          ),
        ),
      ),
    );
  }

  /// [ghost] is the closing copy: only its details show, and they don't
  /// spring in again.
  Widget _body({
    required bool open,
    required double width,
    bool ghost = false,
  }) {
    final preview = widget.preview;
    final image = _loadable(preview.image);
    final description = preview.description;
    final hasMore = image != null || description != null;
    final play = _toggled && !ghost;

    Widget line = _PreviewLine(
      link: widget.link,
      preview: preview,
      icon: _loadable(preview.icon),
      dimmed: widget.dimmed,
      open: open,
      onToggle: hasMore ? _toggle : null,
      onImageError: _failed,
    );
    if (ghost) {
      line = Visibility.maintain(visible: false, child: line);
    }
    final imageView = open && image != null
        ? _ImageIn(
            play: play,
            child: _PreviewImage(
              src: image,
              dimmed: widget.dimmed,
              onOpen: () => openLink(widget.link),
              onError: () => _failed(image),
            ),
          )
        : null;
    final descriptionView = open && description != null
        ? Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _DescriptionIn(
              play: play,
              child: Text(
                description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
        : null;

    if (imageView != null && width >= _sideBySideWidth) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          SizedBox(
            width: 160,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: imageView,
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [line, ?descriptionView],
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line,
        if (imageView != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: imageView,
          ),
        ?descriptionView,
      ],
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine({
    required this.link,
    required this.preview,
    required this.icon,
    required this.dimmed,
    required this.open,
    required this.onToggle,
    required this.onImageError,
  });

  final String link;
  final Preview preview;
  final String? icon;
  final bool dimmed;
  final bool open;

  /// Null when there is nothing to expand.
  final VoidCallback? onToggle;
  final ValueChanged<String> onImageError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (:site, :title) = previewLabel(link, preview);
    final icon = this.icon;
    final onToggle = this.onToggle;
    final label = LayoutBuilder(
      builder: (context, constraints) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Opacity(
                opacity: dimmed ? 0.6 : 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    icon,
                    width: 16,
                    height: 16,
                    fit: BoxFit.contain,
                    errorBuilder: (context, _, _) {
                      onImageError(icon);
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
            child: Text(
              site,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: dimmed ? colors.onSurfaceVariant : colors.onSurface,
              ),
            ),
          ),
          if (title != null) ...[
            const ExcludeSemantics(child: Text('·')),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                link: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openLink(link),
                  child: label,
                ),
              ),
            ),
          ),
          if (onToggle != null)
            Padding(
              // Centres the chevron under the drag handle.
              padding: const EdgeInsets.only(left: 8, right: 2),
              child: Semantics(
                expanded: open,
                child: AppIconButton(
                  tooltip: 'Details',
                  size: 32,
                  iconSize: 20,
                  onPressed: onToggle,
                  icon: TweenAnimationBuilder<double>(
                    tween: Tween(end: open ? math.pi : 0),
                    duration: fastSpatial.duration,
                    curve: fastSpatial,
                    builder: (context, angle, child) =>
                        Transform.rotate(angle: angle, child: child),
                    child: const Icon(Icons.expand_more),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PreviewImage extends StatelessWidget {
  const _PreviewImage({
    required this.src,
    required this.dimmed,
    required this.onOpen,
    required this.onError,
  });

  final String src;
  final bool dimmed;
  final VoidCallback onOpen;
  final VoidCallback onError;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: GestureDetector(
      onTap: onOpen,
      child: Opacity(
        opacity: dimmed ? 0.6 : 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 1.91,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Image.network(
                src,
                fit: BoxFit.cover,
                errorBuilder: (context, _, _) {
                  onError();
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The web's `image-in`, from the image's top left corner.
class _ImageIn extends StatelessWidget {
  const _ImageIn({required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  Widget build(BuildContext context) => PlayOnce(
    duration: fastSpatial.duration,
    play: play,
    builder: (context, elapsed, child) => Opacity(
      opacity: effects.at(elapsed).clamp(0, 1),
      child: Transform.scale(
        scale: 0.6 + 0.4 * fastSpatial.at(elapsed),
        alignment: Alignment.topLeft,
        child: child,
      ),
    ),
    child: child,
  );
}

/// The web's `description-in`.
class _DescriptionIn extends StatelessWidget {
  const _DescriptionIn({required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  Widget build(BuildContext context) => PlayOnce(
    duration: defaultSpatial.duration,
    play: play,
    builder: (context, elapsed, child) {
      final t = defaultSpatial.at(elapsed);
      return Opacity(
        opacity: effects.at(elapsed).clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, -8 * (1 - t)),
          child: Transform.scale(
            scale: 0.96 + 0.04 * t,
            alignment: Alignment.topLeft,
            child: child,
          ),
        ),
      );
    },
    child: child,
  );
}
