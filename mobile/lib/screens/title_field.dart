import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controls.dart';
import 'lines.dart';
import 'motion.dart';

/// The API's limit on item titles.
const maxItemTitle = 500;

/// The typing pause after which a title is sent.
const saveDelay = Duration(milliseconds: 700);

final _lineBreak = RegExp(r'\s*[\r\n]+\s*');

/// Line breaks, with the whitespace around them, become one space.
String singleLine(String text) => text.replaceAll(_lineBreak, ' ');

/// The lines of a paste of [text]: trimmed, without the empty ones, each cut
/// to [maxItemTitle].
List<String> pastedLines(String text) => [
  for (final line in text.split(_lineBreak))
    if (line.trim() case final title when title.isNotEmpty)
      title.characters.take(maxItemTitle).toString(),
];

/// [lines] without those that repeat an earlier one, ignoring case.
List<String> withoutDuplicates(List<String> lines) {
  final seen = <String>{};
  return [
    for (final line in lines)
      if (seen.add(line.toLowerCase())) line,
  ];
}

/// Whether a change from [before] to [after] arrived whole (pasted, dropped
/// or picked from the suggestions) rather than typed.
bool isPaste(String before, String after) => after.length - before.length > 1;

class _SingleLine extends TextInputFormatter {
  const _SingleLine();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (!text.contains('\n') && !text.contains('\r')) return newValue;
    final joined = singleLine(text);
    final cursor = newValue.selection.isValid
        ? newValue.selection.extentOffset.clamp(0, text.length)
        : text.length;
    final before = singleLine(text.substring(0, cursor)).length;
    return TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(
        offset: math.min(before, joined.length),
      ),
    );
  }
}

/// What [newValue] put in place of [oldValue]'s selection, or, when the
/// lengths don't fit that, what differs between the two.
String _inserted(TextEditingValue oldValue, TextEditingValue newValue) {
  final before = oldValue.text;
  final after = newValue.text;
  final TextSelection(:start, :end) = oldValue.selection;
  final cursor = newValue.selection.extentOffset;
  if (oldValue.selection.isValid &&
      end <= before.length &&
      start <= cursor &&
      cursor <= after.length &&
      after.length - cursor == before.length - end) {
    return after.substring(start, cursor);
  }
  final shorter = math.min(before.length, after.length);
  var head = 0;
  while (head < shorter && before.codeUnitAt(head) == after.codeUnitAt(head)) {
    head++;
  }
  var tail = 0;
  while (tail < shorter - head &&
      before.codeUnitAt(before.length - 1 - tail) ==
          after.codeUnitAt(after.length - 1 - tail)) {
    tail++;
  }
  return after.substring(head, after.length - tail);
}

/// Runs [callback] after the frame: the field is still applying the edit
/// that led to it.
void _afterEdit(VoidCallback callback) => WidgetsBinding.instance
  ..addPostFrameCallback((_) => callback())
  ..ensureVisualUpdate();

/// iOS types the return key's line break into the text, as does a hardware
/// Enter; this hands it to [onEnter] and keeps the field's text.
class _Enter extends TextInputFormatter {
  const _Enter(this.onEnter);

  final VoidCallback onEnter;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (!text.contains('\n') && !text.contains('\r')) return newValue;
    if (_inserted(oldValue, newValue) case '\n' || '\r' || '\r\n') {
      _afterEdit(onEnter);
      return oldValue;
    }
    return newValue;
  }
}

/// Hands a paste of several lines to [onLines] and keeps the field's text.
class _PastedLines extends TextInputFormatter {
  const _PastedLines(this.onLines);

  final ValueChanged<List<String>> onLines;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (!text.contains('\n') && !text.contains('\r')) return newValue;
    final lines = pastedLines(_inserted(oldValue, newValue));
    if (lines.length < 2) return newValue;
    _afterEdit(() => onLines(lines));
    return oldValue;
  }
}

/// The web's `.title-input`: a borderless field that grows with its text and
/// lights up while focused.
class TitleInput extends StatelessWidget {
  const TitleInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.onChanged,
    required this.onEnter,
    required this.onBackspaceWhenEmpty,
    this.onPasteLines,
    this.placeholder,
    this.dimmed = false,
    this.radius = 8,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final ValueChanged<String> onChanged;

  /// Enter or the keyboard's return key, which types no line break.
  final VoidCallback onEnter;

  /// On iOS only hardware keyboards report it: iOS's own keyboard sends
  /// nothing for a Backspace in an empty field.
  final VoidCallback onBackspaceWhenEmpty;

  /// Gets the [pastedLines] of a paste with two or more of them, which then
  /// leaves the text as it was. Without it, that paste becomes one line.
  final ValueChanged<List<String>>? onPasteLines;
  final String? placeholder;

  /// Done items' titles are dimmed, not struck through.
  final bool dimmed;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final field = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: dimmed ? 1 : 0),
        duration: effects.duration,
        curve: effects,
        builder: (context, dim, _) => Semantics(
          label: label,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            minLines: 1,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: [
              _Enter(onEnter),
              if (onPasteLines case final onLines?) _PastedLines(onLines),
              const _SingleLine(),
              LengthLimitingTextInputFormatter(maxItemTitle),
            ],
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Color.lerp(
                colors.onSurface,
                colors.onSurfaceVariant,
                dim.clamp(0, 1),
              ),
            ),
            decoration: bareDecoration(
              hintText: placeholder,
              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            onChanged: onChanged,
            onTapOutside: (_) => focusNode.unfocus(),
          ),
        ),
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape) {
          focusNode.unfocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.backspace && controller.text.isEmpty) {
          onBackspaceWhenEmpty();
          return KeyEventResult.handled;
        }
        return arrowToLine(context, this, event);
      },
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, child) => TweenAnimationBuilder<double>(
          tween: Tween(end: focusNode.hasFocus ? 1 : 0),
          duration: effects.duration,
          curve: effects,
          builder: (context, focus, child) {
            final f = focus.clamp(0.0, 1.0);
            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: f),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Stack(
                children: [
                  child!,
                  // Clipped by the rounded corners, like the web's inset
                  // box-shadow.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 2,
                    child: ColoredBox(
                      color: colors.primary.withValues(alpha: f),
                    ),
                  ),
                ],
              ),
            );
          },
          child: child,
        ),
        child: field,
      ),
    );
  }
}

/// An item's always-editable title, which saves itself like the web's
/// TitleField: [onSave] gets the trimmed, non-empty text once typing pauses
/// for [saveDelay], at once for a paste, and when the field loses focus, but
/// only when it differs from [value]. Unfocused, it shows [value].
class TitleField extends StatefulWidget {
  const TitleField({
    super.key,
    required this.value,
    required this.label,
    required this.onSave,
    required this.onClear,
    this.onPasteLines,
    this.dimmed = false,
  });

  final String value;
  final String label;
  final ValueChanged<String> onSave;

  /// Called when focus leaves the field with no title in it.
  final VoidCallback onClear;

  /// See [TitleInput.onPasteLines].
  final ValueChanged<List<String>>? onPasteLines;
  final bool dimmed;

  @override
  State<TitleField> createState() => _TitleFieldState();
}

class _TitleFieldState extends State<TitleField> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();
  Timer? _timer;

  /// The text being edited; null while unfocused, so [TitleField.value]
  /// shows and follows changes from elsewhere.
  String? _draft;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(TitleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_draft == null) _show(widget.value);
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _draft ??= _controller.text;
      return;
    }
    _flush();
    // Stays empty rather than showing the value again while the row leaves.
    if (_draft?.trim().isEmpty ?? false) {
      widget.onClear();
      return;
    }
    _draft = null;
    _show(widget.value);
  }

  void _enter() {
    if (lineBelow(context, _focus) case final below?) {
      focusEnd(below);
    } else {
      _focus.unfocus();
    }
  }

  /// Like an empty line in a text editor: the caret moves to the end of the
  /// line above.
  void _backspaceWhenEmpty() {
    if (lineAbove(context, _focus) case final above?) {
      focusEnd(above);
    } else {
      _focus.unfocus();
    }
  }

  void _show(String text) {
    if (_controller.text == text) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _changed(String text) {
    final pasted = isPaste(_draft ?? widget.value, text);
    _draft = text;
    _timer?.cancel();
    if (pasted) {
      _flush();
    } else {
      _timer = Timer(saveDelay, _flush);
    }
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    final title = _unsaved();
    if (title != null) widget.onSave(title);
  }

  String? _unsaved() {
    final title = _draft?.trim();
    return title == null || title.isEmpty || title == widget.value
        ? null
        : title;
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _timer?.cancel();
    // Saved after this frame: the save rebuilds the list that is unmounting
    // this field.
    if (_unsaved() case final title?) {
      final save = widget.onSave;
      scheduleMicrotask(() => save(title));
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TitleInput(
    controller: _controller,
    focusNode: _focus,
    label: widget.label,
    dimmed: widget.dimmed,
    onChanged: _changed,
    onEnter: _enter,
    onBackspaceWhenEmpty: _backspaceWhenEmpty,
    onPasteLines: switch (widget.onPasteLines) {
      // Saved first, so the Add items screen names the item by what was
      // typed.
      final onPasteLines? => (lines) {
        _flush();
        onPasteLines(lines);
      },
      null => null,
    },
  );
}
