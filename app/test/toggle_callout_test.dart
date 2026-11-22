import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/toggle_callout.dart';
import 'package:notes/md/markdown_codec.dart';

void main() {
  EditorState editor(List<Node> nodes) =>
      EditorState(document: Document.blank()..insert([0], nodes));

  test('Enter on an open toggle adds its first inner line', () async {
    final s = editor([toggleNode(delta: Delta()..insert('짐 싸기'))]);
    s.selection = Selection.collapsed(Position(path: [0], offset: 4));
    expect(await enterInToggle.handler(s), isTrue);
    final toggle = s.getNodeAtPath([0])!;
    expect(toggle.children.single.type, ParagraphBlockKeys.type);
    expect(s.selection, Selection.collapsed(Position(path: [0, 0])));
  });

  test('Enter on a folded toggle adds a toggle after it; an empty toggle '
      'becomes a plain line', () async {
    final s = editor([
      toggleNode(delta: Delta()..insert('짐'), collapsed: true),
    ]);
    s.selection = Selection.collapsed(Position(path: [0], offset: 1));
    await enterInToggle.handler(s);
    expect(s.getNodeAtPath([1])!.type, ToggleBlockKeys.type);

    await enterInToggle.handler(s); // the new, empty toggle
    expect(s.getNodeAtPath([1])!.type, ParagraphBlockKeys.type);
  });

  test('Markdown: callout ↔ Obsidian "> [!tip]", toggle → list item', () {
    final md = nodesToMarkdown([
      calloutNode(delta: Delta()..insert('여권 챙기기'), icon: '⚠️'),
      toggleNode(
        delta: Delta()..insert('짐'),
        children: [paragraphNode(text: '칫솔')],
      ),
    ], MdExportContext(linkTarget: (_) => null, assetPath: (_) => null));
    expect(md, contains('> [!warning] 여권 챙기기'));
    expect(md, contains('- 짐'));
    expect(md, contains('칫솔'));

    final back = parseMarkdown('> [!warning] 여권 챙기기\n').nodes;
    expect(back.first.type, CalloutBlockKeys.type);
    expect(back.first.delta!.toPlainText(), '여권 챙기기');
    expect(back.first.attributes[CalloutBlockKeys.icon], '⚠️');
  });
}
