import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'title_field.dart';

/// lines.ts's `.list`: the [TitleInput]s under it are one list's lines, which
/// Enter, Backspace and the arrow keys move between.
class LineGroup extends InheritedWidget {
  const LineGroup({super.key, required super.child});

  @override
  bool updateShouldNotify(LineGroup oldWidget) => false;
}

/// The lines of the [LineGroup] around [context] that can take focus, in
/// order, [field] included.
List<TitleInput> _linesAround(BuildContext context, FocusNode field) {
  final lines = <TitleInput>[];
  void visit(Element element) {
    if (element.widget case final TitleInput line) {
      if (line.focusNode == field || line.focusNode.canRequestFocus) {
        lines.add(line);
      }
      return;
    }
    element.visitChildren(visit);
  }

  context.getElementForInheritedWidgetOfExactType<LineGroup>()?.visitChildren(
    visit,
  );
  return lines;
}

TitleInput? _lineFrom(BuildContext context, FocusNode field, int step) {
  final lines = _linesAround(context, field);
  final index = lines.indexWhere((line) => line.focusNode == field);
  if (index < 0 || index + step < 0) return null;
  return lines.elementAtOrNull(index + step);
}

TitleInput? lineAbove(BuildContext context, FocusNode field) =>
    _lineFrom(context, field, -1);

TitleInput? lineBelow(BuildContext context, FocusNode field) =>
    _lineFrom(context, field, 1);

void focusEnd(TitleInput line) => _focusAt(line, line.controller.text.length);

void _focusAt(TitleInput line, int offset) {
  line.controller.selection = TextSelection.collapsed(offset: offset);
  line.focusNode.requestFocus();
}

/// ArrowUp at the start of [field] or ArrowDown at its end, or either with
/// all its text selected, focuses the line that way.
KeyEventResult arrowToLine(
  BuildContext context,
  TitleInput field,
  KeyEvent event,
) {
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed ||
      keyboard.isAltPressed ||
      keyboard.isControlPressed ||
      keyboard.isMetaPressed) {
    return KeyEventResult.ignored;
  }
  final TextEditingValue(:text, :selection) = field.controller.value;
  final all = selection.start == 0 && selection.end == text.length;
  final key = event.logicalKey;
  // The caret lands on the edge it left from, so holding the key walks the
  // list a line at a time.
  if (key == LogicalKeyboardKey.arrowUp && (selection.end == 0 || all)) {
    final above = lineAbove(context, field.focusNode);
    if (above == null) return KeyEventResult.ignored;
    _focusAt(above, 0);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.arrowDown &&
      (selection.start == text.length || all)) {
    final below = lineBelow(context, field.focusNode);
    if (below == null) return KeyEventResult.ignored;
    focusEnd(below);
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}
