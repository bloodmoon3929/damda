import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
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

  Future<List<BlockRow>> liveBlocks(String pageId) => (db.select(
    db.blocks,
  )..where((b) => b.pageId.equals(pageId) & b.deleted.equals(false))).get();

  test('init creates device id and an inbox page once', () async {
    final again = NotesRepository(db);
    await again.init();
    expect(again.inboxPageId, repo.inboxPageId);
    expect(again.deviceId, repo.deviceId);
    final pages = await repo.watchPages().first;
    expect(pages.map((p) => p.title), ['미정리']);
  });

  test('page tree create / rename / cascade delete', () async {
    final parent = await repo.createPage(title: 'A');
    final child = await repo.createPage(parentId: parent, title: 'B');
    await repo.createPage(parentId: child, title: 'C');
    await repo.updatePage(parent, title: 'A2', icon: '📁');

    var pages = await repo.watchPages().first;
    expect(pages.firstWhere((p) => p.id == parent).title, 'A2');

    await repo.deletePage(parent);
    pages = await repo.watchPages().first;
    expect(pages.map((p) => p.title), ['미정리']);

    await repo.deletePage(repo.inboxPageId); // inbox is protected
    expect((await repo.watchPages().first).length, 1);
  });

  test('document round-trips through blocks and saves only changes', () async {
    final pageId = await repo.createPage(title: 'Doc');
    final doc = await repo.openDocument(pageId);
    final root = doc.document.root;
    // Replace the initial empty paragraph with real content.
    for (final n in [...root.children]) {
      n.unlink();
    }
    root.insert(headingNode(level: 1, delta: Delta()..insert('제목')));
    root.insert(
      bulletedListNode(
        delta: Delta()..insert('부모'),
        children: [paragraphNode(text: '자식')],
      ),
    );
    root.insert(todoListNode(checked: true, delta: Delta()..insert('할 일')));
    await doc.save();

    final rows = await liveBlocks(pageId);
    expect(rows.length, 4);

    final reopened = await repo.openDocument(pageId);
    expect(reopened.document.root.toJson(), root.toJson());

    // Edit one block: only that row's updated_at should move.
    final before = {for (final r in rows) r.id: r.updatedAt};
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final todo = reopened.document.root.children.last;
    todo.updateAttributes({'checked': false});
    await reopened.save();
    final after = await liveBlocks(pageId);
    final changed = after.where((r) => before[r.id] != r.updatedAt).toList();
    expect(changed.length, 1);
    expect(changed.single.type, 'todo_list');

    // Move the last block to the top; siblings keep their sort keys.
    final keysBefore = {for (final r in after) r.id: r.sortKey};
    final rootNow = reopened.document.root;
    final moved = rootNow.children.last..unlink();
    rootNow.insert(moved, index: 0);
    await reopened.save();
    final afterMove = await liveBlocks(pageId);
    final rekeyed = afterMove
        .where((r) => keysBefore[r.id] != r.sortKey)
        .toList();
    expect(rekeyed.length, 1);
    final third = await repo.openDocument(pageId);
    expect(third.document.root.toJson(), rootNow.toJson());

    // Delete a nested block -> tombstoned, not removed.
    rootNow.children[2].children.single.unlink();
    await reopened.save();
    expect((await liveBlocks(pageId)).length, 3);
    final all = await db.select(db.blocks).get();
    expect(all.where((r) => r.deleted).length, 1);
  });

  test('upload placeholders are never saved', () async {
    final pageId = await repo.createPage(title: 'P');
    final doc = await repo.openDocument(pageId);
    doc.document.root.insert(
      Node(
        type: uploadPlaceholderType,
        attributes: {'uid': 'x', 'name': 'a.mp4'},
      ),
    );
    await doc.save();
    final reopened = await repo.openDocument(pageId);
    expect(
      reopened.document.root.children.map((n) => n.type),
      isNot(contains(uploadPlaceholderType)),
    );
  });
}
