import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../data/fuzzy.dart';
import '../data/links.dart';
import '../data/notes_repository.dart';
import '../providers.dart';
import '../ui/theme.dart';
import 'inline_math.dart' show inlineFormulaKey;

/// Inline objects are single characters with attributes; text typed right
/// after one must not inherit them (it would become part of the link).
void installInlineObjectSlicing() {
  final fallback = defaultAppFlowyEditorSliceAttributes;
  appflowyEditorSliceAttributes = (delta, index) {
    final attrs = fallback?.call(delta, index);
    if (attrs == null) return null;
    final rest = {...attrs}
      ..remove(inlineFormulaKey)
      ..remove(pageLinkKey)
      ..remove(pageLinkTitleKey);
    return rest.isEmpty ? null : rest;
  };
}

/// Typing `[[` opens the page picker (Obsidian style).
final CharacterShortcutEvent doubleBracketToPageLink = CharacterShortcutEvent(
  key: 'type [[ to link a page',
  character: '[',
  handler: (editorState) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final node = editorState.getNodeAtPath(selection.end.path);
    final delta = node?.delta;
    final offset = selection.end.offset;
    if (node == null || delta == null || offset < 1) return false;
    if (delta.toPlainText().substring(offset - 1, offset) != '[') return false;
    // The line's own widget: under the app's Navigator and ProviderScope.
    final context = node.key.currentContext;
    if (context == null) return false;
    // Remove the first '[' (the second one is never typed).
    await editorState.apply(
      editorState.transaction
        ..deleteText(node, offset - 1, 1)
        ..afterSelection = Selection.collapsed(
          Position(path: node.path, offset: offset - 1),
        ),
    );
    if (!context.mounted) return true;
    await insertPageLink(context, editorState);
    return true;
  },
);

/// Slash menu: 페이지 링크.
final SelectionMenuItem pageLinkMenuItem = SelectionMenuItem(
  getName: () => '페이지 링크',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.north_east,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['link', 'page', 'mention', '링크', '페이지', '연결', '[['],
  handler: (editorState, _, context) => insertPageLink(context, editorState),
);

/// Asks for a page and puts a link to it at the cursor.
Future<void> insertPageLink(
  BuildContext context,
  EditorState editorState,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final repo = container.read(repositoryProvider);
  final here = container.read(selectedPageProvider);
  // The dialog takes focus and the editor drops its selection: remember
  // where the cursor was and put it back afterwards.
  final selection = editorState.selection;
  if (selection == null) return;
  final picked = await showPagePicker(context, repo, currentPageId: here);
  final node = editorState.getNodeAtPath(selection.end.path);
  if (node == null || node.delta == null) return;
  if (picked == null) {
    editorState.selection = selection;
    return;
  }
  final offset = selection.end.offset.clamp(0, node.delta!.length);
  await editorState.apply(
    editorState.transaction
      ..insertText(
        node,
        offset,
        pageLinkChar,
        attributes: {pageLinkKey: picked.id, pageLinkTitleKey: picked.title},
      )
      ..afterSelection = Selection.collapsed(
        Position(path: node.path, offset: offset + 1),
      ),
  );
}

/// Renders page links as the target's live icon + title.
TextSpanDecoratorForAttribute pageLinkDecorator(
  TextSpanDecoratorForAttribute fallback,
) {
  return (context, node, index, text, before, after) {
    final id = text.attributes?[pageLinkKey];
    if (id is! String) {
      return fallback(context, node, index, text, before, after);
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: PageLinkChip(
        pageId: id,
        fallbackTitle: text.attributes?[pageLinkTitleKey] as String?,
      ),
    );
  };
}

class PageLinkChip extends ConsumerWidget {
  const PageLinkChip({super.key, required this.pageId, this.fallbackTitle});

  final String pageId;
  final String? fallbackTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final page = ref.watch(pageProvider(pageId)).value;
    final gone = page == null || page.deleted || page.trashedAt != null;
    final base =
        context.read<EditorState?>()?.editorStyle.textStyleConfiguration.text ??
        DefaultTextStyle.of(context).style;
    final title = page == null
        ? (fallbackTitle ?? '없는 페이지')
        : (page.title.isEmpty ? '제목 없음' : page.title);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: gone
            ? null
            : () => ref.read(screenProvider.notifier).openPage(pageId),
        child: Text.rich(
          TextSpan(
            children: [
              if (page?.icon?.isNotEmpty ?? false)
                TextSpan(text: '${page!.icon} ')
              else
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.description_outlined,
                      size: (base.fontSize ?? 16) * 0.95,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              TextSpan(
                text: title,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  decoration: gone
                      ? TextDecoration.lineThrough
                      : TextDecoration.underline,
                  decorationColor: colors.textMuted.withValues(alpha: 0.5),
                  color: gone ? colors.textMuted : colors.text,
                ),
              ),
            ],
          ),
          style: base,
        ),
      ),
    );
  }
}

/// Page search for links. Returns the chosen (or newly made) page.
Future<PageRow?> showPagePicker(
  BuildContext context,
  NotesRepository repo, {
  String? currentPageId,
}) => showDialog<PageRow>(
  context: context,
  builder: (_) => _PagePicker(repo: repo, currentPageId: currentPageId),
);

class _PagePicker extends StatefulWidget {
  const _PagePicker({required this.repo, this.currentPageId});

  final NotesRepository repo;
  final String? currentPageId;

  @override
  State<_PagePicker> createState() => _PagePickerState();
}

class _PagePickerState extends State<_PagePicker> {
  final _query = TextEditingController();
  List<PageRow> _results = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final db = widget.repo.db;
    final text = _query.text;
    // Closing the link with `]]` (Notion): link the page of that exact name,
    // or make it.
    if (text.endsWith(']]')) {
      final title = text.substring(0, text.length - 2).trim();
      _query.text = title;
      if (title.isEmpty) return;
      final exact =
          await (db.select(db.pages)
                ..where(
                  (p) =>
                      p.deleted.equals(false) &
                      p.trashedAt.isNull() &
                      p.isTemplate.equals(false) &
                      p.title.equals(title),
                )
                ..limit(1))
              .getSingleOrNull();
      if (!mounted) return;
      if (exact != null) {
        Navigator.pop(context, exact);
      } else {
        await _create();
      }
      return;
    }
    final q = text.trim();
    final rows =
        await (db.select(db.pages)
              ..where(
                (p) =>
                    p.deleted.equals(false) &
                    p.trashedAt.isNull() &
                    p.isTemplate.equals(false) &
                    p.id.equals(widget.currentPageId ?? '').not(),
              )
              ..orderBy([(p) => OrderingTerm.desc(p.updatedAt)]))
            .get();
    if (!mounted) return;
    setState(() {
      // Recent pages first; with a query, best fuzzy match first.
      _results = (q.isEmpty ? rows : fuzzySort(q, rows, (p) => p.title))
          .take(30)
          .toList();
      _selected = 0;
    });
  }

  Future<void> _create() async {
    final title = _query.text.trim();
    // New pages go under the page being written, like Notion's sub-page.
    final id = await widget.repo.createPage(
      parentId: widget.currentPageId,
      title: title,
    );
    final page = await widget.repo.getPage(id);
    if (mounted) Navigator.pop(context, page);
  }

  void _choose(int i) {
    final canCreate = _query.text.trim().isNotEmpty;
    if (i < _results.length) {
      Navigator.pop(context, _results[i]);
    } else if (canCreate) {
      _create();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final q = _query.text.trim();
    final count = _results.length + (q.isEmpty ? 0 : 1);
    return Dialog(
      alignment: const Alignment(0, -0.5),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      setState(() => _selected = (_selected + 1) % count),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      setState(
                        () => _selected = (_selected - 1 + count) % count,
                      ),
                },
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '연결할 페이지 검색 (끝에 ]] → 그 이름으로 연결)',
                    prefixIcon: Icon(Icons.north_east, size: 18),
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => _search(),
                  onSubmitted: (_) => _choose(_selected),
                ),
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (var i = 0; i < _results.length; i++)
                    _PickerRow(
                      selected: i == _selected,
                      leading: Text(
                        (_results[i].icon?.isNotEmpty ?? false)
                            ? _results[i].icon!
                            : '📄',
                      ),
                      label: _results[i].title.isEmpty
                          ? '제목 없음'
                          : _results[i].title,
                      onTap: () => _choose(i),
                    ),
                  if (q.isNotEmpty)
                    _PickerRow(
                      selected: _selected == _results.length,
                      leading: const Icon(Icons.add, size: 18),
                      label: '새 페이지 "$q" 만들고 연결',
                      onTap: _create,
                    ),
                  if (count == 0)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '페이지가 없어요',
                        style: TextStyle(color: colors.textMuted),
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

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.selected,
    required this.leading,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final Widget leading;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return Material(
      color: selected ? colors.hover : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SizedBox(width: 24, child: Center(child: leading)),
              const SizedBox(width: 8),
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }
}
