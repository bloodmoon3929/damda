import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/album_repository.dart';
import '../data/database.dart';
import '../data/links.dart';
import '../providers.dart';
import 'icon_picker.dart';
import 'text_prompt.dart';
import 'theme.dart';

/// Page menu actions shared by the sidebar (right-click) and the page's ⋯ menu.
enum PageAction {
  favorite,
  addChild,
  addAlbum,
  rename,
  icon,
  duplicate,
  copyLink,
  move,
  saveAsTemplate,
  trash,
}

List<PopupMenuEntry<PageAction>> pageMenuItems(
  PageRow page, {
  required bool isInbox,
  bool includeAddChild = true,
  bool includeFavorite = true,
}) {
  PopupMenuItem<PageAction> item(
    PageAction a,
    IconData icon,
    String label, {
    String? shortcut,
  }) => PopupMenuItem(
    value: a,
    height: 36,
    child: _MenuRow(icon: icon, label: label, shortcut: shortcut),
  );

  return [
    if (includeFavorite) ...[
      item(
        PageAction.favorite,
        page.favorite ? Icons.star : Icons.star_border,
        page.favorite ? '즐겨찾기에서 제거' : '즐겨찾기에 추가',
      ),
      const PopupMenuDivider(),
    ],
    if (includeAddChild) item(PageAction.addChild, Icons.add, '하위 페이지 추가'),
    if (includeAddChild)
      item(PageAction.addAlbum, Icons.photo_library_outlined, '하위 사진 보관함 추가'),
    item(PageAction.rename, Icons.edit_outlined, '이름 바꾸기'),
    item(PageAction.icon, Icons.emoji_emotions_outlined, '아이콘 변경'),
    item(PageAction.duplicate, Icons.copy_outlined, '복제'),
    item(PageAction.copyLink, Icons.link, '링크 복사'),
    if (!isInbox) item(PageAction.move, Icons.drive_file_move_outline, '옮기기'),
    item(
      PageAction.saveAsTemplate,
      Icons.dashboard_customize_outlined,
      '템플릿으로 저장',
    ),
    if (!isInbox) ...[
      const PopupMenuDivider(),
      item(PageAction.trash, Icons.delete_outline, '휴지통으로 이동'),
    ],
  ];
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.shortcut});

  final IconData icon;
  final String label;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return Row(
      children: [
        Icon(icon, size: 18, color: colors.text),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        if (shortcut != null)
          Text(
            shortcut!,
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
      ],
    );
  }
}

Future<void> runPageAction(
  BuildContext context,
  WidgetRef ref,
  PageRow page,
  PageAction action,
) async {
  final repo = ref.read(repositoryProvider);
  final screen = ref.read(screenProvider.notifier);
  switch (action) {
    case PageAction.favorite:
      await repo.updatePage(page.id, favorite: !page.favorite);
    case PageAction.addChild:
      screen.openPage(await repo.createPage(parentId: page.id));
    case PageAction.addAlbum:
      // Photos used on this page then go here too, and can be picked
      // from it (photo_picker.dart).
      screen.openPage(
        await repo.createAlbum(parentId: page.id, title: '사진 보관함'),
      );
    case PageAction.rename:
      final title = await askText(context, '이름 바꾸기', page.title);
      if (title != null) await repo.updatePage(page.id, title: title);
    case PageAction.icon:
      final icon = await showIconPicker(context);
      if (icon != null) await repo.updatePage(page.id, icon: icon);
    case PageAction.copyLink:
      // Pasted into a page it becomes a link to this page (@mention).
      await Clipboard.setData(ClipboardData(text: pageLinkUrl(page.id)));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('링크를 복사했어요. 페이지에 붙여넣으면 이 페이지로 가는 링크가 돼요'),
          ),
        );
      }
    case PageAction.duplicate:
      screen.openPage(await repo.duplicatePage(page.id));
    case PageAction.move:
      if (!context.mounted) return;
      final target = await showMovePicker(context, ref, page);
      if (target == null) return;
      final ok = await repo.movePage(
        page.id,
        parentId: target.parentId,
        inboxSection: target.inboxSection,
      );
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('자기 자신의 하위로는 옮길 수 없어요')));
      }
    case PageAction.saveAsTemplate:
      await repo.saveAsTemplate(page.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '"${page.title.isEmpty ? '제목 없음' : page.title}"을 템플릿으로 저장했어요',
            ),
            // With an action a SnackBar stays until dismissed; these
            // are notices, so they go away by themselves.
            persist: false,
            action: SnackBarAction(
              label: '템플릿 보기',
              onPressed: screen.openTemplates,
            ),
          ),
        );
      }
    case PageAction.trash:
      // Obsidian: warn when other pages link here.
      final links = await repo.incomingLinkCount(page.id);
      if (links > 0 && context.mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('휴지통으로 옮길까요?'),
            content: Text(
              '다른 페이지 $links개가 이 페이지(또는 하위 페이지)를 링크하고 '
              '있어요. 옮기면 그 링크는 취소선으로 보여요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('옮기기'),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }
      final selected = ref.read(selectedPageProvider);
      final inTrashedTree =
          selected != null &&
          (selected == page.id ||
              (await repo.ancestors(selected)).any((p) => p.id == page.id));
      await repo.trashPage(page.id);
      if (inTrashedTree) screen.openPage(repo.inboxPageId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('휴지통으로 옮겼어요'),
            // With an action a SnackBar stays until dismissed; these
            // are notices, so they go away by themselves.
            persist: false,
            action: SnackBarAction(
              label: '되돌리기',
              onPressed: () => repo.restorePage(page.id),
            ),
          ),
        );
      }
  }
}

class MoveTarget {
  const MoveTarget(this.parentId, {this.inboxSection = false});
  final String? parentId;

  /// Top level, in the sidebar's 미정리 section (not 개인 페이지).
  final bool inboxSection;
}

/// Pick a new parent for [page] (pages inside it are not offered).
Future<MoveTarget?> showMovePicker(
  BuildContext context,
  WidgetRef ref,
  PageRow page,
) {
  final tree = ref.read(pageTreeProvider);
  final options = <(PageRow, int)>[];
  void walk(String? parent, int depth) {
    for (final p in tree[parent] ?? const <PageRow>[]) {
      if (p.id == page.id) continue; // skips the page's own subtree too
      options.add((p, depth));
      walk(p.id, depth + 1);
    }
  }

  walk(null, 0);
  return showDialog<MoveTarget>(
    context: context,
    builder: (context) => _MovePickerDialog(options: options),
  );
}

class _MovePickerDialog extends StatefulWidget {
  const _MovePickerDialog({required this.options});

  final List<(PageRow, int)> options;

  @override
  State<_MovePickerDialog> createState() => _MovePickerDialogState();
}

class _MovePickerDialogState extends State<_MovePickerDialog> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final f = _filter.trim().toLowerCase();
    final shown = [
      for (final o in widget.options)
        if (f.isEmpty || o.$1.title.toLowerCase().contains(f)) o,
    ];
    return Dialog(
      child: SizedBox(
        width: 420,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '옮길 위치 검색',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.inbox_outlined, size: 18),
              title: const Text('미정리 (미정리 노트와 같은 단계)'),
              onTap: () => Navigator.pop(
                context,
                const MoveTarget(null, inboxSection: true),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.vertical_align_top, size: 18),
              title: const Text('개인 페이지 (최상위)'),
              onTap: () => Navigator.pop(context, const MoveTarget(null)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final (p, depth) in shown)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(
                        left: 16.0 + (f.isEmpty ? depth * 16 : 0),
                        right: 16,
                      ),
                      leading: Text(
                        (p.icon?.isNotEmpty ?? false) ? p.icon! : '📄',
                        style: const TextStyle(fontSize: 16),
                      ),
                      title: Text(
                        p.title.isEmpty ? '제목 없음' : p.title,
                        style: TextStyle(color: colors.text),
                      ),
                      onTap: () => Navigator.pop(context, MoveTarget(p.id)),
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

/// "3분 전", "10월 12일 오후 7:26" style edit time.
String formatEdited(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return '방금 편집';
  if (diff.inHours < 1) return '${diff.inMinutes}분 전 편집';
  if (diff.inDays < 1) return '${diff.inHours}시간 전 편집';
  final ampm = t.hour < 12 ? '오전' : '오후';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '${t.month}월 ${t.day}일 $ampm $h:$m 편집';
}
