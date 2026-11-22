import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/asset_repository.dart';
import '../data/plan_map_repository.dart';
import '../providers.dart';
import 'download.dart';
import 'file_drop.dart';
import 'icon_picker.dart';
import 'photo_picker.dart';
import 'theme.dart';

/// 계획 지도: cards for the smaller plans, arrows into the goal they feed.
///
/// - Desktop: double-click empty space to add a card, drag a card to move
///   it, drag from the dot under a card onto another card for an arrow,
///   right-click for its menu, Delete removes the selected card.
/// - Phone: long-press empty space to add, long-press a card for its menu
///   ("연결하기" then tap the target card).
/// - Click an arrow to remove it. The ○ on a card marks it done; a card
///   whose needed cards aren't all done is dimmed.
class PlanMapCanvas extends ConsumerStatefulWidget {
  const PlanMapCanvas({super.key, required this.pageId});

  final String pageId;

  @override
  ConsumerState<PlanMapCanvas> createState() => _PlanMapCanvasState();
}

const _cardW = 128.0;
const _cardH = 124.0;
const _canvas = Size(6000, 4000);
const _handle = 9.0;
const _done = Color(0xFF2F6FED); // blue: done
const _todo = Color(0xFFE5484D); // red: not yet
const _accent = Color(0xFF2383E2);
const _labelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

Size _labelSize(String title) {
  final tp = TextPainter(
    text: TextSpan(text: title.isEmpty ? '제목' : title, style: _labelStyle),
    textDirection: TextDirection.ltr,
  )..layout();
  return Size(tp.width + 12, tp.height + 8);
}

enum _Mode { pan, move, connect }

class _PlanMapCanvasState extends ConsumerState<PlanMapCanvas> {
  final _view = TransformationController();
  final _focus = FocusNode();
  StreamSubscription<PlanMap>? _sub;
  PlanMap _map = const PlanMap([], []);
  bool _loaded = false;
  bool _placed = false;
  Size _viewport = Size.zero;

  /// Cards being dragged: where they are until the write comes back.
  final _moved = <String, Offset>{};
  String? _selected;
  String? _hover;

  // The current one-finger gesture on the canvas.
  Offset? _downScene;
  _Mode _mode = _Mode.pan;
  String? _active;
  Offset _grab = Offset.zero;
  Matrix4? _frozen;
  Offset? _pointer;

  /// The "할 일" panel on the right is open (cards ready to work on).
  bool _panel = false;

  double get _panelWidth => math.min(340, _viewport.width * 0.85);

  /// Where a press on a card's status band started.
  Offset? _bandDown;

  /// Phones: "연결하기" picked on this card, waiting for the target.
  String? _connectFrom;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(repositoryProvider).watchPlanMap(widget.pageId).listen((
      map,
    ) {
      if (!mounted) return;
      setState(() {
        _map = map;
        _loaded = true;
        _moved.removeWhere((key, at) {
          final c = map.card(key);
          return c == null ||
              (c.x == at.dx.roundToDouble() && c.y == at.dy.roundToDouble());
        });
      });
      _placeOnce();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _view.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _pageId => widget.pageId;

  Offset _topLeft(MapCard c) => _moved[c.key] ?? Offset(c.x, c.y);

  Rect _rect(MapCard c) =>
      _topLeft(c) &
      (c.isLabel ? _labelSize(c.title) : const Size(_cardW, _cardH));

  MapCard? _cardAt(Offset scene, {String? except}) {
    for (final c in _map.cards.reversed) {
      if (c.key != except && _rect(c).inflate(4).contains(scene)) return c;
    }
    return null;
  }

  MapCard? _handleAt(Offset scene) {
    for (final c in _map.cards.reversed) {
      if ((scene - _rect(c).bottomCenter).distance <= _handle + 8) return c;
    }
    return null;
  }

  Offset _viewCenterScene() =>
      _view.toScene(Offset(_viewport.width / 2, _viewport.height / 2));

  // ---- view ----

  void _placeOnce() {
    if (_placed || !_loaded || _viewport == Size.zero) return;
    _placed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  /// Shows every card (or the middle of an empty map).
  void _fit() {
    if (_viewport == Size.zero) return;
    Rect? bounds;
    for (final c in _map.cards) {
      final r = _rect(c);
      bounds = bounds == null ? r : bounds.expandToInclude(r);
    }
    bounds =
        (bounds ??
                Rect.fromCenter(
                  center: _canvas.center(Offset.zero),
                  width: 600,
                  height: 400,
                ))
            .inflate(60);
    final s = math
        .min(_viewport.width / bounds.width, _viewport.height / bounds.height)
        .clamp(0.25, 1.0);
    _view.value = Matrix4.translationValues(
      _viewport.width / 2 - bounds.center.dx * s,
      _viewport.height / 2 - bounds.center.dy * s,
      0,
    )..multiply(Matrix4.diagonal3Values(s, s, 1));
  }

  // ---- one-finger gestures: move a card, draw an arrow, or pan ----

  void _onStart(ScaleStartDetails d) {
    final at = _downScene;
    _mode = _Mode.pan;
    if (d.pointerCount != 1 || at == null || _connectFrom != null) return;
    final handle = _handleAt(at);
    final card = handle == null ? _cardAt(at) : null;
    if (handle != null) {
      _mode = _Mode.connect;
      _active = handle.key;
      _pointer = at;
    } else if (card != null) {
      _mode = _Mode.move;
      _active = card.key;
      _grab = at - _topLeft(card);
      _selected = card.key;
    } else {
      return;
    }
    _frozen = _view.value.clone();
    setState(() {});
  }

  void _onUpdate(ScaleUpdateDetails d) {
    if (_mode == _Mode.pan) return;
    // Keep the view still while a card or an arrow is being dragged.
    _view.value = _frozen!;
    final scene = _view.toScene(d.localFocalPoint);
    setState(() {
      if (_mode == _Mode.move) {
        final p = scene - _grab;
        _moved[_active!] = Offset(
          p.dx.clamp(0, _canvas.width - _cardW),
          p.dy.clamp(0, _canvas.height - _cardH),
        );
      } else {
        _pointer = scene;
      }
    });
  }

  Future<void> _onEnd(ScaleEndDetails d) async {
    final mode = _mode, key = _active, pointer = _pointer;
    _mode = _Mode.pan;
    _active = null;
    _pointer = null;
    _frozen = null;
    if (key == null) return;
    final card = _map.card(key);
    final repo = ref.read(repositoryProvider);
    if (mode == _Mode.move && card != null && _moved[key] != null) {
      final at = _moved[key]!;
      setState(() {});
      await repo.updateMapCard(_pageId, card, x: at.dx, y: at.dy);
    } else if (mode == _Mode.connect && pointer != null) {
      final target = _cardAt(pointer, except: key);
      setState(() {});
      if (target != null) {
        await repo.addMapEdge(_pageId, _map, key, target.key);
      }
    }
  }

  // ---- taps ----

  Future<void> _tapCard(MapCard c) async {
    _focus.requestFocus();
    final from = _connectFrom;
    if (from != null) {
      setState(() => _connectFrom = null);
      await ref.read(repositoryProvider).addMapEdge(_pageId, _map, from, c.key);
      return;
    }
    setState(() => _selected = c.key);
  }

  void _tapBackground(TapUpDetails d) {
    _focus.requestFocus();
    if (_connectFrom != null) {
      setState(() => _connectFrom = null);
      return;
    }
    final edge = _edgeAt(d.localPosition);
    if (edge != null) {
      _edgeMenu(edge, d.globalPosition);
      return;
    }
    setState(() => _selected = null);
  }

  MapEdge? _edgeAt(Offset scene) {
    final scale = _view.value.getMaxScaleOnAxis();
    for (final e in _map.edges) {
      final from = _map.card(e.from), to = _map.card(e.to);
      if (from == null || to == null) continue;
      final (a, c1, c2, b) = _curve(_rect(from), _rect(to));
      for (var i = 0; i <= 24; i++) {
        final p = _bezier(a, c1, c2, b, i / 24);
        if ((p - scene).distance < 10 / scale) return e;
      }
    }
    return null;
  }

  Future<void> _edgeMenu(MapEdge e, Offset global) async {
    final from = _map.card(e.from)?.title ?? '';
    final to = _map.card(e.to)?.title ?? '';
    final choice = await _menu(global, [
      _item('cut', Icons.link_off, '연결 끊기  $from → $to'),
    ]);
    if (choice == 'cut') {
      await ref.read(repositoryProvider).deleteMapEdge(_pageId, e);
    }
  }

  Future<String?> _menu(Offset global, List<PopupMenuEntry<String>> items) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        global & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String text, {
    Color? color,
  }) => PopupMenuItem(
    value: value,
    height: 38,
    child: Row(
      children: [
        Icon(icon, size: 18, color: color ?? context.noteColors.textMuted),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: color == _todo ? const TextStyle(color: _todo) : null,
          ),
        ),
      ],
    ),
  );

  Future<void> _cardMenu(MapCard c, Offset global) async {
    setState(() => _selected = c.key);
    final repo = ref.read(repositoryProvider);
    final links = [
      for (final e in _map.edges)
        if (e.from == c.key || e.to == c.key) e,
    ];
    final choice = await _menu(global, [
      if (!c.isLabel)
        _item(
          'done',
          c.done ? Icons.schedule : Icons.check_circle_outline,
          c.done ? '미완성' : '완성',
          color: c.done ? _todo : _done,
        ),
      _item(
        'edit',
        Icons.edit_outlined,
        c.isLabel ? '이름 바꾸기' : '편집 (메모·체크리스트·사진)',
      ),
      if (!c.isLabel)
        _item(
          'picture',
          Icons.image_outlined,
          c.image.isEmpty ? '사진 넣기…' : '사진 바꾸기…',
        ),
      if (c.image.isNotEmpty)
        _item('download', Icons.download_outlined, '사진 다운로드'),
      _item('connect', Icons.arrow_downward, '다른 카드로 화살표 잇기'),
      if (links.isNotEmpty) const PopupMenuDivider(),
      for (final e in links)
        _item(
          'cut:${e.blockId}',
          Icons.link_off,
          e.from == c.key
              ? '연결 끊기  → ${_map.card(e.to)?.title ?? ''}'
              : '연결 끊기  ← ${_map.card(e.from)?.title ?? ''}',
        ),
      const PopupMenuDivider(),
      _item('delete', Icons.delete_outline, '삭제', color: _todo),
    ]);
    switch (choice) {
      case 'edit':
        await _edit(c);
      case 'done':
        await repo.updateMapCard(_pageId, c, done: !c.done);
      case 'download':
        final id = assetIdFromUrl(c.image);
        final asset = id == null
            ? null
            : await (repo.db.select(
                repo.db.assets,
              )..where((a) => a.id.equals(id))).getSingleOrNull();
        if (asset != null && mounted) {
          await downloadAssets(context, repo, [asset]);
        }
      case 'picture':
        final url = await _pickPicture();
        if (!mounted) return;
        if (url != null) await repo.updateMapCard(_pageId, c, image: url);
      case 'connect':
        setState(() => _connectFrom = c.key);
      case 'delete':
        await repo.deleteMapCard(_pageId, _map, c);
      case final String s when s.startsWith('cut:'):
        final id = s.substring(4);
        final edge = links.where((e) => e.blockId == id).firstOrNull;
        if (edge != null) await repo.deleteMapEdge(_pageId, edge);
    }
  }

  // ---- adding and editing ----

  Future<_CardEdit?> _askCard({MapCard? card, required bool label}) =>
      showDialog<_CardEdit>(
        context: context,
        builder: (_) =>
            _CardEditor(card: card, label: label, pickPicture: _pickPicture),
      );

  /// A picture for a card: from the 사진 보관함 under this map (tabs per
  /// album) or a file, which then also goes into that album.
  Future<String?> _pickPicture() async {
    final asset = await pickPhoto(
      context,
      ref.read(repositoryProvider),
      _pageId,
    );
    return asset == null ? null : assetUrl(asset.id);
  }

  Future<void> _add(Offset center, {bool label = false}) async {
    final answer = await _askCard(label: label);
    if (answer == null) return;
    await _addAt(
      center,
      title: answer.title,
      icon: answer.icon,
      image: answer.image,
      note: answer.note,
      checks: answer.checks,
      done: answer.done,
      label: label,
    );
  }

  Future<void> _addAt(
    Offset center, {
    String title = '',
    String icon = '',
    String image = '',
    String note = '',
    List<MapCheck> checks = const [],
    bool done = false,
    bool label = false,
  }) async {
    final size = label ? _labelSize(title) : const Size(_cardW, _cardH);
    final key = await ref
        .read(repositoryProvider)
        .addMapCard(
          _pageId,
          x: (center.dx - size.width / 2).clamp(0, _canvas.width - size.width),
          y: (center.dy - size.height / 2).clamp(
            0,
            _canvas.height - size.height,
          ),
          title: title,
          icon: icon,
          image: image,
          note: note,
          checks: checks,
          done: done,
          label: label,
        );
    if (mounted) setState(() => _selected = key);
  }

  /// Picture files dropped from the file manager: a card each (and into
  /// the 사진 보관함 under this map, if there is one).
  Future<void> _dropFiles(List<String> paths, Offset local) async {
    final repo = ref.read(repositoryProvider);
    var at = _view.toScene(local);
    for (final path in paths) {
      final asset = await repo.importAsset(path, pageId: _pageId);
      if (!asset.mime.startsWith('image/')) continue;
      final name = asset.name.contains('.')
          ? asset.name.substring(0, asset.name.lastIndexOf('.'))
          : asset.name;
      await _addAt(at, title: name, image: assetUrl(asset.id));
      at += const Offset(_cardW + 24, 0);
    }
  }

  Future<void> _edit(MapCard c) async {
    final answer = await _askCard(card: c, label: c.isLabel);
    if (answer == null) return;
    await ref
        .read(repositoryProvider)
        .updateMapCard(
          _pageId,
          c,
          title: answer.title,
          icon: answer.icon,
          image: answer.image,
          note: answer.note,
          checks: answer.checks,
          done: answer.done,
        );
  }

  Future<void> _backgroundMenu(Offset scene, Offset global) async {
    final choice = await _menu(global, [
      _item('card', Icons.add_box_outlined, '여기에 카드 추가'),
      _item('label', Icons.title, '여기에 제목 추가'),
    ]);
    if (choice == 'card') await _add(scene);
    if (choice == 'label') await _add(scene, label: true);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final c = _selected == null ? null : _map.card(_selected!);
    if (c == null) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.delete) {
      ref.read(repositoryProvider).deleteMapCard(_pageId, _map, c);
      setState(() => _selected = null);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.f2 ||
        e.logicalKey == LogicalKeyboardKey.enter) {
      _edit(c);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.space && !c.isLabel) {
      ref.read(repositoryProvider).updateMapCard(_pageId, c, done: !c.done);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        _placeOnce();
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Positioned.fill(
                child: FileDropTarget(
                  onDragDone: (paths, at) => _dropFiles([
                    for (final path in paths)
                      if (FileSystemEntity.typeSync(path) ==
                          FileSystemEntityType.file)
                        path,
                  ], at),
                  child: Listener(
                    onPointerDown: (e) =>
                        _downScene = _view.toScene(e.localPosition),
                    child: InteractiveViewer(
                      transformationController: _view,
                      constrained: false,
                      minScale: 0.2,
                      maxScale: 3,
                      boundaryMargin: const EdgeInsets.all(600),
                      onInteractionStart: _onStart,
                      onInteractionUpdate: _onUpdate,
                      onInteractionEnd: _onEnd,
                      child: _surface(colors),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: _panel ? _panelWidth + 12 : 12,
                child: _toolbar(colors),
              ),
              if (_panel)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: _panelWidth,
                  child: _readyPanel(colors),
                )
              else
                Positioned(
                  right: 0,
                  top: math.max(60, _viewport.height / 2 - 32),
                  child: _panelTab(colors),
                ),
              if (_connectFrom != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: Center(
                    child: Material(
                      color: _accent,
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => setState(() => _connectFrom = null),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            '화살표를 받을 카드를 누르세요 · 취소',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_loaded && _map.cards.isEmpty)
                IgnorePointer(
                  child: Center(
                    child: Text(
                      _isDesktop
                          ? '빈 곳을 두 번 클릭해 카드를 추가하세요.\n'
                                '카드 아래 점을 끌어 다른 카드에 놓으면 화살표가 생겨요.\n'
                                '사진 파일을 끌어다 놓으면 사진 카드가 돼요.'
                          : '빈 곳을 길게 눌러 카드를 추가하세요.\n'
                                '카드를 길게 눌러 "연결하기"로 화살표를 만들어요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.textMuted, height: 1.6),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ---- "할 일": the cards whose needed cards are all done ----

  /// Moves the view so [c] is in the middle of the visible map.
  void _focusCard(MapCard c) {
    final s = _view.value.getMaxScaleOnAxis();
    final visible = _viewport.width - (_panel ? _panelWidth : 0);
    final center = _rect(c).center;
    _view.value = Matrix4.translationValues(
      visible / 2 - center.dx * s,
      _viewport.height / 2 - center.dy * s,
      0,
    )..multiply(Matrix4.diagonal3Values(s, s, 1));
    setState(() => _selected = c.key);
  }

  Future<void> _toggleCheck(MapCard c, int i) {
    final checks = [...c.checks];
    checks[i] = checks[i].toggled();
    return ref
        .read(repositoryProvider)
        .updateMapCard(_pageId, c, checks: checks);
  }

  Widget _panelTab(NoteColors colors) {
    final count = _map.ready.length;
    return Tooltip(
      message: '할 일',
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 3,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
        child: InkWell(
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(10),
          ),
          onTap: () => setState(() => _panel = true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Column(
              children: [
                Icon(Icons.chevron_left, size: 22, color: colors.text),
                if (count > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: _todo,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _readyPanel(NoteColors colors) {
    final ready = _map.ready;
    final waiting = _map.cards.where(_map.blocked).length;
    final allDone = _map.total > 0 && _map.doneCount == _map.total;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.divider)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '닫기',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => setState(() => _panel = false),
                  ),
                  const Text(
                    '할 일',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '${ready.length}개',
                    style: TextStyle(color: colors.textMuted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Expanded(
              child: ready.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          allDone
                              ? '모두 완성'
                              : _map.total == 0
                              ? '카드 없음'
                              : '할 일 없음',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.textMuted),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: ready.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _readyCard(ready[i], colors),
                    ),
            ),
            if (waiting > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  '대기 $waiting개',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _readyCard(MapCard c, NoteColors colors) {
    final selected = _selected == c.key;
    final finished = c.checks.isNotEmpty && c.checksDone == c.checks.length;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? _accent : colors.divider,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _focusCard(c),
            onDoubleTap: () => _edit(c),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
              child: Row(
                children: [
                  if (c.image.isNotEmpty)
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: _Picture(url: c.image),
                    )
                  else if (c.icon.isNotEmpty)
                    Text(c.icon, style: const TextStyle(fontSize: 20)),
                  if (c.image.isNotEmpty || c.icon.isNotEmpty)
                    const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.title.isEmpty ? '이름 없음' : c.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (c.checks.isNotEmpty)
                    Text(
                      '${c.checksDone}/${c.checks.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: finished ? _done : colors.textMuted,
                      ),
                    ),
                  IconButton(
                    tooltip: '편집',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: colors.textMuted,
                    ),
                    onPressed: () => _edit(c),
                  ),
                ],
              ),
            ),
          ),
          if (c.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(
                c.note,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: colors.textMuted,
                  height: 1.4,
                ),
              ),
            ),
          for (var i = 0; i < c.checks.length; i++)
            InkWell(
              onTap: () => _toggleCheck(c, i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      c.checks[i].done
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: c.checks[i].done ? _done : colors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        c.checks[i].text,
                        style: TextStyle(
                          fontSize: 13,
                          color: c.checks[i].done
                              ? colors.textMuted
                              : colors.text,
                          decoration: c.checks[i].done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
            child: Align(
              alignment: Alignment.centerRight,
              // One plain button; it turns blue once every step is done.
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: finished ? Colors.white : _done,
                  backgroundColor: finished ? _done : null,
                  side: const BorderSide(color: _done),
                ),
                onPressed: () => ref
                    .read(repositoryProvider)
                    .updateMapCard(_pageId, c, done: true),
                child: const Text('완성'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(NoteColors colors) {
    final total = _map.total;
    Widget button(IconData icon, String tip, VoidCallback onTap) =>
        IconButton(tooltip: tip, icon: Icon(icon, size: 20), onPressed: onTap);
    return Material(
      elevation: 2,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (total > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '완성 ${_map.doneCount}/$total',
                  style: TextStyle(
                    fontSize: 13,
                    color: _map.doneCount == total ? _done : colors.text,
                  ),
                ),
              ),
            button(
              Icons.add_box_outlined,
              '카드 추가',
              () => _add(_viewCenterScene()),
            ),
            button(
              Icons.title,
              '제목 추가',
              () => _add(_viewCenterScene(), label: true),
            ),
            button(Icons.fit_screen_outlined, '전체 보기', _fit),
          ],
        ),
      ),
    );
  }

  Widget _surface(NoteColors colors) {
    final dragging = _mode == _Mode.connect ? _active : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _tapBackground,
      onDoubleTapDown: _isDesktop ? (d) => _downScene = d.localPosition : null,
      onDoubleTap: _isDesktop
          ? () {
              final at = _downScene;
              if (at != null) _add(at);
            }
          : null,
      onLongPressStart: _isDesktop ? null : (d) => _add(d.localPosition),
      onSecondaryTapUp: (d) =>
          _backgroundMenu(d.localPosition, d.globalPosition),
      child: SizedBox.fromSize(
        size: _canvas,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ArrowPainter(
                  map: _map,
                  rect: _rect,
                  muted: colors.textMuted,
                  dragFrom: dragging == null ? null : _map.card(dragging),
                  dragTo: _pointer,
                ),
              ),
            ),
            for (final c in _map.cards) ..._cardWidgets(c, colors),
          ],
        ),
      ),
    );
  }

  List<Widget> _cardWidgets(MapCard c, NoteColors colors) {
    final r = _rect(c);
    final selected = _selected == c.key || _connectFrom == c.key;
    final showHandle =
        selected ||
        _hover == c.key ||
        (_mode == _Mode.connect && _active == c.key);
    final body = c.isLabel
        ? _label(c, colors, selected)
        : _card(c, colors, selected);
    return [
      Positioned(
        left: r.left,
        top: r.top,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = c.key),
          onExit: (_) => setState(() => _hover = null),
          cursor: SystemMouseCursors.move,
          child: GestureDetector(
            onTap: () => _tapCard(c),
            onDoubleTap: _isDesktop ? () => _edit(c) : null,
            onSecondaryTapUp: (d) => _cardMenu(c, d.globalPosition),
            onLongPressStart: _isDesktop
                ? null
                : (d) => _cardMenu(c, d.globalPosition),
            child: body,
          ),
        ),
      ),
      if (showHandle)
        Positioned(
          left: r.bottomCenter.dx - _handle,
          top: r.bottomCenter.dy - _handle,
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onEnter: (_) => setState(() => _hover = c.key),
            child: Container(
              width: _handle * 2,
              height: _handle * 2,
              decoration: BoxDecoration(
                color: _accent,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _label(MapCard c, NoteColors colors, bool selected) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(4),
      border: selected ? Border.all(color: _accent, width: 1.5) : null,
    ),
    child: Text(
      c.title.isEmpty ? '제목' : c.title,
      style: _labelStyle.copyWith(color: colors.text),
    ),
  );

  Widget _card(MapCard c, NoteColors colors, bool selected) {
    final needs = _map.needs(c.key);
    final ready = needs.where((n) => n.done).length;
    final blocked = _map.blocked(c);
    final Widget? media = c.image.isNotEmpty
        ? ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: _Picture(url: c.image),
          )
        : c.icon.isNotEmpty
        ? FittedBox(child: Text(c.icon, style: const TextStyle(fontSize: 30)))
        : null;
    return Opacity(
      opacity: blocked ? 0.5 : 1,
      child: Container(
        width: _cardW,
        height: _cardH,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _accent : colors.divider,
            width: selected ? 2 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status band: red = not done yet, blue = done. One click
            // switches it (a raw pointer listener: no wait for the card's
            // double-click, and dragging the card doesn't count).
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Listener(
                onPointerDown: (e) => _bandDown = e.position,
                onPointerUp: (e) {
                  final down = _bandDown;
                  _bandDown = null;
                  if (down != null && (e.position - down).distance < 6) {
                    ref
                        .read(repositoryProvider)
                        .updateMapCard(_pageId, c, done: !c.done);
                  }
                },
                child: Container(
                  height: 22,
                  color: c.done ? _done : _todo,
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        c.done ? Icons.check : Icons.schedule,
                        size: 13,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        c.done ? '완성' : '미완성',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                child: Column(
                  children: [
                    if (media != null)
                      Expanded(child: Center(child: media))
                    else
                      const Spacer(),
                    const SizedBox(height: 4),
                    Text(
                      c.title.isEmpty ? '이름 없음' : c.title,
                      maxLines: media == null ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: media == null ? 13 : 12,
                        height: 1.2,
                        color: c.title.isEmpty ? colors.textMuted : colors.text,
                      ),
                    ),
                    if (media == null) const Spacer(),
                    if (needs.isNotEmpty ||
                        c.checks.isNotEmpty ||
                        c.note.isNotEmpty)
                      Row(
                        children: [
                          if (c.checks.isNotEmpty) ...[
                            Icon(
                              Icons.checklist,
                              size: 12,
                              color: c.checksDone == c.checks.length
                                  ? _done
                                  : colors.textMuted,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${c.checksDone}/${c.checks.length}',
                              style: TextStyle(
                                fontSize: 10,
                                color: c.checksDone == c.checks.length
                                    ? _done
                                    : colors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          if (c.note.isNotEmpty)
                            Icon(
                              Icons.notes,
                              size: 12,
                              color: colors.textMuted,
                            ),
                          const Spacer(),
                          if (needs.isNotEmpty)
                            Tooltip(
                              message: '먼저 끝낼 카드 중 완성한 수',
                              child: Text(
                                '$ready/${needs.length}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: ready == needs.length
                                      ? _done
                                      : colors.textMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A card's picture: the attachment's file on this device, once synced.
class _Picture extends StatelessWidget {
  const _Picture({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: assetFilesChanged,
    builder: (context, _, _) {
      final local = resolveAssetUrl(url);
      const missing = Icon(Icons.image_outlined, size: 28, color: Colors.grey);
      if (local == null) return missing;
      return Image.file(
        File(local),
        fit: BoxFit.contain,
        cacheWidth: 320,
        errorBuilder: (_, _, _) => missing,
      );
    },
  );
}

/// The arrow from [from] to [to], leaving by the side that faces it.
/// Top-down stays the rule: a card clearly below (even far to the side)
/// is reached bottom → top; one clearly above, top → bottom; one beside
/// it (heights overlap), side → side, so the arrow isn't hidden under
/// the cards.
(Offset, Offset, Offset, Offset) _curve(Rect from, Rect to) {
  const gap = 16.0;
  if (to.top - from.bottom > gap || from.top - to.bottom > gap) {
    final down = to.top > from.bottom;
    final a = down ? from.bottomCenter : from.topCenter;
    final b = down ? to.topCenter : to.bottomCenter;
    final bend = math.max(40.0, (b.dy - a.dy).abs() / 2) * (down ? 1 : -1);
    return (a, a + Offset(0, bend), b - Offset(0, bend), b);
  }
  final right = to.center.dx > from.center.dx;
  final a = right ? from.centerRight : from.centerLeft;
  final b = right ? to.centerLeft : to.centerRight;
  final bend = math.max(30.0, (b.dx - a.dx).abs() / 2) * (right ? 1 : -1);
  return (a, a + Offset(bend, 0), b - Offset(bend, 0), b);
}

Offset _bezier(Offset a, Offset c1, Offset c2, Offset b, double t) {
  final u = 1 - t;
  return a * (u * u * u) +
      c1 * (3 * u * u * t) +
      c2 * (3 * u * t * t) +
      b * (t * t * t);
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({
    required this.map,
    required this.rect,
    required this.muted,
    this.dragFrom,
    this.dragTo,
  });

  final PlanMap map;
  final Rect Function(MapCard) rect;
  final Color muted;
  final MapCard? dragFrom;
  final Offset? dragTo;

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in map.edges) {
      final from = map.card(e.from), to = map.card(e.to);
      if (from == null || to == null) continue;
      final color = from.done ? _done : muted.withValues(alpha: 0.7);
      _arrow(canvas, _curve(rect(from), rect(to)), color);
    }
    final from = dragFrom, to = dragTo;
    if (from != null && to != null) {
      final a = rect(from).bottomCenter;
      final bend = math.max(40.0, (to.dy - a.dy).abs() / 2);
      _arrow(canvas, (
        a,
        a + Offset(0, bend),
        to - Offset(0, bend),
        to,
      ), _accent);
    }
  }

  void _arrow(Canvas canvas, (Offset, Offset, Offset, Offset) c, Color color) {
    final (a, c1, c2, b) = c;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawPath(
      Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, b.dx, b.dy),
      paint,
    );
    // Head along the curve's last direction.
    final dir = b - _bezier(a, c1, c2, b, 0.95);
    final len = dir.distance;
    if (len == 0) return;
    final u = dir / len;
    final n = Offset(-u.dy, u.dx);
    final head = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo(b.dx - u.dx * 9 + n.dx * 5, b.dy - u.dy * 9 + n.dy * 5)
      ..lineTo(b.dx - u.dx * 9 - n.dx * 5, b.dy - u.dy * 9 - n.dy * 5)
      ..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => true;
}

/// What the card window returns.
typedef _CardEdit = ({
  String title,
  String icon,
  String image,
  String note,
  List<MapCheck> checks,
  bool done,
});

/// Window for a card: name, status, picture, icon, a memo and a checklist
/// of smaller steps. For a section title only the name.
class _CardEditor extends StatefulWidget {
  const _CardEditor({
    required this.card,
    required this.label,
    required this.pickPicture,
  });

  final MapCard? card;
  final bool label;
  final Future<String?> Function() pickPicture;

  @override
  State<_CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<_CardEditor> {
  late final _title = TextEditingController(text: widget.card?.title ?? '');
  late final _note = TextEditingController(text: widget.card?.note ?? '');
  final _newCheck = TextEditingController();
  final _newCheckFocus = FocusNode();
  late final _checks = [
    for (final c in widget.card?.checks ?? const <MapCheck>[])
      (text: TextEditingController(text: c.text), done: c.done),
  ];
  late String _icon = widget.card?.icon ?? '';
  late String _image = widget.card?.image ?? '';
  late bool _isDone = widget.card?.done ?? false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _newCheck.dispose();
    _newCheckFocus.dispose();
    for (final c in _checks) {
      c.text.dispose();
    }
    super.dispose();
  }

  void _addCheck() {
    final text = _newCheck.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _checks.add((text: TextEditingController(text: text), done: false));
      _newCheck.clear();
    });
    _newCheckFocus.requestFocus();
  }

  void _submit() {
    final pending = _newCheck.text.trim(); // typed but not yet added
    Navigator.pop<_CardEdit>(context, (
      title: _title.text.trim(),
      icon: _icon,
      image: _image,
      note: _note.text.trim(),
      checks: [
        for (final c in _checks)
          if (c.text.text.trim().isNotEmpty)
            MapCheck(c.text.text.trim(), done: c.done),
        if (pending.isNotEmpty) MapCheck(pending),
      ],
      done: _isDone,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final title = TextField(
      controller: _title,
      autofocus: true,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: widget.label ? '섹션 이름' : '카드 이름',
        border: InputBorder.none,
      ),
      onSubmitted: (_) => _submit(),
    );
    if (widget.label) {
      return AlertDialog(
        content: SizedBox(width: 360, child: title),
        actions: _actions(),
      );
    }
    Widget status(bool done, String text, Color color) => ChoiceChip(
      label: Text(text),
      selected: _isDone == done,
      selectedColor: color.withValues(alpha: 0.18),
      side: BorderSide(color: _isDone == done ? color : colors.divider),
      labelStyle: TextStyle(color: _isDone == done ? color : colors.text),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => _isDone = done),
    );
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  status(false, '미완성', _todo),
                  status(true, '완성', _done),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: Text(_image.isEmpty ? '사진' : '사진 바꾸기'),
                    onPressed: () async {
                      final url = await widget.pickPicture();
                      if (url != null && mounted) setState(() => _image = url);
                    },
                  ),
                  if (_image.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 36,
                          height: 36,
                          child: _Picture(url: _image),
                        ),
                        IconButton(
                          tooltip: '사진 빼기',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setState(() => _image = ''),
                        ),
                      ],
                    ),
                  TextButton(
                    onPressed: () async {
                      final picked = await showIconPicker(context);
                      if (picked != null && mounted) {
                        setState(() => _icon = picked);
                      }
                    },
                    child: Text(
                      _icon.isEmpty ? '아이콘' : _icon,
                      style: TextStyle(fontSize: _icon.isEmpty ? 14 : 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: '메모',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '체크리스트',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textMuted,
                ),
              ),
              for (var i = 0; i < _checks.length; i++)
                Row(
                  children: [
                    Checkbox(
                      value: _checks[i].done,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(
                        () => _checks[i] = (
                          text: _checks[i].text,
                          done: v ?? false,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _checks[i].text,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        style: TextStyle(
                          decoration: _checks[i].done
                              ? TextDecoration.lineThrough
                              : null,
                          color: _checks[i].done ? colors.textMuted : null,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '지우기',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close,
                        size: 16,
                        color: colors.textMuted,
                      ),
                      onPressed: () => setState(() {
                        _checks.removeAt(i).text.dispose();
                      }),
                    ),
                  ],
                ),
              Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(Icons.add, size: 18, color: colors.textMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _newCheck,
                      focusNode: _newCheckFocus,
                      decoration: const InputDecoration(
                        hintText: '항목 추가 (Enter)',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      // Keep typing the next step after Enter.
                      onEditingComplete: _addCheck,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: _actions(),
    );
  }

  List<Widget> _actions() => [
    TextButton(
      onPressed: () => Navigator.pop(context),
      child: const Text('취소'),
    ),
    FilledButton(onPressed: _submit, child: const Text('저장')),
  ];
}
