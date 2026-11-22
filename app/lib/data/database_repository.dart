import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import 'clock.dart';
import 'database.dart';
import 'formula.dart';
import 'fractional_index.dart';
import 'notes_repository.dart';

/// Notion-style databases: a page of kind 'database' whose children
/// (kind 'row') are the entries. Columns are [DbProperties]; cell values
/// live in [Properties] (page_id = row, key = property id, value = JSON).

/// Column types.
abstract final class PropType {
  static const text = 'text';
  static const number = 'number';
  static const select = 'select';
  static const multiSelect = 'multi_select';
  static const date = 'date';
  static const checkbox = 'checkbox';
  static const url = 'url';
  static const formula = 'formula';
  static const place = 'place';

  static const all = [
    text,
    number,
    select,
    multiSelect,
    date,
    checkbox,
    url,
    formula,
    place,
  ];

  static String label(String type) => switch (type) {
    text => '텍스트',
    number => '숫자',
    select => '선택',
    multiSelect => '다중 선택',
    date => '날짜',
    checkbox => '체크박스',
    url => 'URL',
    formula => '수식',
    place => '장소',
    _ => type,
  };
}

/// View types.
abstract final class ViewType {
  static const table = 'table';
  static const board = 'board';
  static const list = 'list';
  static const calendar = 'calendar';
  static const gallery = 'gallery';
  static const timeline = 'timeline';
  static const map = 'map';

  static const all = [table, board, list, calendar, gallery, timeline, map];

  static String label(String type) => switch (type) {
    table => '표',
    board => '보드',
    list => '리스트',
    calendar => '캘린더',
    gallery => '갤러리',
    timeline => '타임라인',
    map => '지도',
    _ => type,
  };
}

/// Board `groupBy` value meaning "the title column" (it has no property
/// row): one column per distinct title.
const titleGroupKey = '__title__';

/// Notion's tag colors.
const selectColors = [
  'gray',
  'brown',
  'orange',
  'yellow',
  'green',
  'blue',
  'purple',
  'pink',
  'red',
];

class SelectOption {
  const SelectOption(this.id, this.name, this.color);

  factory SelectOption.fromJson(Map<String, dynamic> j) => SelectOption(
    j['id'] as String,
    j['name'] as String? ?? '',
    j['color'] as String? ?? 'gray',
  );

  final String id;
  final String name;
  final String color;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'color': color};
}

class DbProperty {
  DbProperty(this.row)
    : config = jsonDecode(row.config) as Map<String, dynamic>? ?? {};

  final DbPropertyRow row;
  final Map<String, dynamic> config;

  String get id => row.id;
  String get name => row.name;
  String get type => row.type;

  List<SelectOption> get options => [
    for (final o in (config['options'] as List? ?? const []))
      SelectOption.fromJson(Map<String, dynamic>.from(o as Map)),
  ];

  SelectOption? option(String? id) {
    for (final o in options) {
      if (o.id == id) return o;
    }
    return null;
  }
}

class DbView {
  DbView(this.row)
    : config = jsonDecode(row.config) as Map<String, dynamic>? ?? {};

  final DbViewRow row;
  final Map<String, dynamic> config;

  String get id => row.id;
  String get name => row.name;
  String get type => row.type;

  /// Board: the select property whose options are the columns.
  String? get groupBy => config['groupBy'] as String?;

  /// Calendar / timeline: the date property that places rows on days.
  String? get dateBy => config['dateBy'] as String?;

  /// Calendar / board / gallery: properties shown on each card, in order.
  List<String> get cardProps => [
    ...?(config['cardProps'] as List?)?.cast<String>(),
  ];

  /// Map: the 장소 property whose coordinates place the pins.
  String? get placeBy => config['placeBy'] as String?;

  /// Timeline: optional end date property (bars span start..end).
  String? get endBy => config['endBy'] as String?;

  /// Sort: property id ('title' for the title) and direction.
  String? get sortBy => config['sortBy'] as String?;
  bool get sortDesc => config['sortDesc'] == true;

  Set<String> get hidden => {...?(config['hidden'] as List?)?.cast<String>()};

  /// Table footer calculations: property id ([titleGroupKey] for the
  /// name column) → [Calc] name.
  Map<String, String> get calcs => {
    ...?(config['calcs'] as Map?)?.cast<String, String>(),
  };

  /// Filters, all of which must match: `{prop, op, value}`.
  List<Map<String, dynamic>> get filters => [
    for (final f in (config['filters'] as List? ?? const []))
      Map<String, dynamic>.from(f as Map),
  ];
}

/// Everything a database view needs, loaded together.
class DbSnapshot {
  DbSnapshot({
    required this.database,
    required this.properties,
    required this.views,
    required this.rows,
    required this.cells,
    this.covers = const {},
    this.external,
  });

  /// Answers `lookup(...)` in this database's formulas (other databases).
  final ExternalLookup? external;

  final PageRow database;
  final List<DbProperty> properties;
  final List<DbView> views;
  final List<PageRow> rows;

  /// rowId -> propertyId -> decoded JSON value.
  final Map<String, Map<String, Object?>> cells;

  /// rowId -> url of the first image in the row's page (gallery cover).
  final Map<String, String> covers;

  /// Stored value of a cell (formulas have none; see [value]).
  Object? cell(String rowId, String propId) => cells[rowId]?[propId];

  DbProperty? property(String id) {
    for (final p in properties) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// What a cell shows: the stored value, or the computed formula result.
  Object? value(String rowId, DbProperty prop, [int depth = 0]) {
    if (prop.type != PropType.formula) return cell(rowId, prop.id);
    if (depth > 5) return const FormulaError('수식이 서로를 참조해요');
    return evaluate(
      rowId,
      prop.config['expression'] as String? ?? '',
      depth: depth,
      external: external,
    );
  }

  /// [expression] worked out for one row (`prop("…")` reads its cells).
  Object? evaluate(
    String rowId,
    String expression, {
    int depth = 0,
    ExternalLookup? external,
  }) {
    final row = rows.where((r) => r.id == rowId).firstOrNull;
    return evaluateFormula(expression, (name) {
      if (name == '이름' && properties.every((p) => p.name != name)) {
        return row?.title;
      }
      final p = properties.where((p) => p.name == name).firstOrNull;
      if (p == null) return null;
      return formulaInput(p, value(rowId, p, depth + 1));
    }, external: external);
  }

  /// A cell as a formula sees it: numbers as numbers, checkboxes as
  /// true/false, dates and the rest as text.
  static Object? formulaInput(DbProperty p, Object? v) => switch (p.type) {
    PropType.number => v is num ? v.toDouble() : null,
    PropType.checkbox => v == true,
    PropType.formula => v,
    _ => v == null ? null : cellText(p, v),
  };

  /// Plain text of a cell (sorting, search).
  String text(String rowId, DbProperty prop) {
    final v = value(rowId, prop);
    return prop.type == PropType.formula
        ? formatFormulaValue(v)
        : cellText(prop, v);
  }
}

/// An id made from [seed] (same seed → same id on every device), shaped
/// like the app's other ids.
String stableId(String seed) {
  final h = sha256.convert(utf8.encode(seed)).toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20, 32)}';
}

/// The formula that fills [p] by itself (its `auto` setting), if any. Only
/// plain types have one: the result is stored like a typed-in value, so a
/// date filled this way is a real date (sorting, calendar, filters).
String? autoExpression(DbProperty p) {
  if (p.type == PropType.formula) return null;
  final e = (p.config['auto'] as String?)?.trim();
  return e == null || e.isEmpty ? null : e;
}

/// A formula result as the stored value of [p] (null when it doesn't fit).
Object? autoValue(DbProperty p, Object? result) {
  if (result == null || result is FormulaError) return null;
  final text = formatFormulaValue(result).trim();
  return switch (p.type) {
    PropType.date => RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(text)?[0],
    PropType.number => result is num ? result : num.tryParse(text),
    PropType.checkbox => result == true,
    PropType.select => p.options.where((o) => o.name == text).firstOrNull?.id,
    PropType.multiSelect => [
      for (final part in text.split(','))
        ?p.options.where((o) => o.name == part.trim()).firstOrNull?.id,
    ],
    PropType.place => null,
    _ => text.isEmpty ? null : text,
  };
}

/// Columns that can place rows on a calendar / timeline: date columns and
/// formulas (which may compute a date, e.g. `dateAdd(prop("출발"), 3)`).
bool isDateSource(DbProperty p) =>
    p.type == PropType.date || p.type == PropType.formula;

/// The row's day for [prop] as `yyyy-MM-dd`, or null if it isn't a date.
String? dayOf(DbSnapshot snap, String rowId, DbProperty prop) {
  final v = snap.value(rowId, prop);
  if (v is! String || v.length < 10) return null;
  final day = v.substring(0, 10);
  return DateTime.tryParse(day) == null ? null : day;
}

/// Plain-text form of a stored cell value.
/// Number display formats (Notion's names), kept in a number property's
/// config as `format`.
const _currency = {
  'won': '₩',
  'yen': '¥',
  'dollar': r'$',
  'euro': '€',
  'pound': '£',
  'yuan': 'CN¥',
};

bool isCurrencyFormat(String? format) => _currency.containsKey(format);

/// "1234567.5" → "1,234,567.5" (and the currency sign when [format] has
/// one, e.g. won → "₩1,234,568").
String formatNumber(num n, {String? format}) {
  final sign = _currency[format];
  final digits = sign != null && (format == 'won' || format == 'yen') ? 0 : 2;
  final fixed = n == n.roundToDouble() && sign == null
      ? n.toStringAsFixed(0)
      : n.toStringAsFixed(digits);
  final parts = fixed.replaceFirst('-', '').split('.');
  final grouped = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  var frac = parts.length > 1 ? parts[1].replaceFirst(RegExp(r'0+$'), '') : '';
  if (sign != null && digits == 2 && frac.isNotEmpty) {
    frac = frac.padRight(2, '0');
  }
  final body = frac.isEmpty ? grouped : '$grouped.$frac';
  if (format == 'percent') return '${n < 0 ? '-' : ''}$body%';
  return '${n < 0 ? '-' : ''}${sign ?? ''}$body';
}

/// Column calculations at the bottom of a table (Notion's "계산").
abstract final class Calc {
  static const count = 'count';
  static const filled = 'filled';
  static const empty = 'empty';
  static const unique = 'unique';
  static const sum = 'sum';
  static const average = 'average';
  static const min = 'min';
  static const max = 'max';
  static const checked = 'checked';
  static const unchecked = 'unchecked';
  static const earliest = 'earliest';
  static const latest = 'latest';

  static String label(String calc) => switch (calc) {
    count => '모두 세기',
    filled => '값 있음',
    empty => '비어 있음',
    unique => '고유 값',
    sum => '합계',
    average => '평균',
    min => '최소',
    max => '최대',
    checked => '체크됨',
    unchecked => '체크 안 됨',
    earliest => '가장 이른 날짜',
    latest => '가장 늦은 날짜',
    _ => calc,
  };

  /// Calculations that make sense for a column type ('title' for names).
  static List<String> forType(String type) => [
    count,
    filled,
    empty,
    if (type != PropType.checkbox) unique,
    if (type == PropType.number) ...[sum, average, min, max],
    if (type == PropType.checkbox) ...[checked, unchecked],
    if (type == PropType.date) ...[earliest, latest],
  ];
}

/// The result shown under a column, or null when there is nothing to show.
/// [prop] null means the title column.
String? computeCalc(
  String calc,
  DbSnapshot snap,
  List<PageRow> rows,
  DbProperty? prop,
) {
  Object? valueOf(PageRow r) => prop == null ? r.title : snap.value(r.id, prop);
  bool isEmpty(Object? v) =>
      v == null ||
      (v is String && v.trim().isEmpty) ||
      (v is List && v.isEmpty);
  final values = [for (final r in rows) valueOf(r)];
  final nums = [
    for (final v in values)
      if (v is num) v,
  ];
  final dates = [
    for (final v in values)
      if (v is String &&
          v.length >= 10 &&
          DateTime.tryParse(v.substring(0, 10)) != null)
        v.substring(0, 10),
  ]..sort();
  final format = prop?.config['format'] as String?;
  String n(num x) => formatNumber(x, format: format);
  return switch (calc) {
    Calc.count => '${values.length}',
    Calc.filled => '${values.where((v) => !isEmpty(v)).length}',
    Calc.empty => '${values.where(isEmpty).length}',
    Calc.unique =>
      '${{for (final v in values)
        if (!isEmpty(v)) v is List ? (v.map((e) => '$e').toList()..sort()).join(',') : '$v'}.length}',
    Calc.sum => n(nums.fold<num>(0, (a, b) => a + b)),
    Calc.average =>
      nums.isEmpty ? null : n(nums.fold<num>(0, (a, b) => a + b) / nums.length),
    Calc.min => nums.isEmpty ? null : n(nums.reduce((a, b) => a < b ? a : b)),
    Calc.max => nums.isEmpty ? null : n(nums.reduce((a, b) => a > b ? a : b)),
    Calc.checked => '${values.where((v) => v == true).length}',
    Calc.unchecked => '${values.where((v) => v != true).length}',
    Calc.earliest => dates.firstOrNull,
    Calc.latest => dates.lastOrNull,
    _ => null,
  };
}

String cellText(DbProperty prop, Object? value) {
  if (value == null) return '';
  return switch (prop.type) {
    PropType.number when value is num => formatNumber(
      value,
      format: prop.config['format'] as String?,
    ),
    PropType.select => prop.option(value as String?)?.name ?? '',
    PropType.multiSelect => [
      for (final id in (value as List).cast<String>()) prop.option(id)?.name,
    ].whereType<String>().join(', '),
    PropType.checkbox => value == true ? '1' : '0',
    PropType.place =>
      value is Map ? '${value['name'] ?? value['address'] ?? ''}' : '',
    _ => '$value',
  };
}

extension DatabaseRepository on NotesRepository {
  Clock get _clockRef => clock;

  /// Creates a database page with a default "태그" column and a table view.
  Future<String> createDatabase({String? parentId, String title = ''}) async {
    final id = await createPage(
      parentId: parentId,
      title: title,
      kind: 'database',
    );
    await addProperty(id, '태그', PropType.multiSelect);
    await addView(id, ViewType.table);
    return id;
  }

  Stream<DbSnapshot?> watchDatabase(String databaseId) {
    final updates = db.tableUpdates(
      TableUpdateQuery.onAllTables([
        db.pages,
        db.properties,
        db.dbProperties,
        db.dbViews,
      ]),
    );
    late StreamController<DbSnapshot?> controller;
    StreamSubscription<void>? sub;
    var loading = false, again = false;
    Future<void> load() async {
      if (loading) {
        again = true;
        return;
      }
      loading = true;
      do {
        again = false;
        final snap = await loadDatabase(databaseId);
        if (!controller.isClosed) controller.add(snap);
      } while (again);
      loading = false;
    }

    controller = StreamController<DbSnapshot?>(
      onListen: () {
        load();
        sub = updates.listen((_) => load());
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  /// [withLookups]: also load the databases its formulas read with
  /// `lookup(...)`, so those formulas work (one level: a looked-up
  /// database's own lookups are not followed).
  Future<DbSnapshot?> loadDatabase(
    String databaseId, {
    bool withLookups = true,
  }) async {
    final database = await getPage(databaseId);
    if (database == null || database.deleted) return null;
    final props =
        await (db.select(db.dbProperties)
              ..where(
                (p) =>
                    p.databaseId.equals(databaseId) & p.deleted.equals(false),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    final views =
        await (db.select(db.dbViews)
              ..where(
                (v) =>
                    v.databaseId.equals(databaseId) & v.deleted.equals(false),
              )
              ..orderBy([(v) => OrderingTerm.asc(v.sortKey)]))
            .get();
    final rows =
        await (db.select(db.pages)
              ..where(
                (p) =>
                    p.parentId.equals(databaseId) &
                    p.kind.equals('row') &
                    p.deleted.equals(false) &
                    p.trashedAt.isNull(),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    final rowIds = [for (final r in rows) r.id];
    final cells = <String, Map<String, Object?>>{};
    if (rowIds.isNotEmpty) {
      final values = await (db.select(
        db.properties,
      )..where((p) => p.pageId.isIn(rowIds) & p.deleted.equals(false))).get();
      for (final v in values) {
        cells.putIfAbsent(v.pageId, () => {})[v.key] = jsonDecode(v.value);
      }
    }
    final covers = <String, String>{};
    if (rowIds.isNotEmpty) {
      final images =
          await (db.select(db.blocks)
                ..where(
                  (b) =>
                      b.pageId.isIn(rowIds) &
                      b.type.equals('image') &
                      b.deleted.equals(false),
                )
                ..orderBy([(b) => OrderingTerm.asc(b.sortKey)]))
              .get();
      for (final b in images) {
        final url = (jsonDecode(b.data) as Map)['url'];
        if (url is String && url.isNotEmpty) {
          covers.putIfAbsent(b.pageId, () => url);
        }
      }
    }
    final properties = [for (final p in props) DbProperty(p)];
    final lookedUp = withLookups
        ? {
            for (final p in properties)
              if (p.type == PropType.formula)
                ...lookedUpDatabases(p.config['expression'] as String? ?? ''),
          }
        : const <String>{};
    return DbSnapshot(
      database: database,
      properties: properties,
      views: [for (final v in views) DbView(v)],
      rows: rows,
      cells: cells,
      covers: covers,
      external: lookedUp.isEmpty
          ? null
          : await externalLookup(lookedUp, near: databaseId),
    );
  }

  // ---- columns ----

  Future<String> addProperty(
    String databaseId,
    String name,
    String type,
  ) async {
    final last =
        await (db.select(db.dbProperties)
              ..where((p) => p.databaseId.equals(databaseId))
              ..orderBy([(p) => OrderingTerm.desc(p.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    final id = newId();
    await db
        .into(db.dbProperties)
        .insert(
          DbPropertiesCompanion.insert(
            id: id,
            databaseId: databaseId,
            name: name,
            type: type,
            sortKey: keyBetween(last?.sortKey, null),
            updatedAt: _clockRef.tick(),
            deviceId: deviceId,
          ),
        );
    return id;
  }

  Future<void> updateProperty(
    String id, {
    String? name,
    String? type,
    Map<String, dynamic>? config,
  }) {
    return (db.update(db.dbProperties)..where((p) => p.id.equals(id))).write(
      DbPropertiesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        type: type == null ? const Value.absent() : Value(type),
        config: config == null
            ? const Value.absent()
            : Value(jsonEncode(config)),
        updatedAt: Value(_clockRef.tick()),
        deviceId: Value(deviceId),
        dirty: const Value(true),
      ),
    );
  }

  Future<void> deleteProperty(String id) {
    return (db.update(db.dbProperties)..where((p) => p.id.equals(id))).write(
      DbPropertiesCompanion(
        deleted: const Value(true),
        updatedAt: Value(_clockRef.tick()),
        deviceId: Value(deviceId),
        dirty: const Value(true),
      ),
    );
  }

  /// Adds a select option named [name] to [prop] and returns it.
  Future<SelectOption> addSelectOption(DbProperty prop, String name) async {
    final used = {for (final o in prop.options) o.color};
    final color = selectColors.firstWhere(
      (c) => !used.contains(c),
      orElse: () => selectColors[prop.options.length % selectColors.length],
    );
    final option = SelectOption(newId(), name, color);
    await updateProperty(
      prop.id,
      config: {
        ...prop.config,
        'options': [...prop.options.map((o) => o.toJson()), option.toJson()],
      },
    );
    return option;
  }

  // ---- rows & cells ----

  Future<String> addRow(
    String databaseId, {
    String title = '',
    Map<String, Object?> values = const {},
  }) async {
    final id = await createPage(
      parentId: databaseId,
      title: title,
      kind: 'row',
    );
    for (final e in values.entries) {
      await setCell(id, e.key, e.value);
    }
    return id;
  }

  /// Sets (or clears, when [value] is null) one cell.
  Future<void> setCell(String rowId, String propId, Object? value) async {
    final now = _clockRef.tick();
    await db
        .into(db.properties)
        .insertOnConflictUpdate(
          PropertiesCompanion.insert(
            pageId: rowId,
            key: propId,
            value: jsonEncode(value),
            updatedAt: now,
            deviceId: deviceId,
            deleted: Value(value == null),
            dirty: const Value(true),
          ),
        );
    // Rows show their own "last edited". Not marked dirty: the page row
    // itself did not change, and pushing it would let this cell edit
    // overwrite a rename made on another device (sync is per row).
    await (db.update(db.pages)..where((p) => p.id.equals(rowId))).write(
      PagesCompanion(updatedAt: Value(now)),
    );
  }

  // ---- copying a database's columns and views ----

  /// Copies the columns and views of database [from] to database [to] and
  /// returns old column id → new column id (for the rows' values). Views
  /// keep pointing at the right columns. [idFor] gives the new ids (stable
  /// ones when every device must come to the same result).
  Future<Map<String, String>> copyDatabaseSchema(
    String from,
    String to, {
    String Function(String oldId)? idFor,
  }) async {
    final props =
        await (db.select(db.dbProperties)
              ..where(
                (p) => p.databaseId.equals(from) & p.deleted.equals(false),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    final views =
        await (db.select(db.dbViews)
              ..where(
                (v) => v.databaseId.equals(from) & v.deleted.equals(false),
              )
              ..orderBy([(v) => OrderingTerm.asc(v.sortKey)]))
            .get();
    final map = {for (final p in props) p.id: idFor?.call(p.id) ?? newId()};
    String remap(String config) {
      for (final e in map.entries) {
        config = config.replaceAll(e.key, e.value);
      }
      return config;
    }

    final now = _clockRef.tick();
    await db.transaction(() async {
      for (final p in props) {
        await db
            .into(db.dbProperties)
            .insertOnConflictUpdate(
              p.copyWith(
                id: map[p.id],
                databaseId: to,
                updatedAt: now,
                deviceId: deviceId,
                dirty: true,
              ),
            );
      }
      for (final v in views) {
        await db
            .into(db.dbViews)
            .insertOnConflictUpdate(
              v.copyWith(
                id: idFor?.call(v.id) ?? newId(),
                databaseId: to,
                config: remap(v.config),
                updatedAt: now,
                deviceId: deviceId,
                dirty: true,
              ),
            );
      }
    });
    return map;
  }

  /// Databases copied before copying took their columns along (e.g. a page
  /// duplicated to make a 여행 템플릿) have items but no columns or views,
  /// and the copied page's table blocks still show the original database.
  /// This gives each such copy the columns and views of the database its
  /// items came from, and points the copied page's blocks at the copy.
  /// New ids are derived from the old ones, so every device that runs this
  /// ends up with the same rows. Returns how many databases were repaired.
  Future<int> repairCopiedDatabases() async {
    final databases = await (db.select(
      db.pages,
    )..where((p) => p.kind.equals('database') & p.deleted.equals(false))).get();
    var repaired = 0;
    for (final copy in databases) {
      final hasColumns =
          await (db.select(db.dbProperties)
                ..where(
                  (p) => p.databaseId.equals(copy.id) & p.deleted.equals(false),
                )
                ..limit(1))
              .getSingleOrNull();
      if (hasColumns != null) continue;
      final rows =
          await (db.select(db.pages)..where(
                (p) =>
                    p.parentId.equals(copy.id) &
                    p.kind.equals('row') &
                    p.deleted.equals(false),
              ))
              .get();
      if (rows.isEmpty) continue;
      final values =
          await (db.select(db.properties)..where(
                (p) =>
                    p.pageId.isIn([for (final r in rows) r.id]) &
                    p.deleted.equals(false),
              ))
              .get();
      final keys = {
        for (final v in values)
          if (!v.key.startsWith('_')) v.key,
      };
      if (keys.isEmpty) continue;
      final owners = await (db.select(
        db.dbProperties,
      )..where((p) => p.id.isIn(keys))).get();
      final counts = <String, int>{};
      for (final o in owners) {
        counts[o.databaseId] = (counts[o.databaseId] ?? 0) + 1;
      }
      if (counts.isEmpty) continue;
      final source =
          (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
              .first
              .key;
      if (source == copy.id) continue;

      final map = await copyDatabaseSchema(
        source,
        copy.id,
        idFor: (old) => stableId('${copy.id}/$old'),
      );
      final now = _clockRef.tick();
      await db.transaction(() async {
        for (final v in values) {
          final to = map[v.key];
          if (to == null) continue;
          await db
              .into(db.properties)
              .insertOnConflictUpdate(
                v.copyWith(
                  key: to,
                  updatedAt: now,
                  deviceId: deviceId,
                  dirty: true,
                ),
              );
          await (db.update(db.properties)
                ..where((p) => p.pageId.equals(v.pageId) & p.key.equals(v.key)))
              .write(
                PropertiesCompanion(
                  deleted: const Value(true),
                  updatedAt: Value(now),
                  deviceId: Value(deviceId),
                  dirty: const Value(true),
                ),
              );
        }
        // The copied page (the copy's parent) showed the original.
        if (copy.parentId != null) {
          final blocks =
              await (db.select(db.blocks)..where(
                    (b) =>
                        b.pageId.equals(copy.parentId!) &
                        b.deleted.equals(false) &
                        b.data.like('%$source%'),
                  ))
                  .get();
          for (final b in blocks) {
            await (db.update(db.blocks)..where((x) => x.id.equals(b.id))).write(
              BlocksCompanion(
                data: Value(b.data.replaceAll(source, copy.id)),
                updatedAt: Value(now),
                deviceId: Value(deviceId),
                dirty: const Value(true),
              ),
            );
          }
        }
      });
      repaired++;
    }
    return repaired;
  }

  // ---- auto-fill: a formula whose result is stored as a real value ----

  /// Fills every auto-filled property ([autoExpression]) of [databaseId]
  /// from its formula, then the databases whose auto-fill reads this one
  /// with `lookup`. Only cells whose value changes are written (and
  /// synced). Returns how many cells changed.
  Future<int> refreshAutoFill(String databaseId) async {
    var changed = await _applyAutoFill(databaseId);
    final self = await getPage(databaseId);
    if (self == null) return changed;
    // Databases that look this one up by name.
    final readers =
        await (db.select(db.dbProperties)..where(
              (p) =>
                  p.deleted.equals(false) &
                  p.config.like('%lookup(%${self.title}%'),
            ))
            .get();
    for (final id in {
      for (final r in readers) r.databaseId,
    }..remove(databaseId)) {
      changed += await _applyAutoFill(id);
    }
    return changed;
  }

  Future<int> _applyAutoFill(String databaseId) async {
    var snap = await loadDatabase(databaseId);
    if (snap == null) return 0;
    final autos = [
      for (final p in snap.properties)
        if (autoExpression(p) != null) p,
    ];
    if (autos.isEmpty) return 0;
    final external = await externalLookup({
      for (final p in autos) ...lookedUpDatabases(autoExpression(p)!),
    }, near: databaseId);
    var changed = 0;
    // Twice, so an auto-filled property that reads another one settles.
    for (var pass = 0; pass < 2; pass++) {
      var thisPass = 0;
      for (final row in snap!.rows) {
        for (final p in autos) {
          final result = snap.evaluate(
            row.id,
            autoExpression(p)!,
            external: external,
          );
          if (result is FormulaError) continue;
          final next = autoValue(p, result);
          if (jsonEncode(next) == jsonEncode(snap.cell(row.id, p.id))) {
            continue;
          }
          await setCell(row.id, p.id, next);
          thisPass++;
        }
      }
      changed += thisPass;
      if (thisPass == 0) break;
      snap = await loadDatabase(databaseId);
      if (snap == null) break;
    }
    return changed;
  }

  /// `lookup("db", "item", "prop")` over the databases named in [names].
  /// Several can share a name (a trip and its template both have
  /// "날짜 설정"): the one nearest to [near] in the page tree comes first,
  /// so each trip reads its own; an empty value doesn't win.
  Future<ExternalLookup> externalLookup(
    Set<String> names, {
    String? near,
  }) async {
    final snaps = <DbSnapshot>[];
    if (names.isNotEmpty) {
      final pages =
          await (db.select(db.pages)..where(
                (p) =>
                    p.kind.equals('database') &
                    p.title.isIn(names) &
                    p.deleted.equals(false) &
                    p.trashedAt.isNull(),
              ))
              .get();
      final home = near == null
          ? const <String>[]
          : [for (final a in await ancestors(near)) a.id];
      final shared = <String, int>{};
      for (final page in pages) {
        final chain = [for (final a in await ancestors(page.id)) a.id];
        var n = 0;
        while (n < home.length && n < chain.length && home[n] == chain[n]) {
          n++;
        }
        shared[page.id] = n;
        final s = await loadDatabase(page.id, withLookups: false);
        if (s != null) snaps.add(s);
      }
      snaps.sort(
        (a, b) => shared[b.database.id]!.compareTo(shared[a.database.id]!),
      );
    }
    return (database, item, property) {
      var found = false;
      for (final s in snaps.where((s) => s.database.title == database)) {
        final prop = s.properties.where((p) => p.name == property).firstOrNull;
        if (prop == null) continue;
        final row = item.isEmpty
            ? s.rows.firstOrNull
            : s.rows.where((r) => r.title == item).firstOrNull;
        if (row == null) continue;
        found = true;
        final v = DbSnapshot.formulaInput(prop, s.value(row.id, prop));
        if (v != null && v != '') return v; // an empty copy doesn't win
      }
      return found
          ? null
          : FormulaError('"$database"에서 "$item"의 "$property"를 찾지 못했어요');
    };
  }

  /// Changes a property's type, converting what each row holds as well as
  /// possible. A formula turned into a plain type keeps its formula as the
  /// property's auto-fill, so the values stay filled in (and the other way
  /// round).
  Future<void> changePropertyType(
    DbSnapshot snap,
    DbProperty prop,
    String to,
  ) async {
    if (prop.type == to) return;
    final config = {...prop.config};
    final texts = {for (final r in snap.rows) r.id: snap.text(r.id, prop)};

    // Select types: options from the old options or the distinct texts.
    final options = <SelectOption>[...prop.options];
    String? optionFor(String name) {
      name = name.trim();
      if (name.isEmpty) return null;
      final found = options.where((o) => o.name == name).firstOrNull;
      if (found != null) return found.id;
      final o = SelectOption(
        newId(),
        name,
        selectColors[options.length % selectColors.length],
      );
      options.add(o);
      return o.id;
    }

    final values = <String, Object?>{};
    for (final r in snap.rows) {
      final old = snap.value(r.id, prop);
      final text = texts[r.id]!.trim();
      values[r.id] = switch (to) {
        _ when text.isEmpty && old is! num && old is! bool => null,
        PropType.text || PropType.url => text,
        PropType.number =>
          old is num
              ? old
              : num.tryParse(text.replaceAll(RegExp(r'[^\d.\-]'), '')),
        PropType.date => RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(text)?[0],
        PropType.checkbox =>
          old == true || const {'1', '✓', 'true', '예', 'O', 'o'}.contains(text),
        PropType.select => switch (prop.type) {
          PropType.select => old,
          PropType.multiSelect => (old as List?)?.firstOrNull,
          _ => optionFor(text),
        },
        PropType.multiSelect => switch (prop.type) {
          PropType.multiSelect => old,
          PropType.select => old == null ? null : [old],
          _ => [for (final part in text.split(',')) ?optionFor(part)],
        },
        PropType.place => prop.type == PropType.place ? old : {'address': text},
        _ => null, // formula: computed, nothing stored
      };
    }

    if (to == PropType.select || to == PropType.multiSelect) {
      config['options'] = [for (final o in options) o.toJson()];
    }
    if (prop.type == PropType.formula) {
      final expression = (config.remove('expression') as String? ?? '').trim();
      if (expression.isNotEmpty && to != PropType.formula) {
        config['auto'] = expression;
      }
    }
    if (to == PropType.formula) {
      config['expression'] = config.remove('auto') ?? '';
    }
    await updateProperty(prop.id, type: to, config: config);
    if (to == PropType.formula) return;
    for (final r in snap.rows) {
      final v = values[r.id];
      if (jsonEncode(v) != jsonEncode(snap.cell(r.id, prop.id))) {
        await setCell(r.id, prop.id, v);
      }
    }
  }

  // ---- views ----

  Future<String> addView(
    String databaseId,
    String type, {
    String? name,
    Map<String, dynamic> config = const {},
  }) async {
    final last =
        await (db.select(db.dbViews)
              ..where((v) => v.databaseId.equals(databaseId))
              ..orderBy([(v) => OrderingTerm.desc(v.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    final id = newId();
    await db
        .into(db.dbViews)
        .insert(
          DbViewsCompanion.insert(
            id: id,
            databaseId: databaseId,
            name: name ?? ViewType.label(type),
            type: type,
            config: Value(jsonEncode(config)),
            sortKey: keyBetween(last?.sortKey, null),
            updatedAt: _clockRef.tick(),
            deviceId: deviceId,
          ),
        );
    return id;
  }

  Future<void> updateView(
    String id, {
    String? name,
    Map<String, dynamic>? config,
  }) {
    return (db.update(db.dbViews)..where((v) => v.id.equals(id))).write(
      DbViewsCompanion(
        name: name == null ? const Value.absent() : Value(name),
        config: config == null
            ? const Value.absent()
            : Value(jsonEncode(config)),
        updatedAt: Value(_clockRef.tick()),
        deviceId: Value(deviceId),
        dirty: const Value(true),
      ),
    );
  }

  Future<void> deleteView(String id) {
    return (db.update(db.dbViews)..where((v) => v.id.equals(id))).write(
      DbViewsCompanion(
        deleted: const Value(true),
        updatedAt: Value(_clockRef.tick()),
        deviceId: Value(deviceId),
        dirty: const Value(true),
      ),
    );
  }
}

/// Rows of [snap] in the order [view] asks for.
List<PageRow> sortedRows(DbSnapshot snap, DbView view, {String query = ''}) {
  final q = query.trim().toLowerCase();
  final filters = view.filters;
  var rows = [
    for (final r in snap.rows)
      if (filters.every((f) => matchesFilter(snap, r, f))) r,
  ];
  if (q.isNotEmpty) {
    rows = [
      for (final r in rows)
        if (r.title.toLowerCase().contains(q) ||
            snap.properties.any(
              (p) => snap.text(r.id, p).toLowerCase().contains(q),
            ))
          r,
    ];
  }
  final by = view.sortBy;
  if (by == null) return rows;
  final prop = snap.property(by);
  String key(PageRow r) =>
      by == 'title' ? r.title : (prop == null ? '' : snap.text(r.id, prop));
  int compare(PageRow a, PageRow b) {
    final ka = key(a), kb = key(b);
    if (prop?.type == PropType.number || prop?.type == PropType.formula) {
      final na = num.tryParse(ka), nb = num.tryParse(kb);
      if (na != null && nb != null) return na.compareTo(nb);
    }
    return ka.compareTo(kb);
  }

  final sorted = [...rows]..sort(compare);
  return view.sortDesc ? sorted.reversed.toList() : sorted;
}

/// Filter operators per property type, with labels.
List<(String, String)> filterOps(String type) => switch (type) {
  PropType.number || PropType.formula => const [
    ('eq', '='),
    ('neq', '≠'),
    ('gt', '>'),
    ('lt', '<'),
    ('gte', '≥'),
    ('lte', '≤'),
    ('empty', '비어 있음'),
    ('not_empty', '비어 있지 않음'),
  ],
  PropType.select => const [
    ('eq', '다음과 같음'),
    ('neq', '다음과 같지 않음'),
    ('empty', '비어 있음'),
    ('not_empty', '비어 있지 않음'),
  ],
  PropType.multiSelect => const [
    ('contains', '포함'),
    ('not_contains', '포함하지 않음'),
    ('empty', '비어 있음'),
    ('not_empty', '비어 있지 않음'),
  ],
  PropType.checkbox => const [('checked', '체크됨'), ('unchecked', '체크 안 됨')],
  PropType.date => const [
    ('eq', '당일'),
    ('before', '이전'),
    ('after', '이후'),
    ('empty', '비어 있음'),
    ('not_empty', '비어 있지 않음'),
  ],
  _ => const [
    ('contains', '포함'),
    ('not_contains', '포함하지 않음'),
    ('eq', '다음과 같음'),
    ('empty', '비어 있음'),
    ('not_empty', '비어 있지 않음'),
  ],
};

/// Whether [row] passes one filter. Unknown properties/ops pass.
bool matchesFilter(DbSnapshot snap, PageRow row, Map<String, dynamic> f) {
  final propId = f['prop'] as String?;
  final op = f['op'] as String? ?? '';
  final want = f['value'];
  final prop = propId == null || propId == 'title'
      ? null
      : snap.property(propId);
  if (propId != 'title' && prop == null) return true;

  final raw = prop == null ? row.title : snap.value(row.id, prop);
  final text = prop == null ? row.title : snap.text(row.id, prop);
  final isEmpty =
      raw == null ||
      (raw is String && raw.isEmpty) ||
      (raw is List && raw.isEmpty);
  switch (op) {
    case 'empty':
      return isEmpty;
    case 'not_empty':
      return !isEmpty;
    case 'checked':
      return raw == true;
    case 'unchecked':
      return raw != true;
  }
  if (want == null || (want is String && want.isEmpty)) return true;
  final type = prop?.type ?? PropType.text;

  if (type == PropType.number || type == PropType.formula) {
    final a = raw is num ? raw.toDouble() : double.tryParse(text);
    final b = want is num ? want.toDouble() : double.tryParse('$want');
    if (a == null || b == null) {
      return op == 'neq' ? text != '$want' : (op == 'eq' && text == '$want');
    }
    return switch (op) {
      'eq' => a == b,
      'neq' => a != b,
      'gt' => a > b,
      'lt' => a < b,
      'gte' => a >= b,
      'lte' => a <= b,
      _ => true,
    };
  }
  if (type == PropType.select) {
    return switch (op) {
      'eq' => raw == want,
      'neq' => raw != want,
      _ => true,
    };
  }
  if (type == PropType.multiSelect) {
    final ids = (raw as List?)?.cast<String>() ?? const [];
    return switch (op) {
      'contains' => ids.contains(want),
      'not_contains' => !ids.contains(want),
      _ => true,
    };
  }
  if (type == PropType.date) {
    if (raw is! String) return false;
    final c = raw.compareTo('$want');
    return switch (op) {
      'eq' => c == 0,
      'before' => c < 0,
      'after' => c > 0,
      _ => true,
    };
  }
  final t = text.toLowerCase(), w = '$want'.toLowerCase();
  return switch (op) {
    'contains' => t.contains(w),
    'not_contains' => !t.contains(w),
    'eq' => t == w,
    _ => true,
  };
}
