import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/fractional_index.dart';

void main() {
  test('keyBetween is strictly between bounds', () {
    final rnd = Random(1);
    final keys = <String>[keyBetween(null, null)];
    for (var i = 0; i < 2000; i++) {
      final at = rnd.nextInt(keys.length + 1);
      final lo = at == 0 ? null : keys[at - 1];
      final hi = at == keys.length ? null : keys[at];
      final k = keyBetween(lo, hi);
      if (lo != null) expect(lo.compareTo(k) < 0, isTrue, reason: '$lo < $k');
      if (hi != null) expect(k.compareTo(hi) < 0, isTrue, reason: '$k < $hi');
      expect(k.endsWith('0'), isFalse);
      keys.insert(at, k);
    }
  });

  test('rebalanceKeys keeps the longest ordered run and fills the gaps', () {
    final a = keyBetween(null, null);
    final b = keyBetween(a, null);
    final c = keyBetween(b, null);
    // c moved to the front, plus a new item at the end.
    final result = rebalanceKeys([c, a, b, null]);
    expect(result[1], a);
    expect(result[2], b);
    for (var i = 1; i < result.length; i++) {
      expect(result[i - 1].compareTo(result[i]) < 0, isTrue);
    }
  });
}
