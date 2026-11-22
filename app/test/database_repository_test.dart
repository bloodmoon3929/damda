import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/database_repository.dart';
import 'package:notes/data/notes_repository.dart';

void main() {
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db);
    await repo.init();
  });
  tearDown(() => db.close());

  test(
    'new database has a tag column and a table view; rows hidden from tree',
    () async {
      final id = await repo.createDatabase(title: '여행일정표');
      await repo.addRow(id, title: '유니버설');
      final snap = (await repo.loadDatabase(id))!;
      expect(snap.properties.map((p) => (p.name, p.type)), [
        ('태그', PropType.multiSelect),
      ]);
      expect(snap.views.map((v) => v.type), [ViewType.table]);
      expect(snap.rows.map((r) => r.title), ['유니버설']);

      final tree = await repo.watchPages().first;
      expect(tree.map((p) => p.title), containsAll(['미정리', '여행일정표']));
      expect(tree.map((p) => p.title), isNot(contains('유니버설')));
    },
  );

  test('select options, cells and sorting', () async {
    final id = await repo.createDatabase(title: 'DB');
    final dayId = await repo.addProperty(id, '일차', PropType.select);
    final costId = await repo.addProperty(id, '비용', PropType.number);
    var snap = (await repo.loadDatabase(id))!;
    final day = snap.property(dayId)!;
    final d1 = await repo.addSelectOption(day, '1일차');
    snap = (await repo.loadDatabase(id))!;
    final d2 = await repo.addSelectOption(snap.property(dayId)!, '2일차');
    expect(d1.color, isNot(d2.color));

    final a = await repo.addRow(
      id,
      title: 'B',
      values: {dayId: d2.id, costId: 10},
    );
    final b = await repo.addRow(
      id,
      title: 'A',
      values: {dayId: d1.id, costId: 9},
    );
    snap = (await repo.loadDatabase(id))!;
    expect(snap.cell(a, dayId), d2.id);
    expect(snap.cell(b, costId), 9);

    final viewId = await repo.addView(
      id,
      ViewType.board,
      config: {'groupBy': dayId},
    );
    snap = (await repo.loadDatabase(id))!;
    final board = snap.views.firstWhere((v) => v.id == viewId);
    expect(board.groupBy, dayId);

    await repo.updateView(viewId, config: {'sortBy': costId});
    snap = (await repo.loadDatabase(id))!;
    final sortedByCost = sortedRows(
      snap,
      snap.views.firstWhere((v) => v.id == viewId),
    );
    expect(sortedByCost.map((r) => r.title), ['A', 'B']);

    await repo.setCell(a, dayId, null);
    snap = (await repo.loadDatabase(id))!;
    expect(snap.cell(a, dayId), isNull);
  });

  test('formula columns compute per row and sort numerically', () async {
    final id = await repo.createDatabase(title: 'DB');
    final cost = await repo.addProperty(id, '비용', PropType.number);
    final people = await repo.addProperty(id, '인원', PropType.number);
    final each = await repo.addProperty(id, '1인당', PropType.formula);
    await repo.updateProperty(
      each,
      config: {'expression': 'prop("비용") / prop("인원")'},
    );
    final a = await repo.addRow(
      id,
      title: 'A',
      values: {cost: 9000, people: 3},
    );
    final b = await repo.addRow(
      id,
      title: 'B',
      values: {cost: 10000, people: 5},
    );
    final snap = (await repo.loadDatabase(id))!;
    final f = snap.property(each)!;
    expect(snap.value(a, f), 3000);
    expect(snap.value(b, f), 2000);
    expect(snap.text(a, f), '3000');

    final viewId = await repo.addView(
      id,
      ViewType.table,
      config: {'sortBy': each},
    );
    final s2 = (await repo.loadDatabase(id))!;
    final view = s2.views.firstWhere((v) => v.id == viewId);
    expect(sortedRows(s2, view).map((r) => r.title), ['B', 'A']);
  });

  test('view filters (all must match)', () async {
    final id = await repo.createDatabase(title: 'DB');
    final cost = await repo.addProperty(id, '비용', PropType.number);
    final kind = await repo.addProperty(id, '유형', PropType.select);
    final done = await repo.addProperty(id, '완료', PropType.checkbox);
    final date = await repo.addProperty(id, '날짜', PropType.date);
    var snap = (await repo.loadDatabase(id))!;
    final sight = await repo.addSelectOption(snap.property(kind)!, '관광지');
    snap = (await repo.loadDatabase(id))!;
    final food = await repo.addSelectOption(snap.property(kind)!, '식사');

    await repo.addRow(
      id,
      title: '성',
      values: {cost: 600, kind: sight.id, done: true, date: '2027-01-18'},
    );
    await repo.addRow(
      id,
      title: '타코야키',
      values: {cost: 1200, kind: food.id, date: '2027-01-19'},
    );
    await repo.addRow(
      id,
      title: '유니버설',
      values: {cost: 10900, kind: sight.id, date: '2027-01-20'},
    );

    Future<List<String>> titles(List<Map<String, dynamic>> filters) async {
      final viewId = await repo.addView(
        id,
        ViewType.table,
        config: {'filters': filters, 'sortBy': 'title'},
      );
      final s = (await repo.loadDatabase(id))!;
      return sortedRows(
        s,
        s.views.firstWhere((v) => v.id == viewId),
      ).map((r) => r.title).toList();
    }

    expect(
      await titles([
        {'prop': kind, 'op': 'eq', 'value': sight.id},
      ]),
      ['성', '유니버설'],
    );
    expect(
      await titles([
        {'prop': kind, 'op': 'eq', 'value': sight.id},
        {'prop': cost, 'op': 'gt', 'value': 1000},
      ]),
      ['유니버설'],
    );
    expect(
      await titles([
        {'prop': done, 'op': 'checked'},
      ]),
      ['성'],
    );
    expect(
      await titles([
        {'prop': date, 'op': 'after', 'value': '2027-01-18'},
      ]),
      ['유니버설', '타코야키'],
    );
    expect(
      await titles([
        {'prop': 'title', 'op': 'contains', 'value': '야키'},
      ]),
      ['타코야키'],
    );
  });

  test('gallery cover = first image in the row page', () async {
    final id = await repo.createDatabase(title: 'DB');
    final row = await repo.addRow(id, title: '성');
    final doc = await repo.openDocument(row);
    doc.document.root.insert(imageNode(url: 'asset://first'));
    doc.document.root.insert(imageNode(url: 'asset://second'));
    await doc.save();
    final snap = (await repo.loadDatabase(id))!;
    expect(snap.covers[row], 'asset://first');
  });

  test('watchDatabase emits on changes', () async {
    final id = await repo.createDatabase(title: 'DB');
    final stream = repo.watchDatabase(id);
    final seen = <int>[];
    final sub = stream.listen((s) => seen.add(s!.rows.length));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await repo.addRow(id, title: 'x');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(seen.first, 0);
    expect(seen.last, 1);
  });

  test('a formula that computes a date is a calendar date source', () async {
    final id = await repo.createDatabase(title: 'DB');
    final start = await repo.addProperty(id, '출발', PropType.date);
    final due = await repo.addProperty(id, '마감', PropType.formula);
    await repo.updateProperty(
      due,
      config: {'expression': 'dateAdd(prop("출발"), 3, "days")'},
    );
    final row = await repo.addRow(
      id,
      title: 'A',
      values: {start: '2027-01-18'},
    );
    final snap = (await repo.loadDatabase(id))!;
    final f = snap.property(due)!;
    expect(isDateSource(f), isTrue);
    expect(dayOf(snap, row, f), '2027-01-21');
  });
}
