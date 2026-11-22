import 'dart:convert';

import 'package:drift/drift.dart';

import 'clock.dart' show newId;
import 'database.dart';
import 'fractional_index.dart';
import 'notes_repository.dart';

/// 계획 지도: a page (kind `plan_map`) of cards joined by arrows, a big
/// goal fed by the smaller plans that lead to it.
///
/// Cards, section titles and arrows are rows in `blocks` (like an
/// album's items), so they sync one by one. Arrows refer to cards by a
/// `key` kept in the block data, which survives copying the page.
const planMapKind = 'plan_map';
const mapCardType = 'map_card';
const mapLabelType = 'map_label';
const mapEdgeType = 'map_edge';

class MapCard {
  const MapCard({
    required this.blockId,
    required this.key,
    required this.x,
    required this.y,
    required this.title,
    required this.icon,
    required this.done,
    required this.isLabel,
    this.image = '',
    this.note = '',
    this.checks = const [],
  });

  final String blockId;
  final String key;

  /// Top-left corner on the canvas.
  final double x, y;
  final String title;
  final String icon;

  /// A picture (`asset://…`), shown instead of the icon.
  final String image;
  final bool done;

  /// A section title (철 팜, 나무 팜 …) rather than a card.
  final bool isLabel;

  /// Free text under the title.
  final String note;

  /// Smaller steps of this card.
  final List<MapCheck> checks;

  int get checksDone => checks.where((c) => c.done).length;
}

/// One step of a card's checklist.
class MapCheck {
  const MapCheck(this.text, {this.done = false});

  final String text;
  final bool done;

  MapCheck toggled() => MapCheck(text, done: !done);

  Map<String, Object> toJson() => {'t': text, 'd': done};

  static MapCheck? fromJson(Object? j) => j is Map && j['t'] is String
      ? MapCheck(j['t'] as String, done: j['d'] == true)
      : null;
}

class MapEdge {
  const MapEdge({required this.blockId, required this.from, required this.to});

  final String blockId;

  /// Card keys: [from] is needed for [to].
  final String from, to;
}

class PlanMap {
  const PlanMap(this.cards, this.edges);

  final List<MapCard> cards;
  final List<MapEdge> edges;

  MapCard? card(String key) {
    for (final c in cards) {
      if (c.key == key) return c;
    }
    return null;
  }

  /// The cards (not titles) with an arrow into [key].
  List<MapCard> needs(String key) => [
    for (final e in edges)
      if (e.to == key)
        if (card(e.from) case final c? when !c.isLabel) c,
  ];

  /// Cards that can be worked on now: not done, nothing they need is
  /// still open. Top to bottom, then left to right.
  List<MapCard> get ready =>
      [
        for (final c in cards)
          if (!c.isLabel && !c.done && !blocked(c)) c,
      ]..sort((a, b) {
        final y = a.y.compareTo(b.y);
        return y != 0 ? y : a.x.compareTo(b.x);
      });

  /// Not done yet and some card it needs isn't done either.
  bool blocked(MapCard c) => !c.done && needs(c.key).any((n) => !n.done);

  int get total => cards.where((c) => !c.isLabel).length;
  int get doneCount => cards.where((c) => !c.isLabel && c.done).length;
}

extension PlanMapRepository on NotesRepository {
  Future<String> createPlanMap({String? parentId, String title = ''}) =>
      createPage(
        parentId: parentId,
        title: title,
        icon: '🗺️',
        kind: planMapKind,
      );

  Stream<PlanMap> watchPlanMap(String pageId) {
    final query = db.select(db.blocks)
      ..where(
        (b) =>
            b.pageId.equals(pageId) &
            b.deleted.equals(false) &
            b.type.isIn(const [mapCardType, mapLabelType, mapEdgeType]),
      )
      ..orderBy([(b) => OrderingTerm.asc(b.sortKey)]);
    return query.watch().map((rows) {
      final cards = <MapCard>[];
      final edges = <MapEdge>[];
      for (final b in rows) {
        final Map data;
        try {
          data = jsonDecode(b.data) as Map;
        } catch (_) {
          continue;
        }
        if (b.type == mapEdgeType) {
          final from = data['from'], to = data['to'];
          if (from is String && to is String) {
            edges.add(MapEdge(blockId: b.id, from: from, to: to));
          }
          continue;
        }
        final delta = data['delta'];
        final title = delta is List
            ? delta.map((op) => op is Map ? op['insert'] ?? '' : '').join()
            : '';
        cards.add(
          MapCard(
            blockId: b.id,
            key: data['key'] as String? ?? b.id,
            x: (data['x'] as num?)?.toDouble() ?? 0,
            y: (data['y'] as num?)?.toDouble() ?? 0,
            title: title,
            icon: data['icon'] as String? ?? '',
            image: data['image'] as String? ?? '',
            note: data['note'] as String? ?? '',
            checks: [
              if (data['checks'] case final List list)
                for (final j in list) ?MapCheck.fromJson(j),
            ],
            done: data['done'] == true,
            isLabel: b.type == mapLabelType,
          ),
        );
      }
      final keys = {for (final c in cards) c.key};
      return PlanMap(cards, [
        for (final e in edges)
          if (keys.contains(e.from) && keys.contains(e.to)) e,
      ]);
    });
  }

  Map<String, Object?> _cardData(
    String key, {
    required double x,
    required double y,
    required String title,
    required String icon,
    required bool done,
    required String image,
    required String note,
    required List<MapCheck> checks,
  }) => {
    'key': key,
    'x': x.roundToDouble(),
    'y': y.roundToDouble(),
    // As editor text, so search finds the cards.
    'delta': [
      if (title.isNotEmpty) {'insert': title},
    ],
    'icon': icon,
    if (image.isNotEmpty) 'image': image,
    if (note.isNotEmpty) 'note': note,
    if (checks.isNotEmpty) 'checks': [for (final c in checks) c.toJson()],
    'done': done,
  };

  Future<String> _insert(String pageId, String type, Object data) async {
    final last =
        await (db.selectOnly(db.blocks)
              ..addColumns([db.blocks.sortKey.max()])
              ..where(db.blocks.pageId.equals(pageId)))
            .map((r) => r.read(db.blocks.sortKey.max()))
            .getSingleOrNull();
    final id = newId();
    await db
        .into(db.blocks)
        .insert(
          BlocksCompanion.insert(
            id: id,
            pageId: pageId,
            sortKey: keyBetween(last, null),
            type: type,
            data: Value(jsonEncode(data)),
            updatedAt: clock.tick(),
            deviceId: deviceId,
          ),
        );
    await updatePage(pageId);
    return id;
  }

  Future<void> _write(String blockId, Object? data, {bool delete = false}) =>
      (db.update(db.blocks)..where((b) => b.id.equals(blockId))).write(
        BlocksCompanion(
          data: data == null ? const Value.absent() : Value(jsonEncode(data)),
          deleted: delete ? const Value(true) : const Value.absent(),
          dirty: const Value(true),
          updatedAt: Value(clock.tick()),
          deviceId: Value(deviceId),
        ),
      );

  /// Adds a card (or a section title) with its top-left at ([x], [y]).
  Future<String> addMapCard(
    String pageId, {
    required double x,
    required double y,
    String title = '',
    String icon = '',
    String image = '',
    String note = '',
    List<MapCheck> checks = const [],
    bool done = false,
    bool label = false,
  }) async {
    final key = newId();
    await _insert(
      pageId,
      label ? mapLabelType : mapCardType,
      _cardData(
        key,
        x: x,
        y: y,
        title: title,
        icon: icon,
        done: done,
        image: image,
        note: note,
        checks: checks,
      ),
    );
    return key;
  }

  Future<void> updateMapCard(
    String pageId,
    MapCard card, {
    double? x,
    double? y,
    String? title,
    String? icon,
    bool? done,
    String? image,
    String? note,
    List<MapCheck>? checks,
  }) async {
    await _write(
      card.blockId,
      _cardData(
        card.key,
        x: x ?? card.x,
        y: y ?? card.y,
        title: title ?? card.title,
        icon: icon ?? card.icon,
        done: done ?? card.done,
        image: image ?? card.image,
        note: note ?? card.note,
        checks: checks ?? card.checks,
      ),
    );
    await updatePage(pageId);
  }

  /// Removes the card and the arrows to and from it.
  Future<void> deleteMapCard(String pageId, PlanMap map, MapCard card) async {
    await db.transaction(() async {
      await _write(card.blockId, null, delete: true);
      for (final e in map.edges) {
        if (e.from == card.key || e.to == card.key) {
          await _write(e.blockId, null, delete: true);
        }
      }
    });
    await updatePage(pageId);
  }

  /// An arrow: [from] is needed for [to]. Repeats and loops onto itself
  /// are ignored.
  Future<void> addMapEdge(
    String pageId,
    PlanMap map,
    String from,
    String to,
  ) async {
    if (from == to) return;
    if (map.edges.any((e) => e.from == from && e.to == to)) return;
    await _insert(pageId, mapEdgeType, {'from': from, 'to': to});
  }

  Future<void> deleteMapEdge(String pageId, MapEdge edge) async {
    await _write(edge.blockId, null, delete: true);
    await updatePage(pageId);
  }
}
