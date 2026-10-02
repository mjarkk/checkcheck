import 'dart:async';

import 'package:flutter/material.dart';

import 'item_row.dart';
import 'title_field.dart';

/// The web's AddItemLine: what is typed becomes an item the way a title
/// saves itself. The first save creates it as a draft, which the list leaves
/// out while this line still holds it; later saves rename it. Enter or
/// leaving the field finishes the entry: the draft is released into the
/// list, or deleted if its text was cleared, and the line empties for the
/// next one, keeping the keyboard up after Enter.
class AddItemLine extends StatefulWidget {
  const AddItemLine({
    super.key,
    required this.label,
    required this.onCreate,
    required this.onRename,
    required this.onRelease,
    required this.onDiscard,
    this.onPasteLines,
    this.first = true,
    this.last = true,
    this.spread = false,
  });

  final String label;

  /// Creates the draft and returns its id.
  final int Function(String title) onCreate;
  final void Function(int id, String title) onRename;

  /// Shows a finished draft in the list.
  final ValueChanged<int> onRelease;

  /// Deletes a draft whose text was cleared.
  final ValueChanged<int> onDiscard;

  /// See [TitleInput.onPasteLines].
  final ValueChanged<List<String>>? onPasteLines;
  final bool first;
  final bool last;
  final bool spread;

  @override
  State<AddItemLine> createState() => _AddItemLineState();
}

class _AddItemLineState extends State<AddItemLine> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  String _text = '';

  /// The entry's draft, once its first save created one.
  int? _id;

  /// The title the draft has.
  String _sent = '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _finish();
    });
  }

  void _changed(String text) {
    final pasted = isPaste(_text, text);
    _text = text;
    _timer?.cancel();
    if (pasted) {
      _save(text.trim());
    } else {
      _timer = Timer(saveDelay, () => _save(_controller.text.trim()));
    }
  }

  void _save(String title) {
    if (title.isEmpty || title == _sent) return;
    _sent = title;
    switch (_id) {
      case final id?:
        widget.onRename(id, title);
      case null:
        _id = widget.onCreate(title);
    }
  }

  void _finish() => _finishEntry()?.call();

  /// Ends the entry and returns what that does to the list.
  VoidCallback? _finishEntry() {
    _timer?.cancel();
    final title = _controller.text.trim();
    final id = _id;
    if (title.isEmpty && id == null) return null;
    final sent = _sent;
    _id = null;
    _sent = '';
    _text = '';
    _controller.clear();
    final AddItemLine(:onCreate, :onRename, :onRelease, :onDiscard) = widget;
    return switch (id) {
      null => () => onRelease(onCreate(title)),
      _ when title.isEmpty => () => onDiscard(id),
      _ => () {
        if (title != sent) onRename(id, title);
        onRelease(id);
      },
    };
  }

  @override
  void dispose() {
    // Run after this frame: it changes the list that is unmounting this line.
    if (_finishEntry() case final finish?) scheduleMicrotask(finish);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RowSurface(
      radius: rowRadius(
        first: widget.first,
        last: widget.last,
        spread: widget.spread,
      ),
      color: colors.surfaceContainer,
      // The right gap matches the field's distance to the top and bottom
      // edges, so its corners nest in the line's.
      padding: const EdgeInsets.fromLTRB(4, 8, 10, 8),
      child: Row(
        spacing: 4,
        children: [
          ExcludeSemantics(
            child: TextFieldTapRegion(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _focus.requestFocus,
                child: SizedBox.square(
                  dimension: 40,
                  child: Icon(Icons.add, color: colors.onSurfaceVariant),
                ),
              ),
            ),
          ),
          Expanded(
            child: TitleInput(
              controller: _controller,
              focusNode: _focus,
              label: widget.label,
              placeholder: 'Add item',
              radius: 12,
              onChanged: _changed,
              onPasteLines: widget.onPasteLines,
              // Keeps the keyboard up for the next item.
              onEditingComplete: () {},
              onSubmitted: (_) => _finish(),
            ),
          ),
        ],
      ),
    );
  }
}
