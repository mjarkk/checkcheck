import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/checklist_model.dart';
import '../state/sections.dart';
import 'add_item_line.dart';
import 'add_lines_screen.dart';
import 'categories_dialog.dart';
import 'connect_phone_dialog.dart';
import 'controls.dart';
import 'deleted_screen.dart';
import 'feedback.dart';
import 'item_row.dart';
import 'layout_motion.dart';
import 'list_drag.dart';
import 'more_menu.dart';
import 'motion.dart';
import 'move_items_dialog.dart';
import 'new_category.dart';

/// The web app's one page: every section of the checklist, see "Client
/// display conventions" in /API.md.
class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({
    super.key,
    required this.model,
    required this.onDisconnect,
  });

  final ChecklistModel model;
  final VoidCallback onDisconnect;

  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  /// Scrolls the whole page; every row is built, none lazily.
  final scroll = ScrollController();

  final _motion = LayoutMotion();

  /// Drags rows by [ChecklistModel.keyOf], which outlives an id swap.
  late final _drag = ListDrag<int>(
    motion: _motion,
    motionKeyOf: _rowKey,
    onDrop: _drop,
    onStart: _model.holdServerUpdates,
    onEnd: _model.releaseServerUpdates,
  );

  /// While an item is dragged: every section shows its Done list, the
  /// lists part to make room and the ⋯ buttons hide.
  bool get spread => _drag.lifted != null;

  /// The new-category circle, which a dragged item can be dropped on.
  final newCategoryDrop = GlobalKey();

  /// The key of an item dropped on the circle, hidden while its category
  /// is named.
  int? _parked;

  /// What the last build showed, which drops are resolved against.
  List<Section> _sections = const [];

  /// Keys ([ChecklistModel.keyOf]) of items an Add item line created and is
  /// still being typed in: the line shows them, the list doesn't.
  final _drafts = <int>{};

  /// Keys of rows playing their exit before they are deleted.
  final _leaving = <int>{};

  /// Keys of rows whose link preview is expanded, for the session.
  final _expanded = <int>{};

  /// Image and icon URLs that failed to load, for the session.
  final _brokenImages = <String>{};

  late final StreamSubscription<ApiException> _failures;
  late final AppLifecycleListener _lifecycle;

  ChecklistModel get _model => widget.model;

  @override
  void initState() {
    super.initState();
    _failures = _model.failures.listen((error) {
      if (mounted) showError(context, error);
    });
    // Agents change the list through MCP too, so catch up on every return.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _refresh();
        _model.followEvents();
      },
      onPause: () {
        _drag.cancel();
        _model.stopEvents();
      },
    );
    _refresh();
    _model.followEvents();
  }

  @override
  void dispose() {
    _model.stopEvents();
    _failures.cancel();
    _lifecycle.dispose();
    _drag.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await _model.refresh();
    } on ApiException catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _disconnect() async {
    final host = Uri.parse(_model.api.baseUrl).authority;
    final disconnect = await confirm(
      context,
      title: 'Disconnect from $host?',
      message: 'You will need the token to connect again.',
      confirmLabel: 'Disconnect',
    );
    if (disconnect) widget.onDisconnect();
  }

  void _update(VoidCallback change) {
    // Add item lines finish their entry after they unmount, which can be
    // after this screen did.
    if (mounted) setState(change);
  }

  bool _isDraft(Item item) => _drafts.contains(_model.keyOf(item.id));

  /// A key for [section] that survives its category's temporary id being
  /// swapped for the server's.
  String _keyOf(Section section) => switch (section.categoryId) {
    final id? => 'c${_model.keyOf(id)}',
    null => 'none',
  };

  List<Item> _settled(List<Item> rows) => [
    for (final item in rows)
      if (!_leaving.contains(_model.keyOf(item.id))) item,
  ];

  /// Rows play their exit, then are deleted.
  void _leave(Iterable<Item> items) => setState(() {
    _leaving.addAll(items.map((item) => _model.keyOf(item.id)));
  });

  void _left(int id, int key) {
    _model.deleteItems([id]);
    setState(() => _leaving.remove(key));
  }

  /// Asks first when [rows] include items not done yet.
  Future<void> _deleteAll(List<Item> rows, String? sectionTitle) async {
    final open = rows.where((item) => !item.checked).length;
    if (open > 0) {
      final delete = await confirm(
        context,
        title: sectionTitle == null
            ? 'Delete all items?'
            : 'Delete all items in “$sectionTitle”?',
        message: notDoneMessage(open, rows.length),
        confirmLabel: 'Delete all',
      );
      if (!delete || !mounted) return;
    }
    _leave([
      for (final item in rows)
        if (_model.itemById(item.id) != null &&
            !_leaving.contains(_model.keyOf(item.id)))
          item,
    ]);
  }

  /// Moves what [key]'s section holds when a category is picked, which may
  /// differ from what the dialog counted.
  Future<void> _moveAll(String key) async {
    int count(Section section) =>
        _settled([...section.open, ...section.done]).length;
    final from = _sections.where((s) => _keyOf(s) == key).firstOrNull;
    if (from == null) return;
    final target = await showMoveItemsDialog(
      context,
      sectionTitle: from.title ?? '',
      itemCount: count(from),
      targets: [
        for (final section in _sections)
          if (section != from)
            (
              categoryId: section.categoryId,
              name: section.title ?? '',
              itemCount: count(section),
            ),
      ],
    );
    if (target == null || !mounted) return;
    final now = buildSections(
      _model.items,
      _model.categories,
      _model.categoryOrder,
      hidden: _isDraft,
    ).where((s) => _keyOf(s) == key).firstOrNull;
    if (now == null) return;
    final moving = {
      for (final item in _settled([...now.open, ...now.done])) item.id,
    };
    _model.moveItems([
      for (final item in _model.items)
        if (moving.contains(item.id)) item.id,
    ], target.id);
  }

  void _imageFailed(String src) {
    if (_brokenImages.add(src)) _update(() {});
  }

  /// Shows a paste's [lines] on the Add items screen and resolves, once that
  /// is gone, to the ones chosen there, or null.
  Future<List<String>?> _chooseLines(List<String> lines, String message) {
    // Or coming back would focus the field again, raising the keyboard over
    // the new rows.
    FocusManager.instance.primaryFocus?.unfocus();
    final route = MaterialPageRoute<List<String>>(
      builder: (context) => AddLinesScreen(
        model: _model,
        onDisconnect: _disconnect,
        lines: lines,
        message: message,
      ),
    );
    Navigator.push(context, route);
    // After the transition, so the new rows spring in where they can be
    // seen.
    return route.completed;
  }

  /// The chosen lines of a paste go at the end of [section]'s open list.
  Future<void> _pasteInto(Section section, List<String> lines) async {
    final chosen = await _chooseLines(lines, switch (section.title) {
      final title? => 'Choose the lines to add to “$title”.',
      null => 'Choose the lines to add.',
    });
    if (chosen == null || !mounted) return;
    _model.addItems(chosen, categoryId: section.categoryId);
  }

  /// The chosen lines of a paste go directly after [item], into its list,
  /// or at the end of that list if it is gone by then.
  Future<void> _pasteBelow(Item item, List<String> lines) async {
    final chosen = await _chooseLines(
      lines,
      'Choose the lines to add below '
      '“${_model.itemById(item.id)?.title ?? item.title}”.',
    );
    if (chosen == null || !mounted) return;
    final anchor = _model.itemById(item.id);
    if (anchor == null) {
      _model.addItems(
        chosen,
        categoryId: item.categoryId,
        checked: item.checked,
      );
      return;
    }
    final items = _model.items;
    final next = items.indexWhere((i) => i.id == anchor.id) + 1;
    _model.addItems(
      chosen,
      categoryId: anchor.categoryId,
      checked: anchor.checked,
      before: next < items.length ? items[next].id : null,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_model, _drag]),
    builder: (context, _) {
      final padding = MediaQuery.paddingOf(context);
      final holding = _parked != null;
      return Scaffold(
        body: DragArea<int>(
          drag: _drag,
          scroll: scroll,
          circle: newCategoryDrop,
          liftedBuilder: _buildLifted,
          foreground: _model.loaded
              ? Positioned(
                  left: math.max(24, padding.left),
                  bottom: math.max(24, padding.bottom),
                  child: NewCategoryDrop(
                    key: newCategoryDrop,
                    shown: spread || holding,
                    over:
                        holding || _drag.lifted?.target.zone == newCategoryZone,
                  ),
                )
              : null,
          child: SafeArea(
            bottom: false,
            child: RefreshIndicator.adaptive(
              onRefresh: _refresh,
              child: CustomScrollView(
                controller: scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  MotionScope.sliver(
                    controller: _motion,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 704),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            8,
                            16,
                            112 + padding.bottom,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TopBar(
                                onConnectPhone: () => showConnectPhoneDialog(
                                  context,
                                  server: _model.api.baseUrl,
                                  token: _model.api.token,
                                ),
                                onDisconnect: _disconnect,
                              ),
                              ..._buildPage(context),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _buildLifted(BuildContext context, int key) {
    final item = _model.itemById(key);
    if (item == null) return const SizedBox.shrink();
    return ItemRow(
      item: item,
      preview: _model.previewOf(item),
      previewExpanded: _expanded.contains(key),
      brokenImages: _brokenImages,
      lifted: true,
    );
  }

  List<Widget> _buildPage(BuildContext context) {
    if (!_model.loaded) {
      return [
        if (_model.loading)
          const EmptyState('Loading…')
        else
          EmptyState(
            "Couldn't load your checklist.",
            action: FilledButton.tonal(
              onPressed: _refresh,
              child: const Text('Try again'),
            ),
          ),
      ];
    }
    final theme = Theme.of(context);
    final sections = buildSections(
      _model.items,
      _model.categories,
      _model.categoryOrder,
      hidden: _isDraft,
    );
    _sections = sections;
    final counts = countItems(_model.items);
    final first = sections.first;
    return [
      // The web's 12px summary margin, less the head's overhang.
      const SizedBox(height: 2),
      _ListHead(
        // Without categories the only section has no heading to carry its
        // menu.
        menu: first.title == null ? _sectionMenu(first) : null,
        animate: false,
        child: Text(
          summaryText(counts.open, counts.done),
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      for (final (index, section) in sections.indexed)
        _buildSection(section, first: index == 0),
      const SizedBox(height: 40),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => showCategoriesDialog(context, _model),
            style: _footerButton,
            icon: const Icon(Icons.label_outline),
            label: const Text('Manage categories'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) =>
                    DeletedScreen(model: _model, onDisconnect: _disconnect),
              ),
            ),
            style: _footerButton,
            icon: const Icon(Icons.auto_delete_outlined),
            label: const Text('Recently deleted'),
          ),
        ],
      ),
    ];
  }

  static final _footerButton = FilledButton.styleFrom(
    iconSize: 18,
    padding: const EdgeInsetsDirectional.only(start: 20, end: 24),
  );

  Widget _buildSection(Section section, {required bool first}) {
    final theme = Theme.of(context);
    final key = _keyOf(section);
    final title = section.title;
    // The web's margins, less the overhang of the heads around them.
    final above =
        (first ? 24 - _ListHead.overhang : (spread ? 44.0 : 28.0)) -
        (title == null ? 0 : _ListHead.overhang);
    return Padding(
      key: ValueKey(key),
      padding: EdgeInsets.only(top: above),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Motion(
              key: ValueKey(('title', key)),
              motionKey: ('title', key),
              child: _ListHead(
                menu: _sectionMenu(section),
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          buildList(section, done: false),
          if (section.done.isNotEmpty || spread) ...[
            SizedBox(height: (spread ? 24 : 16) - _ListHead.overhang),
            // The web's 8px under the Done heading is less than its
            // overhang.
            Motion(
              key: ValueKey(('done', key)),
              motionKey: ('done', key),
              child: Overhang(
                bottom: _ListHead.overhang - 8,
                child: _ListHead(
                  menu: _doneMenu(section),
                  child: Text(
                    'Done',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.26,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            buildList(section, done: true),
          ],
        ],
      ),
    );
  }

  Object _rowKey(int key) => ('item', key);

  bool _hidden(Item item) {
    final key = _model.keyOf(item.id);
    return key == _drag.lifted?.id || key == _parked;
  }

  /// One of [section]'s lists: its open rows and Add item line, or its Done
  /// rows. Its children are spaced by hand: a hidden row takes no room, not
  /// even a gap.
  Widget buildList(Section section, {required bool done}) {
    final key = _keyOf(section);
    final zone = (key, done);
    final rows = done ? section.done : section.open;
    final lifted = _drag.lifted;
    final children = <(Widget, bool)>[
      ...withGap<Item, (Widget, bool)>(
        rows: rows,
        zone: zone,
        lifted: lifted,
        hidden: _hidden,
        build: (item) => (
          buildRow(
            item,
            first: item == rows.first,
            last: done && item == rows.last,
          ),
          _hidden(item),
        ),
        gap: () => (
          DragGap(
            key: const ValueKey('drag-gap'),
            motionKey: _rowKey(lifted!.id),
            height: lifted.height,
          ),
          false,
        ),
      ),
      if (!done) (_buildAddLine(section, first: rows.isEmpty), false),
    ];
    final gap = spread ? 10.0 : 2.0;
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
      key: ValueKey((done ? 'done-list' : 'open-list', key)),
      zone: zone,
      rows: [
        for (final item in rows)
          if (!_hidden(item)) _model.keyOf(item.id),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: done && spread ? 56 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: spaced,
        ),
      ),
    );
  }

  Widget buildRow(Item item, {required bool first, required bool last}) {
    final key = _model.keyOf(item.id);
    final hidden = _hidden(item);
    final leaving = _leaving.contains(key);
    final landed = _drag.landed;
    return Motion(
      key: ValueKey(('item', key)),
      motionKey: hidden ? null : _rowKey(key),
      enter: true,
      ghost: !leaving,
      child: Offstage(
        offstage: hidden,
        child: RowPresence(
          leaving: leaving,
          onLeft: () => _left(item.id, key),
          child: LandingShadow(
            landing: landed?.id == key ? landed!.count : null,
            child: ItemRow(
              item: item,
              preview: _model.previewOf(item),
              previewExpanded: _expanded.contains(key),
              brokenImages: _brokenImages,
              first: first,
              last: last,
              spread: spread,
              onToggle: (checked) => _model.setChecked([item.id], checked),
              onRename: (title) => _model.renameItem(item.id, title),
              onPasteLines: (lines) => _pasteBelow(item, lines),
              onDelete: () => _leave([item]),
              onGrab: (event) => _drag.grab(event, key),
              onTogglePreview: () => setState(() {
                if (!_expanded.remove(key)) _expanded.add(key);
              }),
              onImageError: _imageFailed,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddLine(Section section, {required bool first}) {
    final key = _keyOf(section);
    return Motion(
      key: ValueKey(('add', key)),
      motionKey: ('add', key),
      enter: true,
      child: AddItemLine(
        label: switch (section.title) {
          final title? => 'Add item to $title',
          null => 'Add item',
        },
        first: first,
        spread: spread,
        onCreate: (title) {
          final id = _model.addItem(title, categoryId: section.categoryId);
          _update(() => _drafts.add(_model.keyOf(id)));
          return id;
        },
        onRename: _model.renameItem,
        onRelease: (id) {
          // The new row starts where the line is instead of entering.
          _motion.inherit(('add', key), _rowKey(_model.keyOf(id)));
          _update(() => _drafts.remove(_model.keyOf(id)));
        },
        onDiscard: (id) {
          _model.deleteItems([id]);
          _update(() => _drafts.remove(_model.keyOf(id)));
        },
        onPasteLines: (lines) => _pasteInto(section, lines),
      ),
    );
  }

  void _drop(int key, DropTarget target) {
    if (target.zone == newCategoryZone) {
      _park(key);
      return;
    }
    final (sectionKey, done) = target.zone as (String, bool);
    final item = _model.itemById(key);
    final section = _sections.where((s) => _keyOf(s) == sectionKey).firstOrNull;
    if (item == null || section == null) return;
    final move = planDrop(
      _model.items,
      item.id,
      categories: _model.categories,
      categoryId: section.categoryId,
      checked: done,
      index: target.index,
      hidden: _isDraft,
    );
    if (move != null) _model.moveItem(item.id, move);
  }

  /// The item waits in the circle for its new category's name, then flies
  /// out of it: into that category, or back where it was.
  Future<void> _park(int key) async {
    final circle = newCategoryDrop.currentContext?.findRenderObject();
    final from = circle is RenderBox && circle.hasSize
        ? circle.localToGlobal(circle.size.center(Offset.zero))
        : null;
    setState(() => _parked = key);
    final categoryId = await showNewCategoryDialog(
      context,
      itemTitle: _model.itemById(key)?.title ?? '',
      model: _model,
    );
    if (!mounted) return;
    if (from != null) {
      _motion.prepare(start: MotionStart.point(_rowKey(key), from));
    }
    final item = _model.itemById(key);
    if (item != null && categoryId != null) {
      final resolved = _model.categoryById(categoryId)?.id ?? categoryId;
      if (resolved != item.categoryId) {
        _model.moveItem(item.id, ItemMove(category: (id: categoryId)));
      }
    }
    setState(() => _parked = null);
  }

  Widget? _sectionMenu(Section section) {
    final open = _settled(section.open);
    final all = [...open, ..._settled(section.done)];
    if (all.isEmpty) return null;
    return MoreButton(
      label: switch (section.title) {
        final title? => 'Actions for $title',
        null => 'Actions for all items',
      },
      hidden: spread,
      actions: [
        MenuAction(
          label: 'Mark all as done',
          icon: Icons.done_all,
          disabled: open.isEmpty,
          onSelect: () => _model.setChecked([for (final i in open) i.id], true),
        ),
        if (_model.categories.isNotEmpty)
          MenuAction(
            label: 'Move all to…',
            icon: Icons.drive_file_move_outlined,
            onSelect: () => _moveAll(_keyOf(section)),
          ),
        MenuAction(
          label: 'Delete all',
          icon: Icons.delete_sweep_outlined,
          danger: true,
          onSelect: () => _deleteAll(all, section.title),
        ),
      ],
    );
  }

  Widget? _doneMenu(Section section) {
    final done = _settled(section.done);
    if (done.isEmpty) return null;
    return MoreButton(
      label: switch (section.title) {
        final title? => 'Actions for done items in $title',
        null => 'Actions for done items',
      },
      hidden: spread,
      actions: [
        MenuAction(
          label: 'Unmark all as done',
          icon: Icons.remove_done,
          onSelect: () =>
              _model.setChecked([for (final i in done) i.id], false),
        ),
        MenuAction(
          label: 'Delete all',
          icon: Icons.delete_sweep_outlined,
          danger: true,
          onSelect: () => _deleteAll(done, section.title),
        ),
      ],
    );
  }
}

/// A heading line ending in [menu], centred over the rows' drag handles.
///
/// The ⋯ button is taller than the line and overhangs it by [overhang]
/// above and below. The box takes that room itself, so the whole button
/// stays tappable, and the space around it is that much less.
class _ListHead extends StatelessWidget {
  const _ListHead({required this.child, this.menu, this.animate = true});

  static const overhang = 10.0;

  final Widget child;
  final Widget? menu;

  /// The web's list heads fade in when they appear; the summary doesn't.
  final bool animate;

  @override
  Widget build(BuildContext context) => FadeIn(
    play: animate,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: DragHandle.width / 2 - 8),
      child: Row(
        spacing: 8,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: overhang),
              child: child,
            ),
          ),
          ?menu,
        ],
      ),
    ),
  );
}

/// Also on the screens pushed over this one.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.onConnectPhone,
    required this.onDisconnect,
  });

  final VoidCallback onConnectPhone;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    // The icon buttons need the wordmark's room on the narrowest phones.
    final wordmark = MediaQuery.sizeOf(context).width >= 352;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        spacing: 8,
        children: [
          Expanded(
            child: Row(
              spacing: 10,
              children: [
                const Logo(),
                if (wordmark)
                  Flexible(
                    child: Text(
                      'CheckCheck',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
              ],
            ),
          ),
          Row(
            spacing: 4,
            children: [
              AppIconButton(
                icon: const Icon(Icons.qr_code),
                tooltip: 'Connect phone',
                iconSize: 20,
                onPressed: onConnectPhone,
              ),
              AppIconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Disconnect',
                iconSize: 20,
                onPressed: onDisconnect,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
