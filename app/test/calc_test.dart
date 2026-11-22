import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/database_repository.dart';
import 'package:notes/data/notes_repository.dart';

void main() {
  test('number formats', () {
    expect(formatNumber(1234567), '1,234,567');
    expect(formatNumber(-1234.5), '-1,234.5');
    expect(formatNumber(120000, format: 'won'), '₩120,000');
    expect(formatNumber(1234.4, format: 'yen'), '¥1,234');
    expect(formatNumber(9.5, format: 'dollar'), r'$9.50');
    expect(formatNumber(12, format: 'percent'), '12%');
  });

  test('column totals over the rows a view shows', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = NotesRepository(db);
    await repo.init();
    final id = await repo.createDatabase(title: '비용');
    final won = await repo.addProperty(id, '원화', PropType.number);
    await repo.updateProperty(won, config: {'format': 'won'});
    final done = await repo.addProperty(id, '결제', PropType.checkbox);
    final when = await repo.addProperty(id, '날짜', PropType.date);
    for (final (t, v, c, d) in [
      ('숙소', 300000, true, '2027-01-18'),
      ('교통', 45000, false, '2027-01-20'),
      ('식비', null, true, null),
    ]) {
      final row = await repo.addRow(id, title: t);
      await repo.setCell(row, won, v);
      await repo.setCell(row, done, c);
      await repo.setCell(row, when, d);
    }
    final snap = (await repo.loadDatabase(id))!;
    final p = snap.property(won)!;
    String? calc(String c, [DbProperty? prop]) =>
        computeCalc(c, snap, snap.rows, prop);
    expect(calc(Calc.sum, p), '₩345,000');
    expect(calc(Calc.average, p), '₩172,500');
    expect(calc(Calc.max, p), '₩300,000');
    expect(calc(Calc.empty, p), '1');
    expect(calc(Calc.count), '3'); // title column
    expect(calc(Calc.checked, snap.property(done)), '2');
    expect(calc(Calc.earliest, snap.property(when)), '2027-01-18');
    expect(calc(Calc.latest, snap.property(when)), '2027-01-20');
    // Only the rows shown (e.g. filtered) count.
    expect(
      computeCalc(Calc.sum, snap, snap.rows.take(1).toList(), p),
      '₩300,000',
    );
    expect(Calc.forType(PropType.number), contains(Calc.sum));
    expect(Calc.forType(PropType.text), isNot(contains(Calc.sum)));
    await db.close();
  });
}
