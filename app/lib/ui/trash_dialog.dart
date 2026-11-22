import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'page_actions.dart';
import 'theme.dart';

/// Trashed pages: restore or delete permanently.
Future<void> showTrashDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _TrashDialog(),
  );
}

class _TrashDialog extends ConsumerWidget {
  const _TrashDialog();

  Future<bool> _confirm(BuildContext context, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('영구 삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final repo = ref.watch(repositoryProvider);
    final pages = ref.watch(trashProvider).value ?? const [];
    return Dialog(
      child: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, size: 20),
                  const SizedBox(width: 8),
                  const Text('휴지통', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(
                    '30일 지나면 자동으로 영구 삭제',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  const Spacer(),
                  if (pages.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        if (await _confirm(
                          context,
                          '휴지통의 페이지 ${pages.length}개를 영구 삭제할까요?',
                        )) {
                          await repo.emptyTrash();
                        }
                      },
                      child: const Text('비우기'),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Expanded(
              child: pages.isEmpty
                  ? Center(
                      child: Text(
                        '휴지통이 비어 있어요',
                        style: TextStyle(color: colors.textMuted),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final p in pages)
                          ListTile(
                            dense: true,
                            leading: Text(
                              (p.icon?.isNotEmpty ?? false) ? p.icon! : '📄',
                              style: const TextStyle(fontSize: 18),
                            ),
                            title: Text(p.title.isEmpty ? '제목 없음' : p.title),
                            subtitle: Text(
                              formatEdited(p.trashedAt!).replaceAll('편집', '삭제'),
                              style: TextStyle(color: colors.textMuted),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '복원',
                                  icon: const Icon(Icons.restore, size: 18),
                                  onPressed: () => repo.restorePage(p.id),
                                ),
                                IconButton(
                                  tooltip: '영구 삭제',
                                  icon: const Icon(
                                    Icons.delete_forever_outlined,
                                    size: 18,
                                  ),
                                  onPressed: () async {
                                    if (await _confirm(
                                      context,
                                      '"${p.title.isEmpty ? '제목 없음' : p.title}"을(를) 영구 삭제할까요?',
                                    )) {
                                      await repo.deletePage(
                                        p.id,
                                        removeUnusedFiles: true,
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
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
