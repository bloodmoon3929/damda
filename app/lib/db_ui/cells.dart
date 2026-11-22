import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database_repository.dart';
import '../data/formula.dart';
import '../data/notes_repository.dart';
import '../providers.dart';
import '../ui/in_editor_text_field.dart';
import '../ui/theme.dart';
import 'map_view.dart';

/// Notion tag colors (background, text) for light / dark themes.
(Color, Color) tagColors(BuildContext context, String color) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  const light = {
    'gray': Color(0xFFE3E2E0),
    'brown': Color(0xFFEEE0DA),
    'orange': Color(0xFFFADEC9),
    'yellow': Color(0xFFFDECC8),
    'green': Color(0xFFDBEDDB),
    'blue': Color(0xFFD3E5EF),
    'purple': Color(0xFFE8DEEE),
    'pink': Color(0xFFF5E0E9),
    'red': Color(0xFFFFE2DD),
  };
  const darkBg = {
    'gray': Color(0xFF373737),
    'brown': Color(0xFF4A3228),
    'orange': Color(0xFF5C3B23),
    'yellow': Color(0xFF564328),
    'green': Color(0xFF243D30),
    'blue': Color(0xFF143A4E),
    'purple': Color(0xFF3C2D49),
    'pink': Color(0xFF4E2C3C),
    'red': Color(0xFF522E2A),
  };
  final bg = (dark ? darkBg : light)[color] ?? light['gray']!;
  return (bg, dark ? const Color(0xFFE6E6E6) : const Color(0xFF37352F));
}

class TagChip extends StatelessWidget {
  const TagChip(this.option, {super.key, this.dense = false});

  final SelectOption option;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tagColors(context, option.color);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: dense ? 0 : 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        option.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: fg, height: 1.4),
      ),
    );
  }
}

IconData propIcon(String type) => switch (type) {
  PropType.text => Icons.notes,
  PropType.number => Icons.tag,
  PropType.select => Icons.arrow_drop_down_circle_outlined,
  PropType.multiSelect => Icons.list,
  PropType.date => Icons.calendar_today_outlined,
  PropType.checkbox => Icons.check_box_outlined,
  PropType.url => Icons.link,
  PropType.formula => Icons.functions,
  PropType.place => Icons.place_outlined,
  _ => Icons.notes,
};

/// Read-only rendering of a cell value.
class CellDisplay extends StatelessWidget {
  const CellDisplay({super.key, required this.prop, required this.value});

  final DbProperty prop;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final v = value;
    switch (prop.type) {
      case PropType.select:
        final o = prop.option(v as String?);
        return o == null ? const SizedBox.shrink() : TagChip(o);
      case PropType.multiSelect:
        final ids = (v as List?)?.cast<String>() ?? const [];
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final id in ids)
              if (prop.option(id) case final o?) TagChip(o),
          ],
        );
      case PropType.checkbox:
        return Icon(
          v == true ? Icons.check_box : Icons.check_box_outline_blank,
          size: 18,
          color: v == true ? const Color(0xFF2383E2) : colors.textMuted,
        );
      case PropType.url:
        return Text(
          v as String? ?? '',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            decoration: TextDecoration.underline,
          ),
        );
      case PropType.place:
        final place = Place.fromCell(v);
        return place == null
            ? const SizedBox.shrink()
            : Text(
                '📍 ${place.name ?? place.address}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: colors.text),
              );
      case PropType.formula:
        return Text(
          formatFormulaValue(v),
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: v is FormulaError ? 12 : 14,
            color: v is FormulaError
                ? Theme.of(context).colorScheme.error
                : colors.text,
          ),
        );
      default:
        return Text(
          v == null ? '' : cellText(prop, v),
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: colors.text),
        );
    }
  }
}

/// A cell you can click to edit (table cells, row page properties).
class EditableCell extends ConsumerStatefulWidget {
  const EditableCell({
    super.key,
    required this.rowId,
    required this.prop,
    required this.value,
    this.minHeight = 34,
  });

  final String rowId;
  final DbProperty prop;
  final Object? value;
  final double minHeight;

  @override
  ConsumerState<EditableCell> createState() => _EditableCellState();
}

class _EditableCellState extends ConsumerState<EditableCell> {
  bool _editing = false;
  late final TextEditingController _text = TextEditingController();
  final _focus = FocusNode();

  NotesRepository get _repo => ref.read(repositoryProvider);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commitText();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _commitText() async {
    setState(() => _editing = false);
    final raw = _text.text.trim();
    Object? value = raw.isEmpty ? null : raw;
    if (widget.prop.type == PropType.number && raw.isNotEmpty) {
      value = num.tryParse(raw.replaceAll(',', ''));
      if (value == null) return; // not a number: keep the old value
    }
    if (value != widget.value) {
      await _repo.setCell(widget.rowId, widget.prop.id, value);
    }
  }

  Future<void> _onTap() async {
    final prop = widget.prop;
    switch (prop.type) {
      case PropType.formula:
        // A formula has no per-row value: clicking edits the expression.
        if (!mounted) return;
        await showFormulaEditor(context, prop, sampleRowId: widget.rowId);
      case PropType.place:
        final picked = await showPlacePicker(
          context,
          Place.fromCell(widget.value),
        );
        if (picked == null) return;
        await _repo.setCell(
          widget.rowId,
          prop.id,
          picked.isEmpty ? null : picked,
        );
      case PropType.checkbox:
        await _repo.setCell(widget.rowId, prop.id, widget.value != true);
      case PropType.date:
        final current = DateTime.tryParse(widget.value as String? ?? '');
        final picked = await showDatePicker(
          context: context,
          initialDate: current ?? DateTime.now(),
          firstDate: DateTime(1900),
          lastDate: DateTime(2200),
        );
        if (picked != null) {
          final s =
              '${picked.year}-${picked.month.toString().padLeft(2, '0')}-'
              '${picked.day.toString().padLeft(2, '0')}';
          await _repo.setCell(widget.rowId, prop.id, s);
        }
      case PropType.select || PropType.multiSelect:
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => OptionPicker(
            rowId: widget.rowId,
            propId: prop.id,
            databaseId: prop.row.databaseId,
          ),
        );
      default:
        _text.text = widget.value == null ? '' : '${widget.value}';
        setState(() => _editing = true);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _focus.requestFocus(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _editing
        ? InEditorTextField(
            child: TextField(
              controller: _text,
              focusNode: _focus,
              keyboardType: widget.prop.type == PropType.number
                  ? TextInputType.number
                  : TextInputType.text,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _focus.unfocus(),
            ),
          )
        : CellDisplay(prop: widget.prop, value: widget.value);
    return InkWell(
      onTap: _editing ? null : _onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: widget.minHeight),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: child,
      ),
    );
  }
}

/// Choose / create select options for one cell (single or multi).
class OptionPicker extends ConsumerStatefulWidget {
  const OptionPicker({
    super.key,
    required this.rowId,
    required this.propId,
    required this.databaseId,
  });

  final String rowId;
  final String propId;
  final String databaseId;

  @override
  ConsumerState<OptionPicker> createState() => _OptionPickerState();
}

class _OptionPickerState extends ConsumerState<OptionPicker> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(databaseProvider(widget.databaseId)).value;
    final prop = snap?.property(widget.propId);
    if (snap == null || prop == null) return const SizedBox.shrink();
    final repo = ref.read(repositoryProvider);
    final multi = prop.type == PropType.multiSelect;
    final value = snap.cell(widget.rowId, prop.id);
    final selected = multi
        ? {...?(value as List?)?.cast<String>()}
        : {if (value is String) value};
    final query = _input.text.trim();
    final shown = [
      for (final o in prop.options)
        if (query.isEmpty || o.name.toLowerCase().contains(query.toLowerCase()))
          o,
    ];
    final exact = prop.options.any((o) => o.name == query);

    Future<void> toggle(String id) async {
      if (multi) {
        final next = selected.contains(id)
            ? (selected..remove(id))
            : (selected..add(id));
        await repo.setCell(
          widget.rowId,
          prop.id,
          next.isEmpty ? null : next.toList(),
        );
      } else {
        await repo.setCell(
          widget.rowId,
          prop.id,
          selected.contains(id) ? null : id,
        );
        if (mounted) Navigator.pop(this.context);
      }
    }

    Future<void> create() async {
      if (query.isEmpty || exact) return;
      final option = await repo.addSelectOption(prop, query);
      _input.clear();
      await toggle(option.id);
      if (mounted) setState(() {});
    }

    return Dialog(
      alignment: const Alignment(0, -0.4),
      child: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _input,
                autofocus: true,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '옵션 검색 또는 새로 만들기',
                  border: const OutlineInputBorder(),
                  prefixIcon: Icon(propIcon(prop.type), size: 18),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) =>
                    shown.length == 1 && query.isNotEmpty && exact
                    ? toggle(shown.single.id)
                    : create(),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in shown)
                    ListTile(
                      dense: true,
                      title: Align(
                        alignment: Alignment.centerLeft,
                        child: TagChip(o),
                      ),
                      trailing: selected.contains(o.id)
                          ? const Icon(Icons.check, size: 18)
                          : null,
                      onTap: () => toggle(o.id),
                    ),
                  if (query.isNotEmpty && !exact)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add, size: 18),
                      title: Text('"$query" 만들기'),
                      onTap: create,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (selected.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await repo.setCell(widget.rowId, prop.id, null);
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text('지우기'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edit a formula property's expression, with property buttons and a live
/// preview on [sampleRowId]. With [auto], edits the formula that fills a
/// plain property by itself (its stored values follow the result).
Future<void> showFormulaEditor(
  BuildContext context,
  DbProperty prop, {
  String? sampleRowId,
  bool auto = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FormulaEditor(
      propId: prop.id,
      databaseId: prop.row.databaseId,
      initial: prop.config[auto ? 'auto' : 'expression'] as String? ?? '',
      sampleRowId: sampleRowId,
      auto: auto,
    ),
  );
}

class _FormulaEditor extends ConsumerStatefulWidget {
  const _FormulaEditor({
    required this.propId,
    required this.databaseId,
    required this.initial,
    this.sampleRowId,
    this.auto = false,
  });

  final String propId;
  final String databaseId;
  final String initial;
  final String? sampleRowId;
  final bool auto;

  @override
  ConsumerState<_FormulaEditor> createState() => _FormulaEditorState();
}

class _FormulaEditorState extends ConsumerState<_FormulaEditor> {
  late final _controller = TextEditingController(text: widget.initial);

  /// Other databases the draft reads with lookup(...), loaded for the
  /// preview whenever that set changes.
  Set<String> _lookedUp = const {};
  ExternalLookup? _external;

  void _loadLookups() {
    final names = lookedUpDatabases(_controller.text);
    if (names.length == _lookedUp.length && names.containsAll(_lookedUp)) {
      return;
    }
    _lookedUp = names;
    ref
        .read(repositoryProvider)
        .externalLookup(names, near: widget.databaseId)
        .then((ext) {
          if (mounted && identical(_lookedUp, names)) {
            setState(() => _external = ext);
          }
        });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLookups());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _insert(String text) {
    final sel = _controller.selection;
    final value = _controller.text;
    final start = sel.isValid ? sel.start : value.length;
    final end = sel.isValid ? sel.end : value.length;
    _controller.value = TextEditingValue(
      text: value.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(databaseProvider(widget.databaseId)).value;
    final prop = snap?.property(widget.propId);
    if (snap == null || prop == null) return const SizedBox.shrink();
    final colors = context.noteColors;

    // Preview: the draft worked out on the sample row, or else the first
    // row it works on (an item with an empty input, like 여행자 보험 without
    // 원화, would only show an error).
    Object? previewOn(String rowId) {
      if (widget.auto) {
        final result = snap.evaluate(
          rowId,
          _controller.text,
          external: _external,
        );
        return result is FormulaError ? result : autoValue(prop, result);
      }
      final draft = DbProperty(
        prop.row.copyWith(
          config: jsonEncode({...prop.config, 'expression': _controller.text}),
        ),
      );
      return DbSnapshot(
        database: snap.database,
        properties: [
          for (final p in snap.properties) p.id == prop.id ? draft : p,
        ],
        views: snap.views,
        rows: snap.rows,
        cells: snap.cells,
        external: _external ?? snap.external,
      ).value(rowId, draft);
    }

    var rowId = widget.sampleRowId ?? snap.rows.firstOrNull?.id;
    Object? preview = rowId == null ? null : previewOn(rowId);
    if (preview is FormulaError) {
      for (final r in snap.rows.take(50)) {
        final v = previewOn(r.id);
        if (v is! FormulaError && v != null) {
          (rowId, preview) = (r.id, v);
          break;
        }
      }
    }
    final previewRow = snap.rows.where((r) => r.id == rowId).firstOrNull;

    return AlertDialog(
      title: Text(widget.auto ? '자동 채우기: ${prop.name}' : '수식: ${prop.name}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 14),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'prop("비용") / prop("인원")',
              ),
              onChanged: (_) {
                _loadLookups();
                setState(() {});
              },
            ),
            if (widget.auto)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '결과가 이 속성(${PropType.label(prop.type)})의 값으로 저장되고, '
                  '항목이나 참조한 값이 바뀌면 다시 채워져요. 비우면 자동 채우기를 꺼요.',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ),
            const SizedBox(height: 10),
            Text('속성', style: TextStyle(fontSize: 12, color: colors.textMuted)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ActionChip(
                  label: const Text('이름'),
                  onPressed: () => _insert('prop("이름")'),
                ),
                for (final p in snap.properties)
                  if (p.id != prop.id)
                    ActionChip(
                      avatar: Icon(propIcon(p.type), size: 14),
                      label: Text(p.name),
                      onPressed: () => _insert('prop("${p.name}")'),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '함수: if(조건, 참, 거짓)  ifs(조건1, 값1, 조건2, 값2, 그 밖)  '
              'round(x, 자릿수)  floor ceil abs sqrt pow mod  min max sum mean median\n'
              '글자: length contains empty concat trim substring(t, 0, 3) '
              'startsWith endsWith replace replaceAll test match padStart upper lower\n'
              '이름 붙이기: let(x, prop("가격"), x * 1.1)  lets(a, 1, b, 2, a + b)  '
              '— 이어 쓰기: prop("이름").length()\n'
              '날짜: today() now() dateAdd(날짜, 3, "days")  dateBetween(a, b, "days")  '
              'formatDate(날짜, "M월 D일 (ddd)")  year month day weekday '
              '— 결과가 날짜면 캘린더·타임라인에 쓸 수 있어요\n'
              '다른 데이터베이스: lookup("데이터베이스", "항목 이름", "속성")\n'
              '연산: + - * / %  == != > < >= <=  and or not',
              style: TextStyle(
                fontSize: 12,
                color: colors.textMuted,
                height: 1.5,
              ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Text(
                  previewRow == null
                      ? '미리보기  '
                      : '미리보기 (${previewRow.title.isEmpty ? '제목 없음' : previewRow.title})  ',
                  style: TextStyle(color: colors.textMuted),
                ),
                Expanded(
                  child: rowId == null
                      ? Text(
                          '항목이 없어요',
                          style: TextStyle(color: colors.textMuted),
                        )
                      : CellDisplay(prop: prop, value: preview),
                ),
              ],
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
          onPressed: () async {
            final repo = ref.read(repositoryProvider);
            await repo.updateProperty(
              prop.id,
              config: {
                ...prop.config,
                (widget.auto ? 'auto' : 'expression'): _controller.text,
              },
            );
            if (widget.auto) await repo.refreshAutoFill(widget.databaseId);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}

String jsonEncodeConfig(Map<String, dynamic> config) => jsonEncode(config);
