import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:http/http.dart' as http;

import '../data/asset_repository.dart';
import '../data/clock.dart' show newId;
import '../data/database.dart';
import '../data/database_repository.dart';
import '../data/formula.dart';
import '../data/links.dart';
import '../data/notes_repository.dart';
import '../editor/attachment_blocks.dart' show FileBlockKeys;
import '../editor/code_block.dart';
import '../editor/toggle_callout.dart';
import '../editor/math_block.dart' show MathBlockKeys;

/// One-way import from Notion (an internal integration token; the user
/// shares the top pages with the integration). Pages, sub-pages, databases
/// with their columns and rows, and attachments come over. Every imported
/// page remembers its Notion id, so importing again updates the same pages.
///
/// API version 2022-06-28. Notion allows about 3 requests a second; the
/// client waits between requests and retries on 429.
class NotionApi {
  NotionApi(
    this.token, {
    http.Client? client,
    this.minGap = const Duration(milliseconds: 340),
  }) : _http = client ?? http.Client();

  final String token;
  final http.Client _http;
  final Duration minGap;
  static const base = 'https://api.notion.com/v1';
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// Version for most calls; the Views API needs a newer one.
  static const version = '2022-06-28';
  static const viewsVersion = '2026-03-11';

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
    String apiVersion = version,
  ]) async {
    for (var attempt = 0; ; attempt++) {
      final wait = minGap - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      final uri = Uri.parse('$base$path');
      final headers = {
        'Authorization': 'Bearer $token',
        'Notion-Version': apiVersion,
        'Content-Type': 'application/json',
      };
      final res =
          await (method == 'GET'
                  ? _http.get(uri, headers: headers)
                  : _http.post(
                      uri,
                      headers: headers,
                      body: jsonEncode(body ?? {}),
                    ))
              .timeout(const Duration(seconds: 60));
      if (res.statusCode == 429 || res.statusCode >= 500) {
        if (attempt >= 5) {
          throw NotionException('Notion 서버가 바빠요 (${res.statusCode})');
        }
        final retry =
            int.tryParse(res.headers['retry-after'] ?? '') ?? (1 << attempt);
        await Future<void>.delayed(Duration(seconds: retry));
        continue;
      }
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        throw NotionException(switch (res.statusCode) {
          401 => '토큰이 맞지 않아요',
          403 || 404 => '접근 권한이 없어요: ${json['message']}',
          _ => 'Notion 오류 ${res.statusCode}: ${json['message']}',
        });
      }
      return json;
    }
  }

  /// All results of a paginated endpoint.
  Future<List<Map<String, dynamic>>> all(
    String method,
    String path, [
    Map<String, dynamic>? body,
    String apiVersion = version,
  ]) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final Map<String, dynamic> res;
      if (method == 'GET') {
        final sep = path.contains('?') ? '&' : '?';
        res = await call(
          'GET',
          '$path${sep}page_size=100${cursor == null ? '' : '&start_cursor=$cursor'}',
          null,
          apiVersion,
        );
      } else {
        res = await call('POST', path, {
          ...?body,
          'page_size': 100,
          'start_cursor': ?cursor,
        }, apiVersion);
      }
      out.addAll((res['results'] as List).cast<Map<String, dynamic>>());
      cursor = res['has_more'] == true ? res['next_cursor'] as String? : null;
    } while (cursor != null);
    return out;
  }

  /// Downloads a Notion-hosted file (signed URL, no token needed).
  Future<Uint8List> download(String url) async {
    final res = await _http
        .get(Uri.parse(url))
        .timeout(const Duration(minutes: 5));
    if (res.statusCode != 200) {
      throw NotionException('첨부를 받지 못했어요 (${res.statusCode})');
    }
    return res.bodyBytes;
  }

  void close() => _http.close();
}

class NotionException implements Exception {
  NotionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A top-level page or database the integration can see.
class NotionItem {
  NotionItem({
    required this.id,
    required this.title,
    required this.icon,
    required this.isDatabase,
    required this.inside,
  });

  final String id;
  final String title;
  final String? icon;
  final bool isDatabase;

  /// Pages and databases below it.
  final int inside;
}

class NotionReport {
  int views = 0;

  /// Formulas kept as live formulas (the rest came over as values).
  int liveFormulas = 0;

  int pages = 0;
  int databases = 0;
  int rows = 0;
  int updated = 0;
  int attachments = 0;
  int failedAttachments = 0;
  int skippedBlocks = 0;
  String? rootPageId;
}

/// Progress: what is happening and how far (done of total pages).
typedef NotionProgress = void Function(String message, int done, int total);

const notionIdKey = '_notion';

class NotionImporter {
  NotionImporter(this.repo, this.api, {this.onProgress});

  final NotesRepository repo;
  final NotionApi api;
  final NotionProgress? onProgress;
  final report = NotionReport();

  /// Notion id (no dashes) -> our page id / title.
  final _ours = <String, String>{};
  final _titles = <String, String>{};
  final _kinds = <String, String>{}; // notion id -> page | database
  final _blockParent = <String, String?>{}; // block id -> notion page id
  final _newDatabases = <String>{}; // our ids, made in this run
  final _currencyColumns = <String>{}; // our number props showing money
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  static String norm(String id) => id.replaceAll('-', '');

  Map<String, Map<String, dynamic>>? _all;
  final _parentOf = <String, String?>{};

  /// Lists what the integration can see, as top-level items (pages or
  /// databases whose parent is not shared) with how much is under each.
  Future<List<NotionItem>> scan() async {
    _progress('Notion에서 목록을 받는 중…', 0, 0);
    final objects = [
      ...await api.all('POST', '/search', {
        'filter': {'property': 'object', 'value': 'page'},
      }),
      ...await api.all('POST', '/search', {
        'filter': {'property': 'object', 'value': 'database'},
      }),
    ].where((o) => o['archived'] != true && o['in_trash'] != true).toList();
    if (objects.isEmpty) {
      throw NotionException(
        '가져올 페이지가 없어요. Notion에서 페이지 ⋯ → 연결 → 이 통합을 추가했는지 확인하세요.',
      );
    }
    final byId = {for (final o in objects) norm(o['id'] as String): o};
    for (final MapEntry(key: id, value: o) in byId.entries) {
      _kinds[id] = o['object'] as String;
      _titles[id] = _titleOf(o);
    }
    // Parents (pages under a block, e.g. in a column, belong to the page
    // that holds the block).
    for (final MapEntry(key: id, value: o) in byId.entries) {
      _parentOf[id] = await _parentPage(o['parent'] as Map<String, dynamic>);
    }
    _all = byId;
    final roots = [
      for (final id in byId.keys)
        if (!byId.containsKey(_parentOf[id])) id,
    ];
    return [
      for (final id in roots)
        NotionItem(
          id: id,
          title: _titles[id] ?? '',
          icon: _emoji(byId[id]!),
          isDatabase: _kinds[id] == 'database',
          inside: _under({id}).length - 1,
        ),
    ]..sort((a, b) => a.title.compareTo(b.title));
  }

  /// [roots] and everything below them.
  Set<String> _under(Set<String> roots) {
    final out = {...roots};
    var grew = true;
    while (grew) {
      grew = false;
      for (final MapEntry(key: id, value: parent) in _parentOf.entries) {
        if (parent != null && out.contains(parent) && out.add(id)) grew = true;
      }
    }
    return out;
  }

  /// Imports [only] (top-level ids from [scan]) with everything below
  /// them, or everything when null.
  Future<NotionReport> run({String? parentId, Set<String>? only}) async {
    if (_all == null) await scan();
    final all = _all!;
    final keep = only == null ? all.keys.toSet() : _under(only);
    final byId = {
      for (final e in all.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };

    // Pages imported before (matched by their Notion id).
    final marks = await (repo.db.select(
      repo.db.properties,
    )..where((p) => p.key.equals(notionIdKey) & p.deleted.equals(false))).get();
    final existing = <String, String>{};
    for (final m in marks) {
      final page = await repo.getPage(m.pageId);
      if (page != null && !page.deleted) {
        existing[jsonDecode(m.value) as String] = m.pageId;
      }
    }

    final parentOf = _parentOf;

    final now = DateTime.now();
    final container = await repo.createPage(
      parentId: parentId,
      title:
          'Notion에서 가져옴 ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      icon: '📥',
    );
    report.rootPageId = container;

    // Pass 1: every page/database exists (parents first), so links and
    // mentions can point at them.
    final pending = byId.keys.toList();
    var guard = pending.length + 1;
    while (pending.isNotEmpty && guard-- > 0) {
      for (final id in [...pending]) {
        final parent = parentOf[id];
        final parentKnown =
            parent == null ||
            !byId.containsKey(parent) ||
            _ours.containsKey(parent);
        if (!parentKnown) continue;
        await _shell(
          id,
          byId[id]!,
          parent == null ? null : _ours[parent],
          container,
          existing,
        );
        pending.remove(id);
      }
    }
    for (final id in pending) {
      await _shell(id, byId[id]!, null, container, existing); // cycles
    }

    // Pass 2: databases (columns, rows' cells), then every page's content.
    final total = byId.length;
    var done = 0;
    for (final MapEntry(key: id, value: o) in byId.entries) {
      if (o['object'] == 'database') await _database(id, o);
    }
    for (final MapEntry(key: id, value: o) in byId.entries) {
      if (_cancelled) break;
      _progress('가져오는 중: ${_titles[id]}', done++, total);
      if (o['object'] != 'page') continue;
      await _content(id, _ours[id]!);
    }
    await repo.reindexLinks(_ours.values);
    // Re-import with nothing new: no empty holder page left behind.
    final held =
        await (repo.db.select(repo.db.pages)..where(
              (x) => x.parentId.equals(container) & x.deleted.equals(false),
            ))
            .get();
    if (held.isEmpty) {
      await repo.deletePage(container);
      report.rootPageId = null;
    }
    _progress('완료', total, total);
    return report;
  }

  void _progress(String m, int done, int total) =>
      onProgress?.call(m, done, total);

  Future<String?> _parentPage(Map<String, dynamic> parent) async {
    switch (parent['type']) {
      case 'page_id':
        return norm(parent['page_id'] as String);
      case 'database_id':
        return norm(parent['database_id'] as String);
      case 'block_id':
        final block = norm(parent['block_id'] as String);
        if (_blockParent.containsKey(block)) return _blockParent[block];
        String? page;
        try {
          final b = await api.call('GET', '/blocks/$block');
          page = await _parentPage(b['parent'] as Map<String, dynamic>);
        } catch (_) {}
        return _blockParent[block] = page;
      default:
        return null; // workspace
    }
  }

  static String _plain(List? rich) =>
      (rich ?? const []).map((r) => (r as Map)['plain_text'] ?? '').join();

  static String _titleOf(Map<String, dynamic> o) {
    if (o['object'] == 'database') return _plain(o['title'] as List?);
    final props = (o['properties'] as Map?) ?? const {};
    for (final p in props.values) {
      if (p is Map && p['type'] == 'title') return _plain(p['title'] as List?);
    }
    return '';
  }

  static String? _emoji(Map<String, dynamic> o) {
    final icon = o['icon'];
    return icon is Map && icon['type'] == 'emoji'
        ? icon['emoji'] as String?
        : null;
  }

  Future<void> _shell(
    String id,
    Map<String, dynamic> o,
    String? parent,
    String container,
    Map<String, String> existing,
  ) async {
    final title = _titles[id] ?? '';
    final icon = _emoji(o);
    final old = existing[id];
    if (old != null) {
      await repo.updatePage(old, title: title, icon: icon);
      final page = await repo.getPage(old);
      if (page?.trashedAt != null) await repo.restorePage(old);
      _ours[id] = old;
      report.updated++;
      return;
    }
    final String ours;
    final parentKind = (o['parent'] as Map)['type'];
    if (o['object'] == 'database') {
      ours = await repo.createDatabase(
        parentId: parent ?? container,
        title: title,
      );
      // Columns come from Notion: drop the default tag column.
      final snap = await repo.loadDatabase(ours);
      for (final p in snap?.properties ?? const <DbProperty>[]) {
        await repo.deleteProperty(p.id);
      }
      if (icon != null) await repo.updatePage(ours, icon: icon);
      _newDatabases.add(ours);
      report.databases++;
    } else if (parentKind == 'database_id' && parent != null) {
      ours = await repo.addRow(parent, title: title);
      if (icon != null) await repo.updatePage(ours, icon: icon);
      report.rows++;
    } else {
      ours = await repo.createPage(
        parentId: parent ?? container,
        title: title,
        icon: icon,
      );
      report.pages++;
    }
    await repo.db
        .into(repo.db.properties)
        .insertOnConflictUpdate(
          PropertiesCompanion.insert(
            pageId: ours,
            key: notionIdKey,
            value: jsonEncode(id),
            updatedAt: repo.clock.tick(),
            deviceId: repo.deviceId,
            dirty: const Value(true),
          ),
        );
    _ours[id] = ours;
  }

  // ------------------------------------------------------------ databases

  static const _colors = {
    'default': 'gray',
    'gray': 'gray',
    'brown': 'brown',
    'orange': 'orange',
    'yellow': 'yellow',
    'green': 'green',
    'blue': 'blue',
    'purple': 'purple',
    'pink': 'pink',
    'red': 'red',
  };

  Future<void> _database(String id, Map<String, dynamic> o) async {
    final dbId = _ours[id]!;
    final schema = (o['properties'] as Map).cast<String, dynamic>();
    final snap = await repo.loadDatabase(dbId);
    final ourByName = {
      for (final p in snap?.properties ?? const <DbProperty>[]) p.name: p,
    };

    // Notion property name -> (our id, our type, option name -> option id).
    final columns =
        <String, ({String id, String type, Map<String, String> options})>{};
    final rows = await api.all('POST', '/databases/$id/query');
    for (final MapEntry(key: name, value: raw) in schema.entries) {
      final p = raw as Map<String, dynamic>;
      final nType = p['type'] as String;
      if (nType == 'title') continue;
      final type = switch (nType) {
        'number' => PropType.number,
        'select' || 'status' => PropType.select,
        'multi_select' => PropType.multiSelect,
        'date' || 'created_time' || 'last_edited_time' => PropType.date,
        'checkbox' => PropType.checkbox,
        'url' => PropType.url,
        'place' => PropType.place,
        // Their results decide: a formula giving dates becomes a date
        // column, so calendars and timelines built on it keep working.
        'formula' || 'rollup' => _resultType(name, rows),
        _ => PropType.text,
      };
      final existing = ourByName[name];
      final propId = existing?.id ?? await repo.addProperty(dbId, name, type);
      // Imported earlier as text (formula dates, places): fix the type.
      if (existing != null &&
          existing.type == PropType.text &&
          type != PropType.text) {
        await repo.updateProperty(propId, type: type);
      }
      final options = <String, String>{
        for (final opt in existing?.options ?? const <SelectOption>[])
          opt.name: opt.id,
      };
      if (type == PropType.select || type == PropType.multiSelect) {
        final list = ((p[nType] as Map?)?['options'] as List?) ?? const [];
        final all = [...existing?.options ?? const <SelectOption>[]];
        for (final opt in list.cast<Map>()) {
          final optName = opt['name'] as String? ?? '';
          if (options.containsKey(optName)) continue;
          final option = SelectOption(
            newId(),
            optName,
            _colors[opt['color']] ?? 'gray',
          );
          options[optName] = option.id;
          all.add(option);
        }
        await repo.updateProperty(
          propId,
          config: {
            'options': [for (final x in all) x.toJson()],
          },
        );
      }
      columns[name] = (id: propId, type: type, options: options);

      // Number display (₩, ¥, …). A formula has no format; its name often
      // says the currency ("엔화 환산 (¥)").
      if (type == PropType.number) {
        final format =
            (p['number'] as Map?)?['format'] as String? ??
            switch (name) {
              _ when name.contains('₩') => 'won',
              _ when name.contains('¥') => 'yen',
              _ when name.contains(r'$') => 'dollar',
              _ when name.contains('€') => 'euro',
              _ => null,
            };
        if (format != null && format != 'number') {
          await repo.updateProperty(propId, config: {'format': format});
          if (isCurrencyFormat(format)) _currencyColumns.add(propId);
        }
      }

      // A date with an end gets a second column for the end (timeline).
      if (nType == 'date' &&
          rows.any(
            (r) =>
                ((r['properties'] as Map)[name] as Map?)?['date']?['end'] !=
                null,
          )) {
        final endName = '$name (끝)';
        columns[endName] = (
          id:
              ourByName[endName]?.id ??
              await repo.addProperty(dbId, endName, PropType.date),
          type: PropType.date,
          options: const {},
        );
      }
    }

    await _views(id, dbId, schema, columns);

    for (final row in rows) {
      final rowId = _ours[norm(row['id'] as String)];
      if (rowId == null) continue;
      final props = (row['properties'] as Map).cast<String, dynamic>();
      for (final MapEntry(key: name, value: raw) in props.entries) {
        final col = columns[name];
        if (col == null) continue;
        final p = raw as Map<String, dynamic>;
        final value = _cell(p, col.type, col.options);
        await repo.setCell(rowId, col.id, value);
        final dateValue = p['type'] == 'date' ? p['date'] : null;
        final end = dateValue is Map ? dateValue['end'] : null;
        final endCol = columns['$name (끝)'];
        if (endCol != null) await repo.setCell(rowId, endCol.id, end);
      }
    }

    // Formulas: keep them live where this app computes the same results.
    final titleName = schema.entries
        .where((e) => (e.value as Map)['type'] == 'title')
        .firstOrNull
        ?.key;
    for (final MapEntry(key: name, value: raw) in schema.entries) {
      if ((raw as Map)['type'] != 'formula') continue;
      final col = columns[name];
      final expr = (raw['formula'] as Map?)?['expression'];
      if (col == null || expr is! String) continue;
      await _liveFormula(dbId, name, col, expr, titleName, rows);
    }
  }

  /// Turns a column into a live formula when the translated Notion formula
  /// gives the same result as Notion on every row; otherwise it stays a
  /// plain column with the values from Notion.
  Future<void> _liveFormula(
    String dbId,
    String name,
    ({String id, String type, Map<String, String> options}) col,
    String expression,
    String? titleName,
    List<Map<String, dynamic>> rows,
  ) async {
    // Notion's title column is "이름" here.
    final translated = titleName == null
        ? expression
        : expression
              .replaceAll('prop("$titleName")', 'prop("이름")')
              .replaceAll("prop('$titleName')", 'prop("이름")');
    final before = (await repo.loadDatabase(dbId))?.property(col.id);
    if (before == null) return;
    final revertConfig = before.type == PropType.formula
        ? <String, dynamic>{}
        : before.config;
    await repo.updateProperty(
      col.id,
      type: PropType.formula,
      config: {'expression': translated},
    );
    final snap = await repo.loadDatabase(dbId);
    final prop = snap?.property(col.id);
    var same = snap != null && prop != null && rows.isNotEmpty;
    for (final row in rows) {
      if (!same) break;
      final ours = _ours[norm(row['id'] as String)];
      final raw = (row['properties'] as Map)[name];
      if (ours == null || raw is! Map) continue;
      final notion = _cell(raw.cast<String, dynamic>(), col.type, col.options);
      same = _sameResult(notion, snap!.value(ours, prop!), col.type);
    }
    if (same) {
      report.liveFormulas++;
    } else {
      await repo.updateProperty(col.id, type: col.type, config: revertConfig);
    }
  }

  static bool _sameResult(Object? notion, Object? ours, String type) {
    if (ours is FormulaError) return false;
    bool blank(Object? v) => v == null || (v is String && v.isEmpty);
    if (blank(notion) || blank(ours)) return blank(notion) && blank(ours);
    return switch (type) {
      PropType.date =>
        '$notion'.length >= 10 &&
            '$ours'.length >= 10 &&
            '$notion'.substring(0, 10) == '$ours'.substring(0, 10),
      PropType.number =>
        notion is num && ours is num && (notion - ours).abs() < 1e-6,
      PropType.checkbox => (notion == true) == (ours == true),
      _ => '$notion' == formatFormulaValue(ours),
    };
  }

  /// Notion's views (Views API, newer API version) → our views: type, name,
  /// board grouping, calendar/timeline dates, visible card properties,
  /// hidden columns, first sort. Without the Views API: a board on the
  /// first select/status and a calendar on the first date, as a guess.
  Future<void> _views(
    String notionDb,
    String dbId,
    Map<String, dynamic> schema,
    Map<String, ({String id, String type, Map<String, String> options})>
    columns,
  ) async {
    // Notion property id or name -> our property id ('title' has none).
    final ours = <String, String>{};
    final endOf = <String, String>{};
    for (final MapEntry(key: name, value: raw) in schema.entries) {
      final col = columns[name];
      if (col == null) continue;
      final nId = (raw as Map)['id'] as String? ?? '';
      ours[name] = col.id;
      ours[nId] = col.id;
      ours[Uri.decodeComponent(nId)] = col.id;
      final end = columns['$name (끝)'];
      if (end != null) endOf[col.id] = end.id;
    }
    String? prop(Object? key) => key is String ? ours[key] : null;

    // Our views that came from Notion carry its view id; re-imports update
    // those and add new ones. Views made here (no id) are never touched.
    final before = (await repo.loadDatabase(dbId))?.views ?? const [];
    final fromNotion = {
      for (final v in before)
        if (v.config[_viewKey] case final String nid) nid: v,
    };
    // The default table of a new database, or of one imported before
    // views came over, gives way to Notion's views.
    final placeholder =
        _newDatabases.contains(dbId) ||
        (before.length == 1 &&
            before.single.type == ViewType.table &&
            before.single.config.isEmpty);
    var added = 0;
    try {
      final list = await api.all(
        'GET',
        '/views?database_id=$notionDb',
        null,
        NotionApi.viewsVersion,
      );
      for (final item in list) {
        final v = await api.call(
          'GET',
          '/views/${item['id']}',
          null,
          NotionApi.viewsVersion,
        );
        final type = v['type'] as String? ?? '';
        if (!ViewType.all.contains(type)) continue; // form, chart, dashboard
        final conf = (v['configuration'] as Map?) ?? const {};
        final config = <String, dynamic>{};
        switch (type) {
          case ViewType.board:
            final by = conf['group_by'] as Map?;
            final group =
                by?['type'] == 'title' || by?['property_id'] == 'title'
                ? titleGroupKey
                : prop(by?['property_id']);
            if (group == null) continue; // grouped by something we lack
            config['groupBy'] = group;
          case ViewType.map:
            final place =
                prop(conf['map_by']) ?? prop(conf['map_by_property_name']);
            if (place != null) config['placeBy'] = place;
          case ViewType.calendar || ViewType.timeline:
            final date = prop(conf['date_property_id']);
            if (date == null) continue;
            config['dateBy'] = date;
            if (type == ViewType.timeline) {
              final end = prop(conf['end_date_property_id']) ?? endOf[date];
              if (end != null) config['endBy'] = end;
            }
        }
        final shown = <String>[];
        final hidden = <String>[];
        for (final entry in (conf['properties'] as List? ?? const [])) {
          final id = prop((entry as Map)['property_id']);
          if (id == null) continue;
          (entry['visible'] == false ? hidden : shown).add(id);
        }
        if (type == ViewType.table || type == ViewType.list) {
          if (hidden.isNotEmpty) config['hidden'] = hidden;
          // Notion's footer sums aren't in the API: total money columns.
          final money = [
            for (final c in columns.values)
              if (_currencyColumns.contains(c.id)) c.id,
          ];
          if (type == ViewType.table && money.isNotEmpty) {
            config['calcs'] = {for (final id in money) id: Calc.sum};
          }
        } else if (shown.isNotEmpty) {
          config['cardProps'] = shown;
        }
        final sort = (v['sorts'] as List?)?.firstOrNull;
        if (sort is Map) {
          final by = prop(sort['property']) ?? prop(sort['property_id']);
          if (by != null) {
            config['sortBy'] = by;
            config['sortDesc'] = sort['direction'] == 'descending';
          }
        }
        // Notion's placeholder names read better as the view type.
        final name = switch (v['name']) {
          final String n
              when n.trim().isNotEmpty &&
                  n != 'Untitled' &&
                  n != 'Default view' =>
            n,
          _ => ViewType.label(type),
        };
        final viewId = '${item['id']}';
        config[_viewKey] = viewId;
        final mine = fromNotion[viewId];
        if (mine != null && mine.type == type) {
          // Totals aren't in Notion's API: keep the ones chosen here.
          if (mine.config['calcs'] case final Object calcs) {
            config['calcs'] = calcs;
          }
          await repo.updateView(mine.id, name: name, config: config);
        } else {
          if (mine != null) await repo.deleteView(mine.id);
          await repo.addView(dbId, type, name: name, config: config);
          added++;
        }
      }
    } catch (_) {
      // Views API not available (or failed part way): keep what came over,
      // guess only when nothing did.
    }
    if (!placeholder) {
      report.views += added;
      return;
    }
    if (added == 0) {
      final select = columns.values
          .where((c) => c.type == PropType.select)
          .firstOrNull;
      final date = columns.values
          .where((c) => c.type == PropType.date)
          .firstOrNull;
      if (select != null) {
        await repo.addView(
          dbId,
          ViewType.board,
          config: {'groupBy': select.id},
        );
        added++;
      }
      if (date != null) {
        await repo.addView(
          dbId,
          ViewType.calendar,
          config: {'dateBy': date.id},
        );
        added++;
      }
      // Keep the default table view next to the guessed ones.
      report.views += added;
      return;
    }
    report.views += added;
    // Notion's own views replace the default table view.
    for (final v in before) {
      await repo.deleteView(v.id);
    }
  }

  /// View config key holding the Notion view id.
  static const _viewKey = 'notionView';

  /// Column type for a formula/rollup from what its rows hold.
  static String _resultType(String name, List<Map<String, dynamic>> rows) {
    final kinds = <String>{};
    for (final r in rows) {
      final p = (r['properties'] as Map?)?[name];
      if (p is! Map) continue;
      final v = p[p['type']];
      if (v is! Map) continue;
      final kind = v['type'] as String?;
      final inner = v[kind];
      if (kind == null || inner == null) continue; // empty result
      kinds.add(kind);
    }
    if (kinds.length != 1) return PropType.text;
    return switch (kinds.single) {
      'date' => PropType.date,
      'number' => PropType.number,
      'boolean' => PropType.checkbox,
      _ => PropType.text,
    };
  }

  Object? _cell(
    Map<String, dynamic> p,
    String type,
    Map<String, String> options,
  ) {
    final t = p['type'] as String;
    var v = p[t];
    // Formula / rollup: use the result as the value itself.
    if ((t == 'formula' || t == 'rollup') && v is Map) {
      final kind = v['type'];
      if (kind == 'date' || kind == 'number' || kind == 'boolean') {
        v = kind == 'date' ? v['date'] : v[kind];
        if (type == PropType.date) return (v as Map?)?['start'];
        if (type == PropType.number) return v is num ? v : null;
        if (type == PropType.checkbox) return v == true;
        v = p[t];
      }
    }
    if (type == PropType.place) {
      if (v is! Map || v['lat'] == null || v['lon'] == null) return null;
      final placeName = v['name'] as String?;
      return {
        'address': (v['address'] as String?) ?? placeName ?? '',
        'lat': (v['lat'] as num).toDouble(),
        'lng': (v['lon'] as num).toDouble(),
        if (placeName != null && placeName.isNotEmpty) 'name': placeName,
      };
    }
    String text() => switch (t) {
      'rich_text' => _plain(v as List?),
      'email' || 'phone_number' || 'url' => '${v ?? ''}',
      'formula' => switch ((v as Map?)?['type']) {
        'string' => '${v!['string'] ?? ''}',
        'number' => '${v!['number'] ?? ''}',
        'boolean' => v!['boolean'] == true ? '예' : '아니오',
        'date' => '${(v!['date'] as Map?)?['start'] ?? ''}',
        _ => '',
      },
      'relation' => [
        for (final r in (v as List? ?? const []))
          _titles[norm((r as Map)['id'] as String)] ?? '',
      ].where((s) => s.isNotEmpty).join(', '),
      'people' => [
        for (final u in (v as List? ?? const [])) (u as Map)['name'] ?? '',
      ].join(', '),
      'created_by' || 'last_edited_by' => '${(v as Map?)?['name'] ?? ''}',
      'files' => [
        for (final f in (v as List? ?? const [])) (f as Map)['name'] ?? '',
      ].join(', '),
      'unique_id' =>
        '${(v as Map?)?['prefix'] ?? ''}${v?['prefix'] == null ? '' : '-'}${v?['number'] ?? ''}',
      'rollup' => _rollup(v as Map?),
      _ => '',
    };
    final Object? value = switch (type) {
      PropType.number => (v is num) ? v : null,
      PropType.checkbox => v == true,
      PropType.date => switch (t) {
        'date' => (v as Map?)?['start'],
        _ => v is String ? v : null, // created_time / last_edited_time
      },
      PropType.select => v is Map ? options[v['name']] : null,
      PropType.multiSelect => [
        for (final o in (v as List? ?? const []))
          if (options[(o as Map)['name']] case final String id) id,
      ],
      PropType.url => v as String?,
      _ => text(),
    };
    if (value is String && value.isEmpty) return null;
    if (value is List && value.isEmpty) return null;
    return value;
  }

  String _rollup(Map? v) {
    if (v == null) return '';
    return switch (v['type']) {
      'number' => '${v['number'] ?? ''}',
      'date' => '${(v['date'] as Map?)?['start'] ?? ''}',
      'array' =>
        (v['array'] as List).map((x) => _cellLike(x as Map)).join(', '),
      _ => '',
    };
  }

  String _cellLike(Map x) => switch (x['type']) {
    'title' || 'rich_text' => _plain(x[x['type']] as List?),
    'number' => '${x['number'] ?? ''}',
    _ => '',
  };

  // -------------------------------------------------------------- content

  Future<void> _content(String notionId, String pageId) async {
    final nodes = await _blocks(notionId, pageId);
    final doc = await repo.openDocument(pageId);
    doc.document.delete([0], doc.document.root.children.length);
    doc.document.insert([0], nodes.isEmpty ? [paragraphNode()] : nodes);
    await doc.save();
  }

  Future<List<Node>> _blocks(String blockId, String pageId) async {
    final blocks = await api.all('GET', '/blocks/$blockId/children');
    final out = <Node>[];
    for (final b in blocks) {
      if (_cancelled) break;
      out.addAll(await _block(b, pageId));
    }
    return out;
  }

  Future<List<Node>> _block(Map<String, dynamic> b, String pageId) async {
    final type = b['type'] as String;
    final data = (b[type] as Map?)?.cast<String, dynamic>() ?? const {};
    final rich = data['rich_text'] as List?;
    Delta delta() => _delta(rich);
    Future<List<Node>> kids() async => b['has_children'] == true
        ? _blocks(b['id'] as String, pageId)
        : const [];

    switch (type) {
      case 'paragraph':
        return [paragraphNode(delta: delta(), children: await kids())];
      case 'heading_1' || 'heading_2' || 'heading_3':
        return [
          headingNode(level: int.parse(type.substring(8)), delta: delta()),
          ...await kids(), // toggle headings
        ];
      case 'bulleted_list_item':
        return [bulletedListNode(delta: delta(), children: await kids())];
      case 'toggle':
        // Folded, like it shows in Notion.
        return [
          toggleNode(delta: delta(), collapsed: true, children: await kids()),
        ];
      case 'numbered_list_item':
        return [numberedListNode(delta: delta(), children: await kids())];
      case 'to_do':
        return [
          todoListNode(
            checked: data['checked'] == true,
            delta: delta(),
            children: await kids(),
          ),
        ];
      case 'quote':
        return [quoteNode(delta: delta(), children: await kids())];
      case 'callout':
        final icon = data['icon'];
        return [
          calloutNode(
            delta: delta(),
            icon: icon is Map && icon['type'] == 'emoji'
                ? icon['emoji'] as String
                : '💡',
          ),
          ...await kids(),
        ];
      case 'code':
        final lang = (data['language'] as String? ?? '').replaceAll(
          'plain text',
          '',
        );
        return [
          codeNode(text: _plain(rich), language: lang == 'c++' ? 'cpp' : lang),
        ];
      case 'equation':
        return [
          Node(
            type: MathBlockKeys.type,
            attributes: {MathBlockKeys.formula: data['expression'] ?? ''},
          ),
        ];
      case 'divider':
        return [dividerNode()];
      case 'image' || 'file' || 'pdf' || 'video' || 'audio':
        return [await _file(type, data, pageId)];
      case 'bookmark' || 'embed' || 'link_preview':
        final url = data['url'] as String? ?? '';
        final caption = _plain(data['caption'] as List?);
        return [
          paragraphNode(
            delta: Delta()
              ..insert(
                caption.isEmpty ? url : caption,
                attributes: {'href': url},
              ),
          ),
        ];
      case 'table':
        return [await _table(b, pageId)];
      case 'column_list' || 'column' || 'synced_block':
        return kids();
      case 'child_page':
        return [_linkLine(norm(b['id'] as String), data['title'] as String?)];
      case 'child_database':
        final db = _ours[norm(b['id'] as String)];
        return db == null
            ? [paragraphNode(text: data['title'] as String? ?? '')]
            : [
                Node(type: 'database', attributes: {'databaseId': db}),
              ];
      case 'link_to_page':
        final target = data['page_id'] ?? data['database_id'];
        return target is String ? [_linkLine(norm(target), null)] : const [];
      case 'table_of_contents' || 'breadcrumb':
        return const [];
      default:
        report.skippedBlocks++;
        return const [];
    }
  }

  Node _linkLine(String notionId, String? title) {
    final ours = _ours[notionId];
    final name = title ?? _titles[notionId] ?? '';
    if (ours == null) return paragraphNode(text: name);
    return paragraphNode(
      delta: Delta()
        ..insert(
          pageLinkChar,
          attributes: {pageLinkKey: ours, pageLinkTitleKey: name},
        ),
    );
  }

  Future<Node> _table(Map<String, dynamic> b, String pageId) async {
    final rows = await api.all('GET', '/blocks/${b['id']}/children');
    final cells = [
      for (final r in rows)
        [
          for (final c in ((r['table_row'] as Map)['cells'] as List))
            _delta(c as List),
        ],
    ];
    if (cells.isEmpty || cells.first.isEmpty) return paragraphNode();
    final width = cells.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final cols = [
      for (var c = 0; c < width; c++)
        [
          for (final r in cells)
            paragraphNode(delta: c < r.length ? r[c] : Delta()),
        ],
    ];
    return TableNode.fromList<Node>(cols).node;
  }

  Future<Node> _file(
    String type,
    Map<String, dynamic> data,
    String pageId,
  ) async {
    final hosted = data['type'] == 'file';
    final url = (data[data['type']] as Map?)?['url'] as String? ?? '';
    final caption = _plain(data['caption'] as List?);
    if (!hosted) {
      return type == 'image'
          ? imageNode(url: url)
          : paragraphNode(
              delta: Delta()
                ..insert(
                  caption.isEmpty ? url : caption,
                  attributes: {'href': url},
                ),
            );
    }
    try {
      final bytes = await api.download(url);
      var name = Uri.decodeComponent(
        Uri.parse(url).pathSegments.lastOrNull ?? 'file',
      );
      if (data['name'] is String && (data['name'] as String).isNotEmpty) {
        name = data['name'] as String;
      }
      final asset = await repo.importAssetBytes(bytes, name, pageId: pageId);
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
    } catch (_) {
      report.failedAttachments++;
      return paragraphNode(
        text: '(첨부를 받지 못함: ${caption.isEmpty ? type : caption})',
      );
    }
  }

  Delta _delta(List? rich) {
    final d = Delta();
    for (final r in (rich ?? const []).cast<Map>()) {
      final ann = (r['annotations'] as Map?) ?? const {};
      final attrs = <String, Object>{
        if (ann['bold'] == true) 'bold': true,
        if (ann['italic'] == true) 'italic': true,
        if (ann['strikethrough'] == true) 'strikethrough': true,
        if (ann['underline'] == true) 'underline': true,
        if (ann['code'] == true) 'code': true,
      };
      final text = r['plain_text'] as String? ?? '';
      switch (r['type']) {
        case 'equation':
          d.insert(
            r'$',
            attributes: {
              ...attrs,
              'formula': (r['equation'] as Map)['expression'],
            },
          );
        case 'mention':
          final m = r['mention'] as Map;
          final target = m['page']?['id'] ?? m['database']?['id'];
          final ours = target is String ? _ours[norm(target)] : null;
          if (ours != null) {
            d.insert(
              pageLinkChar,
              attributes: {pageLinkKey: ours, pageLinkTitleKey: text},
            );
          } else {
            d.insert(text, attributes: attrs.isEmpty ? null : attrs);
          }
        default:
          final href = (r['text'] as Map?)?['link']?['url'] ?? r['href'];
          d.insert(
            text,
            attributes: {...attrs, 'href': ?href}.isEmpty
                ? null
                : {...attrs, 'href': ?href},
          );
      }
    }
    return d;
  }
}
