import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import 'asset_repository.dart';
import 'clock.dart' show newId;
import 'database.dart';
import 'fractional_index.dart';
import 'notes_repository.dart';

/// Block type of one photo/video inside an album page. `data.src` holds
/// `asset://<id>`, so 자료실's usage lookup and sync see it like any block.
const albumItemType = 'album_item';

/// One entry of an album: the block (for ordering/removal) and its file.
typedef AlbumItem = ({String blockId, AssetRow asset});

/// One tab of an album: its own items, a page's photos, or an album inside.
/// [album] says whether new photos can be added to it ([id] is an album).
typedef AlbumGroup = ({
  String id,
  String label,
  bool album,
  List<AlbumItem> items,
});

/// 사진 보관함: a page of kind 'album' whose blocks are photos and videos.
/// Created in the page tree like a database, so each trip or note can have
/// its own album.
extension AlbumRepository on NotesRepository {
  Future<String> createAlbum({String? parentId, String title = ''}) =>
      createPage(parentId: parentId, title: title, kind: 'album');

  /// The 사진 보관함 pages a photo on [pageId] belongs to, nearest first:
  /// albums sitting right under [pageId] or under one of its ancestors.
  /// Such an album covers its parent page and everything below it.
  Future<List<PageRow>> albumsFor(String pageId) async {
    final pages = await (db.select(
      db.pages,
    )..where((p) => p.deleted.equals(false) & p.trashedAt.isNull())).get();
    final byId = {for (final p in pages) p.id: p};
    final children = <String, List<PageRow>>{};
    for (final p in pages) {
      if (p.parentId != null) (children[p.parentId!] ??= []).add(p);
    }
    final out = <PageRow>[];
    String? at = pageId;
    for (var depth = 0; at != null && depth < 64; depth++) {
      final albums = [
        for (final c in children[at] ?? const <PageRow>[])
          if (c.kind == 'album' && c.id != pageId) c,
      ]..sort((a, b) => a.sortKey.compareTo(b.sortKey));
      out.addAll(albums);
      at = byId[at]?.parentId;
    }
    return out;
  }

  /// What albums show: their own items, plus every photo and video used in
  /// the notes around them — the album's parent page and all pages under
  /// it (albums down there included). Own items first; each file once. Items
  /// from notes have an empty `blockId` (they can't be taken out here).
  Stream<List<AlbumItem>> watchAlbumView(List<String> albumIds) async* {
    yield await _loadAlbumView(albumIds);
    await for (final _ in db.tableUpdates(
      TableUpdateQuery.onAllTables([db.blocks, db.assets, db.pages]),
    )) {
      yield await _loadAlbumView(albumIds);
    }
  }

  Future<List<AlbumItem>> _loadAlbumView(List<String> albumIds) async {
    final own = await watchAlbums(albumIds).first;
    final seen = {for (final i in own) i.asset.id};
    final pages = await (db.select(
      db.pages,
    )..where((p) => p.deleted.equals(false) & p.trashedAt.isNull())).get();
    final byId = {for (final p in pages) p.id: p};
    final children = <String, List<PageRow>>{};
    for (final p in pages) {
      if (p.parentId != null) (children[p.parentId!] ??= []).add(p);
    }
    // Note pages covered by the albums.
    final scope = <String>{};
    void walk(String id) {
      final page = byId[id];
      if (page == null || !scope.add(id)) return;
      for (final c in children[id] ?? const <PageRow>[]) {
        walk(c.id);
      }
    }

    for (final id in albumIds) {
      final parent = byId[id]?.parentId;
      if (parent != null) walk(parent);
    }
    if (scope.isEmpty) return own;
    final re = RegExp('${RegExp.escape(assetScheme)}([0-9a-f-]+)');
    final used = <String>{
      for (final b
          in await (db.select(db.blocks)..where(
                (b) =>
                    b.deleted.equals(false) &
                    b.pageId.isIn(scope) &
                    b.data.like('%$assetScheme%'),
              ))
              .get())
        for (final m in re.allMatches(b.data)) m.group(1)!,
    };
    final assets =
        await (db.select(db.assets)..where(
              (a) =>
                  a.deleted.equals(false) &
                  (a.id.isIn(used) | a.pageId.isIn(scope)),
            ))
            .get();
    return [
      ...own,
      for (final a in assets)
        if (!seen.contains(a.id) &&
            switch (assetKind(a.mime)) {
              AssetKind.image || AssetKind.video => true,
              _ => false,
            })
          (blockId: '', asset: a),
    ];
  }

  /// An album's photos split for its tabs:
  /// - its own items ("이 보관함"),
  /// - photos used right on its parent page (tab named after that page),
  /// - one tab per page next to the album (the parent's other sub-pages),
  ///   each holding the photos of that page and everything under it,
  /// - one tab per album inside this album.
  /// Groups without photos are left out; "전체" is all of them together.
  Stream<List<AlbumGroup>> watchAlbumGroups(String albumId) async* {
    yield await _loadAlbumGroups(albumId);
    await for (final _ in db.tableUpdates(
      TableUpdateQuery.onAllTables([db.blocks, db.assets, db.pages]),
    )) {
      yield await _loadAlbumGroups(albumId);
    }
  }

  Future<List<AlbumGroup>> _loadAlbumGroups(String albumId) async {
    final pages =
        await (db.select(db.pages)
              ..where((p) => p.deleted.equals(false) & p.trashedAt.isNull())
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    final byId = {for (final p in pages) p.id: p};
    final children = <String, List<PageRow>>{};
    for (final p in pages) {
      if (p.parentId != null) (children[p.parentId!] ??= []).add(p);
    }
    Set<String> subtree(String id) {
      final out = <String>{};
      void walk(String at) {
        final page = byId[at];
        // Albums below count too: a page's tab shows the photos kept in
        // the 사진 보관함 under it as well.
        if (page == null || !out.add(at)) return;
        for (final c in children[at] ?? const <PageRow>[]) {
          walk(c.id);
        }
      }

      walk(id);
      return out;
    }

    String name(PageRow p, String fallback) =>
        p.title.isEmpty ? fallback : p.title;
    final groups = <AlbumGroup>[
      (
        id: albumId,
        label: '이 보관함',
        album: true,
        items: await watchAlbum(albumId).first,
      ),
    ];
    final parent = byId[byId[albumId]?.parentId];
    if (parent != null) {
      groups.add((
        id: parent.id,
        label: name(parent, '상위 페이지'),
        album: false,
        items: await _photosOn({parent.id}),
      ));
      for (final sibling in children[parent.id] ?? const <PageRow>[]) {
        if (sibling.kind == 'album' || sibling.kind == 'row') continue;
        groups.add((
          id: sibling.id,
          label: name(sibling, '제목 없음'),
          album: false,
          items: await _photosOn(subtree(sibling.id)),
        ));
      }
    }
    for (final inner in children[albumId] ?? const <PageRow>[]) {
      if (inner.kind != 'album') continue;
      groups.add((
        id: inner.id,
        label: name(inner, '사진 보관함'),
        album: true,
        items: await watchAlbum(inner.id).first,
      ));
    }
    // A photo used in a note shows only under that note's tab, not also
    // under "이 보관함" (which keeps the photos used nowhere else).
    final inNotes = {
      for (final g in groups)
        if (!g.album)
          for (final i in g.items) i.asset.id,
    };
    final own = groups.first;
    groups[0] = (
      id: own.id,
      label: own.label,
      album: true,
      items: [
        for (final i in own.items)
          if (!inNotes.contains(i.asset.id)) i,
      ],
    );
    return [
      for (final g in groups)
        if (g.items.isNotEmpty || g.id == albumId) g,
    ];
  }

  /// Photos and videos used in [pageIds] (in their blocks, or attached to
  /// them), as album items without a block.
  Future<List<AlbumItem>> _photosOn(Set<String> pageIds) async {
    if (pageIds.isEmpty) return const [];
    final re = RegExp('${RegExp.escape(assetScheme)}([0-9a-f-]+)');
    final used = <String>{
      for (final b
          in await (db.select(db.blocks)..where(
                (b) =>
                    b.deleted.equals(false) &
                    b.pageId.isIn(pageIds) &
                    b.data.like('%$assetScheme%'),
              ))
              .get())
        for (final m in re.allMatches(b.data)) m.group(1)!,
    };
    final assets =
        await (db.select(db.assets)..where(
              (a) =>
                  a.deleted.equals(false) &
                  (a.id.isIn(used) | a.pageId.isIn(pageIds)),
            ))
            .get();
    return [
      for (final a in assets)
        if (switch (assetKind(a.mime)) {
          AssetKind.image || AssetKind.video => true,
          _ => false,
        })
          (blockId: '', asset: a),
    ];
  }

  /// Items of several albums together ("전체"), each file once.
  Stream<List<AlbumItem>> watchAlbums(List<String> albumIds) {
    if (albumIds.length == 1) return watchAlbum(albumIds.single);
    final query =
        db.select(db.blocks).join([
            innerJoin(
              db.assets,
              db.assets.deleted.equals(false) &
                  db.blocks.data.equalsExp(
                    const Constant('{"src":"') +
                        const Constant(assetScheme) +
                        db.assets.id +
                        const Constant('"}'),
                  ),
            ),
          ])
          ..where(
            db.blocks.pageId.isIn(albumIds) &
                db.blocks.type.equals(albumItemType) &
                db.blocks.deleted.equals(false),
          )
          ..orderBy([OrderingTerm.asc(db.blocks.sortKey)]);
    return query.watch().map((rows) {
      final seen = <String>{};
      return [
        for (final r in rows)
          if (seen.add(r.readTable(db.assets).id))
            (blockId: r.readTable(db.blocks).id, asset: r.readTable(db.assets)),
      ];
    });
  }

  /// Items of [albumId] in album order, files that are gone skipped.
  Stream<List<AlbumItem>> watchAlbum(String albumId) {
    final query =
        db.select(db.blocks).join([
            innerJoin(
              db.assets,
              db.assets.deleted.equals(false) &
                  // data is {"src":"asset://<id>"}; match the id exactly.
                  db.blocks.data.equalsExp(
                    const Constant('{"src":"') +
                        const Constant(assetScheme) +
                        db.assets.id +
                        const Constant('"}'),
                  ),
            ),
          ])
          ..where(
            db.blocks.pageId.equals(albumId) &
                db.blocks.type.equals(albumItemType) &
                db.blocks.deleted.equals(false),
          )
          ..orderBy([OrderingTerm.asc(db.blocks.sortKey)]);
    return query.watch().map(
      (rows) => [
        for (final r in rows)
          (blockId: r.readTable(db.blocks).id, asset: r.readTable(db.assets)),
      ],
    );
  }

  /// Appends [assets] to the album, skipping ones already in it.
  Future<int> addToAlbum(String albumId, List<AssetRow> assets) {
    return db.transaction(() async {
      final existing =
          await (db.select(db.blocks)..where(
                (b) =>
                    b.pageId.equals(albumId) &
                    b.type.equals(albumItemType) &
                    b.deleted.equals(false),
              ))
              .get();
      final have = {for (final b in existing) b.data};
      String? last = existing.isEmpty
          ? null
          : (existing.map((b) => b.sortKey).toList()..sort()).last;
      var added = 0;
      for (final a in assets) {
        final data = jsonEncode({'src': assetUrl(a.id)});
        if (!have.add(data)) continue;
        last = keyBetween(last, null);
        await db
            .into(db.blocks)
            .insert(
              BlocksCompanion.insert(
                id: newId(),
                pageId: albumId,
                sortKey: last,
                type: albumItemType,
                data: Value(data),
                updatedAt: clock.tick(),
                deviceId: deviceId,
              ),
            );
        added++;
      }
      if (added > 0) await updatePage(albumId);
      return added;
    });
  }

  /// Takes an item out of the album; the file stays in 자료실.
  Future<void> removeFromAlbum(String blockId) {
    return (db.update(db.blocks)..where((b) => b.id.equals(blockId))).write(
      BlocksCompanion(
        deleted: const Value(true),
        dirty: const Value(true),
        updatedAt: Value(clock.tick()),
        deviceId: Value(deviceId),
      ),
    );
  }
}
