import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'clock.dart' show newId;
import 'database.dart';
import 'notes_repository.dart';

/// Blocks refer to attachments as `asset://<id>`; the file path is resolved
/// per device, so the same note works everywhere after sync.
const assetScheme = 'asset://';

String assetUrl(String id) => '$assetScheme$id';

String? assetIdFromUrl(String url) =>
    url.startsWith(assetScheme) ? url.substring(assetScheme.length) : null;

/// id -> local file path, kept in memory so the editor's image block can
/// resolve `asset://` synchronously. Filled at startup and on import.
final assetPathIndex = <String, String>{};

/// Bumped whenever an attachment's file lands on this device (import or a
/// sync download), so widgets waiting for a file can show it.
final assetFilesChanged = ValueNotifier<int>(0);

/// Local path for an `asset://<id>` url, or null for other urls.
String? resolveAssetUrl(String url) {
  final id = assetIdFromUrl(url);
  return id == null ? null : assetPathIndex[id];
}

/// Kinds used by the 자료실 filter.
enum AssetKind { image, video, audio, pdf, other }

AssetKind assetKind(String mime) {
  if (mime.startsWith('image/')) return AssetKind.image;
  if (mime.startsWith('video/')) return AssetKind.video;
  if (mime.startsWith('audio/')) return AssetKind.audio;
  if (mime == 'application/pdf') return AssetKind.pdf;
  return AssetKind.other;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

extension AssetRepository on NotesRepository {
  String get _dir {
    final dir = assetsDir;
    if (dir == null) throw StateError('assetsDir not configured');
    return dir;
  }

  /// Absolute path of an asset's file on this device.
  String assetPath(AssetRow asset) => p.join(_dir, asset.fileName);

  Future<AssetRow?> getAsset(String id) =>
      (db.select(db.assets)..where((a) => a.id.equals(id))).getSingleOrNull();

  /// Copies [sourcePath] into the assets folder and records it. The same
  /// file (by SHA-256) is stored once; importing it again returns the
  /// existing asset.
  Future<AssetRow> importAsset(String sourcePath, {String? pageId}) async {
    final bytes = await File(sourcePath).readAsBytes();
    return importAssetBytes(bytes, p.basename(sourcePath), pageId: pageId);
  }

  /// Same as [importAsset] for in-memory data (clipboard images).
  Future<AssetRow> importAssetBytes(
    Uint8List bytes,
    String name, {
    String? pageId,
  }) async {
    final hash = sha256.convert(bytes).toString();
    final existing =
        await (db.select(db.assets)
              ..where((a) => a.sha256.equals(hash) & a.deleted.equals(false))
              ..limit(1))
            .getSingleOrNull();
    if (existing != null && File(assetPath(existing)).existsSync()) {
      assetPathIndex[existing.id] = assetPath(existing);
      return existing;
    }

    final mime =
        lookupMimeType(name, headerBytes: bytes.take(32).toList()) ??
        'application/octet-stream';
    final id = newId();
    final fileName = '$id${p.extension(name).toLowerCase()}';
    await Directory(_dir).create(recursive: true);
    await File(p.join(_dir, fileName)).writeAsBytes(bytes, flush: true);

    int? width, height;
    if (assetKind(mime) == AssetKind.image) {
      (width, height) = await _imageSize(bytes);
    }

    final now = clock.tick();
    final row = AssetRow(
      id: id,
      name: name,
      mime: mime,
      size: bytes.length,
      sha256: hash,
      width: width,
      height: height,
      fileName: fileName,
      remotePath: null,
      pageId: pageId,
      createdAt: now,
      updatedAt: now,
      deviceId: deviceId,
      deleted: false,
      dirty: true,
    );
    await db.into(db.assets).insert(row);
    assetPathIndex[id] = assetPath(row);
    assetFilesChanged.value++;
    return row;
  }

  /// Reads image dimensions from the header without decoding pixels.
  Future<(int?, int?)> _imageSize(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return (null, null);
    }
  }

  Stream<List<AssetRow>> watchAssets() {
    return (db.select(db.assets)
          ..where((a) => a.deleted.equals(false))
          ..orderBy([(a) => OrderingTerm.desc(a.createdAt)]))
        .watch();
  }

  /// Live pages whose blocks reference [assetId].
  Future<List<PageRow>> assetUsage(String assetId) async {
    final blocks =
        await (db.select(db.blocks)..where(
              (b) =>
                  b.deleted.equals(false) &
                  b.data.like('%${assetUrl(assetId)}%'),
            ))
            .get();
    final ids = {for (final b in blocks) b.pageId};
    if (ids.isEmpty) return const [];
    return (db.select(db.pages)..where(
          (p) =>
              p.id.isIn(ids) & p.deleted.equals(false) & p.trashedAt.isNull(),
        ))
        .get();
  }

  /// 로컬 자료실: ids of the files used in [pageId] and the pages under it
  /// (or added to them), like the local graph is for links.
  Future<Set<String>> assetIdsUnder(String pageId) async {
    final pages = await (db.select(
      db.pages,
    )..where((p) => p.deleted.equals(false) & p.trashedAt.isNull())).get();
    final ids = <String>{pageId};
    for (var grew = true; grew;) {
      grew = false;
      for (final p in pages) {
        if (p.parentId != null && ids.contains(p.parentId) && ids.add(p.id)) {
          grew = true;
        }
      }
    }
    final rows =
        await (db.select(db.blocks)..where(
              (b) =>
                  b.deleted.equals(false) &
                  b.pageId.isIn(ids) &
                  b.data.like('%$assetScheme%'),
            ))
            .get();
    final re = RegExp('${RegExp.escape(assetScheme)}([0-9a-f-]+)');
    final attached = await (db.select(
      db.assets,
    )..where((a) => a.deleted.equals(false) & a.pageId.isIn(ids))).get();
    return {
      for (final b in rows)
        for (final m in re.allMatches(b.data)) m.group(1)!,
      for (final a in attached) a.id,
    };
  }

  /// Ids of assets that no live block references.
  Future<Set<String>> unusedAssetIds() async {
    final assets = await (db.select(
      db.assets,
    )..where((a) => a.deleted.equals(false))).get();
    final rows =
        await (db.select(db.blocks)..where(
              (b) => b.deleted.equals(false) & b.data.like('%$assetScheme%'),
            ))
            .get();
    final used = <String>{};
    final re = RegExp('${RegExp.escape(assetScheme)}([0-9a-f-]+)');
    for (final b in rows) {
      for (final m in re.allMatches(b.data)) {
        used.add(m.group(1)!);
      }
    }
    return {
      for (final a in assets)
        if (!used.contains(a.id)) a.id,
    };
  }

  /// Deletes the attachments used in or added to [pageIds] that no other
  /// live page uses.
  Future<void> deleteAssetsOnlyUsedBy(Set<String> pageIds) async {
    final re = RegExp('${RegExp.escape(assetScheme)}([0-9a-f-]+)');
    final rows =
        await (db.select(db.blocks).join([
              innerJoin(db.pages, db.pages.id.equalsExp(db.blocks.pageId)),
            ])..where(
              db.blocks.deleted.equals(false) &
                  db.blocks.data.like('%$assetScheme%'),
            ))
            .get();
    final mine = <String>{}, elsewhere = <String>{};
    for (final r in rows) {
      final block = r.readTable(db.blocks);
      final page = r.readTable(db.pages);
      final ids = [for (final m in re.allMatches(block.data)) m.group(1)!];
      if (pageIds.contains(block.pageId)) {
        mine.addAll(ids);
      } else if (!page.deleted) {
        elsewhere.addAll(ids);
      }
    }
    final assets = await (db.select(
      db.assets,
    )..where((a) => a.deleted.equals(false))).get();
    for (final a in assets) {
      final ours = mine.contains(a.id) || pageIds.contains(a.pageId);
      if (ours && !elsewhere.contains(a.id)) await deleteAsset(a);
    }
  }

  /// Removes the record (sync tombstone) and the local file.
  Future<void> deleteAsset(AssetRow asset) async {
    await (db.update(db.assets)..where((a) => a.id.equals(asset.id))).write(
      AssetsCompanion(
        deleted: const Value(true),
        dirty: const Value(true),
        updatedAt: Value(clock.tick()),
        deviceId: Value(deviceId),
      ),
    );
    final file = File(assetPath(asset));
    if (file.existsSync()) await file.delete();
  }
}
