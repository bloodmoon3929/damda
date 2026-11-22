import 'dart:math' as math;
import 'dart:ui';

/// Force-directed layout (like Obsidian's graph): nodes push each other
/// apart, links pull their ends together, a weak pull keeps everything
/// near the center. Call [step] every frame until it returns false.
class GraphLayout {
  GraphLayout({math.Random? random}) : _random = random ?? math.Random(7);

  final math.Random _random;
  final positions = <String, Offset>{};
  final _velocity = <String, Offset>{};

  /// Nodes held by the pointer (not moved by forces).
  final pinned = <String>{};

  List<String> _nodes = const [];
  List<(String, String)> _edges = const [];
  double _heat = 1;

  static const _linkLength = 70.0;
  static const _repulsion = 5200.0;
  static const _spring = 0.04;
  static const _gravity = 0.012;
  static const _damping = 0.82;

  bool get settled => _heat < 0.005;

  /// New nodes start near a linked node (or at random); existing ones keep
  /// their place so the graph doesn't jump when a page is added.
  void setGraph(List<String> nodes, List<(String, String)> edges) {
    final ids = nodes.toSet();
    _nodes = nodes;
    _edges = [
      for (final e in edges)
        if (ids.contains(e.$1) && ids.contains(e.$2) && e.$1 != e.$2) e,
    ];
    positions.removeWhere((id, _) => !ids.contains(id));
    _velocity.removeWhere((id, _) => !ids.contains(id));
    final spread = 40 * math.sqrt(nodes.length + 1);
    for (final id in nodes) {
      if (positions.containsKey(id)) continue;
      Offset? near;
      for (final e in _edges) {
        final other = e.$1 == id ? e.$2 : (e.$2 == id ? e.$1 : null);
        if (other != null && positions[other] != null) {
          near = positions[other];
          break;
        }
      }
      final jitter = Offset(
        (_random.nextDouble() - 0.5) * (near == null ? spread * 2 : 40),
        (_random.nextDouble() - 0.5) * (near == null ? spread * 2 : 40),
      );
      positions[id] = (near ?? Offset.zero) + jitter;
      _velocity[id] = Offset.zero;
    }
    reheat();
  }

  void reheat([double heat = 1]) => _heat = math.max(_heat, heat);

  /// One simulation tick. Returns whether anything still moves.
  bool step() {
    if (settled) return false;
    final force = {for (final id in _nodes) id: Offset.zero};
    final n = _nodes.length;
    for (var i = 0; i < n; i++) {
      final a = _nodes[i];
      final pa = positions[a]!;
      for (var j = i + 1; j < n; j++) {
        final b = _nodes[j];
        var d = pa - positions[b]!;
        var dist2 = d.distanceSquared;
        if (dist2 < 0.01) {
          d = Offset(_random.nextDouble() - 0.5, _random.nextDouble() - 0.5);
          dist2 = 0.25;
        }
        if (dist2 > 600 * 600) continue; // far apart: negligible
        final f = d / math.sqrt(dist2) * (_repulsion / dist2);
        force[a] = force[a]! + f;
        force[b] = force[b]! - f;
      }
    }
    for (final (a, b) in _edges) {
      final d = positions[b]! - positions[a]!;
      final dist = d.distance;
      if (dist < 0.01) continue;
      final f = d / dist * ((dist - _linkLength) * _spring);
      force[a] = force[a]! + f;
      force[b] = force[b]! - f;
    }
    var moved = 0.0;
    for (final id in _nodes) {
      if (pinned.contains(id)) {
        _velocity[id] = Offset.zero;
        continue;
      }
      final p = positions[id]!;
      var v = (_velocity[id]! + force[id]! - p * _gravity) * _damping;
      // Cap per-tick speed while hot, so starts aren't explosive.
      final max = 30 * _heat + 1;
      if (v.distance > max) v = v / v.distance * max;
      _velocity[id] = v * _heat.clamp(0.05, 1);
      positions[id] = p + _velocity[id]!;
      moved += _velocity[id]!.distance;
    }
    _heat *= 0.985;
    if (n > 0 && moved / n < 0.02) _heat *= 0.9;
    return !settled;
  }

  /// The node at [point] (graph coordinates), if any.
  String? hit(Offset point, double Function(String id) radius) {
    String? best;
    var bestDist = double.infinity;
    for (final id in _nodes) {
      final d = (positions[id]! - point).distance;
      if (d <= radius(id) + 4 && d < bestDist) {
        best = id;
        bestDist = d;
      }
    }
    return best;
  }
}
