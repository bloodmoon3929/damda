import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/formula.dart';

void main() {
  final props = <String, Object?>{
    '비용': 12000.0,
    '인원': 3.0,
    '완료': true,
    '이름': '오사카',
  };
  Object? eval(String s) => evaluateFormula(s, (n) => props[n]);

  test('arithmetic and precedence', () {
    expect(eval('1 + 2 * 3'), 7);
    expect(eval('(1 + 2) * 3'), 9);
    expect(eval('-2 + 5'), 3);
    expect(eval('7 % 4'), 3);
  });

  test('prop() and functions', () {
    expect(eval('prop("비용") / prop("인원")'), 4000);
    expect(eval('round(10 / 3, 2)'), 3.33);
    expect(eval('max(1, 5, 3)'), 5);
    expect(eval('sum(1, 2, 3)'), 6);
    expect(eval('prop("이름") + " 여행"'), '오사카 여행');
    expect(eval('length(prop("이름"))'), 3);
  });

  test('conditions', () {
    expect(eval('if(prop("완료"), "끝", "진행")'), '끝');
    expect(eval('if(prop("비용") > 10000 and prop("인원") >= 3, 1, 0)'), 1);
    expect(eval('not prop("완료")'), false);
    expect(eval('prop("이름") == "오사카"'), true);
  });

  test('errors are values, never exceptions', () {
    expect(eval('1 / 0'), isA<FormulaError>());
    expect(eval('prop("없음") + 1'), 1); // missing prop = empty
    expect(eval('foo(1)'), isA<FormulaError>());
    expect(eval('(1 + 2'), isA<FormulaError>());
    expect(eval('"abc'), isA<FormulaError>());
    expect(eval(''), isNull);
  });

  test('display format', () {
    expect(formatFormulaValue(4000.0), '4000');
    expect(formatFormulaValue(3.3300), '3.33');
    expect(formatFormulaValue(true), '✓');
  });

  test('date functions', () {
    final p = {'출발': '2027-01-18', '도착': '2027-01-21'};
    Object? ev(String s) => evaluateFormula(s, (n) => p[n]);
    expect(ev('dateAdd(prop("출발"), 3, "days")'), '2027-01-21');
    expect(ev('dateAdd(prop("출발"), 1, "months")'), '2027-02-18');
    expect(ev('dateAdd(prop("출발"), -1, "weeks")'), '2027-01-11');
    expect(ev('dateBetween(prop("도착"), prop("출발"), "days")'), 3);
    expect(ev('month(prop("출발"))'), 1);
    expect(ev('weekday(prop("출발"))'), 1); // 2027-01-18 is a Monday
    expect(ev('dateAdd("hello", 1, "days")'), isA<FormulaError>());
  });

  test("Notion's trip-day formula (ifs, replaceAll, toNumber)", () {
    const f =
        'ifs(!empty(prop("1일차 날짜")) and !empty(replaceAll(prop("이름"), "[^0-9]", "")), '
        'dateAdd(prop("1일차 날짜"), toNumber(replaceAll(prop("이름"), "[^0-9]", "")) - 1, "days"))';
    Object? day(String title, Object? first) =>
        evaluateFormula(f, (n) => n == '이름' ? title : first);
    expect(day('5일차', '2027-01-18'), '2027-01-22');
    expect(day('1일차', '2027-01-18'), '2027-01-18');
    // No number in the name, or no start date: empty, not an error.
    expect(day('준비물', '2027-01-18'), isNull);
    expect(day('3일차', null), isNull);
  });

  test('only the chosen branch is evaluated', () {
    // The other branch would fail (no date to add to).
    expect(
      evaluateFormula(
        'if(true, 1, dateAdd(prop("x"), 1, "days"))',
        (_) => null,
      ),
      1,
    );
    expect(evaluateFormula('ifs(false, 1, false, 2, 3)', (_) => null), 3);
    expect(evaluateFormula('ifs(false, 1, true, 2, 3)', (_) => null), 2);
    expect(
      evaluateFormula('and(true, or(false, not(false)))', (_) => null),
      true,
    );
    expect(evaluateFormula('toNumber("12일차") * 2', (_) => null), 24);
    expect(
      evaluateFormula('dateSubtract("2027-01-10", 2, "days")', (_) => null),
      '2027-01-08',
    );
  });
}
