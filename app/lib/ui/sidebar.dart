import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/plan_map_repository.dart';
import '../data/album_repository.dart';
import '../data/database.dart';
import '../data/database_repository.dart';
import '../providers.dart';
import 'page_actions.dart';
import 'md_actions.dart';
import 'notion_dialog.dart';
import 'search_dialog.dart';
import 'sync_dialog.dart';
import 'theme.dart';
import 'trash_dialog.dart';

bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Where a dragged page lands relative to the tile under the pointer.
enum _Drop { before, inside, after }

/// Notion-style sidebar: search, templates, favorites, page tree, trash.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key, this.onNavigate});

  /// Called after something is opened (closes the drawer on mobile).
  final VoidCallback? onNavigate;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

/// Open pages in the tree. Kept outside the widget: the phone drawer builds
/// a new sidebar every time it opens, which closed everything again.
final _expandedPages = <String>{};

class _SidebarState extends ConsumerState<Sidebar> {
  Set<String> get _expanded => _expandedPages;

  /// On the tile of the page being viewed, to scroll it into view.
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final id = ref.read(selectedPageProvider);
    if (id != null) _reveal(id);
  }

  /// Opens the parents of [id] so the page being viewed shows in the tree,
  /// and scrolls to it (only as far as needed).
  Future<void> _reveal(String id) async {
    final parents = await ref.read(repositoryProvider).ancestors(id);
    if (!mounted) return;
    final closed = [
      for (final p in parents)
        if (!_expanded.contains(p.id)) p.id,
    ];
    if (closed.isNotEmpty) setState(() => _expanded.addAll(closed));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final c = _selectedKey.currentContext;
      if (c == null || !c.mounted) return;
      await Scrollable.ensureVisible(
        c,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      if (!c.mounted) return;
      await Scrollable.ensureVisible(
        c,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  /// Keeps keyboard focus on the page list after a click, so Delete / F2
  /// act on the selected page (like a file explorer). Clicking into the
  /// page moves focus to the editor, where Delete edits text again.
  final _keys = FocusNode(debugLabel: 'sidebar pages');

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  void _open(String id) {
    ref.read(screenProvider.notifier).openPage(id);
    widget.onNavigate?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keys.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final action = switch (e.logicalKey) {
      LogicalKeyboardKey.delete => PageAction.trash,
      LogicalKeyboardKey.f2 => PageAction.rename,
      _ => null,
    };
    final id = ref.read(selectedPageProvider);
    if (action == null || id == null) return KeyEventResult.ignored;
    final page = ref.read(pageProvider(id)).value;
    // 미정리 itself can't be deleted (rename is fine).
    if (page == null ||
        (action == PageAction.trash && id == ref.read(inboxIdProvider))) {
      return KeyEventResult.ignored;
    }
    runPageAction(context, ref, page, action);
    return KeyEventResult.handled;
  }

  /// The sidebar's "새 페이지" items create a top-level page in the 미정리
  /// section (beside the 미정리 note, sorted later).
  Future<void> _newPage() async {
    _open(await ref.read(repositoryProvider).createPage(inboxSection: true));
  }

  /// Opens a page just made at the top level, after putting it in the
  /// 미정리 section.
  Future<void> _openInSection(String id) async {
    await ref.read(repositoryProvider).setInInboxSection(id, true);
    _open(id);
  }

  Future<void> _newFromTemplate(BuildContext anchor) async {
    final templates = ref.read(templatesProvider).value ?? const [];
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem(
          value: value,
          height: 36,
          child: Row(
            children: [
              Icon(icon, size: 18, color: context.noteColors.text),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontSize: 14)),
            ],
          ),
        );
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy - 8,
        overlay.size.width - pos.dx - box.size.width,
        overlay.size.height - pos.dy,
      ),
      items: [
        item('', Icons.description_outlined, '빈 페이지'),
        item('#db', Icons.table_chart_outlined, '데이터베이스'),
        item('#album', Icons.photo_library_outlined, '사진 보관함'),
        item('#map', Icons.account_tree_outlined, '계획 지도'),
        if (templates.isNotEmpty) const PopupMenuDivider(),
        for (final t in templates)
          PopupMenuItem(
            value: t.id,
            height: 36,
            child: Text(
              '${(t.icon?.isNotEmpty ?? false) ? '${t.icon} ' : ''}'
              '${t.title.isEmpty ? '제목 없음' : t.title}',
            ),
          ),
        const PopupMenuDivider(),
        item('#manage', Icons.dashboard_customize_outlined, '템플릿 관리…'),
        const PopupMenuDivider(),
        item('#import', Icons.file_download_outlined, 'Markdown 가져오기…'),
        item('#notion', Icons.cloud_download_outlined, 'Notion에서 가져오기…'),
        item('#exportAll', Icons.file_upload_outlined, '전체를 Markdown으로 내보내기…'),
      ],
    );
    if (choice == null) return;
    if (choice == '') return _newPage();
    if (choice == '#db') {
      await _openInSection(
        await ref.read(repositoryProvider).createDatabase(title: '새 데이터베이스'),
      );
      return;
    }
    if (choice == '#album') {
      await _openInSection(
        await ref.read(repositoryProvider).createAlbum(title: '새 사진 보관함'),
      );
      return;
    }
    if (choice == '#map') {
      await _openInSection(
        await ref.read(repositoryProvider).createPlanMap(title: '새 계획 지도'),
      );
      return;
    }
    if (choice == '#import') {
      if (mounted) await importMarkdownFlow(context, ref);
      return;
    }
    if (choice == '#notion') {
      if (mounted) await showNotionImport(context, ref);
      return;
    }
    if (choice == '#exportAll') {
      if (mounted) await exportMarkdownFlow(context, ref);
      return;
    }
    if (choice == '#manage') {
      ref.read(screenProvider.notifier).openTemplates();
      widget.onNavigate?.call();
      return;
    }
    await _openInSection(
      await ref.read(repositoryProvider).createFromTemplate(choice),
    );
  }

  Future<void> _drop(String draggedId, PageRow target, _Drop where) async {
    final repo = ref.read(repositoryProvider);
    // Beside a top-level page = in that page's section. The 미정리 note
    // is always in the 미정리 section.
    final besideInSection =
        target.parentId == null &&
        (target.id == ref.read(inboxIdProvider) ||
            (ref.read(inboxSectionProvider).value ?? const {}).contains(
              target.id,
            ));
    final ok = switch (where) {
      _Drop.before => await repo.movePage(
        draggedId,
        parentId: target.parentId,
        beforeId: target.id,
        inboxSection: besideInSection,
      ),
      _Drop.after => await repo.movePage(
        draggedId,
        parentId: target.parentId,
        afterId: target.id,
        inboxSection: besideInSection,
      ),
      _Drop.inside => await repo.movePage(draggedId, parentId: target.id),
    };
    if (where == _Drop.inside && ok) setState(() => _expanded.add(target.id));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('자기 자신의 하위로는 옮길 수 없어요')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final tree = ref.watch(pageTreeProvider);
    final favorites = ref.watch(favoritesProvider).value ?? const [];
    final selected = ref.watch(selectedPageProvider);
    final screen = ref.watch(screenProvider);
    final inboxId = ref.watch(inboxIdProvider);
    final section = ref.watch(inboxSectionProvider).value ?? const {};
    // Opened from a link, search, the graph… → show it in the tree too.
    ref.listen(selectedPageProvider, (_, id) {
      if (id != null) _reveal(id);
    });

    Widget tile(PageRow page, int depth, {bool inTree = true}) {
      final hasChildren = tree[page.id]?.isNotEmpty ?? false;
      final open = inTree && _expanded.contains(page.id);
      final row = _PageTile(
        key: ValueKey('${inTree ? 't' : 'f'}${page.id}'),
        page: page,
        depth: depth,
        selected: page.id == selected,
        expanded: open,
        hasChildren: inTree && hasChildren,
        isInbox: page.id == inboxId,
        draggable: inTree && page.id != inboxId,
        onTap: () => _open(page.id),
        onToggle: () => setState(() {
          open ? _expanded.remove(page.id) : _expanded.add(page.id);
        }),
        onAction: (action) => runPageAction(context, ref, page, action),
        onDrop: inTree ? (id, where) => _drop(id, page, where) : null,
      );
      return inTree && page.id == selected
          ? KeyedSubtree(key: _selectedKey, child: row)
          : row;
    }

    // Two top-level sections. 미정리: the 미정리 note (captures land in it)
    // and the top-level pages marked for this section, all at one level.
    // 개인 페이지: every other top-level page.
    List<Widget> rowsFor(Iterable<PageRow> pages, int depth) => [
      for (final page in pages) ...[
        tile(page, depth),
        if (_expanded.contains(page.id))
          ...rowsFor(tree[page.id] ?? const <PageRow>[], depth + 1),
      ],
    ];
    final roots = tree[null] ?? const <PageRow>[];
    bool inSection(PageRow p) => p.id == inboxId || section.contains(p.id);
    final inboxRows = rowsFor([
      ...roots.where((p) => p.id == inboxId),
      ...roots.where((p) => p.id != inboxId && inSection(p)),
    ], 0);
    final treeRows = rowsFor(roots.where((p) => !inSection(p)), 0);
    Widget sectionLabel(String name) => _SectionLabel(
      name,
      onToggle: () => setState(() {
        _foldedSections.contains(name)
            ? _foldedSections.remove(name)
            : _foldedSections.add(name);
      }),
    );

    return Container(
      color: colors.sidebar,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
              child: Text(
                '나무',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
            _SidebarButton(
              icon: Icons.search,
              label: '검색',
              trailing: _isDesktop ? 'Ctrl+P' : null,
              onTap: () => showSearchDialog(context, ref),
            ),
            _SidebarButton(
              icon: Icons.dashboard_customize_outlined,
              label: '템플릿',
              selected: screen is TemplatesScreen,
              onTap: () {
                ref.read(screenProvider.notifier).openTemplates();
                widget.onNavigate?.call();
              },
            ),
            _SidebarButton(
              icon: Icons.hub_outlined,
              label: '그래프',
              selected: screen is GraphScreen,
              onTap: () {
                ref.read(screenProvider.notifier).openGraph();
                widget.onNavigate?.call();
              },
            ),
            _SidebarButton(
              icon: Icons.perm_media_outlined,
              label: '자료실',
              selected: screen is AssetsScreen,
              onTap: () {
                ref.read(screenProvider.notifier).openAssets();
                widget.onNavigate?.call();
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Focus(
                focusNode: _keys,
                onKeyEvent: _onKey,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  // Build rows off screen too, so the page being viewed can
                  // be scrolled to (only open rows exist; they're small).
                  scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
                  children: [
                    if (favorites.isNotEmpty) ...[
                      sectionLabel('즐겨찾기'),
                      if (!_foldedSections.contains('즐겨찾기'))
                        for (final p in favorites) tile(p, 0, inTree: false),
                      const SizedBox(height: 10),
                    ],
                    sectionLabel('미정리'),
                    if (!_foldedSections.contains('미정리')) ...inboxRows,
                    // Drop here to move a page to the end of each section.
                    _EndDrop(
                      height: 12,
                      onDrop: (id) => ref
                          .read(repositoryProvider)
                          .movePage(id, inboxSection: true),
                    ),
                    sectionLabel('개인 페이지'),
                    if (!_foldedSections.contains('개인 페이지')) ...treeRows,
                    _EndDrop(
                      height: 40,
                      onDrop: (id) => ref.read(repositoryProvider).movePage(id),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _SidebarButton(
                      icon: Icons.add,
                      label: '새 페이지',
                      onTap: () => _newPage(),
                    ),
                  ),
                  Builder(
                    builder: (anchor) => IconButton(
                      tooltip: '템플릿으로 새 페이지',
                      iconSize: 18,
                      color: colors.textMuted,
                      icon: const Icon(Icons.expand_less),
                      onPressed: () => _newFromTemplate(anchor),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            _SidebarButton(
              icon: Icons.delete_outline,
              label: '휴지통',
              onTap: () => showTrashDialog(context),
            ),
            Consumer(
              builder: (context, ref, _) {
                final (icon, label) = syncLabel(ref.watch(syncStatusProvider));
                return _SidebarButton(
                  icon: icon,
                  label: label,
                  onTap: () => showSyncDialog(context),
                );
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// Sections folded by tapping their label (kept while the app runs).
final _foldedSections = <String>{};

/// Section label (즐겨찾기, 미정리, 개인 페이지): tap to fold or unfold it,
/// like Notion.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.onToggle});

  final String text;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final folded = _foldedSections.contains(text);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Row(
          children: [
            Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              folded ? Icons.keyboard_arrow_right : Icons.keyboard_arrow_down,
              size: 14,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _PageTile extends StatefulWidget {
  const _PageTile({
    super.key,
    required this.page,
    required this.depth,
    required this.selected,
    required this.expanded,
    required this.hasChildren,
    required this.isInbox,
    required this.draggable,
    required this.onTap,
    required this.onToggle,
    required this.onAction,
    required this.onDrop,
  });

  final PageRow page;
  final int depth;
  final bool selected;
  final bool expanded;
  final bool hasChildren;
  final bool isInbox;
  final bool draggable;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final ValueChanged<PageAction> onAction;
  final void Function(String draggedId, _Drop where)? onDrop;

  @override
  State<_PageTile> createState() => _PageTileState();
}

class _PageTileState extends State<_PageTile> {
  bool _hover = false;
  _Drop? _dropZone;

  /// Holding a dragged page over a folded page opens it (Obsidian: 0.75 s).
  Timer? _openTimer;

  void _setDropZone(_Drop? zone) {
    if (zone == _dropZone) return;
    setState(() => _dropZone = zone);
    _openTimer?.cancel();
    if (zone == _Drop.inside && widget.hasChildren && !widget.expanded) {
      _openTimer = Timer(const Duration(milliseconds: 750), () {
        if (mounted && _dropZone == _Drop.inside && !widget.expanded) {
          widget.onToggle();
        }
      });
    }
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    super.dispose();
  }

  /// Phones: where the finger went down, and whether the long-press drag
  /// actually moved (no move → it was a long-press, open the menu).
  Offset _pressAt = Offset.zero;
  bool _dragMoved = false;

  Future<void> _showMenuAt(Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<PageAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: pageMenuItems(widget.page, isInbox: widget.isInbox),
    );
    if (action != null) widget.onAction(action);
  }

  _Drop _zoneFor(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    final y = box.globalToLocal(global).dy / box.size.height;
    if (y < 0.28) return _Drop.before;
    if (y > 0.72) return _Drop.after;
    return _Drop.inside;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final page = widget.page;
    final showActions = _hover || widget.selected;
    const accent = Color(0xFF2383E2);

    Widget row = Container(
      height: 30,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: EdgeInsets.only(left: 4.0 + widget.depth * 14, right: 2),
      decoration: BoxDecoration(
        color: _dropZone == _Drop.inside
            ? accent.withValues(alpha: 0.15)
            : (widget.selected || _hover ? colors.hover : null),
        borderRadius: BorderRadius.circular(5),
        border: switch (_dropZone) {
          _Drop.before => const Border(
            top: BorderSide(color: accent, width: 2),
          ),
          _Drop.after => const Border(
            bottom: BorderSide(color: accent, width: 2),
          ),
          _ => null,
        },
      ),
      child: Row(
        children: [
          _IconBox(
            onTap: widget.onToggle,
            child: Icon(
              widget.expanded
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_right,
              size: 16,
              color: widget.hasChildren
                  ? colors.textMuted
                  : colors.textMuted.withValues(alpha: 0.35),
            ),
          ),
          SizedBox(
            width: 22,
            child: Center(
              child: (page.icon?.isNotEmpty ?? false)
                  ? Text(page.icon!, style: const TextStyle(fontSize: 14))
                  : Icon(
                      switch (page.kind) {
                        'database' => Icons.table_chart_outlined,
                        'album' => Icons.photo_library_outlined,
                        _ => Icons.description_outlined,
                      },
                      size: 16,
                      color: colors.textMuted,
                    ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              page.title.isEmpty ? '제목 없음' : page.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: page.title.isEmpty ? colors.textMuted : colors.text,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (showActions) ...[
            _IconBox(
              onTap: () {
                final box = context.findRenderObject()! as RenderBox;
                _showMenuAt(
                  box.localToGlobal(
                    Offset(box.size.width - 40, box.size.height),
                  ),
                );
              },
              child: Icon(Icons.more_horiz, size: 16, color: colors.textMuted),
            ),
            _IconBox(
              onTap: () => widget.onAction(PageAction.addChild),
              child: Icon(Icons.add, size: 16, color: colors.textMuted),
            ),
          ],
        ],
      ),
    );

    row = GestureDetector(
      onTap: widget.onTap,
      // Right-click on desktop. On phones a long-press starts a drag (see
      // below); letting go without moving opens this menu instead.
      onSecondaryTapDown: (d) => _showMenuAt(d.globalPosition),
      onLongPressStart: _isDesktop || widget.draggable
          ? null
          : (d) => _showMenuAt(d.globalPosition),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: row,
      ),
    );

    // Each wrapper captures a *final* copy: the builder closure below runs
    // later, and capturing the reassigned `row` made it contain itself
    // (infinite recursion, ISSUES.md #014).
    final onDrop = widget.onDrop;
    if (onDrop != null) {
      final inner = row;
      row = DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != page.id,
        onMove: (d) => _setDropZone(_zoneFor(d.offset)),
        onLeave: (_) => _setDropZone(null),
        onAcceptWithDetails: (d) {
          final zone = _zoneFor(d.offset);
          _setDropZone(null);
          onDrop(d.data, zone);
        },
        builder: (context, _, _) => inner,
      );
    }

    if (widget.draggable) {
      final inner = row;
      final feedback = Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            '${(page.icon?.isNotEmpty ?? false) ? '${page.icon} ' : ''}'
            '${page.title.isEmpty ? '제목 없음' : page.title}',
          ),
        ),
      );
      final childWhenDragging = Opacity(opacity: 0.4, child: inner);
      row = _isDesktop
          ? Draggable<String>(
              data: page.id,
              // Left button only. A right-click opens the context menu,
              // whose route swallows the button-up, which left a drag stuck
              // to the cursor (ISSUES.md #015).
              allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: feedback,
              childWhenDragging: childWhenDragging,
              child: inner,
            )
          // Phones: a plain drag scrolls the list, so moving a page starts
          // with a long-press.
          : Listener(
              onPointerDown: (e) => _pressAt = e.position,
              child: LongPressDraggable<String>(
                data: page.id,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                hapticFeedbackOnStart: true,
                feedback: feedback,
                childWhenDragging: childWhenDragging,
                onDragStarted: () => _dragMoved = false,
                onDragUpdate: (d) {
                  // A finger shakes: only a real move is a drag.
                  if ((d.globalPosition - _pressAt).distance > 28) {
                    _dragMoved = true;
                  }
                },
                onDragEnd: (_) {
                  if (!_dragMoved) _showMenuAt(_pressAt);
                },
                child: inner,
              ),
            );
    }
    return row;
  }
}

/// Empty strip after a section's pages; a page dropped on it goes to the
/// end of that section.
class _EndDrop extends StatelessWidget {
  const _EndDrop({required this.height, required this.onDrop});

  final double height;
  final void Function(String id) onDrop;

  @override
  Widget build(BuildContext context) => DragTarget<String>(
    onAcceptWithDetails: (d) => onDrop(d.data),
    builder: (context, candidates, _) => Container(
      height: height,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        border: candidates.isEmpty
            ? null
            : const Border(top: BorderSide(color: Color(0xFF2383E2), width: 2)),
      ),
    ),
  );
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(width: 22, height: 22, child: Center(child: child)),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? colors.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(icon, size: 17, color: colors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 14, color: colors.text),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: TextStyle(fontSize: 11, color: colors.textMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
