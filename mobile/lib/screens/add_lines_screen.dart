import 'package:flutter/material.dart';

import '../state/checklist_model.dart';
import 'checkbox.dart';
import 'checklist_screen.dart';
import 'connect_phone_dialog.dart';
import 'controls.dart';
import 'item_row.dart';
import 'title_field.dart';

/// Add items: the lines of a paste as rows to check, under [message], which
/// says where they go; see "Client display conventions" in /API.md. Pops
/// with the checked lines in order on OK, otherwise with null.
class AddLinesScreen extends StatefulWidget {
  const AddLinesScreen({
    super.key,
    required this.model,
    required this.onDisconnect,
    required this.lines,
    required this.message,
  });

  final ChecklistModel model;

  /// The top bar's Disconnect, which asks first.
  final VoidCallback onDisconnect;

  /// A paste's [pastedLines]; this screen leaves out the duplicates and says
  /// how many.
  final List<String> lines;
  final String message;

  @override
  State<AddLinesScreen> createState() => _AddLinesScreenState();
}

class _AddLinesScreenState extends State<AddLinesScreen> {
  late final _lines = withoutDuplicates(widget.lines);
  late final _checked = List.filled(_lines.length, true);

  List<String> get _chosen => [
    for (final (index, line) in _lines.indexed)
      if (_checked[index]) line,
  ];

  @override
  Widget build(BuildContext context) {
    final api = widget.model.api;
    return Scaffold(
      // The page scrolls on under the bar.
      extendBody: true,
      bottomNavigationBar: _ActionBar(
        onCancel: () => Navigator.pop(context),
        onOk: _checked.contains(true)
            ? () => Navigator.pop(context, _chosen)
            : null,
      ),
      // Its own context, whose bottom padding includes the bar.
      body: Builder(
        builder: (context) {
          final padding = MediaQuery.paddingOf(context);
          return SafeArea(
            bottom: false,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 704),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          8,
                          16,
                          24 + padding.bottom,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TopBar(
                              onConnectPhone: () => showConnectPhoneDialog(
                                context,
                                server: api.baseUrl,
                                token: api.token,
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
          );
        },
      ),
    );
  }

  List<Widget> _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final dropped = widget.lines.length - _lines.length;
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
                    'Add items',
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
          switch (dropped) {
            0 => widget.message,
            1 => '${widget.message} 1\u00a0duplicate line was left out.',
            _ =>
              '${widget.message} $dropped\u00a0duplicate lines were left out.',
          },
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      // The checklist's margin above its first section.
      const SizedBox(height: 24),
      for (final (index, line) in _lines.indexed)
        Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 2),
          child: _LineRow(
            line: line,
            checked: _checked[index],
            first: index == 0,
            last: index == _lines.length - 1,
            onToggle: () => setState(() => _checked[index] = !_checked[index]),
          ),
        ),
    ];
  }
}

/// Cancel and OK, pinned to the bottom of the screen.
class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.onCancel, required this.onOk});

  final VoidCallback onCancel;

  /// Null while nothing is checked.
  final VoidCallback? onOk;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          // The buttons end where the rows do.
          constraints: const BoxConstraints(maxWidth: 704),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
                FilledButton(onPressed: onOk, child: const Text('OK')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A row like the checklist's: the checkbox, then the line where a title's
/// text is. A tap anywhere toggles it.
class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.checked,
    required this.first,
    required this.last,
    required this.onToggle,
  });

  final String line;
  final bool checked;
  final bool first;
  final bool last;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: RowSurface(
        radius: rowRadius(first: first, last: last, spread: false),
        color: theme.colorScheme.surfaceContainer,
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
        child: Row(
          spacing: 4,
          children: [
            ExpressiveCheckbox(
              value: checked,
              semanticLabel: line,
              onChanged: (_) => onToggle(),
            ),
            Expanded(
              child: Padding(
                // A title field's own padding.
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: ExcludeSemantics(
                  child: Text(line, style: theme.textTheme.bodyLarge),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
