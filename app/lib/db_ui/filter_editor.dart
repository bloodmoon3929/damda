import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database_repository.dart';
import '../providers.dart';
import '../ui/theme.dart';
import 'cells.dart';

/// Edit a view's filters (all conditions must match).
Future<void> showFilterEditor(
  BuildContext context,
  DbView view,
  DbSnapshot snap,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FilterEditor(view: view, snap: snap),
  );
}

class _FilterEditor extends ConsumerStatefulWidget {
  const _FilterEditor({required this.view, required this.snap});

  final DbView view;
  final DbSnapshot snap;

  @override
  ConsumerState<_FilterEditor> createState() => _FilterEditorState();
}

class _FilterEditorState extends ConsumerState<_FilterEditor> {
  late final List<Map<String, dynamic>> _filters = widget.view.filters;

  String _typeOf(String propId) => propId == 'title'
      ? PropType.text
      : widget.snap.property(propId)?.type ?? PropType.text;

  void _setProp(int i, String propId) => setState(() {
    _filters[i] = {
      'prop': propId,
      'op': filterOps(_typeOf(propId)).first.$1,
      'value': null,
    };
  });

  Future<void> _save() async {
    await ref
        .read(repositoryProvider)
        .updateView(
          widget.view.id,
          config: {...widget.view.config, 'filters': _filters},
        );
    if (mounted) Navigator.pop(context);
  }

  Widget _valueField(int i) {
    final f = _filters[i];
    final op = f['op'] as String;
    if (const {'empty', 'not_empty', 'checked', 'unchecked'}.contains(op)) {
      return const SizedBox.shrink();
    }
    final propId = f['prop'] as String;
    final prop = propId == 'title' ? null : widget.snap.property(propId);
    switch (prop?.type) {
      case PropType.select || PropType.multiSelect:
        return DropdownButton<String>(
          value: prop!.option(f['value'] as String?)?.id,
          hint: const Text('옵션'),
          isExpanded: true,
          items: [
            for (final o in prop.options)
              DropdownMenuItem(value: o.id, child: TagChip(o)),
          ],
          onChanged: (v) => setState(() => f['value'] = v),
        );
      case PropType.date:
        final value = f['value'] as String?;
        return OutlinedButton(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: DateTime.tryParse(value ?? '') ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2200),
            );
            if (picked != null) {
              setState(
                () => f['value'] =
                    '${picked.year}-${picked.month.toString().padLeft(2, '0')}-'
                    '${picked.day.toString().padLeft(2, '0')}',
              );
            }
          },
          child: Text(value ?? '날짜 선택'),
        );
      default:
        return TextFormField(
          key: ValueKey('v$i$propId'),
          initialValue: f['value'] == null ? '' : '${f['value']}',
          decoration: const InputDecoration(isDense: true, hintText: '값'),
          keyboardType:
              prop?.type == PropType.number || prop?.type == PropType.formula
              ? TextInputType.number
              : TextInputType.text,
          onChanged: (v) => f['value'] = v,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final props = [
      ('title', '이름'),
      for (final p in widget.snap.properties) (p.id, p.name),
    ];
    return AlertDialog(
      title: Text('필터: ${widget.view.name}'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_filters.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '필터가 없어요. 모든 항목이 보여요.',
                  style: TextStyle(color: colors.textMuted),
                ),
              ),
            for (var i = 0; i < _filters.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        i == 0 ? '조건' : '그리고',
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: DropdownButton<String>(
                        value: props.any((p) => p.$1 == _filters[i]['prop'])
                            ? _filters[i]['prop'] as String
                            : null,
                        isExpanded: true,
                        items: [
                          for (final (id, name) in props)
                            DropdownMenuItem(
                              value: id,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => v == null ? null : _setProp(i, v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 140,
                      child: DropdownButton<String>(
                        value: _filters[i]['op'] as String,
                        isExpanded: true,
                        items: [
                          for (final (op, label) in filterOps(
                            _typeOf(_filters[i]['prop'] as String),
                          ))
                            DropdownMenuItem(value: op, child: Text(label)),
                        ],
                        onChanged: (v) => setState(() => _filters[i]['op'] = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _valueField(i)),
                    IconButton(
                      tooltip: '삭제',
                      iconSize: 18,
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _filters.removeAt(i)),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('필터 추가'),
                onPressed: () => setState(
                  () => _filters.add({
                    'prop': 'title',
                    'op': 'contains',
                    'value': '',
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_filters.isNotEmpty)
          TextButton(
            onPressed: () => setState(_filters.clear),
            child: const Text('모두 지우기'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _save, child: const Text('적용')),
      ],
    );
  }
}
