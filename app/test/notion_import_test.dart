import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/database_repository.dart';
import 'package:notes/data/links.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/notion/notion_import.dart';
import 'package:path/path.dart' as p;

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map<String, Object?> rt(String text, {bool bold = false, String? link}) => {
  'type': 'text',
  'plain_text': text,
  'text': {
    'content': text,
    'link': link == null ? null : {'url': link},
  },
  'annotations': {'bold': bold},
};

Map<String, Object?> block(
  String type,
  Map<String, Object?> data, {
  String? id,
  bool children = false,
}) => {
  'object': 'block',
  'id': id ?? 'b-$type-${data.hashCode}',
  'type': type,
  'has_children': children,
  type: data,
};

/// A small Notion workspace:
///   여행 (page)
///     ├ 오사카 (sub-page) — text, mention of 경비, image, todo, code, table
///     └ 경비 (database: 금액 number, 분류 select, 날짜 date with end, 메모 rich_text)
///         └ 숙소 (row)
///   메모장 (another top-level page)
const memo = '55555555-5555-5555-5555-555555555555';
Map<String, Object?> fake(
  String method,
  String path,
  Map<String, dynamic>? body,
) {
  const trip = '11111111-1111-1111-1111-111111111111';
  const osaka = '22222222-2222-2222-2222-222222222222';
  const db = '33333333-3333-3333-3333-333333333333';
  const row = '44444444-4444-4444-4444-444444444444';
  Map<String, Object?> page(
    String id,
    String title,
    Map<String, Object?> parent, {
    Map<String, Object?> props = const {},
  }) => {
    'object': 'page',
    'id': id,
    'parent': parent,
    'icon': id == trip ? {'type': 'emoji', 'emoji': '✈️'} : null,
    'properties': {
      'title': {
        'type': 'title',
        'title': [rt(title)],
      },
      ...props,
    },
  };
  final rowPage = page(
    row,
    '숙소',
    {'type': 'database_id', 'database_id': db},
    props: {
      '금액': {'type': 'number', 'number': 120000},
      '분류': {
        'type': 'select',
        'select': {'name': '숙박'},
      },
      '날짜': {
        'type': 'date',
        'date': {'start': '2026-11-01', 'end': '2026-11-03'},
      },
      '메모': {
        'type': 'rich_text',
        'rich_text': [rt('조식 포함')],
      },
      '체크인': {
        'type': 'formula',
        'formula': {
          'type': 'date',
          'date': {'start': '2026-11-01T15:00:00.000+09:00'},
        },
      },
      '비싼가': {
        'type': 'formula',
        'formula': {'type': 'boolean', 'boolean': true},
      },
      '위치': {
        'type': 'place',
        'place': {
          'lat': 34.6594,
          'lon': 135.4981,
          'name': '호텔',
          'address': '오사카 난바',
        },
      },
    },
  );
  if (path.startsWith('/search')) {
    final want = (body!['filter'] as Map)['value'];
    return {
      'results': want == 'page'
          ? [
              page(trip, '여행', {'type': 'workspace', 'workspace': true}),
              page(osaka, '오사카', {'type': 'page_id', 'page_id': trip}),
              rowPage,
              page(memo, '메모장', {'type': 'workspace', 'workspace': true}),
            ]
          : [
              {
                'object': 'database',
                'id': db,
                'parent': {'type': 'page_id', 'page_id': trip},
                'title': [rt('경비')],
                'properties': {
                  '이름': {'id': 'title', 'type': 'title', 'title': {}},
                  '금액': {'id': 'amt', 'type': 'number', 'number': {}},
                  '분류': {
                    'id': 'c%3Aat',
                    'type': 'select',
                    'select': {
                      'options': [
                        {'name': '숙박', 'color': 'blue'},
                        {'name': '식비', 'color': 'default'},
                      ],
                    },
                  },
                  '날짜': {'id': 'dt', 'type': 'date', 'date': {}},
                  '메모': {'id': 'memo', 'type': 'rich_text', 'rich_text': {}},
                  '체크인': {
                    'id': 'ci',
                    'type': 'formula',
                    'formula': {'expression': 'dateAdd(prop("날짜"), 0, "days")'},
                  },
                  '비싼가': {
                    'id': 'exp',
                    'type': 'formula',
                    // Relation traversal: not computable here → values.
                    'formula': {'expression': 'prop("금액").map(current > 1)'},
                  },
                  '위치': {'id': 'lytM', 'type': 'place', 'place': {}},
                },
              },
            ],
      'has_more': false,
    };
  }
  if (path.startsWith('/databases/${db.replaceAll('-', '')}/query')) {
    return {
      'results': [rowPage],
      'has_more': false,
    };
  }
  if (path.startsWith('/blocks/${trip.replaceAll('-', '')}/children')) {
    return {
      'results': [
        block('paragraph', {
          'rich_text': [rt('여행 모음')],
        }),
        block('child_page', {'title': '오사카'}, id: osaka),
        block('child_database', {'title': '경비'}, id: db),
      ],
      'has_more': false,
    };
  }
  if (path.startsWith('/blocks/${osaka.replaceAll('-', '')}/children')) {
    return {
      'results': [
        block('heading_1', {
          'rich_text': [rt('첫날')],
        }),
        block('paragraph', {
          'rich_text': [
            rt('비용은 ', bold: true),
            {
              'type': 'mention',
              'plain_text': '경비',
              'mention': {
                'type': 'database',
                'database': {'id': db},
              },
              'annotations': {},
            },
            rt(' 참고 '),
            rt('링크', link: 'https://example.com'),
            {
              'type': 'equation',
              'plain_text': 'x^2',
              'equation': {'expression': 'x^2'},
              'annotations': {},
            },
          ],
        }),
        block('image', {
          'type': 'file',
          'file': {'url': 'https://files.notion.test/photo.png?sig=1'},
          'caption': [],
        }),
        block('to_do', {
          'rich_text': [rt('환전')],
          'checked': true,
        }),
        block('code', {
          'rich_text': [rt('print(1)')],
          'language': 'python',
        }),
        block('table', {'table_width': 2}, id: 'tbl', children: true),
        block('callout', {
          'rich_text': [rt('주의')],
          'icon': {'type': 'emoji', 'emoji': '⚠️'},
        }),
        block('unsupported', {}),
      ],
      'has_more': false,
    };
  }
  if (path.startsWith('/blocks/tbl/children')) {
    return {
      'results': [
        block('table_row', {
          'cells': [
            [rt('a')],
            [rt('b')],
          ],
        }),
        block('table_row', {
          'cells': [
            [rt('1')],
            [rt('2')],
          ],
        }),
      ],
      'has_more': false,
    };
  }
  if (path.contains('/children')) return {'results': [], 'has_more': false};
  throw StateError('unexpected $method $path');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;
  late NotesRepository repo;

  /// Views of the 경비 database (Views API, newer version only).
  Map<String, Object?> views(String path) {
    if (path.startsWith('/views?')) {
      return {
        'results': [
          {'object': 'view', 'id': 'v1'},
          {'object': 'view', 'id': 'v2'},
          {'object': 'view', 'id': 'v3'},
          {'object': 'view', 'id': 'v4'},
          {'object': 'view', 'id': 'v5'},
        ],
        'has_more': false,
      };
    }
    return switch (path.split('/').last) {
      'v1' => {
        'id': 'v1',
        'type': 'table',
        'name': '전체',
        'configuration': {
          'type': 'table',
          'properties': [
            {'property_id': 'memo', 'visible': false},
          ],
        },
        'sorts': [
          {'property': '금액', 'direction': 'descending'},
        ],
      },
      'v2' => {
        'id': 'v2',
        'type': 'board',
        'name': '분류별',
        'configuration': {
          'type': 'board',
          'group_by': {'type': 'select', 'property_id': 'c%3Aat'},
          'properties': [
            {'property_id': 'amt', 'visible': true},
          ],
        },
      },
      'v3' => {
        'id': 'v3',
        'type': 'timeline',
        'name': '일정',
        'configuration': {'type': 'timeline', 'date_property_id': 'dt'},
      },
      'v5' => {
        'id': 'v5',
        'type': 'map',
        'name': 'Untitled',
        'configuration': {'type': 'map', 'map_by': 'lytM'},
      },
      _ => {'id': 'v4', 'type': 'chart', 'name': '차트'},
    };
  }

  NotionApi api({bool viewsApi = true}) => NotionApi(
    'secret_test',
    minGap: Duration.zero,
    client: MockClient((req) async {
      if (req.url.host == 'files.notion.test') {
        return http.Response.bytes(base64Decode(_png), 200);
      }
      expect(req.headers['Authorization'], 'Bearer secret_test');
      if (req.url.path.startsWith('/v1/views')) {
        expect(req.headers['Notion-Version'], '2026-03-11');
        if (!viewsApi) {
          return http.Response('{"message":"invalid version"}', 400);
        }
        final path =
            req.url.path.replaceFirst('/v1', '') +
            (req.url.hasQuery ? '?${req.url.query}' : '');
        return http.Response(
          jsonEncode(views(path)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(req.headers['Notion-Version'], '2022-06-28');
      // Notion accepts ids with or without dashes; compare without.
      final path =
          req.url.path.replaceFirst('/v1', '').replaceAll('-', '') +
          (req.url.hasQuery ? '?${req.url.query}' : '');
      final body = req.body.isEmpty
          ? null
          : jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(fake(req.method, path, body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notion_test');
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db, assetsDir: p.join(tmp.path, 'assets'));
    await repo.init();
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<PageRow> byTitle(String t) async => (await (db.select(
    db.pages,
  )..where((x) => x.title.equals(t) & x.deleted.equals(false))).get()).single;

  test('imports pages, a database with cells, content and files', () async {
    final report = await NotionImporter(repo, api()).run();
    expect(report.pages, 3);
    expect(report.databases, 1);
    expect(report.rows, 1);
    expect(report.attachments, 1);
    expect(report.skippedBlocks, 1);

    final trip = await byTitle('여행');
    final osaka = await byTitle('오사카');
    final expenses = await byTitle('경비');
    expect(trip.icon, '✈️');
    expect(trip.parentId, report.rootPageId);
    expect(osaka.parentId, trip.id);
    expect(expenses.parentId, trip.id);
    expect(expenses.kind, 'database');

    final snap = (await repo.loadDatabase(expenses.id))!;
    expect(snap.properties.map((x) => x.name), [
      '금액',
      '분류',
      '날짜',
      '날짜 (끝)',
      '메모',
      '체크인',
      '비싼가',
      '위치',
    ]);
    final types = {for (final x in snap.properties) x.name: x.type};
    // A formula this app computes the same way stays a live formula …
    expect(types['체크인'], PropType.formula);
    expect(report.liveFormulas, 1);
    // … one it can't (relation traversal) comes over as its values.
    expect(types['비싼가'], PropType.checkbox);
    expect(types['위치'], PropType.place);
    final row = snap.rows.single;
    expect(row.title, '숙소');
    String text(String name) {
      final prop = snap.properties.firstWhere((x) => x.name == name);
      return cellText(prop, snap.value(row.id, prop));
    }

    expect(text('금액'), '120,000'); // shown with separators
    expect(text('분류'), '숙박');
    expect(text('날짜'), contains('2026-11-01'));
    expect(text('날짜 (끝)'), contains('2026-11-03'));
    expect(text('메모'), '조식 포함');
    expect(text('체크인'), contains('2026-11-01'));
    final place = snap.value(
      row.id,
      snap.properties.firstWhere((x) => x.name == '위치'),
    );
    expect(place, {
      'address': '오사카 난바',
      'lat': 34.6594,
      'lng': 135.4981,
      'name': '호텔',
    });
    final category = snap.properties.firstWhere((x) => x.name == '분류');
    expect(category.options.map((o) => (o.name, o.color)), [
      ('숙박', 'blue'),
      ('식비', 'gray'),
    ]);

    final doc = await repo.openDocument(osaka.id);
    final blockTypes = [for (final n in doc.document.root.children) n.type];
    expect(blockTypes, [
      'heading',
      'paragraph',
      'image',
      'todo_list',
      'code',
      'table',
      'callout',
    ]);
    final para = doc.document.root.children[1].delta!.toJson();
    expect(jsonEncode(para), contains('"bold":true'));
    expect(jsonEncode(para), contains('"href":"https://example.com"'));
    expect(jsonEncode(para), contains('"formula":"x^2"'));
    expect(jsonEncode(para), contains('"$pageLinkKey":"${expenses.id}"'));
    final callout = doc.document.root.children[6];
    expect(callout.delta!.toPlainText(), '주의');
    expect(callout.attributes['icon'], '⚠️');

    // The trip page shows the database inline and links its sub-page.
    final tripDoc = await repo.openDocument(trip.id);
    final tripTypes = [for (final n in tripDoc.document.root.children) n.type];
    expect(tripTypes, ['paragraph', 'paragraph', 'database']);
    expect(
      (await repo.watchBacklinks(expenses.id).first).single.page.id,
      osaka.id,
    );
  });

  test('importing again updates the same pages', () async {
    await NotionImporter(repo, api()).run();
    final before = (await db.select(db.pages).get())
        .where((x) => !x.deleted)
        .length;
    final osaka = await byTitle('오사카');
    final again = await NotionImporter(repo, api()).run();
    expect(again.updated, 5);
    expect(again.pages + again.databases + again.rows, 0);
    final after = (await db.select(db.pages).get())
        .where((x) => !x.deleted)
        .length;
    expect(after, before); // nothing new, not even a holder page
    expect(again.rootPageId, isNull);
    expect((await byTitle('오사카')).id, osaka.id);
    final snap = (await repo.loadDatabase((await byTitle('경비')).id))!;
    expect(snap.properties.length, 8); // no duplicated columns
    expect(again.liveFormulas, 1);
    expect(snap.rows.length, 1);
    expect(snap.views.length, 4); // views are not added twice
  });

  test("Notion's views come over", () async {
    final report = await NotionImporter(repo, api()).run();
    expect(report.views, 4); // the chart view is skipped
    final snap = (await repo.loadDatabase((await byTitle('경비')).id))!;
    String id(String name) =>
        snap.properties.firstWhere((x) => x.name == name).id;
    final views = {for (final v in snap.views) v.name: v};
    expect(views.keys, ['전체', '분류별', '일정', '지도']); // replaces the default
    expect(views['지도']!.placeBy, id('위치')); // "Untitled" → type name
    expect(views['전체']!.type, 'table');
    expect(views['전체']!.hidden, {id('메모')});
    expect(views['전체']!.sortBy, id('금액'));
    expect(views['전체']!.sortDesc, isTrue);
    expect(views['분류별']!.type, 'board');
    expect(views['분류별']!.groupBy, id('분류'));
    expect(views['분류별']!.cardProps, [id('금액')]);
    expect(views['일정']!.type, 'timeline');
    expect(views['일정']!.dateBy, id('날짜'));
    expect(views['일정']!.endBy, id('날짜 (끝)')); // from the date's end
  });

  test(
    'a database imported before views existed gets them on re-import',
    () async {
      // First import without the Views API, then remove the guessed views
      // (as the earlier version of the importer left only a table).
      await NotionImporter(repo, api(viewsApi: false)).run();
      final dbId = (await byTitle('경비')).id;
      for (final v in (await repo.loadDatabase(dbId))!.views.skip(1)) {
        await repo.deleteView(v.id);
      }
      await NotionImporter(repo, api()).run();
      final names = [
        for (final v in (await repo.loadDatabase(dbId))!.views) v.name,
      ];
      expect(names, ['전체', '분류별', '일정', '지도']);
    },
  );

  test('re-import updates Notion views and keeps views made here', () async {
    await NotionImporter(repo, api()).run();
    final dbId = (await byTitle('경비')).id;
    await repo.addView(dbId, ViewType.list, name: '내 목록');
    final board = (await repo.loadDatabase(dbId))!.views
        .firstWhere((v) => v.name == '분류별');
    await repo.updateView(board.id, name: '바꾼 이름'); // Notion's name wins again
    await NotionImporter(repo, api()).run();
    final names = [
      for (final v in (await repo.loadDatabase(dbId))!.views) v.name,
    ];
    expect(names, ['전체', '분류별', '일정', '지도', '내 목록']);
  });

  test('without the Views API, a board and a calendar are guessed', () async {
    final report = await NotionImporter(repo, api(viewsApi: false)).run();
    final snap = (await repo.loadDatabase((await byTitle('경비')).id))!;
    expect(
      [for (final v in snap.views) v.type],
      ['table', 'board', 'calendar'],
    );
    expect(report.views, 2);
  });

  test('only the chosen top-level pages are imported', () async {
    final importer = NotionImporter(repo, api());
    final items = await importer.scan();
    expect(
      [for (final i in items) (i.title, i.inside, i.isDatabase)],
      [('메모장', 0, false), ('여행', 3, false)], // 오사카, 경비, 숙소 inside
    );
    final r = await importer.run(
      only: {items.firstWhere((i) => i.title == '메모장').id},
    );
    expect(r.pages, 1);
    expect(r.databases, 0);
    final titles = {
      for (final x in await db.select(db.pages).get())
        if (!x.deleted) x.title,
    };
    expect(titles, contains('메모장'));
    expect(titles, isNot(contains('여행')));
  });

  test('a bad token gives a clear message', () async {
    final bad = NotionApi(
      'x',
      minGap: Duration.zero,
      client: MockClient(
        (_) async => http.Response('{"message":"API token is invalid."}', 401),
      ),
    );
    await expectLater(
      NotionImporter(repo, bad).run(),
      throwsA(
        isA<NotionException>().having(
          (e) => e.message,
          'message',
          contains('토큰'),
        ),
      ),
    );
  });
}
