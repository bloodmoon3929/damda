import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'asset_repository.dart';
import 'clock.dart';
import 'links.dart';
import 'database.dart';
import 'notes_repository.dart';

/// Offline-first sync with the notes server (server/ in this repo).
///
/// Every edit is written to the local DB first and marked `dirty`. A sync
/// round then:
/// 1. uploads attachment files the server lacks,
/// 2. pushes dirty rows (the server keeps the newer version per row and
///    hands back its own when ours lost),
/// 3. pulls rows changed since the last seen sequence number,
/// 4. downloads attachment files this device lacks,
/// 5. merges duplicate 미정리 pages.
/// Nothing here blocks editing; without a network the round just fails and
/// is retried later.
class SyncEngine {
  SyncEngine(this.repo, {http.Client? client})
    : _http = client ?? http.Client();

  final NotesRepository repo;
  final http.Client _http;

  final status = ValueNotifier<SyncStatus>(const SyncStatus.off());

  /// Page ids whose content changed by a pull (open editors reload).
  Stream<Set<String>> get remotePageChanges => _remote.stream;
  final _remote = StreamController<Set<String>>.broadcast();

  static const _metaUrl = 'sync_url';
  static const _metaToken = 'sync_token';
  static const _metaSeq = 'sync_seq';
  static const _batch = 500;
  static const _period = Duration(minutes: 1);
  static const _debounce = Duration(seconds: 3);
  static const _keepTombstones = Duration(days: 30);

  /// Files larger than this are fetched only when opened (phones have
  /// little storage); null downloads everything.
  int? autoDownloadLimit = Platform.isAndroid ? 20 * 1024 * 1024 : null;

  AppDatabase get _db => repo.db;
  String? _url;
  String? _token;
  Timer? _timer;
  Timer? _debounceTimer;
  StreamSubscription<void>? _edits;
  Future<void>? _running;
  bool _again = false;
  bool _applying = false;
  late final Map<String, _Table<Object>> _tables = _buildTables();

  bool get connected => _url != null && _token != null;
  String? get url => _url;

  // ---------------------------------------------------------------- setup

  /// Reads saved settings and starts syncing if a server is configured.
  Future<void> load() async {
    _url = await _db.getMeta(_metaUrl);
    _token = await _db.getMeta(_metaToken);
    if (connected) {
      status.value = const SyncStatus.idle();
      _start();
      unawaited(syncNow());
    }
  }

  /// Issues a token for this device using the server's admin token. Only
  /// the device token is stored.
  Future<void> register(
    String url,
    String adminToken,
    String deviceName,
  ) async {
    final base = _normalize(url);
    final res = await _http
        .post(
          Uri.parse('$base/devices'),
          headers: {
            'Authorization': 'Bearer $adminToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'name': deviceName}),
        )
        .timeout(const Duration(seconds: 20));
    _check(res);
    await connect(base, (jsonDecode(res.body) as Map)['token'] as String);
  }

  /// Uses an existing device token.
  Future<void> connect(String url, String token) async {
    final base = _normalize(url);
    final res = await _http
        .get(
          Uri.parse('$base/sync/pull?since=0&limit=1'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 20));
    _check(res);
    if (await _db.getMeta(_metaUrl) != base) {
      await _db.setMeta(_metaSeq, '0');
    }
    await _db.setMeta(_metaUrl, base);
    await _db.setMeta(_metaToken, token);
    _url = base;
    _token = token;
    status.value = const SyncStatus.idle();
    _start();
    await syncNow();
  }

  /// Stops syncing. Local notes stay as they are.
  Future<void> disconnect() async {
    _stop();
    await (_db.delete(
      _db.meta,
    )..where((m) => m.key.isIn([_metaUrl, _metaToken, _metaSeq]))).go();
    _url = _token = null;
    status.value = const SyncStatus.off();
  }

  void dispose() {
    _stop();
    _remote.close();
    _http.close();
  }

  void _start() {
    _stop();
    _timer = Timer.periodic(_period, (_) => syncNow());
    // Edits trigger a sync a few seconds after typing stops.
    _edits = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.pages,
            _db.blocks,
            _db.properties,
            _db.dbProperties,
            _db.dbViews,
            _db.assets,
          ]),
        )
        .listen((_) {
          if (_applying) return;
          _debounceTimer?.cancel();
          _debounceTimer = Timer(_debounce, syncNow);
        });
  }

  void _stop() {
    _timer?.cancel();
    _debounceTimer?.cancel();
    _edits?.cancel();
    _timer = _debounceTimer = null;
    _edits = null;
  }

  static String _normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    return u;
  }

  // ---------------------------------------------------------------- round

  /// Runs a sync round (or queues one if a round is running).
  Future<void> syncNow() {
    if (!connected) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      status.value = status.value.copyWith(phase: SyncPhase.syncing);
      try {
        await _resendOwnRowsOnce();
        // Notes first, so text is never stuck behind a big video upload.
        await _push();
        final changed = await _pull();
        // A merge leaves dirty rows behind: push them in another round.
        if (await _quiet(repo.reconcileInbox)) _again = true;
        if (changed.isNotEmpty && !_remote.isClosed) _remote.add(changed);
        // Then files. Other devices may already see an attachment's row
        // before its file is here; they get a 404 and retry next round.
        await _uploadAssets();
        await _downloadAssets();
        await _purgeTombstones();
        status.value = SyncStatus(
          phase: SyncPhase.idle,
          lastSync: DateTime.now(),
        );
      } catch (e) {
        status.value = SyncStatus(
          phase: SyncPhase.error,
          lastSync: status.value.lastSync,
          error: _describe(e),
        );
        return;
      }
    } while (_again && connected);
  }

  /// Versions before 1.0.12 dropped emptied fields when writing a synced
  /// row (a page moved to the top level kept its old parent elsewhere, then
  /// vanished with that parent; a page restored from the trash stayed in
  /// it). Once per device, the pages (and top-level blocks) this device
  /// wrote last go out again 1 ms newer, so the stale copies elsewhere are
  /// replaced; anything edited later on another device still wins.
  Future<void> _resendOwnRowsOnce() async {
    const flag = 'resend_emptied_fields_v1';
    if (await _db.getMeta(flag) != null) return;
    await _quiet(() async {
      await _db.transaction(() async {
        await _db.customUpdate(
          'UPDATE pages SET updated_at = updated_at + 1, dirty = 1 '
          'WHERE device_id = ? AND deleted = 0',
          variables: [Variable(repo.deviceId)],
          updates: {_db.pages},
        );
        await _db.customUpdate(
          'UPDATE blocks SET updated_at = updated_at + 1, dirty = 1 '
          'WHERE device_id = ? AND deleted = 0 AND parent_id IS NULL',
          variables: [Variable(repo.deviceId)],
          updates: {_db.blocks},
        );
        await _db.setMeta(flag, '1');
      });
    });
  }

  /// Runs local writes that must not trigger another sync round.
  Future<T> _quiet<T>(Future<T> Function() f) async {
    _applying = true;
    try {
      return await f();
    } finally {
      // Table-update events are delivered asynchronously.
      await Future<void>.delayed(Duration.zero);
      _applying = false;
    }
  }

  Map<String, String> get _auth => {'Authorization': 'Bearer $_token'};

  Future<Map<String, dynamic>> _json(
    String method,
    String path, [
    Object? body,
  ]) async {
    final uri = Uri.parse('$_url$path');
    final headers = {..._auth, 'Content-Type': 'application/json'};
    final res =
        await (method == 'GET'
                ? _http.get(uri, headers: headers)
                : _http.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 60));
    _check(res);
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  // ----------------------------------------------------------------- push

  Future<void> _push() async {
    for (final t in _tables.values) {
      for (var round = 0; round < 1000; round++) {
        final rows = await t.dirty(_batch);
        if (rows.isEmpty) break;
        final sent = <String, int>{};
        final changes = [
          for (final r in rows)
            () {
              final m = t.meta(r);
              sent[m.id] = m.updatedAt;
              return {
                'table': t.name,
                'id': m.id,
                'hlc': hlcOf(m.updatedAt, m.deviceId),
                'deleted': m.deleted,
                'data': m.json..remove('dirty'),
              };
            }(),
        ];
        final res = await _json('POST', '/sync/push', {'changes': changes});
        await _quiet(() async {
          await _db.transaction(() async {
            for (final a in res['accepted'] as List) {
              final id = (a as Map)['id'] as String;
              await t.markClean(id, sent[id]!);
            }
            final pages = <String>{};
            for (final r in res['rejected'] as List) {
              // The server's version is newer than what we sent; it
              // still loses to an edit made here since then.
              final page = await _apply(r as Map<String, dynamic>);
              if (page != null) pages.add(page);
            }
            await repo.reindexLinks(pages);
          });
        });
        if (rows.length < _batch) break;
      }
    }
  }

  // ----------------------------------------------------------------- pull

  /// Returns the ids of pages whose content changed.
  Future<Set<String>> _pull() async {
    final changed = <String>{};
    var since = int.tryParse(await _db.getMeta(_metaSeq) ?? '') ?? 0;
    while (true) {
      final res = await _json('GET', '/sync/pull?since=$since&limit=$_batch');
      final changes = (res['changes'] as List).cast<Map<String, dynamic>>();
      await _quiet(() async {
        await _db.transaction(() async {
          for (final c in changes) {
            final page = await _apply(c);
            if (page != null) changed.add(page);
          }
          since = res['next'] as int;
          await _db.setMeta(_metaSeq, '$since');
          await repo.reindexLinks(changed);
        });
      });
      if (res['more'] != true) break;
    }
    return changed;
  }

  /// Writes a server version locally unless a newer local edit is waiting
  /// to be pushed. Returns the affected page id when it was written.
  Future<String?> _apply(Map<String, dynamic> c) async {
    final t = _tables[c['table']];
    if (t == null) return null;
    final data = Map<String, dynamic>.from(c['data'] as Map);
    final remoteUpdated = data['updatedAt'] as int? ?? 0;
    repo.clock.observe(remoteUpdated);
    final local = await t.find(c['id'] as String);
    if (local != null) {
      final m = t.meta(local);
      final localHlc = hlcOf(m.updatedAt, m.deviceId);
      if (m.dirty && localHlc.compareTo(c['hlc'] as String) >= 0) return null;
      if (!m.dirty && localHlc == c['hlc']) return null; // our own echo
    }
    data['dirty'] = false;
    await t.write(data);
    if (t.name == 'assets' &&
        data['deleted'] == true &&
        repo.assetsDir != null) {
      final file = File(repo.assetPath(AssetRow.fromJson(data)));
      if (file.existsSync()) await file.delete();
    }
    return t.pageOf(data);
  }

  // --------------------------------------------------------------- assets

  /// Uploads files the server lacks. `remotePath` (the hash) marks files
  /// known to be on the server; it is local bookkeeping, so writing it
  /// does not make the row dirty.
  Future<void> _uploadAssets() async {
    final rows = await (_db.select(
      _db.assets,
    )..where((a) => a.remotePath.isNull() & a.deleted.equals(false))).get();
    if (rows.isEmpty || repo.assetsDir == null) return;
    final res = await _json('POST', '/assets/missing', {
      'hashes': [for (final a in rows) a.sha256],
    });
    final missing = (res['missing'] as List).cast<String>().toSet();
    final todo = [
      for (final a in rows)
        if (missing.contains(a.sha256)) a,
    ];
    var done = 0;
    for (final a in rows) {
      if (missing.contains(a.sha256)) {
        final file = File(repo.assetPath(a));
        if (!file.existsSync()) continue; // another device's; not here yet
        status.value = status.value.copyWith(
          detail: '파일 올리는 중 ${++done}/${todo.length}',
          progress: done / todo.length,
        );
        final req = http.StreamedRequest(
          'PUT',
          Uri.parse('$_url/assets/${a.sha256}'),
        )..headers.addAll(_auth);
        req.contentLength = await file.length();
        unawaited(file.openRead().pipe(req.sink));
        final res = await http.Response.fromStream(await _http.send(req));
        _check(res);
        missing.remove(a.sha256);
      }
      await _quiet(
        () => (_db.update(_db.assets)..where((x) => x.id.equals(a.id))).write(
          AssetsCompanion(remotePath: Value(a.sha256)),
        ),
      );
    }
  }

  Future<void> _downloadAssets() async {
    if (repo.assetsDir == null) return;
    final rows = await (_db.select(
      _db.assets,
    )..where((a) => a.deleted.equals(false))).get();
    final limit = autoDownloadLimit;
    final todo = [
      for (final a in rows)
        // Big files on a phone are fetched on demand: [download].
        if ((limit == null || a.size <= limit) &&
            !File(repo.assetPath(a)).existsSync())
          a,
    ];
    for (var i = 0; i < todo.length; i++) {
      status.value = status.value.copyWith(
        detail: '파일 받는 중 ${i + 1}/${todo.length}',
        progress: i / todo.length,
      );
      await _downloadOne(todo[i]);
    }
  }

  final _downloading = <String, Future<bool>>{};

  /// Fetches one attachment now (a big video on a phone). Returns whether
  /// the file is there afterwards.
  Future<bool> download(String assetId) async {
    if (!connected || repo.assetsDir == null) return false;
    final a = await repo.getAsset(assetId);
    if (a == null) return false;
    // (Block body: whenComplete would otherwise wait on the removed
    // future, i.e. on itself.)
    return _downloading[assetId] ??= _downloadOne(a)
        .catchError((_) => false)
        .whenComplete(() {
          _downloading.remove(assetId);
        });
  }

  Future<bool> _downloadOne(AssetRow a) async {
    final path = repo.assetPath(a);
    if (File(path).existsSync()) return true;
    final res = await _http.send(
      http.Request('GET', Uri.parse('$_url/assets/${a.sha256}'))
        ..headers.addAll(_auth),
    );
    if (res.statusCode == 404) {
      await res.stream.drain<void>();
      return false; // not uploaded yet by its device
    }
    if (res.statusCode != 200) {
      throw SyncException('첨부 받기 실패 (${res.statusCode})');
    }
    final tmp = File('$path.part');
    await tmp.parent.create(recursive: true);
    await res.stream.pipe(tmp.openWrite());
    await tmp.rename(path);
    assetPathIndex[a.id] = path;
    assetFilesChanged.value++;
    return true;
  }

  /// Once a day, forgets local delete markers older than 30 days that the
  /// server already has (the server keeps them for devices still offline).
  Future<void> _purgeTombstones() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = int.tryParse(await _db.getMeta('sync_purged_at') ?? '') ?? 0;
    if (now - last < const Duration(days: 1).inMilliseconds) return;
    final cutoff = now - _keepTombstones.inMilliseconds;
    await _quiet(
      () => _db.transaction(() async {
        await (_db.delete(_db.pages)..where(
              (t) =>
                  t.deleted.equals(true) &
                  t.dirty.equals(false) &
                  t.updatedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        await (_db.delete(_db.blocks)..where(
              (t) =>
                  t.deleted.equals(true) &
                  t.dirty.equals(false) &
                  t.updatedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        await (_db.delete(_db.properties)..where(
              (t) =>
                  t.deleted.equals(true) &
                  t.dirty.equals(false) &
                  t.updatedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        await (_db.delete(_db.dbProperties)..where(
              (t) =>
                  t.deleted.equals(true) &
                  t.dirty.equals(false) &
                  t.updatedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        await (_db.delete(_db.dbViews)..where(
              (t) =>
                  t.deleted.equals(true) &
                  t.dirty.equals(false) &
                  t.updatedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        await (_db.delete(_db.assets)..where(
              (t) =>
                  t.deleted.equals(true) &
                  t.dirty.equals(false) &
                  t.updatedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        await _db.setMeta('sync_purged_at', '$now');
      }),
    );
  }

  /// Older versions of a page's title and blocks kept by the server
  /// (another device's overwritten edits, and 10-minute snapshots).
  Future<List<HistoryEntry>> pageHistory(String pageId) async {
    if (!connected) throw SyncException('서버에 연결되어 있지 않아요');
    final res = await _http
        .get(Uri.parse('$_url/history/page/$pageId'), headers: _auth)
        .timeout(const Duration(seconds: 30));
    _check(res);
    return [
      for (final h in jsonDecode(utf8.decode(res.bodyBytes)) as List)
        HistoryEntry.fromJson(h as Map<String, dynamic>),
    ];
  }

  /// Tells open editors that [pageId] changed outside them.
  void notifyPageChanged(String pageId) {
    if (!_remote.isClosed) _remote.add({pageId});
  }

  // ---------------------------------------------------------------- tables

  Map<String, _Table<Object>> _buildTables() {
    final db = _db;
    _RowMeta meta(
      String id,
      int updatedAt,
      String deviceId,
      bool deleted,
      bool dirty,
      Map<String, dynamic> json,
    ) => (
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      dirty: dirty,
      json: json,
    );

    final tables = <_Table<Object>>[
      _Table<PageRow>(
        name: 'pages',
        dirtyRows: (n) =>
            (db.select(db.pages)
                  ..where((t) => t.dirty.equals(true))
                  ..limit(n))
                .get(),
        findRow: (id) => (db.select(
          db.pages,
        )..where((t) => t.id.equals(id))).getSingleOrNull(),
        metaOf: (r) =>
            meta(r.id, r.updatedAt, r.deviceId, r.deleted, r.dirty, r.toJson()),
        write: (j) => db
            .into(db.pages)
            .insertOnConflictUpdate(PageRow.fromJson(j).toCompanion(false)),
        markClean: (id, at) =>
            (db.update(db.pages)
                  ..where((t) => t.id.equals(id) & t.updatedAt.equals(at)))
                .write(const PagesCompanion(dirty: Value(false))),
        pageOf: (j) => j['id'] as String?,
      ),
      _Table<BlockRow>(
        name: 'blocks',
        dirtyRows: (n) =>
            (db.select(db.blocks)
                  ..where((t) => t.dirty.equals(true))
                  ..limit(n))
                .get(),
        findRow: (id) => (db.select(
          db.blocks,
        )..where((t) => t.id.equals(id))).getSingleOrNull(),
        metaOf: (r) =>
            meta(r.id, r.updatedAt, r.deviceId, r.deleted, r.dirty, r.toJson()),
        write: (j) => db
            .into(db.blocks)
            .insertOnConflictUpdate(BlockRow.fromJson(j).toCompanion(false)),
        markClean: (id, at) =>
            (db.update(db.blocks)
                  ..where((t) => t.id.equals(id) & t.updatedAt.equals(at)))
                .write(const BlocksCompanion(dirty: Value(false))),
        pageOf: (j) => j['pageId'] as String?,
      ),
      _Table<PropertyRow>(
        name: 'properties',
        dirtyRows: (n) =>
            (db.select(db.properties)
                  ..where((t) => t.dirty.equals(true))
                  ..limit(n))
                .get(),
        findRow: (id) {
          final (page, key) = _splitPropId(id);
          return (db.select(db.properties)
                ..where((t) => t.pageId.equals(page) & t.key.equals(key)))
              .getSingleOrNull();
        },
        metaOf: (r) => meta(
          '${r.pageId}|${r.key}',
          r.updatedAt,
          r.deviceId,
          r.deleted,
          r.dirty,
          r.toJson(),
        ),
        write: (j) => db
            .into(db.properties)
            .insertOnConflictUpdate(PropertyRow.fromJson(j).toCompanion(false)),
        markClean: (id, at) {
          final (page, key) = _splitPropId(id);
          return (db.update(db.properties)..where(
                (t) =>
                    t.pageId.equals(page) &
                    t.key.equals(key) &
                    t.updatedAt.equals(at),
              ))
              .write(const PropertiesCompanion(dirty: Value(false)));
        },
        pageOf: (j) => j['pageId'] as String?,
      ),
      _Table<DbPropertyRow>(
        name: 'db_properties',
        dirtyRows: (n) =>
            (db.select(db.dbProperties)
                  ..where((t) => t.dirty.equals(true))
                  ..limit(n))
                .get(),
        findRow: (id) => (db.select(
          db.dbProperties,
        )..where((t) => t.id.equals(id))).getSingleOrNull(),
        metaOf: (r) =>
            meta(r.id, r.updatedAt, r.deviceId, r.deleted, r.dirty, r.toJson()),
        write: (j) => db
            .into(db.dbProperties)
            .insertOnConflictUpdate(
              DbPropertyRow.fromJson(j).toCompanion(false),
            ),
        markClean: (id, at) =>
            (db.update(db.dbProperties)
                  ..where((t) => t.id.equals(id) & t.updatedAt.equals(at)))
                .write(const DbPropertiesCompanion(dirty: Value(false))),
        pageOf: (j) => j['databaseId'] as String?,
      ),
      _Table<DbViewRow>(
        name: 'db_views',
        dirtyRows: (n) =>
            (db.select(db.dbViews)
                  ..where((t) => t.dirty.equals(true))
                  ..limit(n))
                .get(),
        findRow: (id) => (db.select(
          db.dbViews,
        )..where((t) => t.id.equals(id))).getSingleOrNull(),
        metaOf: (r) =>
            meta(r.id, r.updatedAt, r.deviceId, r.deleted, r.dirty, r.toJson()),
        write: (j) => db
            .into(db.dbViews)
            .insertOnConflictUpdate(DbViewRow.fromJson(j).toCompanion(false)),
        markClean: (id, at) =>
            (db.update(db.dbViews)
                  ..where((t) => t.id.equals(id) & t.updatedAt.equals(at)))
                .write(const DbViewsCompanion(dirty: Value(false))),
        pageOf: (j) => j['databaseId'] as String?,
      ),
      _Table<AssetRow>(
        name: 'assets',
        dirtyRows: (n) =>
            (db.select(db.assets)
                  ..where((t) => t.dirty.equals(true))
                  ..limit(n))
                .get(),
        findRow: (id) => (db.select(
          db.assets,
        )..where((t) => t.id.equals(id))).getSingleOrNull(),
        metaOf: (r) =>
            meta(r.id, r.updatedAt, r.deviceId, r.deleted, r.dirty, r.toJson()),
        write: (j) => db
            .into(db.assets)
            .insertOnConflictUpdate(
              AssetRow.fromJson(j)
                  .toCompanion(false)
                  .copyWith(remotePath: const Value.absent()),
            ),
        markClean: (id, at) =>
            (db.update(db.assets)
                  ..where((t) => t.id.equals(id) & t.updatedAt.equals(at)))
                .write(const AssetsCompanion(dirty: Value(false))),
        pageOf: (_) => null,
      ),
    ];
    return {for (final t in tables) t.name: t};
  }

  static (String, String) _splitPropId(String id) {
    final i = id.indexOf('|');
    return (id.substring(0, i), id.substring(i + 1));
  }

  // ---------------------------------------------------------------- errors

  static void _check(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String? detail;
    try {
      detail = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['detail']
          ?.toString();
    } catch (_) {}
    throw SyncException(switch (res.statusCode) {
      401 => '토큰이 맞지 않아요${detail == null ? '' : ' ($detail)'}',
      403 => '권한이 없어요${detail == null ? '' : ' ($detail)'}',
      404 => '서버 주소를 확인하세요 (404)',
      _ => '서버 오류 ${res.statusCode}${detail == null ? '' : ': $detail'}',
    });
  }

  static String _describe(Object e) => switch (e) {
    SyncException() => e.message,
    TimeoutException() => '서버 응답이 없어요',
    SocketException() || http.ClientException() => '서버에 연결할 수 없어요 (오프라인?)',
    _ => '$e',
  };
}

/// One older version from the server's history.
class HistoryEntry {
  HistoryEntry.fromJson(Map<String, dynamic> j)
    : table = j['table'] as String,
      id = j['id'] as String,
      device = j['device'] as String? ?? '',
      deleted = j['deleted'] as bool? ?? false,
      replacedAt = DateTime.fromMillisecondsSinceEpoch(j['replaced_at'] as int),
      conflict = j['reason'] == 'rejected',
      data = Map<String, dynamic>.from(j['data'] as Map);

  final String table;
  final String id;
  final String device;
  final bool deleted;
  final DateTime replacedAt;

  /// True when this version lost to a newer edit while being sent.
  final bool conflict;
  final Map<String, dynamic> data;
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum SyncPhase { off, idle, syncing, error }

@immutable
class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.lastSync,
    this.error,
    this.detail,
    this.progress,
  });
  const SyncStatus.off() : this(phase: SyncPhase.off);
  const SyncStatus.idle() : this(phase: SyncPhase.idle);

  final SyncPhase phase;
  final DateTime? lastSync;
  final String? error;

  /// What a running round is doing, e.g. "파일 올리는 중 2/5".
  final String? detail;

  /// 0..1 while files move (for a progress bar), else null.
  final double? progress;

  SyncStatus copyWith({SyncPhase? phase, String? detail, double? progress}) =>
      SyncStatus(
        phase: phase ?? this.phase,
        lastSync: lastSync,
        error: error,
        detail: detail,
        progress: progress,
      );
}

typedef _RowMeta = ({
  String id,
  int updatedAt,
  String deviceId,
  bool deleted,
  bool dirty,
  Map<String, dynamic> json,
});

/// How one synced table is read and written.
class _Table<R extends Object> {
  _Table({
    required this.name,
    required this.dirtyRows,
    required this.findRow,
    required this.metaOf,
    required this.write,
    required this.markClean,
    required this.pageOf,
  });

  final String name;
  final Future<List<R>> Function(int limit) dirtyRows;
  final Future<R?> Function(String id) findRow;
  final _RowMeta Function(R row) metaOf;
  final Future<void> Function(Map<String, dynamic> json) write;
  final Future<void> Function(String id, int updatedAt) markClean;
  final String? Function(Map<String, dynamic> json) pageOf;

  // Typed wrappers so callers holding a _Table<Object> stay type-safe.
  Future<List<Object>> dirty(int limit) => dirtyRows(limit);
  Future<Object?> find(String id) => findRow(id);
  _RowMeta meta(Object row) => metaOf(row as R);
}
