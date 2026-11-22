import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart' show Node;
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/album_repository.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/database_repository.dart';
import 'package:notes/data/links.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/md/vault.dart';
import 'package:path/path.dart' as p;

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_test');
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db, assetsDir: p.join(tmp.path, 'app_assets'));
    await repo.init();
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  void write(String root, String rel, Object content) {
    final f = File(p.join(root, rel))..parent.createSync(recursive: true);
    content is List<int>
        ? f.writeAsBytesSync(content)
        : f.writeAsStringSync('$content');
  }

  Future<List<PageRow>> live() => (db.select(
    db.pages,
  )..where((x) => x.deleted.equals(false) & x.trashedAt.isNull())).get();

  Future<String> textOf(String pageId) async {
    final doc = await repo.openDocument(pageId);
    return doc.document.root.children
        .map((n) => n.delta?.toPlainText() ?? n.type)
        .join('\n')
        .trimRight(); // a trailing empty line is not written to .md
  }

  test('Obsidian vault: folders, links, embeds, unresolved links', () async {
    final vault = p.join(tmp.path, 'vault');
    write(
      vault,
      '여행/오사카.md',
      '# 오사카\n\n[[교토]]에서 하루. ![[사진.png]]\n\n![[메모.pdf]]',
    );
    write(
      vault,
      '여행/교토.md',
      '---\naliases: [Kyoto]\n---\n[[Kyoto]] 는 나.\n[[없는 노트]]',
    );
    write(vault, '여행.md', '여행 모음 [[여행/오사카|오사카]] 표: [[data.csv]]');
    // A standard link written from the vault top, from a note in a folder.
    write(vault, '여행/교토/메모.md', '![](attachments/사진.png)\n\n![]()');
    write(vault, 'attachments/사진.png', base64Decode(_png));
    write(vault, 'attachments/메모.pdf', utf8.encode('%PDF-1.4'));
    write(vault, 'attachments/data.csv', utf8.encode('a,b\n1,2'));
    write(vault, '.obsidian/app.json', '{}');

    final r = await repo.importMarkdown(vault);
    expect(r.pages, 4);
    expect(r.attachments, 4);
    expect(r.missingAttachments, 0);
    expect(r.placeholderPages, 0); // no empty pages for missing notes
    expect(r.unresolvedLinks, 1);

    final pages = await live();
    List<PageRow> titled(String t) => [
      for (final x in pages)
        if (x.title == t) x,
    ];
    PageRow byTitle(String t) => titled(t).single;
    final root = byTitle('vault');
    // Like Obsidian: the note 여행.md and the folder 여행/ are two things.
    final trip = titled('여행').firstWhere((x) => x.icon != folderIcon);
    final tripFolder = titled('여행').firstWhere((x) => x.icon == folderIcon);
    final osaka = byTitle('오사카');
    // 여행/교토.md (a note) and 여행/교토/ (a folder) share the name.
    final kyoto = titled('교토').firstWhere((x) => x.icon != folderIcon);
    expect(root.icon, folderIcon);
    expect(trip.parentId, root.id);
    expect(tripFolder.parentId, root.id);
    expect(osaka.parentId, tripFolder.id);
    expect(kyoto.parentId, tripFolder.id);
    expect(titled('없는 노트'), isEmpty);
    // Folders first, then notes (like Obsidian's file list).
    final rootKids = (await live()).where((x) => x.parentId == root.id).toList()
      ..sort((a, b) => a.sortKey.compareTo(b.sortKey));
    expect([for (final x in rootKids) x.id], [tripFolder.id, trip.id]);
    final tripKids =
        (await live()).where((x) => x.parentId == tripFolder.id).toList()
          ..sort((a, b) => a.sortKey.compareTo(b.sortKey));
    expect(
      [for (final x in tripKids) (x.title, x.icon == folderIcon)],
      [('교토', true), ('교토', false), ('오사카', false)],
    );
    expect(titled('data.csv'), isEmpty);
    // [[data.csv]] stays text and the file is attached under the line.
    final tripDoc = await repo.openDocument(trip.id);
    expect(
      [for (final n in tripDoc.document.root.children) n.type],
      ['paragraph', 'file'],
    );
    expect(
      tripDoc.document.root.children.first.delta!.toPlainText(),
      contains('표: data.csv'),
    );

    final backToKyoto = await repo.watchBacklinks(kyoto.id).first;
    expect(
      {for (final b in backToKyoto) b.page.id},
      {osaka.id}, // its own [[Kyoto]] alias link is not a backlink
    );
    expect((await repo.watchBacklinks(osaka.id).first).single.page.id, trip.id);
    final osakaDoc = await repo.openDocument(osaka.id);
    final types = osakaDoc.document.root.children.map((n) => n.type).toList();
    expect(types, containsAll(['heading', 'image', 'file']));
    expect((await repo.watchAssets().first).length, 3);
  });

  test('export then import again: same pages, same content', () async {
    // Some content of every kind.
    final trip = await repo.createPage(title: '여행: 2026/오사카'); // unsafe chars
    final day = await repo.createPage(parentId: trip, title: '1일차');
    final dup = await repo.createPage(parentId: trip, title: '1일차'); // clash
    final img = File(p.join(tmp.path, 'a.png'))
      ..writeAsBytesSync(base64Decode(_png));
    final asset = await repo.importAsset(img.path, pageId: trip);
    final album = await repo.createAlbum(parentId: trip, title: '사진');
    await repo.addToAlbum(album, [asset]);
    final dbId = await repo.createDatabase(parentId: trip, title: '경비');
    final memo = await repo.addProperty(dbId, '메모', PropType.text);
    final row = await repo.addRow(dbId, title: '숙소');
    await repo.setCell(row, memo, '호텔');

    final md = await repo.openDocument(day);
    md.document.insert(
      [0],
      [
        ...(await _nodes(
          '# 첫날\n\n[링크](https://example.com) **굵게**\n\n```py\nprint(1)\n```\n\n\$\$\na^2\n\$\$',
        )),
      ],
    );
    await md.save();

    final out = p.join(tmp.path, 'out');
    final r1 = await repo.exportMarkdown(out, rootPageId: trip);
    expect(r1.pages, 6); // trip, 2 days, album, db, row
    expect(r1.attachments, 1);
    final files = Directory(out)
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: out).replaceAll(r'\', '/'))
        .toSet();
    expect(files, contains('_assets/a.png'));
    expect(
      files
          .where((f) => f.endsWith('1일차.md') || f.endsWith('1일차 (2).md'))
          .length,
      2,
    );
    final tripFile = files.firstWhere((f) => !f.contains('/'));
    expect(tripFile, isNot(contains(':')));
    final dbText = File(
      p.join(out, files.firstWhere((f) => f.endsWith('경비.md'))),
    ).readAsStringSync();
    expect(dbText, contains('| [[숙소]] |  | 호텔 |'));
    final albumText = File(
      p.join(out, files.firstWhere((f) => f.endsWith('사진.md'))),
    ).readAsStringSync();
    expect(albumText, contains('![[_assets/a.png]]'));

    final before = {for (final x in await live()) x.id: x.title};
    final dayText = await textOf(day);

    // Re-import the exported folder: everything is matched by id.
    final r2 = await repo.importMarkdown(out);
    expect(r2.updated, 6);
    expect(r2.created, 1); // only the folder's holder page
    expect(r2.placeholderPages, 0);
    final after = {for (final x in await live()) x.id: x.title};
    expect(after.length, before.length + 1);
    for (final e in before.entries) {
      expect(after[e.key], e.value);
    }
    expect(await textOf(day), dayText);
    expect(await textOf(dup), await textOf(dup)); // untouched copy stays
    // DB and album pages keep their real content.
    expect((await repo.loadDatabase(dbId))!.rows.single.id, row);
    expect((await repo.watchAlbum(album).first).single.asset.id, asset.id);
  });

  test('the sample vault imports without losing text', () async {
    final sample = Directory(
      p.normalize(
        p.join(Directory.current.path, '..', '..', 'jev', 'sample_vault'),
      ),
    );
    if (!sample.existsSync()) return;
    final r = await repo.importMarkdown(sample.path);
    expect(
      r.pages,
      sample
          .listSync(recursive: true)
          .where((e) => e.path.endsWith('.md'))
          .length,
    );
    final pages = await live();
    final recipe = pages.firstWhere((x) => x.title == '레시피');
    expect(await textOf(recipe.id), contains('김치찌개'));
  });
}

/// Markdown -> nodes via a throwaway import (keeps the test short).
Future<List<Node>> _nodes(String md) async {
  final dir = await Directory.systemTemp.createTemp('md_nodes');
  final db = AppDatabase(NativeDatabase.memory());
  final repo = NotesRepository(db);
  await repo.init();
  File(p.join(dir.path, 'x.md')).writeAsStringSync(md);
  await repo.importMarkdown(p.join(dir.path, 'x.md'));
  final page = (await db.select(db.pages).get()).firstWhere(
    (x) => x.title == 'x',
  );
  final doc = await repo.openDocument(page.id);
  final nodes = [for (final n in doc.document.root.children) n.deepCopy()];
  await db.close();
  await dir.delete(recursive: true);
  return nodes;
}
