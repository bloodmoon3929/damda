import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/asset_repository.dart';
import '../data/database.dart';
import '../data/database_repository.dart';
import '../providers.dart';
import '../ui/theme.dart';
import 'calendar_view.dart' show dateKey;
import 'cells.dart';
import 'database_view.dart' show RowMenuArea;
import 'h_scroll.dart';

const _accent = Color(0xFF2383E2);

// -------------------------------------------------------------- gallery ----

/// Cards with a cover (the first image in each item's page).
class GalleryView extends ConsumerWidget {
  const GalleryView({
    super.key,
    required this.snap,
    required this.view,
    required this.rows,
  });

  final DbSnapshot snap;
  final DbView view;
  final List<PageRow> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final chosen = view.config.containsKey('cardProps')
        ? view.cardProps.toSet()
        : null;
    final props = [
      for (final p in snap.properties)
        if (!view.hidden.contains(p.id) &&
            (chosen == null || chosen.contains(p.id)))
          p,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          for (final r in rows) _GalleryCard(snap: snap, row: r, props: props),
          SizedBox(
            width: 240,
            height: 120,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.textMuted,
                side: BorderSide(color: colors.divider),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('새로 만들기'),
              onPressed: () async {
                final id = await ref
                    .read(repositoryProvider)
                    .addRow(snap.database.id);
                ref.read(screenProvider.notifier).openPage(id);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryCard extends ConsumerWidget {
  const _GalleryCard({
    required this.snap,
    required this.row,
    required this.props,
  });

  final DbSnapshot snap;
  final PageRow row;
  final List<DbProperty> props;

  Widget _cover(BuildContext context) {
    final colors = context.noteColors;
    final url = snap.covers[row.id];
    final placeholder = Container(
      color: colors.hover,
      alignment: Alignment.center,
      child: Text(
        (row.icon?.isNotEmpty ?? false) ? row.icon! : '📄',
        style: const TextStyle(fontSize: 36),
      ),
    );
    if (url == null) return placeholder;
    final local = resolveAssetUrl(url);
    Widget error(BuildContext _, Object _, StackTrace? _) => placeholder;
    if (local != null) {
      return Image.file(
        File(local),
        fit: BoxFit.cover,
        cacheWidth: 480,
        errorBuilder: error,
      );
    }
    if (url.startsWith('http')) {
      return Image.network(url, fit: BoxFit.cover, errorBuilder: error);
    }
    return placeholder;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final values = [
      for (final p in props)
        if (snap.value(row.id, p) != null) (p, snap.value(row.id, p)),
    ];
    return RowMenuArea(
      row: row,
      child: SizedBox(
        width: 240,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: colors.divider),
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            onTap: () => ref.read(screenProvider.notifier).openPage(row.id),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: 140, child: _cover(context)),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.title.isEmpty ? '제목 없음' : row.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                        ),
                      ),
                      for (final (p, v) in values.take(4))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: CellDisplay(prop: p, value: v),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- timeline ----

DateTime? _parseDay(Object? v) => v is String && v.length >= 10
    ? DateTime.tryParse(v.substring(0, 10))
    : null;

/// Gantt-style bars from a start date (and optional end date) property.
/// Drag a bar sideways to move it in time.
class TimelineView extends ConsumerWidget {
  const TimelineView({
    super.key,
    required this.snap,
    required this.view,
    required this.rows,
    required this.onChooseDate,
  });

  final DbSnapshot snap;
  final DbView view;
  final List<PageRow> rows;
  final VoidCallback onChooseDate;

  static const dayWidth = 34.0;
  static const rowHeight = 36.0;
  static const labelWidth = 200.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final start = view.dateBy == null ? null : snap.property(view.dateBy!);
    if (start == null || !isDateSource(start)) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              '타임라인은 날짜 속성으로 항목을 배치해요.',
              style: TextStyle(color: colors.textMuted),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onChooseDate,
              child: const Text('시작 날짜 속성 고르기'),
            ),
          ],
        ),
      );
    }
    final end = view.endBy == null ? null : snap.property(view.endBy!);

    final items = <(PageRow, DateTime, DateTime)>[];
    for (final r in rows) {
      final s = _parseDay(dayOf(snap, r.id, start));
      if (s == null) continue;
      var e = end == null ? s : (_parseDay(dayOf(snap, r.id, end)) ?? s);
      if (e.isBefore(s)) e = s;
      items.add((r, s, e));
    }
    items.sort((a, b) => a.$2.compareTo(b.$2));
    final unscheduled = rows.length - items.length;

    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    var from = items.isEmpty ? todayDay : items.first.$2;
    var to = items.isEmpty
        ? todayDay
        : items.map((i) => i.$3).reduce((a, b) => a.isAfter(b) ? a : b);
    from = from.subtract(const Duration(days: 3));
    to = to.add(const Duration(days: 10));
    if (to.difference(from).inDays < 30) {
      to = from.add(const Duration(days: 30));
    }
    final days = to.difference(from).inDays + 1;
    double x(DateTime d) => d.difference(from).inDays * dayWidth;

    final header = SizedBox(
      height: 44,
      child: Stack(
        children: [
          for (var i = 0; i < days; i++)
            Positioned(
              left: i * dayWidth,
              top: 0,
              width: dayWidth,
              height: 44,
              child: Builder(
                builder: (context) {
                  final d = from.add(Duration(days: i));
                  final isToday = dateKey(d) == dateKey(todayDay);
                  return Column(
                    children: [
                      SizedBox(
                        height: 20,
                        child: d.day == 1 || i == 0
                            ? Text(
                                '${d.year}.${d.month}',
                                softWrap: false,
                                overflow: TextOverflow.visible,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.textMuted,
                                ),
                              )
                            : null,
                      ),
                      Text(
                        '${d.day}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isToday ? FontWeight.w700 : null,
                          color: isToday
                              ? const Color(0xFFE03E3E)
                              : (d.weekday == DateTime.sunday
                                    ? const Color(0xFFE03E3E)
                                    : colors.textMuted),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );

    final chart = SizedBox(
      width: days * dayWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          SizedBox(
            height: items.length * rowHeight + 8,
            child: Stack(
              children: [
                // Weekend shading and today line.
                for (var i = 0; i < days; i++)
                  if (from.add(Duration(days: i)).weekday >= DateTime.saturday)
                    Positioned(
                      left: i * dayWidth,
                      top: 0,
                      bottom: 0,
                      width: dayWidth,
                      child: ColoredBox(
                        color: colors.hover.withValues(alpha: 0.5),
                      ),
                    ),
                Positioned(
                  left: x(todayDay) + dayWidth / 2,
                  top: 0,
                  bottom: 0,
                  width: 1.5,
                  child: const ColoredBox(color: Color(0xFFE03E3E)),
                ),
                for (var i = 0; i < items.length; i++)
                  _TimelineBar(
                    key: ValueKey(items[i].$1.id),
                    snap: snap,
                    row: items[i].$1,
                    start: items[i].$2,
                    end: items[i].$3,
                    startProp: start,
                    endProp: end,
                    left: x(items[i].$2),
                    top: i * rowHeight + 4,
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            '${start.name}${end == null ? '' : ' → ${end.name}'}'
            '${unscheduled > 0 ? '  ·  날짜 없음 $unscheduled' : ''}',
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: labelWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 44),
                  for (final (r, _, _) in items)
                    SizedBox(
                      height: rowHeight,
                      child: InkWell(
                        onTap: () =>
                            ref.read(screenProvider.notifier).openPage(r.id),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            r.title.isEmpty ? '제목 없음' : r.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, color: colors.text),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(child: HScroll(child: chart)),
          ],
        ),
      ],
    );
  }
}

class _TimelineBar extends ConsumerStatefulWidget {
  const _TimelineBar({
    super.key,
    required this.snap,
    required this.row,
    required this.start,
    required this.end,
    required this.startProp,
    required this.endProp,
    required this.left,
    required this.top,
  });

  final DbSnapshot snap;
  final PageRow row;
  final DateTime start;
  final DateTime end;
  final DbProperty startProp;
  final DbProperty? endProp;
  final double left;
  final double top;

  @override
  ConsumerState<_TimelineBar> createState() => _TimelineBarState();
}

class _TimelineBarState extends ConsumerState<_TimelineBar> {
  double _dx = 0;

  Future<void> _commit() async {
    final days = (_dx / TimelineView.dayWidth).round();
    setState(() => _dx = 0);
    if (days == 0) return;
    final repo = ref.read(repositoryProvider);
    await repo.setCell(
      widget.row.id,
      widget.startProp.id,
      dateKey(widget.start.add(Duration(days: days))),
    );
    final endProp = widget.endProp;
    if (endProp != null &&
        endProp.type == PropType.date &&
        widget.snap.cell(widget.row.id, endProp.id) != null) {
      await repo.setCell(
        widget.row.id,
        endProp.id,
        dateKey(widget.end.add(Duration(days: days))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final select = widget.snap.properties
        .where((p) => p.type == PropType.select)
        .map((p) => p.option(widget.snap.cell(widget.row.id, p.id) as String?))
        .whereType<SelectOption>()
        .firstOrNull;
    final (bg, fg) = select == null
        ? (_accent.withValues(alpha: 0.18), context.noteColors.text)
        : tagColors(context, select.color);
    final width =
        (widget.end.difference(widget.start).inDays + 1) *
        TimelineView.dayWidth;
    final title = widget.row.title.isEmpty ? '제목 없음' : widget.row.title;
    // Short bars can't fit their title: show it to the right (Notion style).
    final inside = width >= 120;
    final bar = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.centerLeft,
      child: inside
          ? Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: fg),
            )
          : null,
    );
    return Positioned(
      left: widget.left + _dx,
      top: widget.top,
      width: inside ? width : width + 220,
      height: TimelineView.rowHeight - 8,
      child: GestureDetector(
        onTap: () => ref.read(screenProvider.notifier).openPage(widget.row.id),
        // Formula dates are computed, so their bars can't be moved.
        onHorizontalDragUpdate: widget.startProp.type == PropType.date
            ? (d) => setState(() => _dx += d.delta.dx)
            : null,
        onHorizontalDragEnd: widget.startProp.type == PropType.date
            ? (_) => _commit()
            : null,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: inside
              ? bar
              : Row(
                  children: [
                    bar,
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.noteColors.text,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
