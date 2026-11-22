import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/database_repository.dart';
import '../data/text_sort.dart';
import '../providers.dart';
import '../ui/in_editor_text_field.dart';
import '../ui/text_prompt.dart';
import '../ui/theme.dart';
import 'calendar_view.dart';
import 'cells.dart';
import 'filter_editor.dart';
import 'gallery_timeline.dart';
import 'map_view.dart';
import 'h_scroll.dart';

const _accent = Color(0xFF2383E2);

IconData viewIcon(String type) => switch (type) {
  ViewType.board => Icons.view_column_outlined,
  ViewType.list => Icons.format_list_bulleted,
  ViewType.calendar => Icons.calendar_month_outlined,
  ViewType.gallery => Icons.grid_view_outlined,
  ViewType.timeline => Icons.view_timeline_outlined,
  ViewType.map => Icons.map_outlined,
  _ => Icons.table_chart_outlined,
};

/// A database: view tabs + toolbar + the active view (표 / 보드 / 리스트).
/// Used as a full page and inline inside other pages.
class DatabaseView extends ConsumerStatefulWidget {
  const DatabaseView({
    super.key,
    required this.databaseId,
    this.inline = false,
  });

  final String databaseId;
  final bool inline;

  @override
  ConsumerState<DatabaseView> createState() => _DatabaseViewState();
}

/// Last selected view per database for this session, so coming back from a
/// row page shows the same view (Notion behavior).
final _lastViewByDatabase = <String, String>{};

class _DatabaseViewState extends ConsumerState<DatabaseView> {
  late String? _viewId = _lastViewByDatabase[widget.databaseId];

  void _selectView(String? id) {
    setState(() => _viewId = id);
    if (id == null) {
      _lastViewByDatabase.remove(widget.databaseId);
    } else {
      _lastViewByDatabase[widget.databaseId] = id;
    }
  }

  bool _searching = false;
  String _query = '';

  Future<Offset?> _anchorBelow(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    return box?.localToGlobal(Offset(0, box.size.height));
  }

  Future<T?> _menuAt<T>(Offset at, List<PopupMenuEntry<T>> items) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  Future<void> _addView(BuildContext anchor, DbSnapshot snap) async {
    final at = await _anchorBelow(anchor);
    if (at == null) return;
    final type = await _menuAt<String>(at, [
      for (final t in ViewType.all)
        PopupMenuItem(
          value: t,
          child: Row(
            children: [
              Icon(viewIcon(t), size: 18),
              const SizedBox(width: 10),
              Text(ViewType.label(t)),
            ],
          ),
        ),
    ]);
    if (type == null) return;
    final repo = ref.read(repositoryProvider);
    final config = <String, dynamic>{};
    if (type == ViewType.board) {
      if (!mounted) return;
      // The user picks (or names) the grouping property, like Notion.
      final group = await pickBoardGroup(context, ref, snap);
      if (group == null) return;
      config['groupBy'] = group;
    }
    if (type == ViewType.calendar || type == ViewType.timeline) {
      if (!mounted) return;
      final date = await pickCalendarDate(
        context,
        ref,
        snap,
        askText: askText,
        title: type == ViewType.timeline ? '타임라인 시작 날짜 속성' : '캘린더에 쓸 날짜 속성',
      );
      if (date == null) return;
      config['dateBy'] = date;
    }
    if (type == ViewType.map) {
      if (!mounted) return;
      final place = await _pickPlaceProp(snap);
      if (place == null) return;
      config['placeBy'] = place;
    }
    final id = await repo.addView(widget.databaseId, type, config: config);
    _selectView(id);
  }

  /// Which properties appear on each card (calendar chips, board cards,
  /// gallery cards) — e.g. "유형", "지역" to see why an item is on a day.
  Future<void> _chooseCardProps(DbView view, DbSnapshot snap) async {
    final chosen = {...view.cardProps};
    if (!view.config.containsKey('cardProps') &&
        view.type != ViewType.calendar) {
      chosen.addAll(snap.properties.map((p) => p.id)); // current default: all
    }
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('표시할 속성: ${view.name}'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in snap.properties)
                  if (p.id != view.dateBy && p.id != view.groupBy)
                    CheckboxListTile(
                      dense: true,
                      value: chosen.contains(p.id),
                      secondary: Icon(propIcon(p.type), size: 18),
                      title: Text(p.name),
                      onChanged: (v) => setDialogState(
                        () =>
                            v == true ? chosen.add(p.id) : chosen.remove(p.id),
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, chosen),
              child: const Text('적용'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await ref
        .read(repositoryProvider)
        .updateView(
          view.id,
          config: {
            ...view.config,
            // Keep the column order.
            'cardProps': [
              for (final p in snap.properties)
                if (result.contains(p.id)) p.id,
            ],
          },
        );
  }

  /// Which 장소 property the map uses; can create one with a chosen name.
  Future<String?> _pickPlaceProp(DbSnapshot snap) async {
    final places = snap.properties.where((p) => p.type == PropType.place);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('지도에 쓸 장소 속성'),
        children: [
          for (final p in places)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p.id),
              child: Row(
                children: [
                  const Icon(Icons.place_outlined, size: 18),
                  const SizedBox(width: 10),
                  Text(p.name),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '#new'),
            child: const Row(
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 10),
                Text('새 장소 속성 만들기…'),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice != '#new' || !mounted) return choice;
    final name = await askText(context, '새 장소 속성 이름', '장소');
    if (name == null || name.trim().isEmpty) return null;
    return ref
        .read(repositoryProvider)
        .addProperty(snap.database.id, name.trim(), PropType.place);
  }

  Future<void> _choosePlace(DbView view, DbSnapshot snap) async {
    final place = await _pickPlaceProp(snap);
    if (place == null) return;
    await ref
        .read(repositoryProvider)
        .updateView(view.id, config: {...view.config, 'placeBy': place});
  }

  Future<void> _chooseDate(DbView view, DbSnapshot snap) async {
    final date = await pickCalendarDate(context, ref, snap, askText: askText);
    if (date == null) return;
    await ref
        .read(repositoryProvider)
        .updateView(view.id, config: {...view.config, 'dateBy': date});
  }

  Future<void> _viewMenu(Offset at, DbView view, DbSnapshot snap) async {
    final repo = ref.read(repositoryProvider);
    final selects = snap.properties.where(canGroupBy);
    final action = await _menuAt<String>(at, [
      const PopupMenuItem(value: 'rename', child: Text('보기 이름 바꾸기')),
      if (view.type == ViewType.board)
        for (final p in [titleProperty(snap), ...selects])
          CheckedPopupMenuItem(
            value: 'group:${p.id}',
            checked: view.groupBy == p.id,
            child: Text('그룹 기준: ${p.name}'),
          ),
      if (const {
        ViewType.calendar,
        ViewType.board,
        ViewType.gallery,
      }.contains(view.type))
        const PopupMenuItem(value: 'cards', child: Text('표시할 속성…')),
      if (view.type == ViewType.calendar || view.type == ViewType.timeline)
        const PopupMenuItem(value: 'date', child: Text('날짜 속성 바꾸기')),
      if (view.type == ViewType.timeline)
        const PopupMenuItem(value: 'end', child: Text('종료 날짜 속성')),
      if (snap.views.length > 1)
        const PopupMenuItem(value: 'delete', child: Text('보기 삭제')),
    ]);
    if (action == null || !mounted) return;
    if (action == 'rename') {
      final name = await askText(context, '보기 이름', view.name);
      if (name != null && name.trim().isNotEmpty) {
        await repo.updateView(view.id, name: name.trim());
      }
    } else if (action == 'cards') {
      await _chooseCardProps(view, snap);
    } else if (action == 'date') {
      await _chooseDate(view, snap);
    } else if (action == 'end') {
      final end = await pickCalendarDate(
        context,
        ref,
        snap,
        askText: askText,
        title: '종료 날짜 속성 (기간 막대)',
        allowNone: true,
      );
      if (end == null) return;
      final config = {...view.config}..remove('endBy');
      if (end != '#none') config['endBy'] = end;
      await repo.updateView(view.id, config: config);
    } else if (action == 'delete') {
      await repo.deleteView(view.id);
      _selectView(null);
    } else if (action.startsWith('group:')) {
      await repo.updateView(
        view.id,
        config: {...view.config, 'groupBy': action.substring(6)},
      );
    }
  }

  Future<void> _sortMenu(
    BuildContext anchor,
    DbView view,
    DbSnapshot snap,
  ) async {
    final at = await _anchorBelow(anchor);
    if (at == null) return;
    final choice = await _menuAt<String>(at, [
      CheckedPopupMenuItem(
        value: 'none',
        checked: view.sortBy == null,
        child: const Text('정렬 없음'),
      ),
      const PopupMenuDivider(),
      for (final (id, name) in [
        ('title', '이름'),
        for (final p in snap.properties) (p.id, p.name),
      ]) ...[
        CheckedPopupMenuItem(
          value: 'asc:$id',
          checked: view.sortBy == id && !view.sortDesc,
          child: Text('$name ↑ 오름차순'),
        ),
        CheckedPopupMenuItem(
          value: 'desc:$id',
          checked: view.sortBy == id && view.sortDesc,
          child: Text('$name ↓ 내림차순'),
        ),
      ],
    ]);
    if (choice == null) return;
    final config = {...view.config}
      ..remove('sortBy')
      ..remove('sortDesc');
    if (choice != 'none') {
      final [dir, id] = choice.split(':');
      config['sortBy'] = id;
      config['sortDesc'] = dir == 'desc';
    }
    await ref.read(repositoryProvider).updateView(view.id, config: config);
  }

  Future<void> _newRow(DbSnapshot snap, DbView view) async {
    final repo = ref.read(repositoryProvider);
    final id = await repo.addRow(widget.databaseId);
    ref.read(screenProvider.notifier).openPage(id);
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(databaseProvider(widget.databaseId)).value;
    if (snap == null) return const SizedBox(height: 80);
    final colors = context.noteColors;
    if (snap.views.isEmpty) {
      return TextButton(
        onPressed: () => ref
            .read(repositoryProvider)
            .addView(widget.databaseId, ViewType.table),
        child: const Text('보기 추가'),
      );
    }
    final view = snap.views.firstWhere(
      (v) => v.id == _viewId,
      orElse: () => snap.views.first,
    );
    final rows = sortedRows(snap, view, query: _query);

    final toolbar = Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final v in snap.views)
                  _ViewTab(
                    view: v,
                    selected: v.id == view.id,
                    onTap: () => _selectView(v.id),
                    onMenu: (at) => _viewMenu(at, v, snap),
                  ),
                Builder(
                  builder: (anchor) => IconButton(
                    tooltip: '보기 추가',
                    iconSize: 18,
                    color: colors.textMuted,
                    icon: const Icon(Icons.add),
                    onPressed: () => _addView(anchor, snap),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_searching)
          SizedBox(
            width: 160,
            child: InEditorTextField(
              child: TextField(
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '검색',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
        IconButton(
          tooltip: view.filters.isEmpty ? '필터' : '필터 ${view.filters.length}개',
          iconSize: 18,
          color: view.filters.isEmpty ? colors.textMuted : _accent,
          icon: Badge(
            isLabelVisible: view.filters.isNotEmpty,
            label: Text('${view.filters.length}'),
            child: const Icon(Icons.filter_list),
          ),
          onPressed: () => showFilterEditor(context, view, snap),
        ),
        Builder(
          builder: (anchor) => IconButton(
            tooltip: '정렬',
            iconSize: 18,
            color: view.sortBy != null ? _accent : colors.textMuted,
            icon: const Icon(Icons.swap_vert),
            onPressed: () => _sortMenu(anchor, view, snap),
          ),
        ),
        IconButton(
          tooltip: '검색',
          iconSize: 18,
          color: _searching ? _accent : colors.textMuted,
          icon: const Icon(Icons.search),
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) _query = '';
          }),
        ),
        const SizedBox(width: 4),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed: () => _newRow(snap, view),
          child: const Text('새로 만들기'),
        ),
      ],
    );

    final body = switch (view.type) {
      ViewType.board => _BoardView(snap: snap, view: view, rows: rows),
      ViewType.list => _ListView(snap: snap, rows: rows),
      ViewType.gallery => GalleryView(snap: snap, view: view, rows: rows),
      ViewType.map => MapDbView(
        snap: snap,
        view: view,
        rows: rows,
        onChoosePlace: () => _choosePlace(view, snap),
      ),
      ViewType.timeline => TimelineView(
        snap: snap,
        view: view,
        rows: rows,
        onChooseDate: () => _chooseDate(view, snap),
      ),
      ViewType.calendar => CalendarView(
        snap: snap,
        view: view,
        rows: rows,
        onChooseDate: () => _chooseDate(view, snap),
      ),
      _ => _TableView(snap: snap, view: view, rows: rows),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.inline) _InlineTitle(database: snap.database),
        toolbar,
        Divider(height: 1, color: colors.divider),
        body,
      ],
    );
  }
}

/// Title row of an inline database (click to open it as a full page).
class _InlineTitle extends ConsumerWidget {
  const _InlineTitle({required this.database});

  final PageRow database;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: InkWell(
        onTap: () => ref.read(screenProvider.notifier).openPage(database.id),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (database.icon?.isNotEmpty ?? false)
              Text('${database.icon} ', style: const TextStyle(fontSize: 20)),
            Text(
              database.title.isEmpty ? '제목 없는 데이터베이스' : database.title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.open_in_new, size: 14, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _ViewTab extends StatelessWidget {
  const _ViewTab({
    required this.view,
    required this.selected,
    required this.onTap,
    required this.onMenu,
  });

  final DbView view;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return GestureDetector(
      onSecondaryTapDown: (d) => onMenu(d.globalPosition),
      onLongPressStart: (d) => onMenu(d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Material(
          color: selected ? colors.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: selected
                ? () {
                    final box = context.findRenderObject()! as RenderBox;
                    onMenu(box.localToGlobal(Offset(0, box.size.height)));
                  }
                : onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  Icon(viewIcon(view.type), size: 16, color: colors.text),
                  const SizedBox(width: 6),
                  Text(
                    view.name,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.text,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- table ----

/// Menu of one database item (a row / card): open, duplicate, trash.
/// Right-click on desktop, long-press on phones.
Future<void> showRowMenu(
  BuildContext context,
  WidgetRef ref,
  PageRow row,
  Offset at,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  Widget item(IconData icon, String label) => Row(
    children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
  );
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    items: [
      PopupMenuItem(value: 'open', child: item(Icons.open_in_new, '열기')),
      PopupMenuItem(value: 'duplicate', child: item(Icons.copy_outlined, '복제')),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'trash',
        child: item(Icons.delete_outline, '휴지통으로 이동'),
      ),
    ],
  );
  final repo = ref.read(repositoryProvider);
  switch (choice) {
    case 'open':
      ref.read(screenProvider.notifier).openPage(row.id);
    case 'duplicate':
      await repo.duplicatePage(row.id);
    case 'trash':
      await repo.trashPage(row.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '"${row.title.isEmpty ? '제목 없음' : row.title}"을 휴지통으로 옮겼어요',
            ),
            persist: false,
            action: SnackBarAction(
              label: '되돌리기',
              onPressed: () => repo.restorePage(row.id),
            ),
          ),
        );
      }
  }
}

/// Right-click (and, with [longPress], long-press on phones) on [child]
/// opens [showRowMenu] for [row].
class RowMenuArea extends ConsumerWidget {
  const RowMenuArea({
    super.key,
    required this.row,
    required this.child,
    this.longPress = true,
  });

  final PageRow row;
  final Widget child;
  final bool longPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GestureDetector(
    onSecondaryTapDown: (d) => showRowMenu(context, ref, row, d.globalPosition),
    onLongPressStart: longPress && _phone
        ? (d) => showRowMenu(context, ref, row, d.globalPosition)
        : null,
    child: child,
  );
}

class _TableView extends ConsumerWidget {
  const _TableView({
    required this.snap,
    required this.view,
    required this.rows,
  });

  final DbSnapshot snap;
  final DbView view;
  final List<PageRow> rows;

  static const _titleWidth = 260.0;
  static const _colWidth = 180.0;

  Future<void> _columnMenu(
    BuildContext context,
    WidgetRef ref,
    Offset at,
    DbProperty prop,
  ) async {
    final repo = ref.read(repositoryProvider);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'rename', child: Text('이름 바꾸기')),
        PopupMenuItem(
          value: 'type',
          child: Text('유형 바꾸기 (지금: ${PropType.label(prop.type)})'),
        ),
        if (prop.type == PropType.formula)
          const PopupMenuItem(value: 'formula', child: Text('수식 편집')),
        if (prop.type != PropType.formula && prop.type != PropType.place)
          PopupMenuItem(
            value: 'auto',
            child: Text(
              autoExpression(prop) == null ? '자동 채우기 수식…' : '자동 채우기 수식 (켜짐)…',
            ),
          ),
        const PopupMenuItem(value: 'hide', child: Text('이 보기에서 숨기기')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'delete', child: Text('속성 삭제')),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'rename':
        final name = await askText(context, '속성 이름', prop.name);
        if (name != null && name.trim().isNotEmpty) {
          await repo.updateProperty(prop.id, name: name.trim());
        }
      case 'formula':
        await showFormulaEditor(
          context,
          prop,
          sampleRowId: rows.firstOrNull?.id,
        );
      case 'auto':
        await showFormulaEditor(
          context,
          prop,
          sampleRowId: rows.firstOrNull?.id,
          auto: true,
        );
      case 'type':
        final to = await showMenu<String>(
          context: context,
          position: RelativeRect.fromRect(
            at & Size.zero,
            Offset.zero & overlay.size,
          ),
          items: [
            for (final t in PropType.all)
              CheckedPopupMenuItem(
                value: t,
                checked: t == prop.type,
                child: Row(
                  children: [
                    Icon(propIcon(t), size: 18),
                    const SizedBox(width: 10),
                    Text(PropType.label(t)),
                  ],
                ),
              ),
          ],
        );
        if (to == null || to == prop.type) return;
        await repo.changePropertyType(snap, prop, to);
        if (prop.type == PropType.formula &&
            to != PropType.formula &&
            (prop.config['expression'] as String? ?? '').trim().isNotEmpty) {
          await repo.refreshAutoFill(snap.database.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '"${prop.name}"을 ${PropType.label(to)}(으)로 바꿨어요. '
                  '수식은 자동 채우기로 남겨서 값이 계속 채워져요',
                ),
              ),
            );
          }
        }
      case 'hide':
        await repo.updateView(
          view.id,
          config: {
            ...view.config,
            'hidden': [...view.hidden, prop.id],
          },
        );
      case 'delete':
        await repo.deleteProperty(prop.id);
    }
  }

  Future<void> _addColumn(
    BuildContext context,
    WidgetRef ref,
    Offset at,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final hidden = [
      for (final p in snap.properties)
        if (view.hidden.contains(p.id)) p,
    ];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final t in PropType.all)
          PopupMenuItem(
            value: 'new:$t',
            child: Row(
              children: [
                Icon(propIcon(t), size: 18),
                const SizedBox(width: 10),
                Text(PropType.label(t)),
              ],
            ),
          ),
        if (hidden.isNotEmpty) const PopupMenuDivider(),
        for (final p in hidden)
          PopupMenuItem(
            value: 'show:${p.id}',
            child: Text('"${p.name}" 다시 보이기'),
          ),
      ],
    );
    if (choice == null) return;
    final repo = ref.read(repositoryProvider);
    if (choice.startsWith('new:')) {
      final type = choice.substring(4);
      final id = await repo.addProperty(
        snap.database.id,
        PropType.label(type),
        type,
      );
      if (type == PropType.formula && context.mounted) {
        final fresh = await repo.loadDatabase(snap.database.id);
        final prop = fresh?.property(id);
        if (prop != null && context.mounted) {
          await showFormulaEditor(
            context,
            prop,
            sampleRowId: rows.firstOrNull?.id,
          );
        }
      }
    } else {
      final id = choice.substring(5);
      await repo.updateView(
        view.id,
        config: {
          ...view.config,
          'hidden': [...view.hidden.where((h) => h != id)],
        },
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final props = [
      for (final p in snap.properties)
        if (!view.hidden.contains(p.id)) p,
    ];
    final border = BorderSide(color: colors.divider);

    Widget headerCell(
      Widget child,
      double width, {
      VoidCallback? onTap,
      GestureTapDownCallback? onTapDown,
    }) => GestureDetector(
      onTapDown: onTapDown,
      onSecondaryTapDown: onTapDown,
      child: InkWell(
        onTap: onTap ?? () {},
        child: Container(
          width: width,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(border: Border(right: border)),
          alignment: Alignment.centerLeft,
          child: DefaultTextStyle(
            style: TextStyle(fontSize: 13, color: colors.textMuted),
            child: child,
          ),
        ),
      ),
    );

    final header = Row(
      children: [
        headerCell(
          Row(
            children: [
              Icon(Icons.text_fields, size: 15, color: colors.textMuted),
              const SizedBox(width: 6),
              const Text('이름'),
            ],
          ),
          _titleWidth,
        ),
        for (final p in props)
          headerCell(
            Row(
              children: [
                Icon(propIcon(p.type), size: 15, color: colors.textMuted),
                const SizedBox(width: 6),
                Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                if (autoExpression(p) != null)
                  Tooltip(
                    message: '자동 채우기',
                    child: Icon(
                      Icons.auto_awesome,
                      size: 13,
                      color: colors.textMuted,
                    ),
                  ),
              ],
            ),
            _colWidth,
            onTapDown: (d) => _columnMenu(context, ref, d.globalPosition, p),
          ),
        GestureDetector(
          onTapDown: (d) => _addColumn(context, ref, d.globalPosition),
          child: Container(
            width: 40,
            height: 34,
            alignment: Alignment.center,
            child: Icon(Icons.add, size: 18, color: colors.textMuted),
          ),
        ),
      ],
    );

    // Footer: a calculation under each column (click to choose), over the
    // rows this view shows.
    final calcs = view.calcs;
    Future<void> pickCalc(Offset at, String key, String type) async {
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          at & Size.zero,
          Offset.zero & overlay.size,
        ),
        items: [
          CheckedPopupMenuItem(
            value: '',
            checked: calcs[key] == null,
            child: const Text('계산 안 함'),
          ),
          for (final c in Calc.forType(type))
            CheckedPopupMenuItem(
              value: c,
              checked: calcs[key] == c,
              child: Text(Calc.label(c)),
            ),
        ],
      );
      if (choice == null) return;
      final next = {...calcs};
      choice.isEmpty ? next.remove(key) : next[key] = choice;
      await ref
          .read(repositoryProvider)
          .updateView(view.id, config: {...view.config, 'calcs': next});
    }

    Widget calcCell(String key, DbProperty? prop, double width) {
      final calc = calcs[key];
      final result = calc == null ? null : computeCalc(calc, snap, rows, prop);
      return GestureDetector(
        onTapDown: (d) =>
            pickCalc(d.globalPosition, key, prop?.type ?? 'title'),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: width,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerRight,
            child: calc == null
                ? Text(
                    '계산',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textMuted.withValues(alpha: 0.45),
                    ),
                  )
                : Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${Calc.label(calc)} ',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textMuted,
                          ),
                        ),
                        TextSpan(
                          text: result ?? '-',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.text,
                          ),
                        ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ),
      );
    }

    final footer = Container(
      decoration: BoxDecoration(border: Border(top: border)),
      child: Row(
        children: [
          calcCell(titleGroupKey, null, _titleWidth),
          for (final p in props) calcCell(p.id, p, _colWidth),
        ],
      ),
    );

    Widget row(PageRow r) => RowMenuArea(
      row: r,
      child: Container(
        decoration: BoxDecoration(border: Border(top: border)),
        child: Row(
          children: [
            Container(
              width: _titleWidth,
              decoration: BoxDecoration(border: Border(right: border)),
              child: _TitleCell(row: r),
            ),
            for (final p in props)
              Container(
                width: _colWidth,
                decoration: BoxDecoration(border: Border(right: border)),
                child: EditableCell(
                  rowId: r.id,
                  prop: p,
                  value: snap.value(r.id, p),
                ),
              ),
          ],
        ),
      ),
    );

    return HScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          for (final r in rows) row(r),
          Container(
            decoration: BoxDecoration(border: Border(top: border)),
            child: InkWell(
              onTap: () =>
                  ref.read(repositoryProvider).addRow(snap.database.id),
              child: SizedBox(
                width: _titleWidth + props.length * _colWidth,
                height: 34,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Icon(Icons.add, size: 16, color: colors.textMuted),
                    const SizedBox(width: 6),
                    Text(
                      '새 페이지',
                      style: TextStyle(color: colors.textMuted, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
          footer,
        ],
      ),
    );
  }
}

/// Title cell: click to rename in place, "열기" opens the row as a page.
class _TitleCell extends ConsumerStatefulWidget {
  const _TitleCell({required this.row});

  final PageRow row;

  @override
  ConsumerState<_TitleCell> createState() => _TitleCellState();
}

class _TitleCellState extends ConsumerState<_TitleCell> {
  bool _hover = false;
  bool _editing = false;
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    setState(() => _editing = false);
    if (_text.text != widget.row.title) {
      await ref
          .read(repositoryProvider)
          .updatePage(widget.row.id, title: _text.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final r = widget.row;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: _editing
            ? null
            : () {
                _text.text = r.title;
                setState(() => _editing = true);
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _focus.requestFocus(),
                );
              },
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (r.icon?.isNotEmpty ?? false) Text('${r.icon} '),
              Expanded(
                child: _editing
                    ? InEditorTextField(
                        child: TextField(
                          controller: _text,
                          focusNode: _focus,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (_) => _focus.unfocus(),
                        ),
                      )
                    : Text(
                        r.title.isEmpty ? '제목 없음' : r.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: r.title.isEmpty
                              ? colors.textMuted
                              : colors.text,
                        ),
                      ),
              ),
              if (_hover && !_editing)
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => ref.read(screenProvider.notifier).openPage(r.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.divider),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '열기',
                      style: TextStyle(fontSize: 12, color: colors.textMuted),
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

// ---------------------------------------------------------------- board ----

/// Property types a board can be grouped by. Text (and the title, see
/// [titleGroupKey]) group by their distinct values, like Notion.
bool canGroupBy(DbProperty p) =>
    p.type == PropType.select ||
    p.type == PropType.multiSelect ||
    p.type == PropType.checkbox ||
    p.type == PropType.text;

/// A stand-in property for grouping by title.
DbProperty titleProperty(DbSnapshot snap) => DbProperty(
  DbPropertyRow(
    id: titleGroupKey,
    databaseId: snap.database.id,
    name: '이름',
    type: 'title',
    config: '{}',
    sortKey: '',
    updatedAt: 0,
    deviceId: '',
    deleted: false,
    dirty: false,
  ),
);

/// The property [id] names, including the title stand-in.
DbProperty? groupProperty(DbSnapshot snap, String? id) => id == titleGroupKey
    ? titleProperty(snap)
    : (id == null ? null : snap.property(id));

bool _byValue(DbProperty p) => p.type == PropType.text || p.type == 'title';

String _valueOf(DbSnapshot snap, PageRow r, DbProperty p) => p.type == 'title'
    ? r.title.trim()
    : cellText(p, snap.value(r.id, p)).trim();

/// One board column: which rows are in it and what value a row gets when
/// dropped into it.
class _Group {
  const _Group(this.key, this.label, this.option);

  /// Option id, 'true'/'false' for checkboxes, '' for "없음".
  final String key;
  final String label;
  final SelectOption? option;
}

List<_Group> _groupsFor(DbProperty prop, DbSnapshot snap, List<PageRow> rows) =>
    switch (prop.type) {
      _ when _byValue(prop) => [
        _Group('', '${prop.name} 없음', null),
        for (final v in ({
          for (final r in rows) _valueOf(snap, r, prop),
        }..remove('')).toList()..sort(naturalCompare))
          _Group(v, v, null),
      ],
      PropType.checkbox => const [
        _Group('true', '✓ 체크됨', null),
        _Group('false', '☐ 체크 안 됨', null),
      ],
      _ => [
        _Group('', '${prop.name} 없음', null),
        for (final o in prop.options) _Group(o.id, o.name, o),
      ],
    };

bool _inGroup(DbSnapshot snap, PageRow r, DbProperty prop, _Group g) {
  if (_byValue(prop)) return _valueOf(snap, r, prop) == g.key;
  final v = snap.cell(r.id, prop.id);
  return switch (prop.type) {
    PropType.checkbox => (v == true) == (g.key == 'true'),
    PropType.multiSelect =>
      g.key.isEmpty
          ? ((v as List?)
                    ?.where((id) => prop.option(id as String) != null)
                    .isEmpty ??
                true)
          : ((v as List?)?.contains(g.key) ?? false),
    _ => g.key.isEmpty ? prop.option(v as String?) == null : v == g.key,
  };
}

/// New cell value for a row dragged from group [from] to group [to].
Object? _moveValue(
  DbSnapshot snap,
  String rowId,
  DbProperty prop,
  String from,
  String to,
) {
  switch (prop.type) {
    case PropType.checkbox:
      return to == 'true';
    case PropType.multiSelect:
      final ids = [...?(snap.cell(rowId, prop.id) as List?)?.cast<String>()]
        ..remove(from);
      if (to.isNotEmpty && !ids.contains(to)) ids.add(to);
      return ids.isEmpty ? null : ids;
    default:
      return to.isEmpty ? null : to;
  }
}

/// Asks which property to group a board by; can create a new select
/// property with a name the user picks. Returns the property id.
Future<String?> pickBoardGroup(
  BuildContext context,
  WidgetRef ref,
  DbSnapshot snap,
) async {
  final candidates = snap.properties.where(canGroupBy).toList();
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('보드를 어떤 속성으로 나눌까요?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, titleGroupKey),
          child: const Row(
            children: [
              Icon(Icons.title, size: 18),
              SizedBox(width: 10),
              Text('이름 (같은 이름끼리)'),
            ],
          ),
        ),
        for (final p in candidates)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p.id),
            child: Row(
              children: [
                Icon(propIcon(p.type), size: 18),
                const SizedBox(width: 10),
                Text(p.name),
              ],
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, '#new'),
          child: const Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 10),
              Text('새 선택 속성 만들기…'),
            ],
          ),
        ),
      ],
    ),
  );
  if (choice != '#new' || !context.mounted) return choice;
  final name = await askText(context, '새 속성 이름 (예: 일차, 지역, 상태)', '');
  if (name == null || name.trim().isEmpty) return null;
  return ref
      .read(repositoryProvider)
      .addProperty(snap.database.id, name.trim(), PropType.select);
}

class _BoardView extends ConsumerWidget {
  const _BoardView({
    required this.snap,
    required this.view,
    required this.rows,
  });

  final DbSnapshot snap;
  final DbView view;
  final List<PageRow> rows;

  Future<void> _chooseGroup(BuildContext context, WidgetRef ref) async {
    final id = await pickBoardGroup(context, ref, snap);
    if (id == null) return;
    await ref
        .read(repositoryProvider)
        .updateView(view.id, config: {...view.config, 'groupBy': id});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final group = groupProperty(snap, view.groupBy);
    if (group == null || !(canGroupBy(group) || group.type == 'title')) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              '보드는 선택·다중 선택·체크박스·텍스트 속성이나 이름으로 열을 나눠요.',
              style: TextStyle(color: colors.textMuted),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _chooseGroup(context, ref),
              child: const Text('그룹 기준 속성 고르기'),
            ),
          ],
        ),
      );
    }

    final groups = _groupsFor(group, snap, rows);
    final chosen = view.config.containsKey('cardProps')
        ? view.cardProps.toSet()
        : null;
    final cardProps = [
      for (final p in snap.properties)
        if (p.id != group.id &&
            !view.hidden.contains(p.id) &&
            (chosen == null || chosen.contains(p.id)))
          p,
    ];

    return HScroll(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final g in groups)
            if (g.key.isNotEmpty ||
                rows.any((r) => _inGroup(snap, r, group, g)))
              _BoardColumn(
                snap: snap,
                view: view,
                prop: group,
                group: g,
                rows: [
                  for (final r in rows)
                    if (_inGroup(snap, r, group, g)) r,
                ],
                cardProps: cardProps,
              ),
          if (group.type != PropType.checkbox && !_byValue(group))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: colors.textMuted),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('그룹 추가'),
                onPressed: () async {
                  final name = await askText(context, '새 그룹 이름', '');
                  if (name != null && name.trim().isNotEmpty) {
                    await ref
                        .read(repositoryProvider)
                        .addSelectOption(group, name.trim());
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// What a dragged card carries: the row and the column it came from.
class _CardDrag {
  const _CardDrag(this.rowId, this.fromKey);
  final String rowId;
  final String fromKey;
}

/// Puts the dragged card's row into column [to] (sets the grouped value).
Future<void> _moveToGroup(
  WidgetRef ref,
  DbSnapshot snap,
  DbProperty prop,
  _CardDrag d,
  String to,
) async {
  if (d.fromKey == to) return;
  final repo = ref.read(repositoryProvider);
  if (prop.type == 'title') {
    await repo.updatePage(d.rowId, title: to);
  } else {
    await repo.setCell(
      d.rowId,
      prop.id,
      _moveValue(snap, d.rowId, prop, d.fromKey, to),
    );
  }
}

/// Before a card is placed by hand: a view sorted by a property shows rows
/// in that order, so a hand-made order would not show. Like Notion, offer
/// to turn the sort off. Returns whether the hand order may be applied.
Future<bool> _allowManualOrder(
  BuildContext context,
  WidgetRef ref,
  DbView view,
) async {
  if (view.sortBy == null) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: const Text(
        '이 보기는 정렬이 켜져 있어서 직접 정한 순서가 보이지 않아요.\n정렬을 끄고 직접 정한 순서로 바꿀까요?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('그대로 두기'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('정렬 끄기'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await ref
      .read(repositoryProvider)
      .updateView(
        view.id,
        config: {...view.config}
          ..remove('sortBy')
          ..remove('sortDesc'),
      );
  return true;
}

class _BoardColumn extends ConsumerWidget {
  const _BoardColumn({
    required this.snap,
    required this.view,
    required this.prop,
    required this.group,
    required this.rows,
    required this.cardProps,
  });

  final DbSnapshot snap;
  final DbView view;
  final DbProperty prop;
  final _Group group;
  final List<PageRow> rows;
  final List<DbProperty> cardProps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final repo = ref.read(repositoryProvider);
    // Dropped on the column (not on a card): just change the column.
    return DragTarget<_CardDrag>(
      onWillAcceptWithDetails: (d) => d.data.fromKey != group.key,
      onAcceptWithDetails: (d) =>
          _moveToGroup(ref, snap, prop, d.data, group.key),
      builder: (context, candidates, _) => Container(
        width: 260,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: candidates.isEmpty ? null : _accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
              child: Row(
                children: [
                  if (group.option != null)
                    Flexible(child: TagChip(group.option!))
                  else
                    Text(
                      group.label,
                      style: TextStyle(color: colors.textMuted, fontSize: 13),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    '${rows.length}',
                    style: TextStyle(color: colors.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
            for (final r in rows)
              _BoardCard(
                key: ValueKey(r.id),
                snap: snap,
                view: view,
                groupProp: prop,
                row: r,
                props: cardProps,
                fromKey: group.key,
              ),
            TextButton.icon(
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                foregroundColor: colors.textMuted,
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('새로 만들기'),
              onPressed: () async {
                final initial = switch (prop.type) {
                  PropType.checkbox => group.key == 'true',
                  PropType.multiSelect =>
                    group.key.isEmpty ? null : [group.key],
                  _ => group.key.isEmpty ? null : group.key,
                };
                final id = prop.type == 'title'
                    ? await repo.addRow(snap.database.id, title: group.key)
                    : await repo.addRow(
                        snap.database.id,
                        values: {prop.id: ?initial},
                      );
                ref.read(screenProvider.notifier).openPage(id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _BoardCard extends ConsumerStatefulWidget {
  const _BoardCard({
    super.key,
    required this.snap,
    required this.view,
    required this.groupProp,
    required this.row,
    required this.props,
    required this.fromKey,
  });

  final DbSnapshot snap;
  final DbView view;
  final DbProperty groupProp;
  final PageRow row;
  final List<DbProperty> props;
  final String fromKey;

  @override
  ConsumerState<_BoardCard> createState() => _BoardCardState();
}

class _BoardCardState extends ConsumerState<_BoardCard> {
  /// While a card is dragged over this one: drop above (true) or below.
  bool? _above;

  /// Phones: where the finger went down, and whether the long-press drag
  /// moved (if not, it was a long-press for the menu).
  Offset _pressAt = Offset.zero;
  bool _moved = false;

  bool _upperHalf(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    return box.globalToLocal(global).dy < box.size.height / 2;
  }

  /// A card dropped on this one goes right above or below it, in this
  /// column (its value changes if it came from another column).
  Future<void> _drop(_CardDrag d, bool above) async {
    final row = widget.row;
    if (d.rowId == row.id) return;
    final repo = ref.read(repositoryProvider);
    final ordered = await _allowManualOrder(context, ref, widget.view);
    await _moveToGroup(ref, widget.snap, widget.groupProp, d, widget.fromKey);
    if (!ordered) return;
    await repo.movePage(
      d.rowId,
      parentId: row.parentId,
      beforeId: above ? row.id : null,
      afterId: above ? null : row.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final snap = widget.snap;
    final row = widget.row;
    final props = widget.props;
    final card = Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ref.read(screenProvider.notifier).openPage(row.id),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${(row.icon?.isNotEmpty ?? false) ? '${row.icon} ' : ''}'
                '${row.title.isEmpty ? '제목 없음' : row.title}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              for (final p in props)
                if (snap.value(row.id, p) != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: CellDisplay(prop: p, value: snap.value(row.id, p)),
                  ),
            ],
          ),
        ),
      ),
    );
    final data = _CardDrag(row.id, widget.fromKey);
    final feedback = SizedBox(
      width: 240,
      child: Opacity(opacity: 0.85, child: card),
    );
    final dimmed = Opacity(opacity: 0.35, child: card);
    // Held near the board's left/right edge → the board scrolls that way.
    void edge(Offset? global) {
      if (mounted) DragEdgeNotification(global).dispatch(context);
    }

    // Phones: a plain drag scrolls, so a card is picked up by a long-press;
    // letting go without moving opens the card's menu instead.
    final draggable = _phone
        ? Listener(
            onPointerDown: (e) => _pressAt = e.position,
            child: LongPressDraggable<_CardDrag>(
              data: data,
              hapticFeedbackOnStart: true,
              feedback: feedback,
              childWhenDragging: dimmed,
              onDragStarted: () => _moved = false,
              onDragUpdate: (d) {
                if ((d.globalPosition - _pressAt).distance > 12) _moved = true;
                edge(d.globalPosition);
              },
              onDragEnd: (_) {
                edge(null);
                if (!_moved && mounted) {
                  showRowMenu(context, ref, row, _pressAt);
                }
              },
              child: card,
            ),
          )
        : Draggable<_CardDrag>(
            data: data,
            allowedButtonsFilter: (b) => b == kPrimaryButton,
            feedback: feedback,
            childWhenDragging: dimmed,
            onDragUpdate: (d) => edge(d.globalPosition),
            onDragEnd: (_) => edge(null),
            child: card,
          );
    const line = BorderSide(color: _accent, width: 2);
    return DragTarget<_CardDrag>(
      onWillAcceptWithDetails: (d) => d.data.rowId != row.id,
      onMove: (d) {
        final above = _upperHalf(d.offset + const Offset(0, 20));
        if (above != _above) setState(() => _above = above);
      },
      onLeave: (_) => setState(() => _above = null),
      onAcceptWithDetails: (d) {
        final above = _above ?? true;
        setState(() => _above = null);
        _drop(d.data, above);
      },
      builder: (context, _, _) => Container(
        // The gap below each card shows where a dropped card lands.
        padding: const EdgeInsets.symmetric(vertical: 3),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          border: Border(
            top: _above == true ? line : BorderSide.none,
            bottom: _above == false ? line : BorderSide.none,
          ),
        ),
        child: RowMenuArea(row: row, longPress: false, child: draggable),
      ),
    );
  }
}

bool get _phone =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

// ----------------------------------------------------------------- list ----

class _ListView extends ConsumerWidget {
  const _ListView({required this.snap, required this.rows});

  final DbSnapshot snap;
  final List<PageRow> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final chips = [
      for (final p in snap.properties)
        if (p.type == PropType.select ||
            p.type == PropType.multiSelect ||
            p.type == PropType.date)
          p,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rows)
          RowMenuArea(
            row: r,
            child: InkWell(
              onTap: () => ref.read(screenProvider.notifier).openPage(r.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.divider)),
                ),
                child: Row(
                  children: [
                    Text((r.icon?.isNotEmpty ?? false) ? r.icon! : '📄'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.title.isEmpty ? '제목 없음' : r.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: colors.text,
                        ),
                      ),
                    ),
                    for (final p in chips)
                      if (snap.value(r.id, p) != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: CellDisplay(
                            prop: p,
                            value: snap.value(r.id, p),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('항목이 없어요', style: TextStyle(color: colors.textMuted)),
          ),
      ],
    );
  }
}

/// Property list shown at the top of a database row's page.
class RowProperties extends ConsumerWidget {
  const RowProperties({
    super.key,
    required this.rowId,
    required this.databaseId,
  });

  final String rowId;
  final String databaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(databaseProvider(databaseId)).value;
    if (snap == null) return const SizedBox.shrink();
    final colors = context.noteColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in snap.properties)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 150,
                height: 34,
                child: Row(
                  children: [
                    Icon(propIcon(p.type), size: 16, color: colors.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: colors.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: EditableCell(
                  rowId: rowId,
                  prop: p,
                  value: snap.value(rowId, p),
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Divider(height: 1, color: colors.divider),
        ),
      ],
    );
  }
}
