import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/links.dart';
import '../providers.dart';
import 'theme.dart';

final backlinksProvider = StreamProvider.family<List<Backlink>, String>(
  (ref, id) => ref.watch(repositoryProvider).watchBacklinks(id),
);

/// "이 페이지를 링크한 곳" under a page (Obsidian's backlinks pane):
/// each linking page with the lines that contain the link.
class BacklinksPanel extends ConsumerStatefulWidget {
  const BacklinksPanel({super.key, required this.pageId});

  final String pageId;

  @override
  ConsumerState<BacklinksPanel> createState() => _BacklinksPanelState();
}

class _BacklinksPanelState extends ConsumerState<BacklinksPanel> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final links = ref.watch(backlinksProvider(widget.pageId)).value ?? const [];
    if (links.isEmpty) return const SizedBox.shrink();
    final colors = context.noteColors;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: colors.divider),
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(
                    _open ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '백링크 ${links.length}개',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            for (final link in links)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    ref.read(screenProvider.notifier).openPage(link.page.id),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 6, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(link.page.icon?.isNotEmpty ?? false) ? '${link.page.icon} ' : '📄 '}'
                        '${link.page.title.isEmpty ? '제목 없음' : link.page.title}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: colors.text,
                        ),
                      ),
                      for (final s in link.snippets.take(3))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            s,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
