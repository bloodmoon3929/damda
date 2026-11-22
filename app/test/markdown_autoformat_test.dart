import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/markdown_autoformat.dart';
import 'package:notes/editor/math_block.dart';

/// Line-start Markdown typed by a phone keyboard that replaces text in one
/// go (no per-character shortcut), and Backspace next to an equation.
void main() {
  EditorState editor(List<Node> nodes) =>
      EditorState(document: Document.blank()..insert([0], nodes));

  /// What a composing keyboard does: the whole "# " lands in one change.
  Future<void> typeAtOnce(EditorState s, String text) async {
    final node = s.getNodeAtPath([0])!;
    final t = s.transaction
      ..insertText(node, 0, text)
      ..afterSelection = Selection.collapsed(
        Position(path: [0], offset: text.length),
      );
    await s.apply(t);
    await pumpEventQueue();
  }

  for (final (typed, type) in [
    ('# ', HeadingBlockKeys.type),
    ('### ', HeadingBlockKeys.type),
    ('- ', BulletedListBlockKeys.type),
    ('1. ', NumberedListBlockKeys.type),
    ('[] ', TodoListBlockKeys.type),
    ('> ', QuoteBlockKeys.type),
  ]) {
    test('"$typed" at the start of a line → $type', () async {
      final s = editor([paragraphNode()]);
      s.selection = Selection.collapsed(Position(path: [0]));
      final sub = attachMarkdownAutoFormat(s);
      await typeAtOnce(s, typed);
      final node = s.getNodeAtPath([0])!;
      expect(node.type, type);
      expect(node.delta!.toPlainText(), '');
      if (typed == '### ') expect(node.attributes[HeadingBlockKeys.level], 3);
      await sub.cancel();
    });
  }

  test(
    '"---" becomes a divider; text in the middle of a line is left alone',
    () async {
      final s = editor([paragraphNode()]);
      s.selection = Selection.collapsed(Position(path: [0]));
      final sub = attachMarkdownAutoFormat(s);
      await typeAtOnce(s, '---');
      expect(s.getNodeAtPath([0])!.type, DividerBlockKeys.type);

      final t = editor([paragraphNode(text: 'C# 언어')]);
      t.selection = Selection.collapsed(Position(path: [0], offset: 3));
      final sub2 = attachMarkdownAutoFormat(t);
      await t.apply(t.transaction..insertText(t.getNodeAtPath([0])!, 7, '.'));
      await pumpEventQueue();
      expect(t.getNodeAtPath([0])!.type, ParagraphBlockKeys.type);
      await sub.cancel();
      await sub2.cancel();
    },
  );

  test('"- [ ] " (Obsidian) becomes a to-do', () async {
    for (final typed in ['[] ', '[ ] ', '[x] ']) {
      final s = editor([bulletedListNode()]);
      s.selection = Selection.collapsed(Position(path: [0]));
      final sub = attachMarkdownAutoFormat(s);
      await typeAtOnce(s, typed);
      final node = s.getNodeAtPath([0])!;
      expect(node.type, TodoListBlockKeys.type, reason: typed);
      expect(node.attributes[TodoListBlockKeys.checked], typed == '[x] ');
      await sub.cancel();
    }
  });

  test('Backspace under an equation selects it, then deletes it', () async {
    final s = editor([
      paragraphNode(text: '위'),
      mathNode(formula: 'x^2'),
      paragraphNode(),
    ]);
    s.selection = Selection.collapsed(Position(path: [2]));
    backspaceCommand.execute(s);
    await pumpEventQueue();
    // The empty line went, the equation is selected.
    expect(s.document.root.children, hasLength(2));
    expect(s.selection, Selection.collapsed(Position(path: [1])));
    backspaceCommand.execute(s);
    await pumpEventQueue();
    expect(
      [for (final n in s.document.root.children) n.type],
      [ParagraphBlockKeys.type],
    );
  });
}
