import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:path/path.dart' as p;

import '../data/album_repository.dart';
import '../data/asset_repository.dart';
import '../data/database.dart';
import '../data/database_repository.dart';
import '../data/notes_repository.dart';
import '../data/text_sort.dart';
import '../data/fractional_index.dart';
import '../editor/attachment_blocks.dart' show FileBlockKeys;
import 'markdown_codec.dart';

/// Folder of `.md` files (an Obsidian vault) <-> pages.
///
/// Layout: a page is `제목.md`; its sub-pages go in a folder `제목/` next
/// to it. Attachments go to `_assets/`. Every file carries its page `id` in
/// the frontmatter, so importing an exported folder again updates the same
/// pages instead of making copies.
class MdReport {
  int pages = 0;
  int created = 0;
  int updated = 0;
  int attachments = 0;
  int missingAttachments = 0;

  /// Embeds whose file wasn't found ("note.md: ![[x.png]]").
  final missingNames = <String>[];

  /// Pages made for `[[links]]` that pointed at no file (no longer made;
  /// kept for older callers).
  int placeholderPages = 0;

  /// `[[links]]` to notes that don't exist (left as text).
  int unresolvedLinks = 0;

  /// The page holding a folder import (null for single files / updates).
  String? rootPageId;

  @override
  String toString() =>
      'pages=$pages created=$created updated=$updated '
      'attachments=$attachments missing=$missingAttachments '
      'unresolved=$unresolvedLinks';
}

const assetsFolder = '_assets';

/// Icon of pages that stand for a folder of the imported vault.
const folderIcon = '📁';

String _safeName(String title) {
  var s = title.replaceAll(RegExp(r'[\\/:*?"<>|#^\[\]]'), ' ').trim();
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  // Windows: no trailing dots/spaces, no reserved names.
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (RegExp(
    r'^(con|prn|aux|nul|com\d|lpt\d)$',
    caseSensitive: false,
  ).hasMatch(s)) {
    s = '_$s';
  }
  if (s.length > 120) s = s.substring(0, 120).trim();
  return s.isEmpty ? '제목 없음' : s;
}

String _iso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String().split('.').first;

extension MarkdownVault on NotesRepository {
  // ---------------------------------------------------------------- export

  /// Writes [rootPageId] and its sub-pages (or every page) into [dir].
  Future<MdReport> exportMarkdown(String dir, {String? rootPageId}) async {
    final report = MdReport();
    final all = await (db.select(
      db.pages,
    )..where((x) => x.deleted.equals(false) & x.trashedAt.isNull())).get();
    final byId = {for (final x in all) x.id: x};
    final children = <String?, List<PageRow>>{};
    for (final x in all) {
      if (x.isTemplate) continue;
      children.putIfAbsent(x.parentId, () => []).add(x);
    }
    for (final list in children.values) {
      list.sort((a, b) => a.sortKey.compareTo(b.sortKey));
    }

    // Page -> vault-relative path ("a/b/제목.md").
    final paths = <String, String>{};
    void place(PageRow page, String folder) {
      final taken = {
        for (final v in paths.values)
          if (p.posix.dirname(v) == (folder.isEmpty ? '.' : folder))
            p.posix.basenameWithoutExtension(v).toLowerCase(),
      };
      var name = _safeName(page.title);
      for (var i = 2; taken.contains(name.toLowerCase()); i++) {
        name = '${_safeName(page.title)} ($i)';
      }
      paths[page.id] = p.posix.join(folder, '$name.md');
      final kids = children[page.id] ?? const [];
      for (final k in kids) {
        place(k, p.posix.join(folder, name));
      }
    }

    if (rootPageId != null) {
      final root = byId[rootPageId];
      if (root == null) return report;
      place(root, '');
    } else {
      for (final top in children[null] ?? const <PageRow>[]) {
        place(top, '');
      }
    }

    // [[link]] text: the title, or the path when titles clash.
    final titleCount = <String, int>{};
    for (final id in paths.keys) {
      final t = byId[id]!.title.toLowerCase();
      titleCount[t] = (titleCount[t] ?? 0) + 1;
    }
    String? linkTarget(String id) {
      final page = byId[id];
      if (page == null) return null;
      final path = paths[id];
      if (path == null || titleCount[page.title.toLowerCase()] == 1) {
        return page.title.isEmpty
            ? p.posix.withoutExtension(path ?? '')
            : page.title;
      }
      return p.posix.withoutExtension(path);
    }

    // Attachments are copied on first use.
    final assets = {
      for (final a in await (db.select(
        db.assets,
      )..where((x) => x.deleted.equals(false))).get())
        a.id: a,
    };
    final assetPaths = <String, String>{};
    final usedNames = <String>{};
    String? assetPath(String id) {
      final known = assetPaths[id];
      if (known != null) return known;
      final a = assets[id];
      if (a == null) return null;
      final ext = p.extension(a.name);
      final stem = p.basenameWithoutExtension(a.name);
      var name = '${_safeName(stem)}$ext';
      for (var i = 2; usedNames.contains(name.toLowerCase()); i++) {
        name = '${_safeName(stem)} ($i)$ext';
      }
      usedNames.add(name.toLowerCase());
      final rel = '$assetsFolder/$name';
      final source = File(this.assetPath(a));
      if (source.existsSync()) {
        final target = File(p.join(dir, assetsFolder, name));
        target.parent.createSync(recursive: true);
        source.copySync(target.path);
        report.attachments++;
      } else {
        report.missingAttachments++;
      }
      return assetPaths[id] = rel;
    }

    final ctx = MdExportContext(linkTarget: linkTarget, assetPath: assetPath);
    for (final MapEntry(key: id, value: rel) in paths.entries) {
      final page = byId[id]!;
      final fm = <String, Object?>{
        'id': page.id,
        // The file name can differ (unsafe characters, " (2)" for clashes).
        if (p.posix.basenameWithoutExtension(rel) != page.title)
          'title': page.title,
        'icon': page.icon,
        if (page.kind != 'page') 'type': page.kind,
        'created': _iso(page.createdAt),
        'updated': _iso(page.updatedAt),
      };
      final body = StringBuffer();
      switch (page.kind) {
        case 'database':
          body.write(await _databaseTable(page.id, linkTarget));
        case 'album':
          for (final item in await watchAlbum(page.id).first) {
            final path = assetPath(item.asset.id);
            if (path != null) body.writeln('![[$path]]');
          }
        default:
          if (page.kind == 'row') fm.addAll(await _rowProperties(page));
          final doc = await openDocument(page.id);
          body.write(nodesToMarkdown(doc.document.root.children.toList(), ctx));
      }
      final file = File(p.join(dir, rel));
      file.parent.createSync(recursive: true);
      await file.writeAsString('${frontmatterToString(fm)}$body');
      report.pages++;
    }
    return report;
  }

  /// A database as a Markdown table; rows are linked sub-pages.
  Future<String> _databaseTable(
    String id,
    String? Function(String) linkTarget,
  ) async {
    final snap = await loadDatabase(id);
    if (snap == null) return '';
    String esc(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');
    final props = snap.properties;
    final b = StringBuffer()
      ..writeln('| 이름 | ${props.map((x) => esc(x.name)).join(' | ')} |')
      ..writeln('|---|${props.map((_) => '---|').join()}');
    for (final row in snap.rows) {
      final target = linkTarget(row.id);
      final cells = [
        for (final prop in props) esc(cellText(prop, snap.value(row.id, prop))),
      ];
      b.writeln(
        '| ${target == null ? esc(row.title) : '[[$target]]'} | ${cells.join(' | ')} |',
      );
    }
    return b.toString();
  }

  /// A database row's cells as frontmatter (property name: text).
  Future<Map<String, Object?>> _rowProperties(PageRow row) async {
    final dbId = row.parentId;
    if (dbId == null) return const {};
    final snap = await loadDatabase(dbId);
    if (snap == null) return const {};
    return {
      for (final prop in snap.properties)
        if (!const {
          'id',
          'title',
          'icon',
          'type',
          'created',
          'updated',
        }.contains(prop.name))
          prop.name: cellText(prop, snap.value(row.id, prop)),
    };
  }

  // ---------------------------------------------------------------- import

  /// Imports one `.md` file or a whole folder (Obsidian vault). New pages
  /// go under [parentId]; a folder gets its own page holding them.
  Future<MdReport> importMarkdown(String path, {String? parentId}) async {
    final report = MdReport();
    final isDir = FileSystemEntity.isDirectorySync(path);
    final root = isDir ? path : p.dirname(path);

    // Files, vault-relative with '/'.
    final mdFiles = <String>[];
    final otherFiles = <String>[];
    if (isDir) {
      for (final e in Directory(path).listSync(recursive: true)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: root).replaceAll(r'\', '/');
        if (rel.split('/').any((s) => s.startsWith('.'))) continue;
        (rel.toLowerCase().endsWith('.md') ? mdFiles : otherFiles).add(rel);
      }
    } else {
      mdFiles.add(p.basename(path));
    }
    mdFiles.sort();

    var container = parentId;
    if (isDir) {
      container = await createPage(
        parentId: parentId,
        title: p.basename(path),
        icon: folderIcon,
      );
      report.rootPageId = container;
      report.created++;
    }

    // Pass 1: a page per file (and per folder without its own file).
    final parsed = <String, MdParsed>{};
    final pageOfFile = <String, String>{};
    final folderPages = <String, String>{};
    final keep = <String>{}; // existing DB / album pages: body untouched
    // Files this app exported (they carry an id): their "X.md" and "X/"
    // are one page with its sub-pages. In an Obsidian vault they are two
    // separate things, a note and a folder.
    final exported = <String>{};
    final index = <String, ({String id, String title})>{}; // lookup keys

    void remember(String key, ({String id, String title}) page) =>
        index.putIfAbsent(key.toLowerCase(), () => page);

    Future<String?> parentFor(String folder) async {
      if (folder == '.' || folder.isEmpty) return container;
      final ownFile = '$folder.md';
      if (exported.contains(ownFile)) return pageOfFile[ownFile];
      final known = folderPages[folder];
      if (known != null) return known;
      final id = await createPage(
        parentId: await parentFor(p.posix.dirname(folder)),
        title: p.posix.basename(folder),
        icon: folderIcon,
      );
      report.created++;
      return folderPages[folder] = id;
    }

    // Parents before children: shorter paths first.
    final ordered = [...mdFiles]
      ..sort(
        (a, b) => '/'.allMatches(a).length.compareTo('/'.allMatches(b).length),
      );
    for (final rel in ordered) {
      final file = isDir ? p.join(root, rel) : path;
      final mdText = await File(file).readAsString();
      final data = parseMarkdown(mdText);
      parsed[rel] = data;
      final fm = data.frontmatter;
      final title =
          (fm['title'] as String?) ?? p.posix.basenameWithoutExtension(rel);
      final fmId = fm['id'] is String ? fm['id'] as String : null;
      if (fmId != null) exported.add(rel);
      final existing = fmId == null ? null : await getPage(fmId);
      String id;
      if (existing != null && !existing.deleted) {
        id = existing.id;
        await updatePage(id, title: title, icon: fm['icon'] as String?);
        if (existing.trashedAt != null) await restorePage(id);
        if (existing.kind == 'database' || existing.kind == 'album') {
          keep.add(id);
        }
        report.updated++;
      } else {
        id = await createPage(
          parentId: await parentFor(p.posix.dirname(rel)),
          title: title,
          icon: fm['icon'] as String?,
          id: existing == null ? fmId : null,
        );
        report.created++;
      }
      pageOfFile[rel] = id;
      final page = (id: id, title: title);
      remember(p.posix.withoutExtension(rel), page);
      remember(title, page);
      remember(p.posix.basenameWithoutExtension(rel), page);
      final aliases = fm['aliases'];
      if (aliases is List) {
        for (final a in aliases) {
          remember('$a', page);
        }
      }
    }

    // Pass 2: bodies, with links and attachments resolved.
    final byName = <String, String>{};
    for (final f in otherFiles) {
      byName.putIfAbsent(p.posix.basename(f).toLowerCase(), () => f);
      byName.putIfAbsent(f.toLowerCase(), () => f);
    }
    for (final MapEntry(key: rel, value: data) in parsed.entries) {
      final pageId = pageOfFile[rel]!;
      report.pages++;
      if (keep.contains(pageId)) continue;

      Future<({String id, String title})?> pageFor(String target) async {
        var t = target.trim().replaceAll(r'\', '/');
        if (t.startsWith('./')) t = t.substring(2);
        if (t.toLowerCase().endsWith('.md')) t = t.substring(0, t.length - 3);
        final relative = p.posix.normalize(
          p.posix.join(p.posix.dirname(rel), t),
        );
        final hit =
            index[t.toLowerCase()] ??
            index[relative.toLowerCase()] ??
            index[p.posix.basename(t).toLowerCase()];
        // A note that doesn't exist: the text stays, no empty page.
        if (hit == null) report.unresolvedLinks++;
        return hit;
      }

      Future<Node?> attach(
        String target, {
        required bool wiki,
        required bool quiet,
      }) async {
        final t = target.replaceAll(r'\', '/').trim();
        if (t.isEmpty) return null; // "![]()": nothing to keep
        // Like Obsidian: next to the note, from the vault top, then by
        // file name anywhere in the vault.
        String? found(String candidate) =>
            File(p.join(root, candidate)).existsSync() ? candidate : null;
        final rel2 = wiki
            ? (byName[t.toLowerCase()] ??
                  byName[p.posix.basename(t).toLowerCase()])
            : found(p.posix.normalize(p.posix.join(p.posix.dirname(rel), t))) ??
                  found(p.posix.normalize(t)) ??
                  byName[t.toLowerCase()] ??
                  byName[p.posix.basename(t).toLowerCase()];
        final file = rel2 == null ? null : File(p.join(root, rel2));
        if (file == null || !file.existsSync()) {
          if (quiet) return null;
          report.missingAttachments++;
          report.missingNames.add('$rel: $target');
          return paragraphNode(text: wiki ? '![[$target]]' : '![]($target)');
        }
        final asset = await importAsset(file.path, pageId: pageId);
        report.attachments++;
        if (assetKind(asset.mime) == AssetKind.image) {
          return imageNode(url: assetUrl(asset.id));
        }
        return Node(
          type: FileBlockKeys.type,
          attributes: {
            FileBlockKeys.url: assetUrl(asset.id),
            FileBlockKeys.name: asset.name,
            FileBlockKeys.size: asset.size,
            FileBlockKeys.mime: asset.mime,
          },
        );
      }

      final nodes = await resolveParsed(
        data.nodes,
        pageFor: pageFor,
        embed: (t, {required wiki}) => attach(t, wiki: wiki, quiet: false),
        // [[a.pdf]]: attach the file when it's in the vault.
        fileLink: (t) => attach(t, wiki: true, quiet: true),
      );
      final doc = await openDocument(pageId);
      doc.document.delete([0], doc.document.root.children.length);
      doc.document.insert([0], nodes.isEmpty ? [paragraphNode()] : nodes);
      await doc.save();
    }
    if (isDir && container != null) await sortLikeExplorer(container);
    return report;
  }

  /// Orders the pages under [parentId] like Obsidian's file list: folders
  /// first, then notes, each by name ("2일차" before "10일차"); folders
  /// recursively.
  Future<void> sortLikeExplorer(String parentId) async {
    final kids =
        await (db.select(db.pages)..where(
              (x) => x.parentId.equals(parentId) & x.deleted.equals(false),
            ))
            .get();
    bool folder(PageRow x) => x.icon == folderIcon;
    kids.sort((a, b) {
      if (folder(a) != folder(b)) return folder(a) ? -1 : 1;
      return naturalCompare(a.title, b.title);
    });
    String? key;
    for (final k in kids) {
      key = keyBetween(key, null);
      if (k.sortKey != key) {
        await (db.update(db.pages)..where((x) => x.id.equals(k.id))).write(
          PagesCompanion(
            sortKey: Value(key),
            updatedAt: Value(clock.tick()),
            deviceId: Value(deviceId),
            dirty: const Value(true),
          ),
        );
      }
      if (folder(k)) await sortLikeExplorer(k.id);
    }
  }
}
