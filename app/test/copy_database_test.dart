import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' show Node;
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/database_repository.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/editor/database_block.dart';

/// A trip page ("오사카 여행") with a 일정 page holding two databases shown
/// as table blocks, like the user's Notion import.
void main() {
  late AppDatabase db;
  late NotesRepository repo;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db);
    await repo.init();
  });
  tearDown(() => db.close());

  Future<({String trip, String schedule, String plan, String settings})>
  makeTrip() async {
    final trip = await repo.createPage(title: '오사카 여행');
    final schedule = await repo.createPage(parentId: trip, title: '일정');
    final settings = await repo.createDatabase(
      parentId: schedule,
      title: '날짜 설정',
    );
    final first = await repo.addProperty(settings, '1일차 날짜', PropType.date);
    await repo.addRow(settings, title: '여행 시작일', values: {first: '2027-01-18'});
    final plan = await repo.createDatabase(parentId: schedule, title: '여행일정표');
    final day = await repo.addProperty(plan, '1일차 날짜', PropType.date);
    await repo.addRow(plan, title: '4일차', values: {day: '2027-01-18'});
    // The 일정 page shows both as table blocks.
    final doc = await repo.openDocument(schedule);
    doc.document.insert(
      [0],
      [
        for (final id in [settings, plan])
          Node(
            type: DatabaseBlockKeys.type,
            attributes: {DatabaseBlockKeys.databaseId: id},
          ),
      ],
    );
    await doc.save();
    return (trip: trip, schedule: schedule, plan: plan, settings: settings);
  }

  Future<List<String>> shownDatabases(String pageId) async => [
    for (final b in await (db.select(
      db.blocks,
    )..where((b) => b.pageId.equals(pageId) & b.deleted.equals(false))).get())
      if (b.type == DatabaseBlockKeys.type)
        (jsonDecode(b.data) as Map)[DatabaseBlockKeys.databaseId] as String,
  ];

  Future<String> childNamed(String parent, String title) async =>
      (await (db.select(db.pages)..where(
                (p) =>
                    p.parentId.equals(parent) &
                    p.title.equals(title) &
                    p.deleted.equals(false),
              ))
              .getSingle())
          .id;

  test('duplicating a trip copies its databases with their columns, and '
      'the copy shows its own tables', () async {
    final osaka = await makeTrip();
    final copy = await repo.duplicatePage(osaka.trip);
    final schedule = await childNamed(copy, '일정');
    final plan = await childNamed(schedule, '여행일정표');
    final settings = await childNamed(schedule, '날짜 설정');

    expect(await shownDatabases(schedule), [settings, plan]);
    final snap = (await repo.loadDatabase(plan))!;
    expect(snap.properties.map((p) => p.name), contains('1일차 날짜'));
    expect(snap.views, isNotEmpty);
    final day = snap.properties.singleWhere((p) => p.name == '1일차 날짜');
    expect(snap.cell(snap.rows.single.id, day.id), '2027-01-18');
    // Separate from the original: a change there doesn't show here.
    final original = (await repo.loadDatabase(osaka.plan))!;
    expect(
      original.properties
          .map((p) => p.id)
          .toSet()
          .intersection(snap.properties.map((p) => p.id).toSet()),
      isEmpty,
    );
  });

  test('a copy made before the fix (no columns, blocks on the original) is '
      'repaired, the same way on every device', () async {
    final osaka = await makeTrip();
    // What older versions made: pages and items copied, columns not.
    final template = await repo.createPage(title: '여행 템플릿');
    final schedule = await repo.createPage(parentId: template, title: '일정');
    final plan = await repo.createPage(
      parentId: schedule,
      title: '여행일정표',
      kind: 'database',
    );
    final original = (await repo.loadDatabase(osaka.plan))!;
    final day = original.properties.singleWhere((p) => p.name == '1일차 날짜');
    final row = await repo.createPage(
      parentId: plan,
      title: '4일차',
      kind: 'row',
    );
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            pageId: row,
            key: day.id,
            value: '"2027-01-18"',
            updatedAt: 1,
            deviceId: 'x',
          ),
        );
    final doc = await repo.openDocument(schedule);
    doc.document.insert(
      [0],
      [
        Node(
          type: DatabaseBlockKeys.type,
          attributes: {DatabaseBlockKeys.databaseId: osaka.plan},
        ),
      ],
    );
    await doc.save();

    expect(await repo.repairCopiedDatabases(), 1);
    final snap = (await repo.loadDatabase(plan))!;
    final copied = snap.properties.singleWhere((p) => p.name == '1일차 날짜');
    expect(copied.id, stableId('$plan/${day.id}'));
    expect(snap.cell(row, copied.id), '2027-01-18');
    expect(snap.views, isNotEmpty);
    expect(await shownDatabases(schedule), [plan]);
    // The original is untouched; running again changes nothing.
    expect((await repo.loadDatabase(osaka.plan))!.rows, hasLength(1));
    expect(await repo.repairCopiedDatabases(), 0);
  });

  test('lookup reads the database of the same trip', () async {
    final osaka = await makeTrip();
    final copy = await repo.duplicatePage(osaka.trip);
    final copySettings = await childNamed(
      await childNamed(copy, '일정'),
      '날짜 설정',
    );
    final s = (await repo.loadDatabase(copySettings))!;
    final first = s.properties.singleWhere((p) => p.name == '1일차 날짜');
    await repo.setCell(s.rows.single.id, first.id, '2030-05-01');

    Future<Object?> read(String near) async => (await repo.externalLookup({
      '날짜 설정',
    }, near: near))('날짜 설정', '여행 시작일', '1일차 날짜');
    final copyPlan = await childNamed(await childNamed(copy, '일정'), '여행일정표');
    expect(await read(osaka.plan), '2027-01-18');
    expect(await read(copyPlan), '2030-05-01');
  });
}
