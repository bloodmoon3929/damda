import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/album_repository.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:path/path.dart' as p;

// 1x1 transparent PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notes_album_test');
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db, assetsDir: p.join(tmp.path, 'assets'));
    await repo.init();
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<AssetRow> import(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(bytes);
    return repo.importAsset(f.path);
  }

  test('each album keeps its own items; duplicates skipped; remove', () async {
    final trip = await repo.createAlbum(title: '오사카');
    final other = await repo.createAlbum(title: '제주');
    final photo = await import('a.png', base64Decode(_png));
    final clip = await import('b.mp4', utf8.encode('not really a video'));

    expect(await repo.addToAlbum(trip, [photo, clip]), 2);
    expect(await repo.addToAlbum(trip, [photo]), 0);
    expect(await repo.addToAlbum(other, [photo]), 1);

    final items = await repo.watchAlbum(trip).first;
    expect([for (final i in items) i.asset.id], [photo.id, clip.id]);
    expect((await repo.watchAlbum(other).first).single.asset.id, photo.id);
    expect((await repo.getPage(trip))!.kind, 'album');

    // The album counts as a use of the file in 자료실.
    expect(
      {for (final pg in await repo.assetUsage(photo.id)) pg.id},
      {trip, other},
    );

    await repo.removeFromAlbum(items.first.blockId);
    final left = await repo.watchAlbum(trip).first;
    expect([for (final i in left) i.asset.id], [clip.id]);
    expect((await repo.watchAlbum(other).first).length, 1);
  });

  test('a deleted file disappears from the album', () async {
    final album = await repo.createAlbum();
    final photo = await import('a.png', base64Decode(_png));
    await repo.addToAlbum(album, [photo]);
    await repo.deleteAsset(photo);
    expect(await repo.watchAlbum(album).first, isEmpty);
  });
}
