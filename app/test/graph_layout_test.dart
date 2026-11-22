import 'package:flutter_test/flutter_test.dart';
import 'package:notes/graph/graph_layout.dart';

void main() {
  test('linked pages end up close, unlinked ones apart, and it settles', () {
    final layout = GraphLayout();
    layout.setGraph(['a', 'b', 'c', 'd'], [('a', 'b'), ('a', 'c'), ('x', 'a')]);
    var ticks = 0;
    while (layout.step()) {
      ticks++;
      expect(ticks, lessThan(2000));
    }
    double dist(String p, String q) =>
        (layout.positions[p]! - layout.positions[q]!).distance;
    expect(dist('a', 'b'), lessThan(dist('b', 'd')));
    expect(dist('a', 'c'), lessThan(dist('c', 'd')));
    expect(dist('b', 'c'), greaterThan(20)); // not on top of each other
    expect(layout.hit(layout.positions['d']!, (_) => 5), 'd');
    expect(layout.hit(const Offset(9999, 9999), (_) => 5), isNull);
  });

  test('adding a page keeps the others in place', () {
    final layout = GraphLayout();
    layout.setGraph(['a', 'b'], [('a', 'b')]);
    while (layout.step()) {}
    final before = layout.positions['a'];
    layout.setGraph(['a', 'b', 'c'], [('a', 'b'), ('c', 'a')]);
    expect(layout.positions['a'], before);
    expect((layout.positions['c']! - before!).distance, lessThan(40));
  });
}
