import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';

/// 로컬 자료실: the files of a page and the pages under it, not others.
void main() {
  test('files used under a page, its sub-pages included', () async {
    final dir = Directory.systemTemp.createTempSync('local_assets');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = NotesRepository(db, assetsDir: dir.path);
    await repo.init();

    final trip = await repo.createPage(title: '오사카 여행');
    final day = await repo.createPage(parentId: trip, title: '1일차');
    final other = await repo.createPage(title: '다른 페이지');

    Future<String> imageOn(String page, int seed) async {
      final a = await repo.importAssetBytes(
        Uint8List.fromList([seed, 1, 2, 3]),
        'p$seed.png',
      );
      final doc = await repo.openDocument(page);
      doc.document.insert([0], [imageNode(url: assetUrl(a.id))]);
      await doc.save();
      return a.id;
    }

    final onTrip = await imageOn(trip, 1);
    final onDay = await imageOn(day, 2);
    final elsewhere = await imageOn(other, 3);
    // Added from the local 자료실 itself (not placed in a page yet).
    final added = (await repo.importAssetBytes(
      Uint8List.fromList([9]),
      'added.pdf',
      pageId: day,
    )).id;

    final ids = await repo.assetIdsUnder(trip);
    expect(ids, containsAll([onTrip, onDay, added]));
    expect(ids, isNot(contains(elsewhere)));
    expect(await repo.assetIdsUnder(day), {onDay, added});
  });
}
