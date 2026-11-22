import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
    tmp = await Directory.systemTemp.createTemp('notes_assets_test');
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db, assetsDir: p.join(tmp.path, 'assets'));
    await repo.init();
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<String> file(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('import copies the file, detects type and image size', () async {
    final asset = await repo.importAsset(
      await file('dot.png', base64Decode(_png)),
    );
    expect(asset.mime, 'image/png');
    expect((asset.width, asset.height), (1, 1));
    expect(File(repo.assetPath(asset)).existsSync(), isTrue);
    expect(resolveAssetUrl(assetUrl(asset.id)), repo.assetPath(asset));
    expect(resolveAssetUrl('https://example.com/a.png'), isNull);
  });

  test('same content is stored once', () async {
    final a = await repo.importAsset(await file('a.txt', utf8.encode('hello')));
    final b = await repo.importAsset(await file('b.txt', utf8.encode('hello')));
    expect(b.id, a.id);
    expect((await repo.watchAssets().first).length, 1);
  });

  test('usage, unused list and delete', () async {
    final asset = await repo.importAsset(
      await file('a.pdf', utf8.encode('%PDF-1.4')),
    );
    expect(await repo.unusedAssetIds(), {asset.id});

    final pageId = await repo.createPage(title: '여행');
    final doc = await repo.openDocument(pageId);
    doc.document.root.insert(imageNode(url: assetUrl(asset.id)));
    await doc.save();

    expect((await repo.assetUsage(asset.id)).map((p) => p.id), [pageId]);
    expect(await repo.unusedAssetIds(), isEmpty);

    await repo.deleteAsset(asset);
    expect(await repo.watchAssets().first, isEmpty);
    expect(File(repo.assetPath(asset)).existsSync(), isFalse);
  });
}
