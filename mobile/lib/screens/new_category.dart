import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../state/checklist_model.dart';
import '../theme.dart';
import 'controls.dart';
import 'feedback.dart';
import 'motion.dart';

/// The API's limit on category names.
const maxCategoryName = 100;

/// Asks for the name of the category that the item [itemTitle], dropped on
/// the new-category circle, moves into. Resolves to that category's id
/// (an existing one with the name, ignoring case, or a new one), or null
/// when cancelled.
Future<int?> showNewCategoryDialog(
  BuildContext context, {
  required String itemTitle,
  required ChecklistModel model,
}) => showAppDialog<int>(
  context,
  (_) => _NewCategoryDialog(itemTitle: itemTitle, model: model),
);

class _NewCategoryDialog extends StatefulWidget {
  const _NewCategoryDialog({required this.itemTitle, required this.model});

  final String itemTitle;
  final ChecklistModel model;

  @override
  State<_NewCategoryDialog> createState() => _NewCategoryDialogState();
}

class _NewCategoryDialogState extends State<_NewCategoryDialog>
    with InlineNotice {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    try {
      Navigator.pop(context, widget.model.categoryNamed(name));
    } on ConflictException catch (error) {
      showNotice(describeError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = this.notice;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New category', style: theme.dialogTheme.titleTextStyle),
              const SizedBox(height: 16),
              if (notice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ErrorNotice(message: notice, onDismiss: dismissNotice),
                ),
              Text(
                '“${widget.itemTitle}” moves into it.',
                style: theme.dialogTheme.contentTextStyle,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(maxCategoryName),
                ],
                onSubmitted: (_) => _create(),
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  ListenableBuilder(
                    listenable: _name,
                    builder: (context, _) => FilledButton(
                      onPressed: _name.text.trim().isEmpty ? null : _create,
                      child: const Text('Create'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The web's `.new-category-drop`: the circle an item is dropped on to
/// move it into a new category. It springs up while [shown], and grows and
/// fills while [over]. It takes no taps; whatever drags over it hit-tests
/// it by its box.
class NewCategoryDrop extends StatelessWidget {
  const NewCategoryDrop({super.key, required this.shown, required this.over});

  final bool shown;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final circle = TweenAnimationBuilder<double>(
      tween: Tween(end: over ? 1 : 0),
      duration: effects.duration,
      curve: effects,
      builder: (context, fill, _) {
        final f = fill.clamp(0.0, 1.0);
        return Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color.lerp(colors.primaryContainer, colors.primary, f),
            boxShadow: elevation3,
          ),
          child: Icon(
            Icons.new_label,
            color: Color.lerp(colors.onPrimaryContainer, colors.onPrimary, f),
          ),
        );
      },
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: shown ? 1 : 0),
          duration: effects.duration,
          curve: effects,
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity.clamp(0, 1), child: child),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: shown ? 0 : 112),
            duration: fastSpatial.duration,
            curve: fastSpatial,
            builder: (context, dy, child) =>
                Transform.translate(offset: Offset(0, dy), child: child),
            child: TweenAnimationBuilder<double>(
              tween: Tween(
                end: switch ((shown, over)) {
                  (false, _) => 0.4,
                  (true, true) => 1.3,
                  (true, false) => 1,
                },
              ),
              duration: fastSpatial.duration,
              curve: fastSpatial,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: circle,
            ),
          ),
        ),
      ),
    );
  }
}
