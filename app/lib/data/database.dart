import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// Every synced table carries the same bookkeeping columns:
// updated_at (monotonic clock), device_id, deleted (tombstone) and dirty
// (changed locally, not yet pushed to the server — used from step 2 on).

@DataClassName('PageRow')
@TableIndex(name: 'pages_parent', columns: {#parentId})
class Pages extends Table {
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get icon => text().nullable()();
  TextColumn get sortKey => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  // ---- v2 ----
  /// 'page' | 'database' (a Notion database; its rows are its children)
  /// | 'row' (a database entry: a page that the sidebar doesn't list).
  TextColumn get kind => text().withDefault(const Constant('page'))();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();

  /// Set when moved to the trash (with its whole subtree, same timestamp).
  IntColumn get trashedAt => integer().nullable()();

  /// Templates live outside the page tree, in the 템플릿 manager.
  BoolColumn get isTemplate => boolean().withDefault(const Constant(false))();

  /// "테마와 레이아웃": 'default' | 'serif' | 'mono'.
  TextColumn get fontStyle => text().withDefault(const Constant('default'))();
  BoolColumn get smallText => boolean().withDefault(const Constant(false))();
  BoolColumn get fullWidth => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A column of a Notion-style database. The title column is implicit
/// (pages.title); cell values live in [Properties] keyed by this id.
@DataClassName('DbPropertyRow')
@TableIndex(name: 'db_properties_db', columns: {#databaseId})
class DbProperties extends Table {
  TextColumn get id => text()();
  TextColumn get databaseId => text()();
  TextColumn get name => text()();

  /// text | number | select | multi_select | date | checkbox | url
  TextColumn get type => text()();

  /// Type-specific settings, e.g. select options `[{id,name,color}]`.
  TextColumn get config => text().withDefault(const Constant('{}'))();
  TextColumn get sortKey => text()();
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A saved view (표, 보드, 리스트, ...) of a database.
@DataClassName('DbViewRow')
@TableIndex(name: 'db_views_db', columns: {#databaseId})
class DbViews extends Table {
  TextColumn get id => text()();
  TextColumn get databaseId => text()();
  TextColumn get name => text()();

  /// table | board | list (later: calendar, gallery, timeline)
  TextColumn get type => text()();

  /// groupBy, sorts, filters, hidden properties, column widths.
  TextColumn get config => text().withDefault(const Constant('{}'))();
  TextColumn get sortKey => text()();
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// An attachment (photo, video, PDF, ...). The file lives on disk in the
/// app's `assets/` folder (later also Nextcloud); only metadata is here.
/// Blocks refer to it as `asset://<id>`.
@DataClassName('AssetRow')
@TableIndex(name: 'assets_sha', columns: {#sha256})
class Assets extends Table {
  TextColumn get id => text()();

  /// Original file name, shown to the user.
  TextColumn get name => text()();
  TextColumn get mime => text()();
  IntColumn get size => integer()();
  TextColumn get sha256 => text()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();

  /// File name inside the local assets folder (`<id>.<ext>`).
  TextColumn get fileName => text()();

  /// Where it is stored on the server, once synced (step 2).
  TextColumn get remotePath => text().nullable()();

  /// Page it was first added to.
  TextColumn get pageId => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('BlockRow')
@TableIndex(name: 'blocks_page', columns: {#pageId})
class Blocks extends Table {
  TextColumn get id => text()();
  TextColumn get pageId => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get sortKey => text()();
  TextColumn get type => text()();
  // Editor node attributes (delta, level, checked, ...) as JSON, children excluded.
  TextColumn get data => text().withDefault(const Constant('{}'))();
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Derived from block contents on save; filled in step 3 (backlinks/graph).
@DataClassName('LinkRow')
@TableIndex(name: 'links_target', columns: {#targetPageId})
class Links extends Table {
  TextColumn get sourcePageId => text()();
  TextColumn get sourceBlockId => text()();
  TextColumn get targetPageId => text()();
  TextColumn get targetBlockId => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {sourceBlockId, targetPageId, targetBlockId};
}

/// Notion page properties / markdown frontmatter.
@DataClassName('PropertyRow')
class Properties extends Table {
  TextColumn get pageId => text()();
  TextColumn get key => text()();
  TextColumn get value => text()(); // JSON
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {pageId, key};
}

/// Local-only key/value settings (device id, inbox page id, ...). Never synced.
@DataClassName('MetaRow')
class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    Pages,
    Blocks,
    Links,
    Properties,
    Meta,
    DbProperties,
    DbViews,
    Assets,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// [dataDir] overrides the default app data folder (used for test runs so
  /// they never touch the real notes).
  AppDatabase([QueryExecutor? executor, String? dataDir])
    : super(
        executor ??
            driftDatabase(
              name: 'notes',
              native: DriftNativeOptions(
                databaseDirectory: dataDir != null
                    ? () async => dataDir
                    // App data folder, not the user's Documents.
                    : getApplicationSupportDirectory,
              ),
            ),
      );

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // Real user data exists at v1: only additive changes here.
        await m.addColumn(pages, pages.kind);
        await m.addColumn(pages, pages.favorite);
        await m.addColumn(pages, pages.trashedAt);
        await m.addColumn(pages, pages.isTemplate);
        await m.addColumn(pages, pages.fontStyle);
        await m.addColumn(pages, pages.smallText);
        await m.addColumn(pages, pages.fullWidth);
        await m.createTable(dbProperties);
        await m.createTable(dbViews);
        await m.createIndex(dbPropertiesDb);
        await m.createIndex(dbViewsDb);
      }
      if (from < 3) {
        await m.createTable(assets);
        await m.createIndex(assetsSha);
      }
    },
  );

  Future<String?> getMeta(String key) async {
    final row = await (select(
      meta,
    )..where((m) => m.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setMeta(String key, String value) =>
      into(meta).insertOnConflictUpdate(MetaRow(key: key, value: value));
}
