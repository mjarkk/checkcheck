import 'package:flutter/material.dart';

import 'controls.dart';
import 'feedback.dart';

/// [categoryId] is null for Uncategorized.
typedef MoveTarget = ({int? categoryId, String name, int itemCount});

/// The web's MoveItemsDialog. Resolves to the picked target's category,
/// `(id: null)` for Uncategorized, or null when cancelled.
Future<({int? id})?> showMoveItemsDialog(
  BuildContext context, {
  required String sectionTitle,
  required int itemCount,
  required List<MoveTarget> targets,
}) => showAppDialog<({int? id})>(
  context,
  (_) => _MoveItemsDialog(
    message:
        'Choose a category for '
        '${itemCount == 1 ? 'the item' : 'the $itemCount items'} '
        'in “$sectionTitle”.',
    targets: targets,
  ),
);

class _MoveItemsDialog extends StatelessWidget {
  const _MoveItemsDialog({required this.message, required this.targets});

  final String message;
  final List<MoveTarget> targets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Move all items',
                    style: theme.dialogTheme.titleTextStyle,
                  ),
                  const SizedBox(height: 16),
                  Text(message, style: theme.dialogTheme.contentTextStyle),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.symmetric(
                    horizontal: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 2,
                    children: [
                      for (final (index, target) in targets.indexed)
                        _TargetRow(
                          target: target,
                          first: index == 0,
                          last: index == targets.length - 1,
                          onTap: () =>
                              Navigator.pop(context, (id: target.categoryId)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Looks like a categories dialog row without its buttons and handle.
class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.target,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final MoveTarget target;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final count = target.itemCount;
    const outer = Radius.circular(20);
    const inner = Radius.circular(4);
    return Semantics(
      button: true,
      child: ClipRRect(
        // Gives the state layer the row's corners too.
        borderRadius: BorderRadius.vertical(
          top: first ? outer : inner,
          bottom: last ? outer : inner,
        ),
        child: ColoredBox(
          color: colors.surfaceContainerLowest,
          child: Pressable(
            onTap: onTap,
            color: colors.onSurface,
            radius: 0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  // CategoryRow's paragraph: an en space, then a count kept
                  // whole by a no-break space.
                  child: Text.rich(
                    TextSpan(
                      text: '${target.name} ',
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
                      color: target.categoryId == null
                          ? colors.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
