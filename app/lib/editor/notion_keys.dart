import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import 'toggle_callout.dart';

/// Key rules taken from Notion's editor (docs/rea/notion.md).

/// Once, at start-up: Backspace at the start of a toggle or callout turns
/// it into a plain line keeping its text and children, like a list item;
/// Tab can put lines inside a toggle.
void installNotionBlockRules() {
  for (final type in [ToggleBlockKeys.type, CalloutBlockKeys.type]) {
    if (!convertibleBlockTypes.contains(type)) convertibleBlockTypes.add(type);
  }
  indentableBlockTypes.add(ToggleBlockKeys.type);
}

/// `/` opens the menu only at the start of a line or after a space, so
/// `1/2`, `a/b` and URLs type normally.
CharacterShortcutEvent slashOnlyAtWordStart(CharacterShortcutEvent e) =>
    CharacterShortcutEvent(
      key: e.key,
      character: e.character,
      handler: (editorState) async {
        final selection = editorState.selection;
        if (selection == null || !selection.isCollapsed) return false;
        final node = editorState.getNodeAtPath(selection.end.path);
        final text = node?.delta?.toPlainText();
        final offset = selection.end.offset;
        if (text != null && offset > 0 && offset <= text.length) {
          final before = text[offset - 1];
          if (before.trim().isNotEmpty) return false;
        }
        return e.handler(editorState);
      },
    );

/// Shift+Tab on one line (Notion): the line moves out one level and the
/// lines that followed it at its old level become its children, so the
/// order on screen stays the same. Anything else: the stock outdent.
final CommandShortcutEvent outdentKeepingOrder = CommandShortcutEvent(
  key: 'outdent, taking the following lines along',
  getDescription: () => '내어쓰기',
  command: 'shift+tab',
  handler: (editorState) {
    final selection = editorState.selection;
    if (selection == null || !selection.isSingle) {
      return KeyEventResult.ignored;
    }
    final node = editorState.getNodeAtPath(selection.start.path);
    final parent = node?.parent;
    if (node == null ||
        parent == null ||
        node.path.length < 2 ||
        !indentableBlockTypes.contains(parent.type) ||
        !indentableBlockTypes.contains(node.type)) {
      return KeyEventResult.ignored;
    }
    final followers = <Node>[];
    for (var n = node.next; n != null; n = n.next) {
      followers.add(n);
    }
    if (followers.isEmpty) return KeyEventResult.ignored; // stock is the same
    final moved = node.copyWith(
      children: [
        for (final c in node.children) c.deepCopy(),
        for (final f in followers) f.deepCopy(),
      ],
    );
    final at = parent.path.next;
    final t = editorState.transaction
      ..deleteNodes([node, ...followers])
      ..insertNode(at, moved)
      ..afterSelection = Selection(
        start: selection.start.copyWith(path: at),
        end: selection.end.copyWith(path: at),
      );
    editorState.apply(t);
    return KeyEventResult.handled;
  },
);
