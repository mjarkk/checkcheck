import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/checklist_model.dart';
import '../state/days.dart';
import 'checklist_screen.dart';
import 'connect_phone_dialog.dart';
import 'controls.dart';
import 'item_row.dart';
import 'layout_motion.dart';
import 'motion.dart';

/// Recently deleted: what was deleted in the last 30 days, by the day it was
/// deleted on, each with a restore button; see "Client display conventions"
/// in /API.md.
class DeletedScreen extends StatefulWidget {
  const DeletedScreen({
    super.key,
    required this.model,
    required this.onDisconnect,
  });

  final ChecklistModel model;

  /// The top bar's Disconnect, which asks first.
  final VoidCallback onDisconnect;

  @override
  State<DeletedScreen> createState() => _DeletedScreenState();
}

class _DeletedScreenState extends State<DeletedScreen> {
  final _motion = LayoutMotion();

  /// Keys ([ChecklistModel.keyOf]) of rows playing their exit before they
  /// are restored.
  final _leaving = <int>{};

  ChecklistModel get _model => widget.model;

  @override
  void initState() {
    super.initState();
    // After the frame: refreshing notifies the screen below, which can't
    // rebuild while this one is first built. The offline copy shows
    // meanwhile, and a failure leaves it as it is.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _model.refresh().ignore(),
    );
  }

  void _restore(int key) => setState(() => _leaving.add(key));

  void _restored(int id, int key) {
    _model.restoreItem(id);
    setState(() => _leaving.remove(key));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _model,
    builder: (context, _) {
      final padding = MediaQuery.paddingOf(context);
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
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
                            onDisconnect: widget.onDisconnect,
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
      );
    },
  );

  List<Widget> _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final groups = groupByDay(_model.deletedItems);
    final now = DateTime.now();
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Transform.translate(
          // Like the web: the arrow's tip under the logo's left edge.
          offset: const Offset(-12, 0),
          child: Row(
            spacing: 4,
            children: [
              AppIconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
                onPressed: () => Navigator.maybePop(context),
              ),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Recently deleted',
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // Like the checklist's summary line.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          'Deleted items are kept for 30 days',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      if (groups.isEmpty)
        const EmptyState('Nothing deleted in the last 30 days')
      else
        for (final (index, group) in groups.indexed)
          _buildGroup(group, first: index == 0, now: now),
    ];
  }

  Widget _buildGroup(
    DayGroup group, {
    required bool first,
    required DateTime now,
  }) {
    final theme = Theme.of(context);
    final key = ('day', group.day);
    // The heading leaves with the group's last row.
    final leaving = group.items.every(
      (item) => _leaving.contains(_model.keyOf(item.id)),
    );
    final rows = group.items;
    return Padding(
      key: ValueKey(key),
      // The checklist's margins above its first and later sections.
      padding: EdgeInsets.only(top: first ? 24 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Motion(
            key: ValueKey(key),
            motionKey: key,
            ghost: !leaving,
            child: RowPresence(
              leaving: leaving,
              child: FadeIn(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Semantics(
                    header: true,
                    child: Text(
                      dayLabel(group.day, now: now),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final (index, item) in rows.indexed)
            _buildRow(item, first: index == 0, last: index == rows.length - 1),
        ],
      ),
    );
  }

  Widget _buildRow(
    DeletedItem item, {
    required bool first,
    required bool last,
  }) {
    final key = _model.keyOf(item.id);
    final leaving = _leaving.contains(key);
    return Motion(
      key: ValueKey(('deleted', key)),
      motionKey: ('deleted', key),
      enter: true,
      ghost: !leaving,
      child: Padding(
        padding: EdgeInsets.only(top: first ? 0 : 2),
        child: RowPresence(
          leaving: leaving,
          onLeft: () => _restored(item.id, key),
          child: _DeletedRow(
            item: item,
            first: first,
            last: last,
            onRestore: () => _restore(key),
          ),
        ),
      ),
    );
  }
}

/// The title, read-only, and a restore button where the checklist's rows
/// have their drag handle.
class _DeletedRow extends StatelessWidget {
  const _DeletedRow({
    required this.item,
    required this.first,
    required this.last,
    required this.onRestore,
  });

  final DeletedItem item;
  final bool first;
  final bool last;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return RowSurface(
      radius: rowRadius(first: first, last: last, spread: false),
      color: colors.surfaceContainer,
      // The title in line with the headings, and the button's centre where
      // the handle's is (12px padding plus half its 36px).
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
      child: Row(
        spacing: 4,
        children: [
          Expanded(
            child: Padding(
              // A title field's own padding.
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                item.title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: item.checked
                      ? colors.onSurfaceVariant
                      : colors.onSurface,
                ),
              ),
            ),
          ),
          AppIconButton(
            icon: const Icon(Icons.restore_from_trash_outlined),
            tooltip: 'Restore',
            semanticLabel: 'Restore ${item.title}',
            onPressed: onRestore,
          ),
        ],
      ),
    );
  }
}
