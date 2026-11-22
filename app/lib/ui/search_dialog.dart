import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/notes_repository.dart';
import '../providers.dart';
import 'theme.dart';

/// Ctrl+P: search page titles and text. Empty query lists recently
/// edited pages. ↑/↓ to move, Enter to open.
Future<void> showSearchDialog(BuildContext context, WidgetRef ref) async {
  final id = await showDialog<String>(
    context: context,
    builder: (_) => const _SearchDialog(),
  );
  if (id != null) ref.read(screenProvider.notifier).openPage(id);
}

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog();

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SearchHit> _hits = const [];
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(String query) async {
    final repo = ref.read(repositoryProvider);
    List<SearchHit> hits;
    if (query.trim().isEmpty) {
      final pages = [...?ref.read(pagesProvider).value]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      hits = [for (final p in pages.take(8)) SearchHit(p, null)];
    } else {
      hits = await repo.search(query);
    }
    if (!mounted || query != _controller.text) return;
    setState(() {
      _hits = hits;
      _index = 0;
    });
  }

  void _open(PageRow page) => Navigator.pop(context, page.id);

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _index = (_index + 1).clamp(0, _hits.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _index = (_index - 1).clamp(0, _hits.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && _hits.isNotEmpty) {
      _open(_hits[_index].page);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final empty = _controller.text.trim().isEmpty;
    return Dialog(
      alignment: const Alignment(0, -0.6),
      child: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(
                  hintText: '검색 (제목·내용 · path: title: content: task:)',
                  prefixIcon: Icon(Icons.search),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 16),
                ),
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(
                    const Duration(milliseconds: 150),
                    () => _run(v),
                  );
                },
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                empty ? '최근 편집' : '결과 ${_hits.length}개',
                style: TextStyle(fontSize: 12, color: colors.textMuted),
              ),
            ),
            Expanded(
              child: _hits.isEmpty && !empty
                  ? Center(
                      child: Text(
                        '결과 없음',
                        style: TextStyle(color: colors.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _hits.length,
                      itemBuilder: (context, i) {
                        final hit = _hits[i];
                        final p = hit.page;
                        return Material(
                          color: i == _index
                              ? colors.hover
                              : Colors.transparent,
                          child: ListTile(
                            dense: true,
                            leading: Text(
                              (p.icon?.isNotEmpty ?? false) ? p.icon! : '📄',
                              style: const TextStyle(fontSize: 18),
                            ),
                            title: Text(
                              p.title.isEmpty ? '제목 없음' : p.title,
                              style: TextStyle(color: colors.text),
                            ),
                            subtitle: hit.snippet == null
                                ? null
                                : Text(
                                    hit.snippet!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: colors.textMuted),
                                  ),
                            onTap: () => _open(p),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
