import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import 'clock.dart';
import 'database.dart';
import 'database_repository.dart';
import 'fractional_index.dart';
import 'asset_repository.dart';
import 'fuzzy.dart';
import 'search_query.dart';
import 'links.dart';

/// Editor-only blocks that must never be stored (e.g. upload skeletons).
const uploadPlaceholderType = 'upload_placeholder';
const transientBlockTypes = {uploadPlaceholderType};

/// All reads and writes of pages and blocks go through here.
class NotesRepository {
  NotesRepository(this.db, {this.assetsDir});

  final AppDatabase db;

  /// Folder holding attachment files (see asset_repository.dart).
  final String? assetsDir;
  final _clock = Clock();

  /// Shared with the database extension so all writes use one clock.
  Clock get clock => _clock;
  late final String deviceId;

  /// The 미정리 page. It can change once: when sync finds that another
  /// device already has one, the two are merged ([reconcileInbox]).
  final inbox = ValueNotifier<String>('');
  String get inboxPageId => inbox.value;

  /// Synced marker property that tells devices which page is an inbox.
  static const systemKey = '_system';
  static const inboxMark = '"inbox"';

  /// Synced marker on a top-level page that sits in the sidebar's 미정리
  /// section (beside the 미정리 note, not inside it) instead of 개인 페이지.
  /// Only means something while the page is at the top level.
  static const sectionKey = '_section';
  static const inboxSection = '"inbox"';

  Future<void> init() async {
    deviceId = await db.getMeta('device_id') ?? await _createMeta('device_id');
    var id = await db.getMeta('inbox_page_id');
    if (id == null) {
      id = await createPage(title: '미정리', icon: '📥');
      await db.setMeta('inbox_page_id', id);
    }
    final mark =
        await (db.select(db.properties)
              ..where((p) => p.pageId.equals(id!) & p.key.equals(systemKey)))
            .getSingleOrNull();
    if (mark == null) {
      await db
          .into(db.properties)
          .insert(
            PropertiesCompanion.insert(
              pageId: id,
              key: systemKey,
              value: inboxMark,
              updatedAt: _clock.tick(),
              deviceId: deviceId,
            ),
          );
    }
    inbox.value = id;
  }

  /// After a sync, more than one inbox can exist (one per device). All
  /// devices keep the same one, the oldest id, and move the others'
  /// sub-pages and content into it.
  /// Puts an old version of a block (from sync history) back at the end of
  /// [pageId] as a new block, so nothing current is overwritten.
  Future<void> restoreBlockCopy(String pageId, String type, String data) async {
    final last =
        await (db.select(db.blocks)
              ..where(
                (b) =>
                    b.pageId.equals(pageId) &
                    b.parentId.isNull() &
                    b.deleted.equals(false),
              )
              ..orderBy([(b) => OrderingTerm.desc(b.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    await db
        .into(db.blocks)
        .insert(
          BlocksCompanion.insert(
            id: newId(),
            pageId: pageId,
            sortKey: keyBetween(last?.sortKey, null),
            type: type,
            data: Value(data),
            updatedAt: _clock.tick(),
            deviceId: deviceId,
          ),
        );
    await reindexLinks([pageId]);
  }

  /// Returns whether anything was merged.
  Future<bool> reconcileInbox() async {
    final marks =
        await (db.select(db.properties)..where(
              (p) =>
                  p.key.equals(systemKey) &
                  p.value.equals(inboxMark) &
                  p.deleted.equals(false),
            ))
            .get();
    final pages =
        await (db.select(db.pages)..where(
              (p) =>
                  p.id.isIn([for (final m in marks) m.pageId]) &
                  p.deleted.equals(false),
            ))
            .get();
    if (pages.isEmpty) return false;
    pages.sort((a, b) => a.id.compareTo(b.id));
    final keep = pages.first.id;
    for (final other in pages.skip(1)) {
      await db.transaction(() async {
        for (final child
            in await (db.select(db.pages)
                  ..where((p) => p.parentId.equals(other.id))
                  ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
                .get()) {
          await (db.update(
            db.pages,
          )..where((p) => p.id.equals(child.id))).write(
            _touch().copyWith(
              parentId: Value(keep),
              sortKey: Value(keyBetween(await _lastSiblingKey(keep), null)),
            ),
          );
        }
        final last =
            await (db.select(db.blocks)
                  ..where(
                    (b) =>
                        b.pageId.equals(keep) &
                        b.parentId.isNull() &
                        b.deleted.equals(false),
                  )
                  ..orderBy([(b) => OrderingTerm.desc(b.sortKey)])
                  ..limit(1))
                .getSingleOrNull();
        var key = last?.sortKey;
        for (final b
            in await (db.select(db.blocks)
                  ..where((b) => b.pageId.equals(other.id))
                  ..orderBy([(b) => OrderingTerm.asc(b.sortKey)]))
                .get()) {
          final root = b.parentId == null;
          if (root) key = keyBetween(key, null);
          await (db.update(db.blocks)..where((x) => x.id.equals(b.id))).write(
            BlocksCompanion(
              pageId: Value(keep),
              sortKey: root ? Value(key!) : const Value.absent(),
              updatedAt: Value(_clock.tick()),
              deviceId: Value(deviceId),
              dirty: const Value(true),
            ),
          );
        }
        await (db.update(db.pages)..where((p) => p.id.equals(other.id))).write(
          _touch().copyWith(deleted: const Value(true)),
        );
      });
    }
    if (pages.length > 1) await reindexLinks([keep]);
    if (keep != inboxPageId) {
      await db.setMeta('inbox_page_id', keep);
      inbox.value = keep;
    }
    return pages.length > 1;
  }

  Future<String> _createMeta(String key) async {
    final value = newId();
    await db.setMeta(key, value);
    return value;
  }

  // ---- pages ----

  /// Live (not deleted, not in the trash) pages matching [where].
  Stream<List<PageRow>> _watchLive(
    Expression<bool> Function($PagesTable p) where, {
    OrderingTerm Function($PagesTable p)? order,
  }) {
    return (db.select(db.pages)
          ..where(
            (p) => p.deleted.equals(false) & p.trashedAt.isNull() & where(p),
          )
          ..orderBy([order ?? (p) => OrderingTerm.asc(p.sortKey)]))
        .watch();
  }

  /// Pages for the sidebar tree (database rows and templates excluded).
  Stream<List<PageRow>> watchPages() =>
      _watchLive((p) => p.isTemplate.equals(false) & p.kind.isNotValue('row'));

  Stream<List<PageRow>> watchFavorites() => _watchLive(
    (p) => p.favorite.equals(true) & p.isTemplate.equals(false),
    order: (p) => OrderingTerm.asc(p.title),
  );

  Stream<List<PageRow>> watchTemplates() => _watchLive(
    (p) => p.isTemplate.equals(true) & p.parentId.isNull(),
    order: (p) => OrderingTerm.asc(p.createdAt),
  );

  /// Roots of trashed subtrees (the page the user actually trashed).
  Stream<List<PageRow>> watchTrash() {
    return (db.select(db.pages)
          ..where((p) => p.deleted.equals(false) & p.trashedAt.isNotNull())
          ..orderBy([(p) => OrderingTerm.desc(p.trashedAt)]))
        .watch()
        .map((rows) {
          final byId = {for (final r in rows) r.id: r};
          return [
            for (final r in rows)
              if (byId[r.parentId]?.trashedAt != r.trashedAt) r,
          ];
        });
  }

  /// Top-level pages in the 미정리 section (see [sectionKey]).
  Stream<Set<String>> watchInboxSection() =>
      (db.select(db.properties)..where(
            (p) =>
                p.key.equals(sectionKey) &
                p.value.equals(inboxSection) &
                p.deleted.equals(false),
          ))
          .watch()
          .map((rows) => {for (final r in rows) r.pageId});

  Future<bool> isInInboxSection(String id) async =>
      await (db.select(db.properties)..where(
            (p) =>
                p.pageId.equals(id) &
                p.key.equals(sectionKey) &
                p.value.equals(inboxSection) &
                p.deleted.equals(false),
          ))
          .getSingleOrNull() !=
      null;

  /// Puts top-level page [id] in the 미정리 section ([on]) or 개인 페이지.
  /// Writes (and syncs) only when that changes.
  Future<void> setInInboxSection(String id, bool on) async {
    if (await isInInboxSection(id) == on) return;
    final existing =
        await (db.select(db.properties)
              ..where((p) => p.pageId.equals(id) & p.key.equals(sectionKey)))
            .getSingleOrNull();
    if (existing == null && !on) return;
    await db
        .into(db.properties)
        .insertOnConflictUpdate(
          PropertiesCompanion.insert(
            pageId: id,
            key: sectionKey,
            value: inboxSection,
            updatedAt: _clock.tick(),
            deviceId: deviceId,
            deleted: Value(!on),
            dirty: const Value(true),
          ),
        );
  }

  Stream<PageRow?> watchPage(String id) {
    return (db.select(
      db.pages,
    )..where((p) => p.id.equals(id))).watchSingleOrNull();
  }

  Future<PageRow?> getPage(String id) =>
      (db.select(db.pages)..where((p) => p.id.equals(id))).getSingleOrNull();

  /// Root-first chain of parents, for the breadcrumb.
  Future<List<PageRow>> ancestors(String id) async {
    final chain = <PageRow>[];
    var current = await getPage(id);
    final seen = <String>{};
    while (current?.parentId != null && seen.add(current!.id)) {
      current = await getPage(current.parentId!);
      if (current != null) chain.insert(0, current);
    }
    return chain;
  }

  Future<String?> _lastSiblingKey(String? parentId) async {
    final last =
        await (db.select(db.pages)
              ..where(
                (p) => parentId == null
                    ? p.parentId.isNull()
                    : p.parentId.equals(parentId),
              )
              ..orderBy([(p) => OrderingTerm.desc(p.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    return last?.sortKey;
  }

  Future<String> createPage({
    String? parentId,
    String title = '',
    String? icon,
    String kind = 'page',
    bool isTemplate = false,
    String? id,
    bool inboxSection = false,
  }) async {
    id ??= newId();
    final now = _clock.tick();
    await db
        .into(db.pages)
        .insert(
          PagesCompanion.insert(
            id: id,
            parentId: Value(parentId),
            title: Value(title),
            icon: Value(icon),
            kind: Value(kind),
            isTemplate: Value(isTemplate),
            sortKey: keyBetween(await _lastSiblingKey(parentId), null),
            createdAt: now,
            updatedAt: now,
            deviceId: deviceId,
          ),
        );
    if (parentId == null && inboxSection) await setInInboxSection(id, true);
    return id;
  }

  PagesCompanion _touch() => PagesCompanion(
    updatedAt: Value(_clock.tick()),
    deviceId: Value(deviceId),
    dirty: const Value(true),
  );

  Future<void> updatePage(
    String id, {
    String? title,
    String? icon,
    bool? favorite,
    String? fontStyle,
    bool? smallText,
    bool? fullWidth,
  }) {
    Value<T> v<T>(T? x) => x == null ? const Value.absent() : Value(x);
    return (db.update(db.pages)..where((p) => p.id.equals(id))).write(
      _touch().copyWith(
        title: v(title),
        icon: v(icon),
        favorite: v(favorite),
        fontStyle: v(fontStyle),
        smallText: v(smallText),
        fullWidth: v(fullWidth),
      ),
    );
  }

  Future<Set<String>> _subtree(String id) async {
    final all = await (db.select(
      db.pages,
    )..where((p) => p.deleted.equals(false))).get();
    final ids = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final p in all) {
        if (p.parentId != null && ids.contains(p.parentId) && ids.add(p.id)) {
          grew = true;
        }
      }
    }
    return ids;
  }

  /// Moves [id] under [parentId] (null = top level), placed before
  /// [beforeId] / after [afterId] among its new siblings (else last).
  /// At the top level [inboxSection] picks the sidebar section: 미정리
  /// (true) or 개인 페이지. Returns false if the move would put a page
  /// inside itself.
  Future<bool> movePage(
    String id, {
    String? parentId,
    String? beforeId,
    String? afterId,
    bool inboxSection = false,
  }) async {
    if (parentId != null && (await _subtree(id)).contains(parentId)) {
      return false;
    }
    final siblings =
        await (db.select(db.pages)
              ..where(
                (p) =>
                    p.deleted.equals(false) &
                    p.id.isNotValue(id) &
                    (parentId == null
                        ? p.parentId.isNull()
                        : p.parentId.equals(parentId)),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    var index = siblings.length;
    if (beforeId != null) {
      final i = siblings.indexWhere((p) => p.id == beforeId);
      if (i >= 0) index = i;
    } else if (afterId != null) {
      final i = siblings.indexWhere((p) => p.id == afterId);
      if (i >= 0) index = i + 1;
    }
    final lo = index > 0 ? siblings[index - 1].sortKey : null;
    final hi = index < siblings.length ? siblings[index].sortKey : null;
    await (db.update(db.pages)..where((p) => p.id.equals(id))).write(
      _touch().copyWith(
        parentId: Value(parentId),
        sortKey: Value(keyBetween(lo, hi)),
      ),
    );
    await setInInboxSection(id, parentId == null && inboxSection);
    return true;
  }

  /// Copies a page with its blocks, properties and sub-pages. The copy is
  /// placed right after the original unless [parentId] is given.
  Future<String> duplicatePage(
    String id, {
    String? parentId,
    bool keepParent = true,
    bool? asTemplate,
    String titleSuffix = ' (사본)',
  }) async {
    final source = await getPage(id);
    if (source == null) throw StateError('no page $id');
    final targetParent = keepParent ? source.parentId : parentId;
    final pages = <String, String>{}; // original page id → its copy
    final copyId = await _copyTree(
      source,
      targetParent,
      asTemplate ?? source.isTemplate,
      titleSuffix,
      pages: pages,
    );
    await _pointCopiesAtCopies(pages);
    if (keepParent) {
      await movePage(
        copyId,
        parentId: targetParent,
        afterId: id,
        inboxSection: await isInInboxSection(id),
      );
    }
    await reindexLinks(await _subtree(copyId));
    return copyId;
  }

  /// Blocks in the copied pages that show or link to a page that was copied
  /// too (a table block of a database inside the copy, a mention) now point
  /// at that copy, not at the original.
  Future<void> _pointCopiesAtCopies(Map<String, String> pages) async {
    final now = _clock.tick();
    for (final copy in pages.values) {
      final blocks = await (db.select(
        db.blocks,
      )..where((b) => b.pageId.equals(copy) & b.deleted.equals(false))).get();
      for (final b in blocks) {
        var data = b.data;
        for (final e in pages.entries) {
          data = data.replaceAll(e.key, e.value);
        }
        if (data == b.data) continue;
        await (db.update(db.blocks)..where((x) => x.id.equals(b.id))).write(
          BlocksCompanion(
            data: Value(data),
            updatedAt: Value(now),
            deviceId: Value(deviceId),
            dirty: const Value(true),
          ),
        );
      }
    }
  }

  Future<String> _copyTree(
    PageRow source,
    String? parentId,
    bool asTemplate,
    String titleSuffix, {
    required Map<String, String> pages,
    Map<String, String> columns = const {},
  }) async {
    final now = _clock.tick();
    final copyId = newId();
    pages[source.id] = copyId;
    await db.transaction(() async {
      await db
          .into(db.pages)
          .insert(
            source
                .copyWith(
                  id: copyId,
                  parentId: Value(parentId),
                  title: '${source.title}$titleSuffix',
                  sortKey: keyBetween(await _lastSiblingKey(parentId), null),
                  favorite: false,
                  isTemplate: asTemplate,
                  trashedAt: const Value(null),
                  createdAt: now,
                  updatedAt: now,
                  deviceId: deviceId,
                  dirty: true,
                )
                .toCompanion(true),
          );
      final blocks =
          await (db.select(db.blocks)..where(
                (b) => b.pageId.equals(source.id) & b.deleted.equals(false),
              ))
              .get();
      final idMap = {for (final b in blocks) b.id: newId()};
      for (final b in blocks) {
        await db
            .into(db.blocks)
            .insert(
              b
                  .copyWith(
                    id: idMap[b.id],
                    pageId: copyId,
                    parentId: Value(
                      b.parentId == null ? null : idMap[b.parentId],
                    ),
                    updatedAt: now,
                    deviceId: deviceId,
                    dirty: true,
                  )
                  .toCompanion(true),
            );
      }
      // Not the section marker: where the copy goes is set by the caller.
      final props =
          await (db.select(db.properties)..where(
                (p) =>
                    p.pageId.equals(source.id) &
                    p.deleted.equals(false) &
                    p.key.isNotValue(sectionKey),
              ))
              .get();
      for (final p in props) {
        await db
            .into(db.properties)
            .insert(
              p
                  .copyWith(
                    pageId: copyId,
                    // An item of a copied database: its copied column.
                    key: columns[p.key] ?? p.key,
                    updatedAt: now,
                    deviceId: deviceId,
                    dirty: true,
                  )
                  .toCompanion(true),
            );
      }
    });
    // A database takes its columns and views along; its items' values
    // move to the new columns.
    final childColumns = source.kind == 'database'
        ? await copyDatabaseSchema(source.id, copyId)
        : columns;
    final children =
        await (db.select(db.pages)
              ..where(
                (p) =>
                    p.parentId.equals(source.id) &
                    p.deleted.equals(false) &
                    p.trashedAt.isNull(),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    for (final child in children) {
      await _copyTree(
        child,
        copyId,
        asTemplate,
        '',
        pages: pages,
        columns: childColumns,
      );
    }
    return copyId;
  }

  /// Moves the page and its sub-pages to the trash.
  Future<void> trashPage(String id) async {
    if (id == inboxPageId) return;
    final ids = await _subtree(id);
    final now = _clock.tick();
    await (db.update(db.pages)
          ..where((p) => p.id.isIn(ids) & p.trashedAt.isNull()))
        .write(_touch().copyWith(trashedAt: Value(now)));
  }

  /// Restores a trashed page (and what was trashed with it). If its old
  /// parent is gone, it comes back at the top level.
  Future<void> restorePage(String id) async {
    final page = await getPage(id);
    if (page?.trashedAt == null) return;
    final ids = await _subtree(id);
    await (db.update(db.pages)
          ..where((p) => p.id.isIn(ids) & p.trashedAt.equals(page!.trashedAt!)))
        .write(_touch().copyWith(trashedAt: const Value(null)));
    final parent = page!.parentId == null
        ? null
        : await getPage(page.parentId!);
    if (page.parentId != null &&
        (parent == null || parent.deleted || parent.trashedAt != null)) {
      await movePage(id);
    }
  }

  /// Permanently deletes the page and its sub-pages (sync tombstones).
  /// With [removeUnusedFiles], attachments no other page uses go too
  /// (Obsidian asks; here the delete was already confirmed).
  Future<Set<String>> deletePage(
    String id, {
    bool removeUnusedFiles = false,
  }) async {
    if (id == inboxPageId) return const {};
    final ids = await _subtree(id);
    await (db.update(db.pages)..where((p) => p.id.isIn(ids))).write(
      _touch().copyWith(deleted: const Value(true)),
    );
    if (removeUnusedFiles) await deleteAssetsOnlyUsedBy(ids);
    return ids;
  }

  Future<void> emptyTrash() async {
    final roots = await watchTrash().first;
    for (final r in roots) {
      await deletePage(r.id, removeUnusedFiles: true);
    }
  }

  /// Notion: pages stay in the trash for [keep], then go for good.
  Future<int> purgeOldTrash({Duration keep = const Duration(days: 30)}) async {
    final cutoff = DateTime.now().subtract(keep).millisecondsSinceEpoch;
    var count = 0;
    for (final r in await watchTrash().first) {
      final at = r.trashedAt;
      if (at != null && at < cutoff) {
        await deletePage(r.id, removeUnusedFiles: true);
        count++;
      }
    }
    return count;
  }

  /// How many other live pages link to [id] or a page under it: shown
  /// before it goes to the trash (Obsidian).
  Future<int> incomingLinkCount(String id) async {
    final ids = await _subtree(id);
    final rows =
        await (db.select(db.links).join([
              innerJoin(db.pages, db.pages.id.equalsExp(db.links.sourcePageId)),
            ])..where(
              db.links.targetPageId.isIn(ids) &
                  db.links.sourcePageId.isIn(ids).not() &
                  db.pages.deleted.equals(false) &
                  db.pages.trashedAt.isNull(),
            ))
            .get();
    return {for (final r in rows) r.readTable(db.links).sourcePageId}.length;
  }

  // ---- templates ----

  /// Saves a copy of [pageId] as a template.
  Future<String> saveAsTemplate(String pageId) => duplicatePage(
    pageId,
    keepParent: false,
    parentId: null,
    asTemplate: true,
    titleSuffix: '',
  );

  /// Creates a new page from a template under [parentId].
  /// `{{date}}`, `{{date:YYYY.MM.DD}}`, `{{time}}`, `{{title}}` in the
  /// template are filled in (Obsidian's template variables).
  Future<String> createFromTemplate(
    String templateId, {
    String? parentId,
    DateTime? now,
  }) async {
    final id = await duplicatePage(
      templateId,
      keepParent: false,
      parentId: parentId,
      asTemplate: false,
      titleSuffix: '',
    );
    await _fillTemplateVariables(id, now ?? DateTime.now());
    return id;
  }

  static final _templateVar = RegExp(
    r'\{\{\s*(date|time|title)(?::([^}]*))?\s*\}\}',
  );

  static String _formatStamp(DateTime d, String format) {
    String two(int n) => n.toString().padLeft(2, '0');
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return format
        .replaceAll('YYYY', '${d.year}')
        .replaceAll('MM', two(d.month))
        .replaceAll('DD', two(d.day))
        .replaceAll('HH', two(d.hour))
        .replaceAll('mm', two(d.minute))
        .replaceAll('M', '${d.month}')
        .replaceAll('D', '${d.day}')
        .replaceAll('ddd', days[d.weekday - 1]);
  }

  Future<void> _fillTemplateVariables(String rootId, DateTime now) async {
    String fill(String text, String title) => text.replaceAllMapped(
      _templateVar,
      (m) => switch (m[1]) {
        'date' => _formatStamp(now, m[2]?.trim() ?? 'YYYY-MM-DD'),
        'time' => _formatStamp(now, m[2]?.trim() ?? 'HH:mm'),
        _ => title,
      },
    );
    final ids = await _subtree(rootId);
    final pages = await (db.select(
      db.pages,
    )..where((p) => p.id.isIn(ids))).get();
    final titles = <String, String>{};
    for (final p in pages) {
      final title = fill(p.title, p.title);
      titles[p.id] = title;
      if (title != p.title) {
        await (db.update(db.pages)..where((r) => r.id.equals(p.id))).write(
          _touch().copyWith(title: Value(title)),
        );
      }
    }
    final blocks = await (db.select(
      db.blocks,
    )..where((b) => b.pageId.isIn(ids) & b.data.like('%{{%}}%'))).get();
    for (final b in blocks) {
      // Inside JSON: the page title is put in as a JSON string body.
      final title = jsonEncode(titles[b.pageId] ?? '');
      final data = fill(b.data, title.substring(1, title.length - 1));
      if (data == b.data) continue;
      await (db.update(db.blocks)..where((r) => r.id.equals(b.id))).write(
        BlocksCompanion(
          data: Value(data),
          updatedAt: Value(_clock.tick()),
          deviceId: Value(deviceId),
          dirty: const Value(true),
        ),
      );
    }
  }

  // ---- search & stats ----

  /// The search box (Obsidian style, docs/rea/obsidian.md): titles
  /// ranked by fuzzy score, then pages whose text has all the words.
  /// Operators narrow it down: `title:`, `content:`, `path:` (a parent's
  /// title), `task:` / `task-todo:` / `task-done:` (a to-do's text).
  Future<List<SearchHit>> search(String query, {int limit = 50}) async {
    final sq = SearchQuery.parse(query);
    if (sq.isEmpty) return const [];
    final visible =
        await (db.select(db.pages)..where(
              (p) =>
                  p.deleted.equals(false) &
                  p.trashedAt.isNull() &
                  p.isTemplate.equals(false),
            ))
            .get();
    final byId = {for (final p in visible) p.id: p};
    String pathOf(PageRow p) {
      final names = <String>[];
      var at = p.parentId == null ? null : byId[p.parentId];
      for (var i = 0; at != null && i < 50; i++) {
        names.add(at.title.toLowerCase());
        at = at.parentId == null ? null : byId[at.parentId];
      }
      return names.reversed.join('/');
    }

    var pages = [
      for (final p in visible)
        if (sq.titles.every((t) => p.title.toLowerCase().contains(t)) &&
            sq.paths.every((t) => pathOf(p).contains(t)))
          p,
    ];
    final free = sq.words.join(' ');

    // Page text, only where it is needed: narrowed by the longest term.
    final needText =
        sq.words.isNotEmpty || sq.bodyTerms.isNotEmpty || sq.tasks.isNotEmpty;
    final texts = <String, List<(String type, String data, String text)>>{};
    if (needText) {
      final terms = [...sq.words, ...sq.bodyTerms]
        ..sort((a, b) => b.length.compareTo(a.length));
      final key = terms.isEmpty ? null : terms.first.replaceAll('%', '');
      final ids = {for (final p in pages) p.id};
      final narrowed = key == null
          ? ids
          : {
              for (final b
                  in await (db.select(db.blocks)..where(
                        (b) => b.deleted.equals(false) & b.data.like('%$key%'),
                      ))
                      .get())
                if (ids.contains(b.pageId)) b.pageId,
            };
      if (narrowed.isNotEmpty) {
        final blocks =
            await (db.select(db.blocks)..where(
                  (b) => b.deleted.equals(false) & b.pageId.isIn(narrowed),
                ))
                .get();
        for (final b in blocks) {
          (texts[b.pageId] ??= []).add((
            b.type,
            b.data,
            blockPlainText(b.data).toLowerCase(),
          ));
        }
      }
    }
    bool hasText(String id, String term) =>
        texts[id]?.any((b) => b.$3.contains(term)) ?? false;
    bool hasTask(String id, ({String text, bool? checked}) t) =>
        texts[id]?.any(
          (b) =>
              b.$1 == TodoListBlockKeys.type &&
              b.$3.contains(t.text) &&
              (t.checked == null || b.$2.contains('"checked":${t.checked}')),
        ) ??
        false;
    pages = [
      for (final p in pages)
        if (sq.contents.every((t) => hasText(p.id, t)) &&
            sq.tasks.every((t) => hasTask(p.id, t)))
          p,
    ];

    // Title hits by score, then pages whose text has every word.
    final hits = <SearchHit>[];
    final seen = <String>{};
    if (free.isNotEmpty) {
      for (final p in fuzzySort(free, pages, (p) => p.title)) {
        hits.add(SearchHit(p, null));
        seen.add(p.id);
      }
    } else if (!sq.isPlain && sq.bodyTerms.isEmpty) {
      // Only title:/path: given: every page that passed.
      for (final p
          in pages..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))) {
        hits.add(SearchHit(p, null));
        seen.add(p.id);
      }
    }
    final snippetTerms = [...sq.words, ...sq.bodyTerms];
    for (final p in pages) {
      if (seen.contains(p.id)) continue;
      final lower = p.title.toLowerCase();
      if (!sq.words.every((w) => lower.contains(w) || hasText(p.id, w))) {
        continue;
      }
      if (snippetTerms.isEmpty && sq.tasks.isEmpty) continue;
      final term = snippetTerms.isEmpty ? '' : snippetTerms.first;
      final block = texts[p.id]?.firstWhere(
        (b) =>
            term.isEmpty ? b.$1 == TodoListBlockKeys.type : b.$3.contains(term),
        orElse: () => ('', '', ''),
      );
      final text = block == null ? '' : blockPlainText(block.$2);
      final at = term.isEmpty ? 0 : text.toLowerCase().indexOf(term);
      String? snippet;
      if (text.isNotEmpty && at >= 0) {
        final from = (at - 30).clamp(0, text.length);
        final to = (at + term.length + 50).clamp(0, text.length);
        snippet =
            '${from > 0 ? '…' : ''}${text.substring(from, to)}'
            '${to < text.length ? '…' : ''}';
      }
      seen.add(p.id);
      hits.add(SearchHit(p, snippet));
    }
    return hits.take(limit).toList();
  }

  /// Word and character counts of a page's text.
  Future<({int words, int chars})> pageStats(String pageId) async {
    final blocks = await (db.select(
      db.blocks,
    )..where((b) => b.pageId.equals(pageId) & b.deleted.equals(false))).get();
    var words = 0, chars = 0;
    for (final b in blocks) {
      final text = blockPlainText(b.data);
      chars += text.replaceAll(RegExp(r'\s'), '').length;
      words += text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    }
    return (words: words, chars: chars);
  }

  // ---- documents ----

  Future<PageDocument> openDocument(String pageId) async {
    final rows =
        await (db.select(db.blocks)
              ..where((b) => b.pageId.equals(pageId) & b.deleted.equals(false))
              ..orderBy([(b) => OrderingTerm.asc(b.sortKey)]))
            .get();
    return PageDocument._load(this, pageId, rows);
  }
}

class _SavedBlock {
  const _SavedBlock(this.parentId, this.sortKey, this.type, this.data);
  final String? parentId;
  final String sortKey;
  final String type;
  final String data;

  bool sameAs(_SavedBlock o) =>
      parentId == o.parentId &&
      sortKey == o.sortKey &&
      type == o.type &&
      data == o.data;
}

/// One open page: the editor [Document] plus what is currently stored in the
/// DB, so [save] writes only the blocks that changed.
class PageDocument {
  PageDocument._(this._repo, this.pageId, this.document);

  factory PageDocument._load(
    NotesRepository repo,
    String pageId,
    List<BlockRow> rows,
  ) {
    final byParent = <String?, List<BlockRow>>{};
    for (final r in rows) {
      byParent.putIfAbsent(r.parentId, () => []).add(r);
    }
    final ids = Expando<String>();
    final saved = <String, _SavedBlock>{};

    List<Node> build(String? parentId) => [
      for (final r in byParent[parentId] ?? const <BlockRow>[])
        (Node(
          type: r.type,
          attributes: Map<String, dynamic>.from(jsonDecode(r.data) as Map),
          children: build(r.id),
        ))..also((n) {
          ids[n] = r.id;
          saved[r.id] = _SavedBlock(r.parentId, r.sortKey, r.type, r.data);
        }),
    ];

    final children = build(null);
    final doc = Document(
      root: Node(
        type: 'page',
        children: children.isEmpty ? [paragraphNode()] : children,
      ),
    );
    return PageDocument._(repo, pageId, doc)
      .._ids = ids
      .._saved = saved;
  }

  final NotesRepository _repo;
  final String pageId;
  final Document document;

  Expando<String> _ids = Expando();
  Map<String, _SavedBlock> _saved = {};
  Future<void> _queue = Future.value();

  /// Persists changed blocks. Calls are serialized.
  Future<void> save() => _queue = _queue.then((_) => _save());

  Future<void> _save() async {
    final current = <String, _SavedBlock>{};

    void walk(Node parent, String? parentId) {
      final children = [
        for (final n in parent.children)
          if (!transientBlockTypes.contains(n.type)) n,
      ];
      final ids = [for (final n in children) _ids[n] ??= newId()];
      final keys = rebalanceKeys([
        for (final id in ids)
          _saved[id]?.parentId == parentId ? _saved[id]?.sortKey : null,
      ]);
      for (var i = 0; i < children.length; i++) {
        final node = children[i];
        current[ids[i]] = _SavedBlock(
          parentId,
          keys[i],
          node.type,
          jsonEncode(node.attributes),
        );
        walk(node, ids[i]);
      }
    }

    walk(document.root, null);

    final changed = [
      for (final e in current.entries)
        if (_saved[e.key] == null || !_saved[e.key]!.sameAs(e.value)) e,
    ];
    final removed = _saved.keys
        .where((id) => !current.containsKey(id))
        .toList();
    if (changed.isEmpty && removed.isEmpty) return;

    final db = _repo.db;
    final now = _repo._clock.tick();
    await db.transaction(() async {
      await db.batch((b) {
        for (final e in changed) {
          b.insert(
            db.blocks,
            BlocksCompanion.insert(
              id: e.key,
              pageId: pageId,
              parentId: Value(e.value.parentId),
              sortKey: e.value.sortKey,
              type: e.value.type,
              data: Value(e.value.data),
              updatedAt: now,
              deviceId: _repo.deviceId,
            ),
            mode: InsertMode.insertOrReplace,
          );
        }
        if (removed.isNotEmpty) {
          b.update(
            db.blocks,
            BlocksCompanion(
              deleted: const Value(true),
              dirty: const Value(true),
              updatedAt: Value(now),
              deviceId: Value(_repo.deviceId),
            ),
            where: (t) => t.id.isIn(removed),
          );
        }
        // "Last edited" only; not dirty, so body edits never overwrite a
        // title change from another device (see setCell).
        b.update(
          db.pages,
          PagesCompanion(updatedAt: Value(now)),
          where: (t) => t.id.equals(pageId),
        );
      });
      await _repo.reindexLinks([pageId]);
    });
    _saved = current;
  }
}

extension _Also<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

class SearchHit {
  const SearchHit(this.page, this.snippet);
  final PageRow page;

  /// Matching text around the hit, or null for a title match.
  final String? snippet;
}

/// Plain text of a stored block (`blocks.data`): delta text plus formulas.
String blockPlainText(String data) {
  try {
    final map = jsonDecode(data);
    if (map is! Map) return '';
    final buf = StringBuffer();
    final delta = map['delta'];
    if (delta is List) {
      for (final op in delta) {
        if (op is! Map) continue;
        final attrs = op['attributes'] as Map?;
        final formula = attrs?['formula'];
        final linked = attrs?[pageLinkKey] != null
            ? attrs![pageLinkTitleKey] as String? ?? ''
            : null;
        buf.write(formula is String ? formula : linked ?? op['insert'] ?? '');
      }
    }
    final formula = map['formula'];
    if (formula is String) buf.write(formula);
    return buf.toString();
  } catch (_) {
    return '';
  }
}
