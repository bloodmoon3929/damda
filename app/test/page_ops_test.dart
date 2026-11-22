import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';

void main() {
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db);
    await repo.init();
  });
  tearDown(() => db.close());

  /// Titles in sidebar (depth-first tree) order.
  Future<List<String>> titles() async {
    final pages = await repo.watchPages().first;
    final out = <String>[];
    void walk(String? parent) {
      for (final p in pages.where((p) => p.parentId == parent)) {
        out.add(p.title);
        walk(p.id);
      }
    }

    walk(null);
    return out;
  }

  Future<void> write(String pageId, String text) async {
    final doc = await repo.openDocument(pageId);
    doc.document.root.children.first.unlink();
    doc.document.root.insert(paragraphNode(text: text));
    await doc.save();
  }

  test('trash hides a subtree, restore brings it back', () async {
    final a = await repo.createPage(title: 'A');
    await repo.createPage(parentId: a, title: 'A1');
    await repo.trashPage(a);
    expect(await titles(), ['미정리']);
    expect((await repo.watchTrash().first).map((p) => p.title), ['A']);

    await repo.restorePage(a);
    expect(await titles(), ['미정리', 'A', 'A1']);
    expect(await repo.watchTrash().first, isEmpty);
  });

  test(
    'restoring a child whose parent is still trashed moves it to top',
    () async {
      final a = await repo.createPage(title: 'A');
      final b = await repo.createPage(parentId: a, title: 'B');
      await repo.trashPage(b);
      await repo.trashPage(a);
      await repo.restorePage(b);
      final restored = await repo.getPage(b);
      expect(restored!.trashedAt, isNull);
      expect(restored.parentId, isNull);
    },
  );

  test('emptyTrash deletes permanently', () async {
    final a = await repo.createPage(title: 'A');
    await repo.trashPage(a);
    await repo.emptyTrash();
    expect(await repo.watchTrash().first, isEmpty);
    expect((await repo.getPage(a))!.deleted, isTrue);
  });

  test(
    'duplicate copies blocks and sub-pages, placed after original',
    () async {
      final a = await repo.createPage(title: 'A');
      await repo.createPage(title: 'Z');
      final child = await repo.createPage(parentId: a, title: 'C');
      await write(a, '본문');
      await write(child, '자식 본문');

      final copy = await repo.duplicatePage(a);
      expect(await titles(), ['미정리', 'A', 'C', 'A (사본)', 'C', 'Z']);
      final doc = await repo.openDocument(copy);
      expect(doc.document.root.children.first.delta!.toPlainText(), '본문');
    },
  );

  test('move: reorder, nest, and refuse moving into own subtree', () async {
    final a = await repo.createPage(title: 'A');
    final b = await repo.createPage(title: 'B');
    expect(await repo.movePage(b, beforeId: a), isTrue);
    expect(await titles(), ['미정리', 'B', 'A']);

    expect(await repo.movePage(a, parentId: b), isTrue);
    expect((await repo.getPage(a))!.parentId, b);
    expect(await repo.movePage(b, parentId: a), isFalse);
  });

  test('templates are hidden from the tree and instantiate as pages', () async {
    final a = await repo.createPage(title: '회의록');
    await write(a, '안건:');
    final t = await repo.saveAsTemplate(a);
    expect((await repo.watchTemplates().first).map((p) => p.id), [t]);
    expect(await titles(), ['미정리', '회의록']);

    final p = await repo.createFromTemplate(t);
    expect(await titles(), ['미정리', '회의록', '회의록']);
    expect((await repo.getPage(p))!.isTemplate, isFalse);
    final doc = await repo.openDocument(p);
    expect(doc.document.root.children.first.delta!.toPlainText(), '안건:');
  });

  test('search finds titles and body text with a snippet', () async {
    final a = await repo.createPage(title: '오사카 여행');
    final b = await repo.createPage(title: '메모');
    await write(b, '내일은 오사카 성에 간다');
    final hits = await repo.search('오사카');
    expect(hits.map((h) => h.page.id), [a, b]);
    expect(hits[1].snippet, contains('오사카 성'));
  });

  test('page stats count words and characters', () async {
    final a = await repo.createPage(title: 'A');
    await write(a, '안녕 세상 hello');
    final s = await repo.pageStats(a);
    expect(s.words, 3);
    expect(s.chars, 9);
  });

  test('favorites', () async {
    final a = await repo.createPage(title: 'A');
    await repo.updatePage(a, favorite: true);
    expect((await repo.watchFavorites().first).map((p) => p.id), [a]);
  });
}
