import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import 'database.dart';
import 'notes_repository.dart';

/// Inline page link (Obsidian's `[[...]]`): one placeholder character in a
/// text delta carrying the target page id. The id never changes, so links
/// survive renames and moves; the title is shown live from the page row.
/// `page_title` is the title when the link was made, for plain text
/// (search, .md export) only.
const pageLinkKey = 'page_link';
const pageLinkTitleKey = 'page_title';

/// "링크 복사" of a page: pasted into a page it becomes a mention of it.
String pageLinkUrl(String pageId) => 'damda://page/$pageId';

/// The page id in a copied page link, or null.
String? pageIdFromLink(String? text) =>
    RegExp(r'^damda://page/([\w-]+)$').firstMatch(text?.trim() ?? '')?[1];
const pageLinkChar = '@';

/// Page ids linked from a block's stored JSON.
Set<String> pageLinksInData(String data) {
  if (!data.contains(pageLinkKey)) return const {};
  try {
    final map = jsonDecode(data);
    final out = <String>{};
    void scan(Object? delta) {
      if (delta is! List) return;
      for (final op in delta) {
        if (op is! Map) continue;
        final attrs = op['attributes'];
        final id = attrs is Map ? attrs[pageLinkKey] : null;
        if (id is String && id.isNotEmpty) out.add(id);
      }
    }

    if (map is Map) scan(map['delta']);
    return out;
  } catch (_) {
    return const {};
  }
}

typedef GraphData = ({
  List<PageRow> pages,
  List<({String from, String to})> links,
});

/// A page linking here, with the lines that contain the links.
typedef Backlink = ({PageRow page, List<String> snippets});

/// The `links` table is derived from block contents on this device (never
/// synced): rebuilt for a page whenever its blocks change, locally or by
/// sync.
extension LinkRepository on NotesRepository {
  /// Recomputes the links of [pageIds] from their live blocks.
  Future<void> reindexLinks(Iterable<String> pageIds) async {
    final ids = pageIds.toSet();
    if (ids.isEmpty) return;
    await db.transaction(() async {
      await (db.delete(db.links)..where((l) => l.sourcePageId.isIn(ids))).go();
      final blocks =
          await (db.select(db.blocks)..where(
                (b) =>
                    b.pageId.isIn(ids) &
                    b.deleted.equals(false) &
                    b.data.like('%$pageLinkKey%'),
              ))
              .get();
      await db.batch((batch) {
        for (final b in blocks) {
          for (final target in pageLinksInData(b.data)) {
            batch.insert(
              db.links,
              LinksCompanion.insert(
                sourcePageId: b.pageId,
                sourceBlockId: b.id,
                targetPageId: target,
              ),
              mode: InsertMode.insertOrIgnore,
            );
          }
        }
      });
    });
  }

  /// Builds the whole index once (links made before this existed, or on a
  /// device that just received everything by sync).
  Future<void> ensureLinkIndex() async {
    const version = '1';
    if (await db.getMeta('links_index') == version) return;
    final pages = await db.select(db.pages).get();
    await reindexLinks([for (final p in pages) p.id]);
    await db.setMeta('links_index', version);
  }

  /// Live pages linking to [pageId] (not itself), newest edit first.
  Stream<List<Backlink>> watchBacklinks(String pageId) {
    final query =
        db.select(db.links).join([
          innerJoin(db.pages, db.pages.id.equalsExp(db.links.sourcePageId)),
          innerJoin(db.blocks, db.blocks.id.equalsExp(db.links.sourceBlockId)),
        ])..where(
          db.links.targetPageId.equals(pageId) &
              db.links.sourcePageId.equals(pageId).not() &
              db.pages.deleted.equals(false) &
              db.pages.trashedAt.isNull(),
        );
    return query.watch().map((rows) {
      final byPage = <String, Backlink>{};
      for (final r in rows) {
        final page = r.readTable(db.pages);
        final text = blockPlainText(r.readTable(db.blocks).data).trim();
        final entry = byPage.putIfAbsent(
          page.id,
          () => (page: page, snippets: <String>[]),
        );
        if (text.isNotEmpty) entry.snippets.add(text);
      }
      return byPage.values.toList()
        ..sort((a, b) => b.page.updatedAt.compareTo(a.page.updatedAt));
    });
  }

  /// Pages and links for the graph, refreshed when either changes.
  Stream<GraphData> watchGraph() {
    final updates = db.tableUpdates(
      TableUpdateQuery.onAllTables([db.pages, db.links]),
    );
    late StreamController<GraphData> controller;
    StreamSubscription<void>? sub;
    Timer? debounce;
    Future<void> load() async {
      final pages =
          await (db.select(db.pages)..where(
                (p) =>
                    p.deleted.equals(false) &
                    p.trashedAt.isNull() &
                    p.isTemplate.equals(false),
              ))
              .get();
      final links = await allLinks();
      if (!controller.isClosed) {
        controller.add((pages: pages, links: links));
      }
    }

    controller = StreamController<GraphData>(
      onListen: () {
        load();
        // Typing saves often; the graph does not need every keystroke.
        sub = updates.listen((_) {
          debounce?.cancel();
          debounce = Timer(const Duration(milliseconds: 500), load);
        });
      },
      onCancel: () {
        debounce?.cancel();
        return sub?.cancel();
      },
    );
    return controller.stream;
  }

  /// All links between live pages (for the graph).
  Future<List<({String from, String to})>> allLinks() async {
    final rows = await (db.selectOnly(
      db.links,
      distinct: true,
    )..addColumns([db.links.sourcePageId, db.links.targetPageId])).get();
    return [
      for (final r in rows)
        (
          from: r.read(db.links.sourcePageId)!,
          to: r.read(db.links.targetPageId)!,
        ),
    ];
  }
}
