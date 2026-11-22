import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/links.dart';
import '../providers.dart';
import '../ui/theme.dart';
import 'graph_layout.dart';

final graphDataProvider = StreamProvider<GraphData>(
  (ref) => ref.watch(repositoryProvider).watchGraph(),
);

/// Obsidian-style graph of pages. Edges are page links (`[[...]]`) and,
/// optionally, the page tree (parent → sub-page). Drag to pan, wheel or
/// pinch to zoom, drag a node to move it, click a node to open the page.
/// With [focusPageId] it is a local graph: that page and its neighbors up
/// to [depth] steps away.
class GraphView extends ConsumerStatefulWidget {
  const GraphView({super.key, this.focusPageId, this.depth = 2, this.onOpen});

  final String? focusPageId;
  final int depth;

  /// Called before a page is opened (e.g. to close a dialog).
  final VoidCallback? onOpen;

  @override
  ConsumerState<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends ConsumerState<GraphView>
    with SingleTickerProviderStateMixin {
  final _layout = GraphLayout();
  late final Ticker _ticker = createTicker((_) {
    if (_layout.step()) {
      setState(() {});
    } else {
      _ticker.stop();
      setState(() {});
    }
  });

  bool _treeEdges = true;
  bool _rows = false;
  bool _orphans = true;
  String _query = '';

  // View transform: screen = graph * _scale + center + _pan.
  double _scale = 1;
  Offset _pan = Offset.zero;
  double _startScale = 1;
  Size _size = Size.zero;

  String? _hover;
  String? _dragging;

  Map<String, PageRow> _pages = {};
  List<({String from, String to, bool tree})> _edges = [];
  Map<String, Set<String>> _neighbors = {};
  Object? _lastKey;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _rebuild(GraphData data) {
    final pages = {
      for (final p in data.pages)
        if (_rows || p.kind != 'row') p.id: p,
    };
    var edges = <({String from, String to, bool tree})>[
      for (final l in data.links)
        if (pages.containsKey(l.from) && pages.containsKey(l.to))
          (from: l.from, to: l.to, tree: false),
      if (_treeEdges)
        for (final p in pages.values)
          if (p.parentId != null && pages.containsKey(p.parentId))
            (from: p.parentId!, to: p.id, tree: true),
    ];

    final neighbors = <String, Set<String>>{};
    for (final e in edges) {
      neighbors.putIfAbsent(e.from, () => {}).add(e.to);
      neighbors.putIfAbsent(e.to, () => {}).add(e.from);
    }

    var keep = pages.keys.toSet();
    final focus = widget.focusPageId;
    if (focus != null && pages.containsKey(focus)) {
      keep = {focus};
      var frontier = {focus};
      for (var i = 0; i < widget.depth; i++) {
        frontier = {for (final id in frontier) ...?neighbors[id]}
            .difference(keep);
        keep.addAll(frontier);
      }
    } else if (!_orphans) {
      keep = {
        for (final id in keep)
          if (neighbors.containsKey(id)) id,
      };
    }
    pages.removeWhere((id, _) => !keep.contains(id));
    edges = [
      for (final e in edges)
        if (keep.contains(e.from) && keep.contains(e.to)) e,
    ];

    _pages = pages;
    _edges = edges;
    _neighbors = neighbors;
    _layout.setGraph(pages.keys.toList(), [
      for (final e in edges) (e.from, e.to),
    ]);
    if (focus != null) _layout.pinned.add(focus);
    if (!_ticker.isActive) _ticker.start();
  }

  double _radius(String id) => math.min(
    16,
    4 + math.sqrt((_neighbors[id]?.length ?? 0).toDouble()) * 2.5,
  );

  Offset get _center => Offset(_size.width / 2, _size.height / 2);
  Offset _toScreen(Offset g) => g * _scale + _center + _pan;
  Offset _toGraph(Offset s) => (s - _center - _pan) / _scale;

  String? _hitAt(Offset screen) =>
      _layout.hit(_toGraph(screen), (id) => _radius(id) + 4 / _scale);

  void _zoom(double factor, Offset focal) {
    final before = _toGraph(focal);
    _scale = (_scale * factor).clamp(0.15, 4.0);
    _pan += focal - _toScreen(before);
    setState(() {});
  }

  void _open(String id) {
    widget.onOpen?.call();
    ref.read(screenProvider.notifier).openPage(id);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(graphDataProvider).value;
    final key = (data, _treeEdges, _rows, _orphans);
    if (data != null && key != _lastKey) {
      _lastKey = key;
      // After this frame: _rebuild starts the ticker, which calls setState.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _rebuild(data));
      });
    }
    final colors = context.noteColors;
    final accent = Theme.of(context).colorScheme.primary;
    final query = _query.trim().toLowerCase();

    final canvas = LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              _zoom(e.scrollDelta.dy > 0 ? 0.9 : 1.1, e.localPosition);
            }
          },
          child: MouseRegion(
            cursor: _hover != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.grab,
            onHover: (e) {
              final h = _hitAt(e.localPosition);
              if (h != _hover) setState(() => _hover = h);
            },
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              onTapUp: (d) {
                final id = _hitAt(d.localPosition);
                if (id != null) _open(id);
              },
              onScaleStart: (d) {
                _startScale = _scale;
                _dragging = d.pointerCount == 1
                    ? _hitAt(d.localFocalPoint)
                    : null;
                if (_dragging != null) _layout.pinned.add(_dragging!);
              },
              onScaleUpdate: (d) {
                final drag = _dragging;
                if (drag != null) {
                  _layout.positions[drag] = _toGraph(d.localFocalPoint);
                  _layout.reheat(0.3);
                  if (!_ticker.isActive) _ticker.start();
                  setState(() {});
                } else if (d.pointerCount > 1) {
                  _zoom(_startScale * d.scale / _scale, d.localFocalPoint);
                  _pan += d.focalPointDelta;
                } else {
                  setState(() => _pan += d.focalPointDelta);
                }
              },
              onScaleEnd: (_) {
                final drag = _dragging;
                if (drag != null && drag != widget.focusPageId) {
                  _layout.pinned.remove(drag);
                }
                _dragging = null;
              },
              child: CustomPaint(
                size: Size.infinite,
                painter: _GraphPainter(
                  layout: _layout,
                  pages: _pages,
                  edges: _edges,
                  neighbors: _neighbors,
                  radius: _radius,
                  toScreen: _toScreen,
                  scale: _scale,
                  hover: _hover ?? _dragging,
                  focus: widget.focusPageId,
                  inbox: ref.watch(inboxIdProvider),
                  query: query,
                  colors: colors,
                  accent: accent,
                ),
              ),
            ),
          ),
        );
      },
    );

    final controls = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (widget.focusPageId == null)
          SizedBox(
            width: 200,
            height: 36,
            child: TextField(
              decoration: const InputDecoration(
                hintText: '페이지 찾기',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        FilterChip(
          label: const Text('하위 페이지 연결'),
          selected: _treeEdges,
          onSelected: (v) => setState(() => _treeEdges = v),
        ),
        FilterChip(
          label: const Text('DB 항목'),
          selected: _rows,
          onSelected: (v) => setState(() => _rows = v),
        ),
        if (widget.focusPageId == null)
          FilterChip(
            label: const Text('연결 없는 페이지'),
            selected: _orphans,
            onSelected: (v) => setState(() => _orphans = v),
          ),
        IconButton(
          tooltip: '가운데로',
          icon: const Icon(Icons.center_focus_strong_outlined),
          onPressed: () => setState(() {
            _pan = Offset.zero;
            _scale = 1;
          }),
        ),
      ],
    );

    return Stack(
      children: [
        Positioned.fill(child: ClipRect(child: canvas)),
        Positioned(left: 16, top: 12, right: 16, child: controls),
        if (_pages.isEmpty && data != null)
          Center(
            child: Text(
              '표시할 페이지가 없어요',
              style: TextStyle(color: colors.textMuted),
            ),
          ),
      ],
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.layout,
    required this.pages,
    required this.edges,
    required this.neighbors,
    required this.radius,
    required this.toScreen,
    required this.scale,
    required this.hover,
    required this.focus,
    required this.inbox,
    required this.query,
    required this.colors,
    required this.accent,
  });

  final GraphLayout layout;
  final Map<String, PageRow> pages;
  final List<({String from, String to, bool tree})> edges;
  final Map<String, Set<String>> neighbors;
  final double Function(String) radius;
  final Offset Function(Offset) toScreen;
  final double scale;
  final String? hover;
  final String? focus;
  final String inbox;
  final String query;
  final NoteColors colors;
  final Color accent;

  bool _matches(PageRow p) =>
      query.isNotEmpty && p.title.toLowerCase().contains(query);

  @override
  void paint(Canvas canvas, Size size) {
    final lit = hover == null ? null : {hover!, ...?neighbors[hover]};
    final searching = query.isNotEmpty;

    for (final e in edges) {
      final a = layout.positions[e.from];
      final b = layout.positions[e.to];
      if (a == null || b == null) continue;
      final active = lit != null && lit.contains(e.from) && lit.contains(e.to);
      final dim = (lit != null && !active) || searching;
      final paint = Paint()
        ..strokeWidth = active ? 1.6 : (e.tree ? 0.8 : 1.1)
        ..color = active
            ? accent.withValues(alpha: 0.8)
            : colors.textMuted.withValues(
                alpha: (e.tree ? 0.22 : 0.45) * (dim ? 0.35 : 1),
              );
      canvas.drawLine(toScreen(a), toScreen(b), paint);
    }

    for (final MapEntry(key: id, value: page) in pages.entries) {
      final g = layout.positions[id];
      if (g == null) continue;
      final p = toScreen(g);
      if (p.dx < -50 ||
          p.dy < -50 ||
          p.dx > size.width + 50 ||
          p.dy > size.height + 50) {
        continue;
      }
      final r = radius(id) * math.sqrt(scale).clamp(0.6, 1.6);
      final isLit = lit?.contains(id) ?? false;
      final match = _matches(page);
      final dim = (lit != null && !isLit) || (searching && !match);
      final base = switch (page.kind) {
        'database' => const Color(0xFF4A90D9),
        'album' => const Color(0xFF3FA66B),
        'row' => colors.textMuted.withValues(alpha: 0.7),
        _ => id == inbox ? const Color(0xFFE5883A) : colors.textMuted,
      };
      final fill = id == hover || id == focus || match ? accent : base;
      canvas.drawCircle(
        p,
        r,
        Paint()..color = fill.withValues(alpha: dim ? 0.25 : 1),
      );

      final showLabel =
          scale > 0.75 || isLit || match || id == focus || pages.length < 25;
      if (!showLabel) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: page.title.isEmpty ? '제목 없음' : page.title,
          style: TextStyle(
            fontSize: id == hover ? 13 : 11.5,
            fontWeight: id == hover ? FontWeight.w600 : FontWeight.w400,
            color: colors.text.withValues(alpha: dim ? 0.3 : 0.9),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 160);
      tp.paint(canvas, p + Offset(-tp.width / 2, r + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => true;
}
