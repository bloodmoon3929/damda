import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/formula.dart';
import 'package:notes/data/fuzzy.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/data/search_query.dart';
import 'package:notes/editor/markdown_autoformat.dart';
import 'package:notes/editor/notion_keys.dart';
import 'package:notes/editor/rich_clipboard.dart';
import 'package:notes/editor/toggle_callout.dart';

/// Behaviour taken from Notion / Obsidian (docs/rea/candidates.md).
void main() {
  group('fuzzy search (Obsidian)', () {
    test('a word start and a tight match rank first; Korean per letter', () {
      final titles = ['여행 메모 정리', '일정표', '여행 일정표', '회의록'];
      expect(fuzzySort('일정', titles, (t) => t), ['일정표', '여행 일정표']);
      expect(fuzzySort('여일', titles, (t) => t), ['여행 일정표']);
      expect(fuzzyMatch('ost', 'Osaka Trip'), isNotNull); // letters in order
      expect(fuzzyMatch('xyz', 'Osaka'), isNull);
    });

    test('search operators are parsed', () {
      final q = SearchQuery.parse('path:"오사카 여행" task-todo:여권 맛집');
      expect(q.paths, ['오사카 여행']);
      expect(q.tasks.single, (text: '여권', checked: false));
      expect(q.words, ['맛집']);
    });
  });

  group('repository', () {
    late NotesRepository repo;
    setUp(() async {
      final dir = Directory.systemTemp.createTempSync('rea_features');
      addTearDown(() => dir.deleteSync(recursive: true));
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      repo = NotesRepository(db, assetsDir: dir.path);
      await repo.init();
    });

    Future<void> write(String page, List<Node> nodes) async {
      final doc = await repo.openDocument(page);
      doc.document.insert([0], nodes);
      await doc.save();
    }

    test('search: path:, task-todo:, fuzzy titles first', () async {
      final trip = await repo.createPage(title: '오사카 여행');
      final day = await repo.createPage(parentId: trip, title: '준비물');
      final home = await repo.createPage(title: '집안일');
      await write(day, [
        todoListNode(checked: false, text: '여권 챙기기'),
        todoListNode(checked: true, text: '환전'),
      ]);
      await write(home, [todoListNode(checked: false, text: '여권 사진')]);

      final todo = await repo.search('task-todo:여권');
      expect(todo.map((h) => h.page.id).toSet(), {day, home});
      final inTrip = await repo.search('path:오사카 task-todo:여권');
      expect(inTrip.map((h) => h.page.id), [day]);
      expect(await repo.search('task-done:여권'), isEmpty);
      expect((await repo.search('task-done:환전')).single.page.id, day);
      expect((await repo.search('오여')).first.page.id, trip);
    });

    test('template variables are filled in', () async {
      final t = await repo.createPage(title: '회의록 {{date}}');
      await write(t, [paragraphNode(text: '{{title}} · {{date:M월 D일 (ddd)}}')]);
      await repo.db
          .update(repo.db.pages)
          .write(const PagesCompanion(isTemplate: Value(true)));
      final id = await repo.createFromTemplate(
        t,
        now: DateTime(2026, 10, 30, 9, 5),
      );
      final page = await repo.getPage(id);
      expect(page!.title, '회의록 2026-10-30');
      final doc = await repo.openDocument(id);
      expect(
        doc.document.root.children.first.delta!.toPlainText(),
        '회의록 2026-10-30 · 10월 30일 (금)',
      );
    });

    test('trash: 30 days, then gone with files no one else uses', () async {
      final old = await repo.createPage(title: '오래된');
      final recent = await repo.createPage(title: '최근');
      final shared = await repo.createPage(title: '같이 쓰는');
      final mine = await repo.importAssetBytes(
        Uint8List.fromList([1, 2, 3]),
        'a.png',
      );
      final both = await repo.importAssetBytes(
        Uint8List.fromList([4, 5, 6]),
        'b.png',
      );
      await write(old, [
        imageNode(url: assetUrl(mine.id)),
        imageNode(url: assetUrl(both.id)),
      ]);
      await write(shared, [imageNode(url: assetUrl(both.id))]);
      await repo.trashPage(old);
      await repo.trashPage(recent);
      final longAgo = DateTime.now()
          .subtract(const Duration(days: 31))
          .millisecondsSinceEpoch;
      await (repo.db.update(repo.db.pages)..where((p) => p.id.equals(old)))
          .write(PagesCompanion(trashedAt: Value(longAgo)));

      expect(await repo.purgeOldTrash(), 1);
      expect((await repo.getPage(old))!.deleted, isTrue);
      expect((await repo.getPage(recent))!.deleted, isFalse);
      final assets = {
        for (final a in await repo.db.select(repo.db.assets).get())
          a.id: a.deleted,
      };
      expect(assets[mine.id], isTrue);
      expect(assets[both.id], isFalse);
    });
  });

  group('formula 2.0', () {
    Object? eval(String s) =>
        evaluateFormula(s, (n) => {'가격': 1000.0, '이름': '오사카'}[n]);

    test('let, lets and method chains', () {
      expect(eval('let(x, prop("가격"), x * 2)'), 2000);
      expect(eval('lets(a, 1, b, 2, a + b)'), 3);
      expect(eval('prop("이름").length()'), 3);
      expect(eval('prop("이름").substring(0, 2).repeat(2)'), '오사오사');
      expect(eval('"a,b".replaceAll(",", "-").upper()'), 'A-B');
    });

    test('more functions', () {
      expect(eval('floor(2.7) + ceil(2.1)'), 5);
      expect(eval('pow(2, 10)'), 1024);
      expect(eval('mean(1, 2, 6)'), 3);
      expect(eval('formatDate("2026-10-30", "M월 D일 (ddd)")'), '10월 30일 (금)');
      expect(eval('"12".padStart(4, "0")'), '0012');
      expect(eval('unknown'), isA<FormulaError>());
    });
  });

  group('editor (Notion keys)', () {
    EditorState editor(List<Node> nodes) =>
        EditorState(document: Document.blank()..insert([0], nodes));

    test('a converted "# " is its own undo step', () async {
      final s = editor([paragraphNode()]);
      final sub = attachMarkdownAutoFormat(s);
      addTearDown(sub.cancel);
      Future<void> type(String c) async {
        final at = s.selection!.end.offset;
        await s.apply(
          s.transaction
            ..insertText(s.getNodeAtPath([0])!, at, c)
            ..afterSelection = Selection.collapsed(
              Position(path: [0], offset: at + 1),
            ),
        );
        await pumpEventQueue();
      }

      s.selection = Selection.collapsed(Position(path: [0]));
      await type('#');
      await type(' ');
      expect(s.getNodeAtPath([0])!.type, HeadingBlockKeys.type);
      s.undoManager.undo();
      await pumpEventQueue();
      final node = s.getNodeAtPath([0])!;
      expect(node.type, ParagraphBlockKeys.type);
      expect(node.delta!.toPlainText(), '# ');
    });

    test('"/" opens the menu only at a word start', () async {
      var opened = 0;
      final slash = slashOnlyAtWordStart(
        CharacterShortcutEvent(
          key: 'menu',
          character: '/',
          handler: (_) async => ++opened > 0,
        ),
      );
      final s = editor([paragraphNode(text: '1 a')]);
      s.selection = Selection.collapsed(Position(path: [0], offset: 1));
      expect(await slash.handler(s), isFalse); // "1/"
      s.selection = Selection.collapsed(Position(path: [0], offset: 2));
      expect(await slash.handler(s), isTrue); // after a space
      s.selection = Selection.collapsed(Position(path: [0]));
      expect(await slash.handler(s), isTrue); // line start
      expect(opened, 2);
    });

    test('Shift+Tab takes the following lines along as children', () {
      final s = editor([
        bulletedListNode(
          text: 'A',
          children: [
            bulletedListNode(text: 'B'),
            bulletedListNode(text: 'C'),
            bulletedListNode(text: 'D'),
          ],
        ),
      ]);
      s.selection = Selection.collapsed(Position(path: [0, 1]));
      expect(outdentKeepingOrder.handler(s), KeyEventResult.handled);
      String text(List<int> p) => s.getNodeAtPath(p)!.delta!.toPlainText();
      expect(text([0, 0]), 'B');
      expect(text([1]), 'C');
      expect(text([1, 0]), 'D');
      expect(s.getNodeAtPath([0])!.children.length, 1);
    });

    test('Backspace at the start of a toggle keeps text and children', () {
      installNotionBlockRules();
      final s = editor([
        toggleNode(
          delta: Delta()..insert('짐'),
          children: [paragraphNode(text: '여권')],
        ),
      ]);
      s.selection = Selection.collapsed(Position(path: [0]));
      convertToParagraphCommand.handler(s);
      final node = s.getNodeAtPath([0])!;
      expect(node.type, ParagraphBlockKeys.type);
      expect(node.delta!.toPlainText(), '짐');
      expect(node.children.single.delta!.toPlainText(), '여권');
    });
  });

  group('clipboard (Notion)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    tearDown(() => AppFlowyClipboard.mockSetData(null));
    EditorState editor(List<Node> nodes) =>
        EditorState(document: Document.blank()..insert([0], nodes));

    test('a URL pasted over selected text links that text', () async {
      final s = editor([paragraphNode(text: '공식 사이트 보기')]);
      s.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
      AppFlowyClipboard.mockSetData(
        const AppFlowyClipboardData(text: 'https://example.com'),
      );
      expect(await pasteTextSmart(s), isTrue);
      final ops = s.getNodeAtPath([0])!.delta!.toList();
      expect(
        ops.first.attributes?[AppFlowyRichTextKeys.href],
        'https://example.com',
      );
      expect(s.getNodeAtPath([0])!.delta!.toPlainText(), '공식 사이트 보기');
    });

    test('pasted markdown becomes blocks; plain text is left alone', () async {
      final s = editor([paragraphNode()]);
      s.selection = Selection.collapsed(Position(path: [0]));
      AppFlowyClipboard.mockSetData(
        const AppFlowyClipboardData(
          text: '# 준비물\n\n- [ ] 여권\n- [x] 환전\n\n> 메모',
        ),
      );
      expect(await pasteTextSmart(s), isTrue);
      final types = [for (final n in s.document.root.children) n.type];
      expect(
        types,
        containsAllInOrder(['heading', 'todo_list', 'todo_list', 'quote']),
      );

      AppFlowyClipboard.mockSetData(
        const AppFlowyClipboardData(text: '그냥 문장입니다'),
      );
      expect(await pasteTextSmart(s), isFalse);
    });

    test('copying several lines gives other apps markdown', () async {
      final s = editor([
        headingNode(level: 1, text: '준비물'),
        todoListNode(checked: false, text: '여권'),
      ]);
      s.selection = Selection(
        start: Position(path: [0]),
        end: Position(path: [1], offset: 2),
      );
      richCopyCommand.handler(s);
      await pumpEventQueue();
      expect(AppFlowyClipboard.lastText, contains('# 준비물'));
      expect(AppFlowyClipboard.lastText, contains('- [ ] 여권'));
    });
  });
}
