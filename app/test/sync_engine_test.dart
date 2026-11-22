import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/album_repository.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/data/sync_engine.dart';
import 'package:path/path.dart' as p;

/// End-to-end: two devices (in-memory DBs) syncing through the real
/// server in ../server, started locally. Skipped when its venv is missing
/// (create it with `python -m venv .venv` + `pip install -r
/// requirements-dev.txt` in server/).
const _admin = 'test-admin';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

final _python = p.normalize(
  p.join(
    Directory.current.path,
    '..',
    'server',
    '.venv',
    'Scripts',
    'python.exe',
  ),
);

class _Device {
  _Device(this.repo, this.sync, this.tmp);
  final NotesRepository repo;
  final SyncEngine sync;
  final Directory tmp;

  static Future<_Device> create(String url, String name) async {
    final tmp = await Directory.systemTemp.createTemp('sync_$name');
    final repo = NotesRepository(
      AppDatabase(NativeDatabase.memory()),
      assetsDir: p.join(tmp.path, 'assets'),
    );
    await repo.init();
    return _Device(repo, SyncEngine(repo), tmp);
  }

  Future<void> connect(String url, String name) async {
    await sync.register(url, _admin, name);
    expect(sync.status.value.error, isNull);
  }

  Future<void> syncNow() async {
    await sync.syncNow();
    expect(sync.status.value.error, isNull);
  }

  Future<void> close() async {
    sync.dispose();
    await repo.db.close();
    await tmp.delete(recursive: true);
  }

  Future<PageRow> page(String id) async => (await repo.getPage(id))!;

  Future<List<String>> texts(String pageId) async {
    final doc = await repo.openDocument(pageId);
    return [
      for (final n in doc.document.root.children) n.delta?.toPlainText() ?? '',
    ];
  }

  Future<void> addText(String pageId, String text) async {
    final doc = await repo.openDocument(pageId);
    final root = doc.document.root;
    doc.document.insert([root.children.length], [paragraphNode(text: text)]);
    await doc.save();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test fakes all HTTP; these tests talk to a real local server.
  HttpOverrides.global = null;
  // Two devices = two databases on purpose.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Process server;
  late Directory serverData;
  late String url;
  final skip = File(_python).existsSync() ? null : 'server/.venv missing';

  setUp(() async {
    serverData = await Directory.systemTemp.createTemp('notes_server');
    final port = 18000 + DateTime.now().millisecond;
    url = 'http://127.0.0.1:$port';
    server = await Process.start(
      _python,
      ['-m', 'uvicorn', 'app.main:app', '--port', '$port'],
      workingDirectory: p.join(Directory.current.path, '..', 'server'),
      environment: {
        'NOTES_DATA_DIR': serverData.path,
        'NOTES_ADMIN_TOKEN': _admin,
      },
    );
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    for (var i = 0; i < 100; i++) {
      try {
        final c = HttpClient();
        final r = await (await c.getUrl(Uri.parse('$url/health'))).close();
        await r.drain<void>();
        c.close();
        if (r.statusCode == 200) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });

  tearDown(() async {
    server.kill();
    await server.exitCode;
    await serverData.delete(recursive: true);
  });

  test('pages, blocks, albums and files reach the other device', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);

    final trip = await a.repo.createPage(title: '오사카 여행');
    await a.addText(trip, '도톤보리');
    final img = File(p.join(a.tmp.path, 'osaka.png'))
      ..writeAsBytesSync(base64Decode(_png));
    final photo = await a.repo.importAsset(img.path, pageId: trip);
    final album = await a.repo.createAlbum(parentId: trip, title: '사진');
    await a.repo.addToAlbum(album, [photo]);

    await a.connect(url, 'a');
    await b.connect(url, 'b');

    expect((await b.page(trip)).title, '오사카 여행');
    expect(await b.texts(trip), contains('도톤보리'));
    final items = await b.repo.watchAlbum(album).first;
    expect(items.single.asset.id, photo.id);
    // The file itself was downloaded.
    expect(
      File(b.repo.assetPath(items.single.asset)).readAsBytesSync(),
      base64Decode(_png),
    );
    expect(await b.repo.db.getMeta('sync_seq'), isNot('0'));
  }, skip: skip);

  test('two inboxes merge into one on every device', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    await a.addText(a.repo.inboxPageId, 'A 메모');
    await b.addText(b.repo.inboxPageId, 'B 메모');
    final bChild = await b.repo.createPage(
      parentId: b.repo.inboxPageId,
      title: 'B 링크',
    );

    await a.connect(url, 'a');
    await b.connect(url, 'b');
    await a.syncNow();

    expect(a.repo.inboxPageId, b.repo.inboxPageId);
    final inbox = a.repo.inboxPageId;
    for (final d in [a, b]) {
      expect(await d.texts(inbox), containsAll(['A 메모', 'B 메모']));
      expect((await d.page(bChild)).parentId, inbox);
      final inboxes = await (d.repo.db.select(
        d.repo.db.pages,
      )..where((p) => p.title.equals('미정리') & p.deleted.equals(false))).get();
      expect(inboxes.length, 1);
    }
  }, skip: skip);

  test('later edit wins; body edits do not undo a rename', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    await a.connect(url, 'a');
    await b.connect(url, 'b');
    final id = await a.repo.createPage(title: '처음');
    await a.syncNow();
    await b.syncNow();

    // Both rename offline; B is later and wins everywhere.
    await a.repo.updatePage(id, title: 'A 제목');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.repo.updatePage(id, title: 'B 제목');
    await a.syncNow();
    await b.syncNow();
    await a.syncNow();
    expect((await a.page(id)).title, 'B 제목');
    expect((await b.page(id)).title, 'B 제목');

    // A renames, then B edits the body: the rename survives.
    await a.repo.updatePage(id, title: '최종 제목');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.addText(id, '본문 추가');
    await a.syncNow();
    await b.syncNow();
    await a.syncNow();
    for (final d in [a, b]) {
      expect((await d.page(id)).title, '최종 제목');
      expect(await d.texts(id), contains('본문 추가'));
    }

    // Deleting travels too.
    await b.repo.deletePage(id);
    await b.syncNow();
    await a.syncNow();
    expect((await a.page(id)).deleted, isTrue);
  }, skip: skip);

  test('a sub-page moved out before its parent is deleted survives on the '
      'other device', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    await a.connect(url, 'a');
    await b.connect(url, 'b');
    final parent = await a.repo.createPage(title: '상위');
    final child = await a.repo.createPage(parentId: parent, title: '하위');
    final grandchild = await a.repo.createPage(parentId: child, title: '손자');
    await a.syncNow();
    await b.syncNow();
    expect((await b.page(child)).parentId, parent);

    // A: take 하위 out, then delete the now empty 상위 (trash, then empty
    // the trash).
    await a.repo.movePage(child);
    await a.repo.trashPage(parent);
    await a.syncNow();
    await b.syncNow();
    for (final d in [a, b]) {
      final c = await d.page(child);
      expect(c.parentId, isNull, reason: 'on ${d == a ? 'A' : 'B'}');
      expect(c.trashedAt, isNull);
      expect(c.deleted, isFalse);
      expect((await d.page(grandchild)).trashedAt, isNull);
    }
    await a.repo.deletePage(parent);
    await a.syncNow();
    await b.syncNow();
    await a.syncNow();
    for (final d in [a, b]) {
      expect((await d.page(parent)).deleted, isTrue);
      final c = await d.page(child);
      expect(c.deleted, isFalse, reason: 'on ${d == a ? 'A' : 'B'}');
      expect(c.trashedAt, isNull);
      expect((await d.page(grandchild)).deleted, isFalse);
    }
  }, skip: skip);

  test('emptied fields travel: restore from the trash; stale copies made '
      'by older versions are corrected once', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    await a.connect(url, 'a');
    await b.connect(url, 'b');
    final parent = await a.repo.createPage(title: '상위');
    final child = await a.repo.createPage(parentId: parent, title: '하위');
    await a.syncNow();
    await b.syncNow();

    // Trash and restore on A: B sees it back (trashedAt emptied).
    await a.repo.trashPage(child);
    await a.syncNow();
    await b.syncNow();
    expect((await b.page(child)).trashedAt, isNotNull);
    await a.repo.restorePage(child);
    await a.syncNow();
    await b.syncNow();
    expect((await b.page(child)).trashedAt, isNull);

    // What an older version left on B: A moved 하위 to the top, B kept the
    // old parent with A's version stamp.
    await a.repo.movePage(child);
    await a.syncNow();
    await b.syncNow();
    final row = await b.page(child);
    await (b.repo.db.update(b.repo.db.pages)..where((p) => p.id.equals(child)))
        .write(PagesCompanion(parentId: Value(parent)));
    expect((await b.page(child)).updatedAt, row.updatedAt);
    // A (the last writer) sends its pages once more after updating.
    await a.repo.db.customStatement(
      "DELETE FROM meta WHERE key = 'resend_emptied_fields_v1'",
    );
    await a.syncNow();
    await b.syncNow();
    expect((await b.page(child)).parentId, isNull);
  }, skip: skip);

  test('offline edits are kept and sent later', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    await a.connect(url, 'a');
    await b.connect(url, 'b');

    server.kill();
    await server.exitCode;
    final id = await a.repo.createPage(title: '오프라인 메모');
    await a.sync.syncNow();
    expect(a.sync.status.value.phase, SyncPhase.error);
    expect((await a.page(id)).dirty, isTrue);

    // Server back (same data dir and port).
    server = await Process.start(
      _python,
      [
        '-m',
        'uvicorn',
        'app.main:app',
        '--port',
        Uri.parse(url).port.toString(),
      ],
      workingDirectory: p.join(Directory.current.path, '..', 'server'),
      environment: {
        'NOTES_DATA_DIR': serverData.path,
        'NOTES_ADMIN_TOKEN': _admin,
      },
    );
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    for (var i = 0; i < 100; i++) {
      await a.sync.syncNow();
      if (a.sync.status.value.phase == SyncPhase.idle) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await b.syncNow();
    expect((await b.page(id)).title, '오프라인 메모');
    expect((await a.page(id)).dirty, isFalse);
  }, skip: skip);

  test('cells and database settings sync', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    // A page property row (the composite-key table).
    final id = await a.repo.createPage(title: 'x');
    await a.repo.db
        .into(a.repo.db.properties)
        .insert(
          PropertiesCompanion.insert(
            pageId: id,
            key: 'k',
            value: '"v"',
            updatedAt: a.repo.clock.tick(),
            deviceId: a.repo.deviceId,
            dirty: const Value(true),
          ),
        );
    await a.connect(url, 'a');
    await b.connect(url, 'b');
    final row = await (b.repo.db.select(
      b.repo.db.properties,
    )..where((p) => p.pageId.equals(id) & p.key.equals('k'))).getSingle();
    expect(row.value, '"v"');
    expect(row.dirty, isFalse);
  }, skip: skip);

  test('big files wait until asked for; history and restore', () async {
    final a = await _Device.create(url, 'a');
    final b = await _Device.create(url, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    b.sync.autoDownloadLimit = 0; // like a phone with a big video
    final id = await a.repo.createPage(title: '영상');
    final f = File(p.join(a.tmp.path, 'clip.mp4'))..writeAsBytesSync([1, 2, 3]);
    final clip = await a.repo.importAsset(f.path, pageId: id);
    await a.connect(url, 'a');
    await b.connect(url, 'b');

    final onB = (await b.repo.getAsset(clip.id))!;
    expect(File(b.repo.assetPath(onB)).existsSync(), isFalse);
    expect(await b.sync.download(clip.id), isTrue);
    expect(File(b.repo.assetPath(onB)).readAsBytesSync(), [1, 2, 3]);

    // B's edit loses to A's newer one; it shows up in the page history and
    // can be restored as a copy.
    await a.addText(id, '공통');
    await a.syncNow();
    await b.syncNow();
    final blockId = (await b.repo.db.select(b.repo.db.blocks).get())
        .firstWhere((x) => x.pageId == id && x.data.contains('공통'))
        .id;
    Future<void> edit(_Device d, String text, int at) =>
        (d.repo.db.update(
          d.repo.db.blocks,
        )..where((x) => x.id.equals(blockId))).write(
          BlocksCompanion(
            data: Value(
              jsonEncode({
                'delta': [
                  {'insert': text},
                ],
              }),
            ),
            updatedAt: Value(at),
            deviceId: Value(d.repo.deviceId),
            dirty: const Value(true),
          ),
        );
    final now = DateTime.now().millisecondsSinceEpoch;
    await b.repo.db.transaction(() => edit(b, 'B가 쓴 내용', now + 1000));
    await edit(a, 'A가 쓴 내용', now + 2000);
    await a.syncNow();
    await b.syncNow();
    expect(await b.texts(id), contains('A가 쓴 내용'));
    expect(await b.texts(id), isNot(contains('B가 쓴 내용')));

    final hist = await b.sync.pageHistory(id);
    final lost = hist.firstWhere((h) => h.conflict);
    expect(lost.data['data'], contains('B가 쓴 내용'));
    expect(lost.device, 'b');
    await b.repo.restoreBlockCopy(
      id,
      lost.data['type'] as String,
      lost.data['data'] as String,
    );
    await b.syncNow();
    await a.syncNow();
    final after = [
      for (final t in await a.texts(id))
        if (t.isNotEmpty) t,
    ];
    expect(after, ['A가 쓴 내용', 'B가 쓴 내용']);
  }, skip: skip);

  test('old local delete markers are forgotten after 30 days', () async {
    final a = await _Device.create(url, 'a');
    addTearDown(a.close);
    final gone = await a.repo.createPage(title: '옛날');
    await a.repo.deletePage(gone);
    final old = DateTime.now()
        .subtract(const Duration(days: 31))
        .millisecondsSinceEpoch;
    await (a.repo.db.update(a.repo.db.pages)..where((x) => x.id.equals(gone)))
        .write(PagesCompanion(updatedAt: Value(old)));
    await a.connect(url, 'a'); // pushes, then purges what the server has
    expect(await a.repo.getPage(gone), isNull);
  }, skip: skip);
}
