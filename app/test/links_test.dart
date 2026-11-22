import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/links.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/editor/page_link.dart';

void main() {
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db);
    await repo.init();
  });
  tearDown(() => db.close());

  /// Writes "<before>@<after>" where @ links to [target].
  Future<void> writeLink(
    String pageId,
    String target, {
    String before = '여행 계획은 ',
    String after = ' 참고',
  }) async {
    final doc = await repo.openDocument(pageId);
    final delta = Delta()
      ..insert(before)
      ..insert(
        pageLinkChar,
        attributes: {pageLinkKey: target, pageLinkTitleKey: '오사카'},
      )
      ..insert(after);
    doc.document.insert([0], [paragraphNode(delta: delta)]);
    await doc.save();
  }

  test('links are indexed on save and show up as backlinks', () async {
    final osaka = await repo.createPage(title: '오사카');
    final plan = await repo.createPage(title: '계획');
    await writeLink(plan, osaka);

    final back = await repo.watchBacklinks(osaka).first;
    expect(back.single.page.id, plan);
    expect(back.single.snippets.single, '여행 계획은 오사카 참고');
    expect(await repo.watchBacklinks(plan).first, isEmpty);
    expect(await repo.allLinks(), [(from: plan, to: osaka)]);

    // Renaming the target never breaks the link (it is by id).
    await repo.updatePage(osaka, title: '오사카 2026');
    expect((await repo.watchBacklinks(osaka).first).length, 1);

    // Removing the line removes the link.
    final doc = await repo.openDocument(plan);
    doc.document.delete([0]);
    await doc.save();
    expect(await repo.watchBacklinks(osaka).first, isEmpty);
  });

  test('trashed pages do not count; copies keep their links', () async {
    final osaka = await repo.createPage(title: '오사카');
    final plan = await repo.createPage(title: '계획');
    await writeLink(plan, osaka);

    final copy = await repo.duplicatePage(plan);
    expect(
      {for (final b in await repo.watchBacklinks(osaka).first) b.page.id},
      {plan, copy},
    );
    await repo.trashPage(plan);
    expect(
      [for (final b in await repo.watchBacklinks(osaka).first) b.page.id],
      [copy],
    );
  });

  test('the index is built once for links made before it existed', () async {
    final osaka = await repo.createPage(title: '오사카');
    final plan = await repo.createPage(title: '계획');
    await writeLink(plan, osaka);
    await db.delete(db.links).go();
    await repo.ensureLinkIndex();
    expect((await repo.watchBacklinks(osaka).first).length, 1);
  });

  test('pageLinksInData', () {
    expect(pageLinksInData('{"delta":[{"insert":"x"}]}'), isEmpty);
    expect(
      pageLinksInData(
        '{"delta":[{"insert":"@","attributes":{"page_link":"a"}},'
        '{"insert":"@","attributes":{"page_link":"b"}}]}',
      ),
      {'a', 'b'},
    );
    expect(pageLinksInData('page_link but not json'), isEmpty);
  });

  test('text typed after a link is plain text', () {
    installInlineObjectSlicing();
    final delta = Delta()
      ..insert('a', attributes: {'bold': true})
      ..insert(pageLinkChar, attributes: {pageLinkKey: 'x', 'bold': true});
    expect(delta.sliceAttributes(2), {'bold': true});
    final onlyLink = Delta()
      ..insert(pageLinkChar, attributes: {pageLinkKey: 'x'});
    expect(onlyLink.sliceAttributes(1), isNull);
  });
}
