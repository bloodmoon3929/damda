import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';

import 'code_block.dart';
import 'math_block.dart';

/// Markdown at the start of a line, whatever the keyboard: `# ` heading,
/// `- ` list, `1. ` numbered, `[] ` to-do, `> `/`" ` quote, `---` divider,
/// `$$` equation, ```` ``` ```` code.
///
/// The editor's own shortcuts react to the typed character, which phone
/// keyboards (Korean ones especially) often don't send one by one: they
/// replace the composing text instead, so `# ` stayed plain text. This
/// looks at the line after every change instead, on every device (the
/// stock block shortcuts are left out, see [EditorConfig]).
///
/// Like Notion, the conversion is its own undo step: Ctrl+Z right after
/// gives back the typed `# ` as text.
StreamSubscription<EditorTransactionValue> attachMarkdownAutoFormat(
  EditorState editorState,
) {
  var busy = false;
  return editorState.transactionStream.listen((event) {
    if (event.$1 != TransactionTime.after || busy) return;
    // Not after an undo (it would convert the `# ` straight back) or a
    // remote change.
    if (event.$3.resolvedSource != TransactionSource.userEdit) return;
    // After the current transaction is done.
    scheduleMicrotask(() async {
      if (busy) return;
      busy = true;
      try {
        await _convert(editorState);
      } catch (_) {
        // Never break typing over a formatting nicety.
      } finally {
        busy = false;
      }
    });
  });
}

final _heading = RegExp(r'^(#{1,6}) $');
const _dividers = {'---', '***', '___'};

/// Applies a conversion as a separate undo step.
Future<void> _applyStep(EditorState editorState, Transaction t) {
  final undo = editorState.undoManager.undoStack;
  if (undo.isNonEmpty) undo.last.seal(); // the typed marker stays apart
  return editorState.apply(t, skipHistoryDebounce: true);
}

final _numbered = RegExp(r'^\d+\. $');

Future<void> _convert(EditorState editorState) async {
  final selection = editorState.selection;
  if (selection == null || !selection.isCollapsed) return;
  final path = selection.end.path;
  final node = editorState.getNodeAtPath(path);
  final delta = node?.delta;
  if (node == null || delta == null) return;
  // Obsidian's "- [ ] ": "- " already made a list item, then "[] " follows.
  if (node.type == BulletedListBlockKeys.type) {
    final text = delta.toPlainText();
    final offset = selection.end.offset;
    final prefix = offset <= text.length ? text.substring(0, offset) : '';
    final checked = switch (prefix) {
      '[] ' || '[ ] ' => false,
      '[x] ' || '[X] ' => true,
      _ => null,
    };
    if (checked == null) return;
    final todo = todoListNode(checked: checked, delta: delta.slice(offset));
    for (final child in node.children) {
      todo.insert(child.copyWith());
    }
    final t = editorState.transaction
      ..insertNode(path, todo)
      ..deleteNode(node)
      ..afterSelection = Selection.collapsed(Position(path: path));
    return _applyStep(editorState, t);
  }
  if (node.type != ParagraphBlockKeys.type) return;
  if (node.parent?.type == TableCellBlockKeys.type) return;
  final text = delta.toPlainText();
  final offset = selection.end.offset;
  if (offset <= 0 || offset > text.length) return;
  final prefix = text.substring(0, offset);
  final rest = delta.slice(offset);

  // Whole-line markers.
  if (text == r'$$') {
    final undo = editorState.undoManager.undoStack;
    if (undo.isNonEmpty) undo.last.seal();
    return insertMathBlock(editorState);
  }
  if (text == '```') {
    final t = editorState.transaction
      ..insertNode(path, codeNode())
      ..deleteNode(node)
      ..afterSelection = Selection.collapsed(Position(path: path));
    return _applyStep(editorState, t);
  }
  if (_dividers.contains(text)) {
    final t = editorState.transaction
      ..insertNode(path, dividerNode())
      ..insertNode(path.next, paragraphNode())
      ..deleteNode(node)
      ..afterSelection = Selection.collapsed(Position(path: path.next));
    return _applyStep(editorState, t);
  }

  // Markers followed by a space, at the start of the line.
  Node? replacement;
  final heading = _heading.firstMatch(prefix);
  if (heading != null) {
    replacement = headingNode(level: heading[1]!.length, delta: rest);
  } else if (prefix == '- ' || prefix == '* ' || prefix == '+ ') {
    replacement = bulletedListNode(delta: rest);
  } else if (_numbered.hasMatch(prefix)) {
    replacement = numberedListNode(delta: rest);
  } else if (const {'[] ', '[ ] ', '- [] ', '- [ ] '}.contains(prefix)) {
    replacement = todoListNode(checked: false, delta: rest);
  } else if (const {'[x] ', '[X] ', '- [x] ', '- [X] '}.contains(prefix)) {
    replacement = todoListNode(checked: true, delta: rest);
  } else if (prefix == '> ' || prefix == '" ') {
    replacement = quoteNode(delta: rest);
  }
  if (replacement == null) return;
  for (final child in node.children) {
    replacement.insert(child.copyWith());
  }
  final t = editorState.transaction
    ..insertNode(path, replacement)
    ..deleteNode(node)
    ..afterSelection = Selection.collapsed(Position(path: path));
  await _applyStep(editorState, t);
}
