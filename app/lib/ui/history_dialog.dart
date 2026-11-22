import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notes_repository.dart';
import '../data/sync_engine.dart';
import '../providers.dart';
import 'theme.dart';

/// 변경 기록: older versions of this page kept by the sync server — edits
/// that lost to another device, and snapshots every 10 minutes (30 days).
/// Restoring never overwrites what is there now: a block comes back as a
/// copy at the end of the page, a title replaces the current title.
Future<void> showHistoryDialog(BuildContext context, String pageId) =>
    showDialog<void>(
      context: context,
      builder: (_) => _HistoryDialog(pageId: pageId),
    );

class _HistoryDialog extends ConsumerStatefulWidget {
  const _HistoryDialog({required this.pageId});

  final String pageId;

  @override
  ConsumerState<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends ConsumerState<_HistoryDialog> {
  late final Future<List<HistoryEntry>> _entries = ref
      .read(syncEngineProvider)
      .pageHistory(widget.pageId);
  final _restored = <HistoryEntry>{};

  Future<void> _restore(HistoryEntry e) async {
    final repo = ref.read(repositoryProvider);
    if (e.table == 'pages') {
      await repo.updatePage(widget.pageId, title: e.data['title'] as String?);
    } else {
      await repo.restoreBlockCopy(
        widget.pageId,
        e.data['type'] as String,
        e.data['data'] as String,
      );
      ref.read(syncEngineProvider).notifyPageChanged(widget.pageId);
    }
    setState(() => _restored.add(e));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return AlertDialog(
      title: const Text('변경 기록'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: FutureBuilder(
          future: _entries,
          builder: (context, snap) {
            if (snap.hasError) {
              final e = snap.error;
              return Center(
                child: Text(
                  e is SyncException ? e.message : '불러오지 못했어요: $e',
                  style: TextStyle(color: colors.textMuted),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final title = ref.read(pageProvider(widget.pageId)).value?.title;
            final seen = <String>{};
            final entries = [
              for (final e in snap.data!)
                // Skip empty lines, titles equal to the current one, and
                // the same text repeated.
                if (_preview(e).isNotEmpty &&
                    !(e.table == 'pages' && _preview(e) == title) &&
                    seen.add('${e.table}${e.id}${_preview(e)}'))
                  e,
            ];
            if (entries.isEmpty) {
              return Center(
                child: Text(
                  '남아 있는 이전 버전이 없어요.\n'
                  '다른 기기에서 덮어쓴 내용과 10분 간격의 이전 버전을 30일 동안 보관해요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textMuted),
                ),
              );
            }
            return ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: colors.divider),
              itemBuilder: (context, i) {
                final e = entries[i];
                final t = e.replacedAt;
                final when =
                    '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
                    '${t.minute.toString().padLeft(2, '0')}';
                final what = e.conflict
                    ? '충돌로 밀려난 수정'
                    : e.deleted
                    ? '지워지기 전'
                    : '이전 버전';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    e.conflict ? Icons.warning_amber : Icons.history,
                    color: e.conflict ? Colors.orange : colors.textMuted,
                  ),
                  title: Text(
                    _preview(e),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${e.table == 'pages' ? '제목 · ' : ''}$what · ${e.device} · $when',
                    style: TextStyle(fontSize: 12, color: colors.textMuted),
                  ),
                  trailing: _restored.contains(e)
                      ? const Icon(Icons.check, color: Colors.green)
                      : TextButton(
                          onPressed: () => _restore(e),
                          child: const Text('되살리기'),
                        ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  static String _preview(HistoryEntry e) => e.table == 'pages'
      ? (e.data['title'] as String? ?? '')
      : blockPlainText(e.data['data'] as String? ?? '{}').trim();
}
