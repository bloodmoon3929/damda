import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/database_repository.dart';
import '../providers.dart';
import '../ui/theme.dart';
import 'cells.dart';

const _accent = Color(0xFF2383E2);

String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Asks which date property places rows on the calendar; can create one
/// with a name the user picks. Returns the property id.
Future<String?> pickCalendarDate(
  BuildContext context,
  WidgetRef ref,
  DbSnapshot snap, {
  required Future<String?> Function(BuildContext, String, String) askText,
  String title = '캘린더에 쓸 날짜 속성',
  bool allowNone = false,
}) async {
  final dates = snap.properties.where(isDateSource).toList();
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        if (allowNone)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '#none'),
            child: const Text('없음'),
          ),
        for (final p in dates)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p.id),
            child: Row(
              children: [
                Icon(
                  p.type == PropType.formula
                      ? Icons.functions
                      : Icons.calendar_today_outlined,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(p.type == PropType.formula ? '${p.name} (수식)' : p.name),
              ],
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, '#new'),
          child: const Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 10),
              Text('새 날짜 속성 만들기…'),
            ],
          ),
        ),
      ],
    ),
  );
  if (choice != '#new' || !context.mounted) return choice;
  final name = await askText(context, '새 날짜 속성 이름 (예: 날짜, 방문일)', '날짜');
  if (name == null || name.trim().isEmpty) return null;
  return ref
      .read(repositoryProvider)
      .addProperty(snap.database.id, name.trim(), PropType.date);
}

/// Month grid; rows sit on the day of their date property.
class CalendarView extends ConsumerStatefulWidget {
  const CalendarView({
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

  @override
  ConsumerState<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends ConsumerState<CalendarView> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final snap = widget.snap;
    final dateProp = widget.view.dateBy == null
        ? null
        : snap.property(widget.view.dateBy!);
    if (dateProp == null || !isDateSource(dateProp)) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              '캘린더는 날짜 속성으로 항목을 배치해요.',
              style: TextStyle(color: colors.textMuted),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: widget.onChooseDate,
              child: const Text('날짜 속성 고르기'),
            ),
          ],
        ),
      );
    }

    final byDay = <String, List<PageRow>>{};
    for (final r in widget.rows) {
      final day = dayOf(snap, r.id, dateProp);
      if (day != null) byDay.putIfAbsent(day, () => []).add(r);
    }
    final undated = widget.rows
        .where((r) => dayOf(snap, r.id, dateProp) == null)
        .length;

    // Weeks start on Sunday (일요일), as in Korean calendars.
    final first = DateTime(_month.year, _month.month);
    final start = first.subtract(Duration(days: first.weekday % 7));
    final today = dateKey(DateTime.now());
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    final cardProps = [
      for (final id in widget.view.cardProps)
        if (snap.property(id) case final p? when p.id != dateProp.id) p,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Text(
                '${_month.year}년 ${_month.month}월',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              const SizedBox(width: 8),
              if (undated > 0)
                Text(
                  '날짜 없음 $undated',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              const Spacer(),
              IconButton(
                tooltip: '이전 달',
                iconSize: 20,
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month - 1),
                ),
              ),
              TextButton(
                onPressed: () => setState(
                  () => _month = DateTime(
                    DateTime.now().year,
                    DateTime.now().month,
                  ),
                ),
                child: const Text('오늘'),
              ),
              IconButton(
                tooltip: '다음 달',
                iconSize: 20,
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month + 1),
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 4),
                  child: Text(
                    weekdays[i],
                    style: TextStyle(
                      fontSize: 12,
                      color: i == 0
                          ? const Color(0xFFE03E3E)
                          : colors.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
        for (var week = 0; week < 6; week++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var d = 0; d < 7; d++)
                  Expanded(
                    child: _DayCell(
                      day: start.add(Duration(days: week * 7 + d)),
                      inMonth:
                          start.add(Duration(days: week * 7 + d)).month ==
                          _month.month,
                      isToday:
                          dateKey(start.add(Duration(days: week * 7 + d))) ==
                          today,
                      rows:
                          byDay[dateKey(
                            start.add(Duration(days: week * 7 + d)),
                          )] ??
                          const [],
                      snap: snap,
                      dateProp: dateProp,
                      cardProps: cardProps,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DayCell extends ConsumerWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.rows,
    required this.snap,
    required this.dateProp,
    required this.cardProps,
  });

  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final List<PageRow> rows;
  final DbSnapshot snap;
  final DbProperty dateProp;
  final List<DbProperty> cardProps;

  /// Formula dates are computed: they can't be dragged or set from here.
  bool get editable => dateProp.type == PropType.date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final repo = ref.read(repositoryProvider);
    final key = dateKey(day);
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => editable,
      onAcceptWithDetails: (d) => repo.setCell(d.data, dateProp.id, key),
      builder: (context, candidates, _) => Container(
        constraints: const BoxConstraints(minHeight: 96),
        decoration: BoxDecoration(
          color: candidates.isNotEmpty
              ? _accent.withValues(alpha: 0.10)
              : (inMonth ? null : colors.hover.withValues(alpha: 0.5)),
          border: Border.all(color: colors.divider, width: 0.5),
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: isToday
                      ? BoxDecoration(
                          color: const Color(0xFFE03E3E),
                          borderRadius: BorderRadius.circular(10),
                        )
                      : null,
                  child: Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isToday
                          ? Colors.white
                          : (inMonth ? colors.text : colors.textMuted),
                    ),
                  ),
                ),
                const Spacer(),
                if (editable)
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () async {
                      final id = await repo.addRow(
                        snap.database.id,
                        values: {dateProp.id: key},
                      );
                      ref.read(screenProvider.notifier).openPage(id);
                    },
                    child: Icon(Icons.add, size: 14, color: colors.textMuted),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            for (final r in rows)
              _EventChip(
                row: r,
                snap: snap,
                cardProps: cardProps,
                draggable: editable,
              ),
          ],
        ),
      ),
    );
  }
}

class _EventChip extends ConsumerWidget {
  const _EventChip({
    required this.row,
    required this.snap,
    required this.cardProps,
    required this.draggable,
  });

  final PageRow row;
  final DbSnapshot snap;
  final List<DbProperty> cardProps;
  final bool draggable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    // Color from the first select property, if any (like Notion's tags).
    final select = snap.properties
        .where((p) => p.type == PropType.select)
        .map((p) => p.option(snap.cell(row.id, p.id) as String?))
        .whereType<SelectOption>()
        .firstOrNull;
    final (bg, fg) = select == null
        ? (colors.hover, colors.text)
        : tagColors(context, select.color);
    final chip = Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${(row.icon?.isNotEmpty ?? false) ? '${row.icon} ' : ''}'
            '${row.title.isEmpty ? '제목 없음' : row.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: fg),
          ),
          // The properties the user chose to show ("표시할 속성"): why
          // this item is on this day, at a glance.
          for (final p in cardProps)
            if (snap.value(row.id, p) != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: CellDisplay(prop: p, value: snap.value(row.id, p)),
                ),
              ),
        ],
      ),
    );
    final tappable = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref.read(screenProvider.notifier).openPage(row.id),
        child: chip,
      ),
    );
    if (!draggable) return tappable;
    return Draggable<String>(
      data: row.id,
      allowedButtonsFilter: (b) => b == kPrimaryButton,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(width: 140, child: chip),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: tappable,
    );
  }
}
