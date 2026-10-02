import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/checklist_model.dart';
import '../state/sections.dart';
import '../theme.dart';
import 'controls.dart';
import 'feedback.dart';
import 'layout_motion.dart';
import 'list_drag.dart';
import 'new_category.dart';

Future<void> showCategoriesDialog(BuildContext context, ChecklistModel model) =>
    showAppDialog<void>(context, (_) => CategoriesDialog(model: model));

/// The web's CategoryManager: the category order, Uncategorized included,
/// with renaming, deleting and a field for new ones.
class CategoriesDialog extends StatefulWidget {
  const CategoriesDialog({super.key, required this.model});

  final ChecklistModel model;

  @override
  State<CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<CategoriesDialog> with InlineNotice {
  final _name = TextEditingController();

  /// Scrolls everything under the heading.
  final scroll = ScrollController();

  final _motion = LayoutMotion();

  /// Drags rows by [_dragId].
  late final _drag = ListDrag<Object>(
    motion: _motion,
    motionKeyOf: (id) => ('category', id),
    onDrop: _drop,
    onStart: _model.holdServerUpdates,
    onEnd: _model.releaseServerUpdates,
  );

  /// While a row is dragged, the rows part to make room.
  bool get spread => _drag.lifted != null;

  ChecklistModel get _model => widget.model;

  @override
  void dispose() {
    _drag.dispose();
    scroll.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Reports a duplicate name inline.
  bool _run(void Function() change) {
    try {
      change();
      return true;
    } on ConflictException catch (error) {
      showNotice(describeError(error));
      return false;
    }
  }

  void _add() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    if (_run(() => _model.addCategory(name))) _name.clear();
  }

  Future<void> _delete(Category category, int itemCount) async {
    final delete = await confirm(
      context,
      title: 'Delete “${category.name}”?',
      message: _deleteMessage(itemCount),
      confirmLabel: 'Delete',
    );
    if (delete) _model.deleteCategory(category.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = this.notice;
    return DragArea<Object>(
      drag: _drag,
      scroll: scroll,
      liftedBuilder: _buildLifted,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 704),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                // The web's .dialog-head reaches 8px up and right into the
                // dialog's 24px padding.
                padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
                child: Row(
                  spacing: 8,
                  children: [
                    Expanded(
                      child: Text(
                        'Categories',
                        style: theme.dialogTheme.titleTextStyle,
                      ),
                    ),
                    AppIconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: CustomScrollView(
                  controller: scroll,
                  shrinkWrap: true,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      sliver: MotionScope.sliver(
                        controller: _motion,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (notice != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: ErrorNotice(
                                  message: notice,
                                  onDismiss: dismissNotice,
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              spacing: 12,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _name,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    textInputAction: TextInputAction.done,
                                    inputFormatters: [
                                      LengthLimitingTextInputFormatter(
                                        maxCategoryName,
                                      ),
                                    ],
                                    onSubmitted: (_) => _add(),
                                    decoration: const InputDecoration(
                                      labelText: 'New category',
                                    ),
                                  ),
                                ),
                                ListenableBuilder(
                                  listenable: _name,
                                  builder: (context, _) => FilledButton.tonal(
                                    onPressed: _name.text.trim().isEmpty
                                        ? null
                                        : _add,
                                    style: largeButton,
                                    child: const Text('Add'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            ListenableBuilder(
                              listenable: Listenable.merge([_model, _drag]),
                              builder: (context, _) => buildList(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [_model.keyOf] the category's id, which outlives an id swap, or
  /// `none` for Uncategorized.
  Object _dragId(Category? category) =>
      category == null ? 'none' : _model.keyOf(category.id);

  List<Category?> get _entries => [
    for (final id in _model.categoryOrder)
      if (id == null) null else ?_model.categoryById(id),
  ];

  Category? _categoryOf(Object dragId) =>
      dragId is int ? _model.categoryById(dragId) : null;

  int _countOf(Category? category, Counts counts) => category == null
      ? counts.uncategorized
      : counts.byCategory[category.id] ?? 0;

  Widget _buildLifted(BuildContext context, Object dragId) {
    final category = _categoryOf(dragId);
    return CategoryRow(
      category: category,
      itemCount: _countOf(category, countItems(_model.items)),
      lifted: true,
    );
  }

  void _drop(Object dragId, DropTarget target) {
    final entries = _entries;
    final moving = entries.indexWhere((c) => _dragId(c) == dragId);
    if (moving < 0) return;
    final rest = [...entries];
    final category = rest.removeAt(moving);
    rest.insert(math.min(target.index, rest.length), category);
    final next = [for (final c in rest) c?.id];
    final current = [for (final c in entries) c?.id];
    if (next.indexed.any((e) => e.$2 != current[e.$1])) {
      _model.setCategoryOrder(next);
    }
  }

  /// Every row of the category order, Uncategorized included, spaced by
  /// hand so the hidden lifted row takes no room.
  Widget buildList() {
    final entries = _entries;
    final counts = countItems(_model.items);
    final lifted = _drag.lifted;
    bool hidden(Category? category) => _dragId(category) == lifted?.id;
    final children = withGap<Category?, (Widget, bool)>(
      rows: entries,
      zone: 'categories',
      lifted: lifted,
      hidden: hidden,
      build: (category) => (
        buildRow(
          category,
          counts: counts,
          first: category == entries.first,
          last: category == entries.last,
          hidden: hidden(category),
        ),
        hidden(category),
      ),
      gap: () => (
        DragGap(
          key: const ValueKey('drag-gap'),
          motionKey: ('category', lifted!.id),
          height: lifted.height,
        ),
        false,
      ),
    );
    final gap = spread ? 8.0 : 2.0;
    final spaced = <Widget>[];
    var placed = false;
    for (final (child, hidden) in children) {
      spaced.add(
        KeyedSubtree(
          key: child.key,
          child: Padding(
            padding: EdgeInsets.only(top: hidden || !placed ? 0 : gap),
            child: child,
          ),
        ),
      );
      if (!hidden) placed = true;
    }
    return DragZone(
      zone: 'categories',
      rows: [
        for (final category in entries)
          if (!hidden(category)) _dragId(category),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: spaced,
      ),
    );
  }

  Widget buildRow(
    Category? category, {
    required Counts counts,
    required bool first,
    required bool last,
    required bool hidden,
  }) {
    final id = _dragId(category);
    final count = _countOf(category, counts);
    final landed = _drag.landed;
    return Motion(
      key: ValueKey(('category', id)),
      motionKey: hidden ? null : ('category', id),
      child: Offstage(
        offstage: hidden,
        child: LandingShadow(
          landing: landed?.id == id ? landed!.count : null,
          child: CategoryRow(
            category: category,
            itemCount: count,
            first: first,
            last: last,
            spread: spread,
            onRename: category == null
                ? null
                : (name) =>
                      _run(() => _model.renameCategory(category.id, name)),
            onDelete: category == null ? null : () => _delete(category, count),
            onGrab: (event) => _drag.grab(event, id),
          ),
        ),
      ),
    );
  }
}

String _deleteMessage(int itemCount) => switch (itemCount) {
  0 => 'Its items become uncategorized.',
  1 => 'Its 1 item becomes uncategorized.',
  _ => 'Its $itemCount items become uncategorized.',
};

/// The web's CategoryRow. [category] is null for Uncategorized, which can be
/// moved but not renamed or deleted. [lifted] draws it as the drag
/// overlay's copy: raised and inert.
class CategoryRow extends StatefulWidget {
  const CategoryRow({
    super.key,
    required this.category,
    required this.itemCount,
    this.first = false,
    this.last = false,
    this.spread = false,
    this.lifted = false,
    this.onRename,
    this.onDelete,
    this.onGrab,
  });

  final Category? category;
  final int itemCount;
  final bool first;
  final bool last;
  final bool spread;
  final bool lifted;
  final ValueChanged<String>? onRename;
  final VoidCallback? onDelete;
  final PointerDownEventListener? onGrab;

  @override
  State<CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<CategoryRow> {
  bool _editing = false;

  String get _name => widget.category?.name ?? 'Uncategorized';

  void _finishEdit(String? value) {
    setState(() => _editing = false);
    final name = value?.trim();
    if (name != null && name.isNotEmpty && name != _name) {
      widget.onRename?.call(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final count = widget.itemCount;
    final renamable = widget.category != null;
    const outer = Radius.circular(20);
    const inner = Radius.circular(4);
    final row = DecoratedBox(
      decoration: BoxDecoration(
        color: widget.lifted
            ? colors.surfaceContainerHigh
            : colors.surfaceContainerLowest,
        borderRadius: widget.lifted || widget.spread
            ? BorderRadius.circular(20)
            : BorderRadius.vertical(
                top: widget.first ? outer : inner,
                bottom: widget.last ? outer : inner,
              ),
        boxShadow: widget.lifted ? elevation3 : null,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            spacing: 4,
            children: [
              Expanded(
                child: _editing
                    ? InlineEdit(
                        initial: _name,
                        label: 'Category name',
                        maxLength: maxCategoryName,
                        onDone: _finishEdit,
                      )
                    : Text.rich(
                        TextSpan(
                          // One paragraph keeps the two baseline-aligned. At
                          // 16px an en space is the web's 8px gap, and the
                          // no-break space keeps the count whole on a wrap.
                          text: '$_name ',
                          children: [
                            TextSpan(
                              text: '$count ${count == 1 ? 'item' : 'items'}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w400,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: renamable ? null : colors.onSurfaceVariant,
                        ),
                      ),
              ),
              if (renamable && !_editing) ...[
                AppIconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Rename',
                  semanticLabel: 'Rename $_name',
                  onPressed: () => setState(() => _editing = true),
                ),
                AppIconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  semanticLabel: 'Delete $_name',
                  onPressed: widget.onDelete,
                ),
              ],
              DragHandle(onPointerDown: widget.onGrab),
            ],
          ),
        ),
      ),
    );
    if (!widget.lifted) return row;
    return IgnorePointer(
      child: ExcludeFocus(child: ExcludeSemantics(child: row)),
    );
  }
}
