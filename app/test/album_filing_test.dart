import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/album_repository.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/data/plan_map_repository.dart';

/// A 사진 보관함 shows the photos used in the notes around it (its parent
/// page and everything below), and the picker finds the albums covering
/// a page by going up.
void main() {
  late NotesRepository repo;
  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('album_filing');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    repo = NotesRepository(db, assetsDir: dir.path);
    await repo.init();
  });

  // A 1x1 PNG; a trailing byte makes another file.
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  Uint8List file(int n) => Uint8List.fromList([...png, n]);

  test('photos of sub-pages show in the album above them', () async {
    final trip = await repo.createPlanMap(title: '여행');
    final album = await repo.createAlbum(parentId: trip, title: '사진');
    final day = await repo.createPage(parentId: trip, title: '1일차');
    final food = await repo.createAlbum(parentId: day, title: '음식');
    final elsewhere = await repo.createPage(title: '다른 노트');

    // Covering albums, nearest first; a page with none has none.
    expect((await repo.albumsFor(day)).map((a) => a.id), [food, album]);
    expect((await repo.albumsFor(trip)).map((a) => a.id), [album]);
    expect(await repo.albumsFor(elsewhere), isEmpty);

    final onDay = await repo.importAssetBytes(file(1), 'a.png', pageId: day);
    final onTrip = await repo.importAssetBytes(file(2), 'b.png', pageId: trip);
    final other = await repo.importAssetBytes(
      file(3),
      'c.png',
      pageId: elsewhere,
    );
    final own = await repo.importAssetBytes(file(4), 'd.png', pageId: album);
    await repo.addToAlbum(album, [own]);

    Future<Set<String>> shown(List<String> ids) async => {
      for (final i in await repo.watchAlbumView(ids).first) i.asset.id,
    };
    // The trip's album: its own photo plus the trip's and 1일차's.
    expect(await shown([album]), {own.id, onTrip.id, onDay.id});
    // 1일차's album: only what is under 1일차.
    expect(await shown([food]), {onDay.id});
    expect(await shown([album]), isNot(contains(other.id)));

    // Tabs: own items, the parent page, each sub-page (with what is under
    // it) — pages without photos are left out.
    await repo.createPage(parentId: trip, title: '2일차');
    final deep = await repo.createPage(parentId: day, title: '저녁');
    final onDeep = await repo.importAssetBytes(file(5), 'e.png', pageId: deep);
    final groups = await repo.watchAlbumGroups(album).first;
    expect([for (final g in groups) g.label], ['이 보관함', '여행', '1일차']);
    expect(
      {for (final i in groups[2].items) i.asset.id},
      {onDay.id, onDeep.id},
    );

    // A photo kept only in the album under 1일차 shows in the 1일차 tab of
    // the album above (the 새 지도 / sd / 사진 보관함 case).
    final kept = await repo.importAssetBytes(file(6), 'f.png', pageId: food);
    await repo.addToAlbum(food, [kept]);
    final again = await repo.watchAlbumGroups(album).first;
    expect({
      for (final i in again[2].items) i.asset.id,
    }, containsAll([onDay.id, onDeep.id, kept.id]));
    expect(groups[0].album, isTrue);

    // An album photo that a note also uses shows only under the note.
    await repo.addToAlbum(album, [onTrip]);
    final split = await repo.watchAlbumGroups(album).first;
    expect({
      for (final i in split[0].items) i.asset.id,
    }, isNot(contains(onTrip.id)));
    expect({for (final i in split[1].items) i.asset.id}, contains(onTrip.id));
    expect(groups[1].album, isFalse);
  });
}
