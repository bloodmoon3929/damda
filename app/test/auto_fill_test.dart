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

  Future<Map<String, Object?>> column(String dbId, String name) async {
    final snap = (await repo.loadDatabase(dbId))!;
    final p = snap.properties.singleWhere((p) => p.name == name);
    return {for (final r in snap.rows) r.title: snap.cell(r.id, p.id)};
  }

  test('여행 일정표: a date formula becomes a real date that fills itself, '
      'from the start date in another database', () async {
    // 날짜 설정: one item holding the first day.
    final settings = await repo.createDatabase(title: '날짜 설정');
    final first = await repo.addProperty(settings, '1일차 날짜', PropType.date);
    final start = await repo.addRow(
      settings,
      title: '여행 시작일',
      values: {first: '2027-01-18'},
    );

    // 여행일정표: 날짜 is a formula on the item's name ("4일차" → +3 days).
    final plan = await repo.createDatabase(title: '여행일정표');
    final date = await repo.addProperty(plan, '날짜', PropType.formula);
    const expression =
        'dateAdd(lookup("날짜 설정", "여행 시작일", "1일차 날짜"), '
        'toNumber(replaceAll(prop("이름"), "[^0-9]", "")) - 1, "days")';
    var snap = (await repo.loadDatabase(plan))!;
    await repo.updateProperty(
      date,
      config: {...snap.property(date)!.config, 'expression': expression},
    );
    await repo.addRow(plan, title: '1일차');
    await repo.addRow(plan, title: '4일차');

    // Formula → 날짜: values filled in, the formula kept as auto-fill.
    snap = (await repo.loadDatabase(plan))!;
    await repo.changePropertyType(snap, snap.property(date)!, PropType.date);
    await repo.refreshAutoFill(plan);
    snap = (await repo.loadDatabase(plan))!;
    expect(snap.property(date)!.type, PropType.date);
    expect(autoExpression(snap.property(date)!), expression);
    expect(await column(plan, '날짜'), {
      '1일차': '2027-01-18',
      '4일차': '2027-01-21',
    });

    // A new day fills itself.
    await repo.addRow(plan, title: '2일차');
    await repo.refreshAutoFill(plan);
    expect((await column(plan, '날짜'))['2일차'], '2027-01-19');

    // Moving the trip: changing 날짜 설정 refills the plan.
    await repo.setCell(start, first, '2027-02-01');
    expect(await repo.refreshAutoFill(settings), 3);
    expect(await column(plan, '날짜'), {
      '1일차': '2027-02-01',
      '4일차': '2027-02-04',
      '2일차': '2027-02-02',
    });

    // Nothing changes → nothing written.
    expect(await repo.refreshAutoFill(plan), 0);
  });

  test('lookup works in a plain formula column too', () async {
    final settings = await repo.createDatabase(title: '날짜 설정');
    final first = await repo.addProperty(settings, '1일차 날짜', PropType.date);
    final start = await repo.addRow(
      settings,
      title: '여행 시작일',
      values: {first: '2027-01-18'},
    );
    final plan = await repo.createDatabase(title: '여행일정표');
    final date = await repo.addProperty(plan, '날짜', PropType.formula);
    await repo.updateProperty(
      date,
      config: {
        'expression':
            'dateAdd(lookup("날짜 설정", "여행 시작일", "1일차 날짜"), '
            'toNumber(replaceAll(prop("이름"), "[^0-9]", "")) - 1, "days")',
      },
    );
    await repo.addRow(plan, title: '4일차');

    Future<String> shown() async {
      final snap = (await repo.loadDatabase(plan))!;
      return snap.text(snap.rows.single.id, snap.property(date)!);
    }

    expect(await shown(), '2027-01-21');
    await repo.setCell(start, first, '2027-03-01');
    expect(await shown(), '2027-03-04');
  });

  test('changing a type converts the values', () async {
    final d = await repo.createDatabase(title: '살 것');
    final kind = await repo.addProperty(d, '분류', PropType.text);
    final price = await repo.addProperty(d, '가격', PropType.text);
    await repo.addRow(d, title: 'a', values: {kind: '과자', price: '1,200엔'});
    await repo.addRow(d, title: 'b', values: {kind: '약', price: '980'});
    await repo.addRow(d, title: 'c', values: {kind: '과자'});

    var snap = (await repo.loadDatabase(d))!;
    await repo.changePropertyType(snap, snap.property(kind)!, PropType.select);
    await repo.changePropertyType(snap, snap.property(price)!, PropType.number);
    snap = (await repo.loadDatabase(d))!;
    final select = snap.property(kind)!;
    expect(select.options.map((o) => o.name), ['과자', '약']);
    expect(
      [for (final r in snap.rows) snap.text(r.id, select)],
      ['과자', '약', '과자'],
    );
    expect(await column(d, '가격'), {'a': 1200, 'b': 980, 'c': null});

    // And back to text.
    await repo.changePropertyType(snap, select, PropType.text);
    expect(await column(d, '분류'), {'a': '과자', 'b': '약', 'c': '과자'});
  });
}
