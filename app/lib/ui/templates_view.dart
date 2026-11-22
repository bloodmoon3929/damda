import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../providers.dart';
import 'page_actions.dart';
import 'theme.dart';

/// 템플릿 관리: create, edit, use and delete page templates.
/// Templates are ordinary pages flagged `is_template`, kept out of the tree.
class TemplatesView extends ConsumerWidget {
  const TemplatesView({super.key});

  Future<void> _delete(BuildContext context, WidgetRef ref, PageRow t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
          '템플릿 "${t.title.isEmpty ? '제목 없음' : t.title}"을(를) 삭제할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(repositoryProvider).deletePage(t.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final repo = ref.watch(repositoryProvider);
    final screen = ref.read(screenProvider.notifier);
    final templates = ref.watch(templatesProvider).value ?? const [];

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(32, 48, 32, 48),
          children: [
            Row(
              children: [
                const Text('🧩', style: TextStyle(fontSize: 40)),
                const SizedBox(width: 12),
                Text(
                  '템플릿',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    color: colors.text,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('새 템플릿'),
                  onPressed: () async => screen.openPage(
                    await repo.createPage(title: '새 템플릿', isTemplate: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '자주 쓰는 페이지 형식을 템플릿으로 만들어 두고, 사이드바 "새 페이지" 옆 ▲ 버튼으로 바로 만들 수 있어요.\n'
              '기존 페이지는 ⋯ 메뉴의 "템플릿으로 저장"으로 템플릿이 돼요.',
              style: TextStyle(color: colors.textMuted, height: 1.5),
            ),
            const SizedBox(height: 24),
            if (templates.isEmpty)
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.divider),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '아직 템플릿이 없어요',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textMuted),
                ),
              )
            else
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final t in templates)
                    _TemplateCard(
                      template: t,
                      onUse: () async =>
                          screen.openPage(await repo.createFromTemplate(t.id)),
                      onEdit: () => screen.openPage(t.id),
                      onDelete: () => _delete(context, ref, t),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.onUse,
    required this.onEdit,
    required this.onDelete,
  });

  final PageRow template;
  final VoidCallback onUse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final t = template;
    return Container(
      width: 260,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                (t.icon?.isNotEmpty ?? false) ? t.icon! : '📄',
                style: const TextStyle(fontSize: 26),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                iconSize: 18,
                icon: Icon(Icons.more_horiz, color: colors.textMuted),
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('편집')),
                  PopupMenuItem(value: 'delete', child: Text('삭제')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t.title.isEmpty ? '제목 없음' : t.title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            formatEdited(t.updatedAt),
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(onPressed: onUse, child: const Text('사용')),
              const SizedBox(width: 8),
              TextButton(onPressed: onEdit, child: const Text('편집')),
            ],
          ),
        ],
      ),
    );
  }
}
