import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme.dart';
import 'checkbox.dart';
import 'controls.dart';
import 'link_preview.dart';
import 'motion.dart';
import 'title_field.dart';

/// A list's rows touch, with small inner corners and large outer ones; on a
/// spread board every row is a separate pill.
BorderRadius rowRadius({
  required bool first,
  required bool last,
  required bool spread,
}) {
  if (spread) return BorderRadius.circular(20);
  const outer = Radius.circular(22);
  const inner = Radius.circular(4);
  return BorderRadius.vertical(
    top: first ? outer : inner,
    bottom: last ? outer : inner,
  );
}

/// The background of the web's `.item` and `.add-line`, whose corners spring
/// when the row's place in its list changes.
class RowSurface extends StatelessWidget {
  const RowSurface({
    super.key,
    required this.radius,
    required this.color,
    required this.padding,
    required this.child,
    this.shadow,
    this.animate = true,
  });

  final BorderRadius radius;
  final Color color;
  final EdgeInsets padding;
  final Widget child;
  final List<BoxShadow>? shadow;
  final bool animate;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<BorderRadius?>(
    tween: BorderRadiusTween(end: radius),
    duration: animate ? defaultSpatial.duration : Duration.zero,
    curve: defaultSpatial,
    builder: (context, radius, child) => DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius,
        boxShadow: shadow,
      ),
      child: child,
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(padding: padding, child: child),
    ),
  );
}

/// The web's ItemRow: checkbox, always-editable title, delete and drag
/// handle, with the link preview under them.
///
/// [lifted] draws it as the drag overlay's copy: raised and inert.
class ItemRow extends StatefulWidget {
  const ItemRow({
    super.key,
    required this.item,
    this.preview,
    this.previewExpanded = false,
    this.brokenImages = const {},
    this.first = false,
    this.last = false,
    this.spread = false,
    this.lifted = false,
    this.onToggle,
    this.onRename,
    this.onPasteLines,
    this.onDelete,
    this.onGrab,
    this.onTogglePreview,
    this.onImageError,
  });

  final Item item;

  /// The preview of the item's link, once the server has found one.
  final Preview? preview;
  final bool previewExpanded;

  /// Image and icon URLs that failed to load, which are left out.
  final Set<String> brokenImages;
  final bool first;
  final bool last;
  final bool spread;
  final bool lifted;
  final ValueChanged<bool>? onToggle;
  final ValueChanged<String>? onRename;

  /// See [TitleInput.onPasteLines].
  final ValueChanged<List<String>>? onPasteLines;
  final VoidCallback? onDelete;
  final PointerDownEventListener? onGrab;
  final VoidCallback? onTogglePreview;
  final ValueChanged<String>? onImageError;

  @override
  State<ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<ItemRow> {
  // A preview the row was built with doesn't spring in, only one that
  // arrives (or replaces it) later.
  late final String? _shownLink = widget.preview == null
      ? null
      : widget.item.link;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ItemRow(:item, :preview, :lifted) = widget;
    final link = item.link;
    final row = RowSurface(
      radius: lifted
          ? BorderRadius.circular(20)
          : rowRadius(
              first: widget.first,
              last: widget.last,
              spread: widget.spread,
            ),
      color: lifted ? colors.surfaceContainerHigh : colors.surfaceContainer,
      shadow: lifted ? elevation3 : null,
      animate: !lifted,
      // The right padding puts the handle's dots as far from the edge as
      // the checkbox is from the left one.
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: 4,
            children: [
              ExpressiveCheckbox(
                value: item.checked,
                semanticLabel: item.title,
                onChanged: (checked) => widget.onToggle?.call(checked),
              ),
              Expanded(
                child: TitleField(
                  value: item.title,
                  label: 'Item title',
                  dimmed: item.checked,
                  onSave: (title) => widget.onRename?.call(title),
                  onPasteLines: widget.onPasteLines,
                ),
              ),
              AppIconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                semanticLabel: 'Delete ${item.title}',
                onPressed: () => widget.onDelete?.call(),
              ),
              DragHandle(onPointerDown: widget.onGrab),
            ],
          ),
          if (link != null && preview != null)
            Padding(
              // Under the title's text (the checkbox, the gap and the
              // field's padding in) and the row's actions.
              padding: const EdgeInsets.only(left: 40 + 4 + 8),
              child: Overhang(
                top: 4,
                child: LinkPreview(
                  key: ValueKey(link),
                  link: link,
                  preview: preview,
                  expanded: widget.previewExpanded,
                  springIn: link != _shownLink,
                  dimmed: item.checked,
                  brokenImages: widget.brokenImages,
                  onToggle: () => widget.onTogglePreview?.call(),
                  onImageError: (src) => widget.onImageError?.call(src),
                ),
              ),
            ),
        ],
      ),
    );
    if (!lifted) return row;
    return IgnorePointer(
      child: ExcludeFocus(child: ExcludeSemantics(child: row)),
    );
  }
}
