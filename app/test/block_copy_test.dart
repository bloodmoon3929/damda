import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/rich_clipboard.dart';

/// Blocks picked with the ⋮⋮ handle (a block selection, usually empty)
/// copy and cut as whole blocks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return {'text': clipboard};
          }
          return null;
        });
  });

  EditorState editor(List<Node> nodes) =>
      EditorState(document: Document.blank()..insert([0], nodes));

  void pickWithHandle(EditorState s, Path path) => s.updateSelectionWithReason(
    Selection.collapsed(Position(path: path)),
    customSelectionType: SelectionType.block,
  );

  List<String> texts(EditorState s) => [
    for (final n in s.document.root.children) n.delta?.toPlainText() ?? n.type,
  ];

  test('copy a handle-picked block, paste it elsewhere', () async {
    final s = editor([
      paragraphNode(text: '첫 줄'),
      todoListNode(checked: false, text: '우산 사기'),
      paragraphNode(text: ''),
    ]);
    pickWithHandle(s, [1]);
    expect(richCopyCommand.handler(s), KeyEventResult.handled);
    await pumpEventQueue();
    expect(clipboard, '우산 사기');

    s.updateSelectionWithReason(Selection.collapsed(Position(path: [2])));
    expect(await pasteRichCopy(s), isTrue);
    expect(texts(s), containsAllInOrder(['첫 줄', '우산 사기', '우산 사기']));
    // Pasted as the same kind of block (a to-do), not plain text.
    expect(
      s.document.root.children
          .where((n) => n.type == TodoListBlockKeys.type)
          .length,
      2,
    );
  });

  test(
    'cut a handle-picked block; a block without text still pastes',
    () async {
      final s = editor([
        paragraphNode(text: '위'),
        dividerNode(),
        paragraphNode(text: '아래'),
      ]);
      pickWithHandle(s, [1]);
      expect(richCutCommand.handler(s), KeyEventResult.handled);
      await pumpEventQueue();
      expect(texts(s), ['위', '아래']);

      s.updateSelectionWithReason(
        Selection.collapsed(Position(path: [1], offset: 2)),
      );
      expect(await pasteRichCopy(s), isTrue);
      expect(
        s.document.root.children.where((n) => n.type == DividerBlockKeys.type),
        hasLength(1),
      );
    },
  );

  test('a normal text selection still copies the usual way', () async {
    final s = editor([paragraphNode(text: '안녕하세요')]);
    s.updateSelectionWithReason(
      Selection(
        start: Position(path: [0], offset: 0),
        end: Position(path: [0], offset: 2),
      ),
    );
    richCopyCommand.handler(s);
    await pumpEventQueue();
    expect(clipboard, '안녕');
  });
}
