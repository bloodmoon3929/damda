import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/notes_repository.dart';
import '../db_ui/database_view.dart';
import '../editor/attachment_blocks.dart';
import '../editor/editor_config.dart';
import '../editor/math_block.dart';
import '../editor/markdown_autoformat.dart';
import '../editor/mobile_selection_menu.dart';
import '../editor/notion_keys.dart';
import '../editor/rich_clipboard.dart';
import '../providers.dart';
import 'album_view.dart';
import 'assets_view.dart';
import 'backlinks_panel.dart';
import '../graph/graph_view.dart';
import 'history_dialog.dart';
import 'md_actions.dart';
import 'icon_picker.dart';
import 'in_editor_text_field.dart';
import 'page_actions.dart';
import 'plan_map_view.dart';
import 'theme.dart';

bool get _isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

const _maxWidth = 900.0;
EdgeInsets get _padding =>
    EdgeInsets.symmetric(horizontal: _isMobile ? 20 : 96);

/// One page: icon + title header and the block editor. Edits are saved to
/// the local DB shortly after typing stops.
///
/// The editor itself never watches the page row: every save bumps the row's
/// updated_at, and rebuilding the editor on that caused visible flicker.
class PageView extends ConsumerStatefulWidget {
  const PageView({super.key, required this.pageId});

  final String pageId;

  @override
  ConsumerState<PageView> createState() => _PageViewState();
}

final _findWords = FindReplaceLocalizations(
  find: '찾기',
  previousMatch: '이전',
  nextMatch: '다음',
  close: '닫기',
  replace: '바꾸기',
  replaceAll: '모두 바꾸기',
  noResult: '없음',
);

/// "페이지에서 찾기" from the page's ⋯ menu (phones have no Ctrl+F): the
/// id of the page whose editor should open its find bar.
final pageFindRequest = ValueNotifier<String?>(null);

class _PageViewState extends ConsumerState<PageView> {
  static const _saveDelay = Duration(milliseconds: 400);

  late final NotesRepository _repo = ref.read(repositoryProvider);
  PageDocument? _doc;
  EditorState? _editorState;
  EditorScrollController? _scroll;
  StreamSubscription<EditorTransactionValue>? _sub;
  StreamSubscription<Set<String>>? _remoteSub;
  StreamSubscription<EditorTransactionValue>? _autoFormat;
  Timer? _saveTimer;
  bool _reloadAfterSave = false;

  /// Built once: stock shortcuts with Ctrl+V replaced by the attachment-
  /// aware paste (#002: never rebuild editor inputs per frame).
  late final List<CommandShortcutEvent> _commands = [
    attachmentPasteCommand(_repo, widget.pageId),
    richCopyCommand,
    richCutCommand,
    // Ctrl+F find, Ctrl+H find and replace (also "페이지에서 찾기" in ⋯).
    ...findAndReplaceCommands(context: context, localizations: _findWords),
    outdentKeepingOrder,
    for (final e in standardCommandShortcutEvents)
      if (e != pasteCommand && e != copyCommand && e != cutCommand) e,
  ];

  EditorConfig? _config;
  NoteColors? _configColors;
  _Layout? _configLayout;

  void _onFindRequest() {
    final editorState = _editorState;
    if (pageFindRequest.value != widget.pageId || editorState == null) return;
    pageFindRequest.value = null;
    _commands
        .firstWhere((c) => c.key == 'show the find dialog')
        .handler(editorState);
  }

  @override
  void initState() {
    super.initState();
    pageFindRequest.addListener(_onFindRequest);
    _open();
    _remoteSub = ref
        .read(syncEngineProvider)
        .remotePageChanges
        .listen(_onRemoteChange);
  }

  Future<void> _open() async {
    final doc = await _repo.openDocument(widget.pageId);
    if (!mounted) return;
    // Typing within 0.7 s of the last change is one undo step (Notion).
    final editorState = EditorState(
      document: doc.document,
      minHistoryItemDuration: const Duration(milliseconds: 700),
    );
    final old = (_sub, _scroll, _editorState);
    await _autoFormat?.cancel();
    _autoFormat = attachMarkdownAutoFormat(editorState);
    _sub = editorState.transactionStream.listen((value) {
      if (value.$1 != TransactionTime.after) return;
      _saveTimer?.cancel();
      _saveTimer = Timer(_saveDelay, () async {
        await doc.save();
        if (_reloadAfterSave && mounted) {
          _reloadAfterSave = false;
          _open();
        }
      });
    });
    setState(() {
      _doc = doc;
      _editorState = editorState;
      _scroll = EditorScrollController(editorState: editorState);
    });
    // The previous editor (after a remote change) goes once it is off screen.
    if (old.$3 != null) {
      await old.$1?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        old.$2?.dispose();
        old.$3?.dispose();
      });
    }
  }

  /// Another device changed this page: show its version. While the user is
  /// typing (save pending) the reload waits for that save, so nothing typed
  /// here is lost; the block-level merge happened in the DB already.
  void _onRemoteChange(Set<String> pageIds) {
    if (!pageIds.contains(widget.pageId) || _doc == null) return;
    if (_saveTimer?.isActive ?? false) {
      _reloadAfterSave = true;
    } else {
      _open();
    }
  }

  @override
  void dispose() {
    _remoteSub?.cancel();
    _autoFormat?.cancel();
    pageFindRequest.removeListener(_onFindRequest);
    _sub?.cancel();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      _doc?.save();
    }
    _scroll?.dispose();
    _editorState?.dispose();
    super.dispose();
  }

  /// Clicking below the content (Notion behavior): continue in the last
  /// line if it is an empty paragraph, otherwise add one. Without this, a
  /// page ending in a table or equation had no way to type below it (#009).
  Future<void> _focusEnd(EditorState editorState) async {
    final root = editorState.document.root;
    final last = root.children.lastOrNull;
    if (last != null &&
        last.type == ParagraphBlockKeys.type &&
        (last.delta?.isEmpty ?? false)) {
      editorState.selection = Selection.collapsed(Position(path: last.path));
      return;
    }
    final path = [root.children.length];
    final transaction = editorState.transaction
      ..insertNode(path, paragraphNode())
      ..afterSelection = Selection.collapsed(Position(path: path));
    await editorState.apply(transaction);
  }

  void _focusEditor() {
    _editorState?.selection = Selection.collapsed(Position(path: [0]));
  }

  @override
  Widget build(BuildContext context) {
    final editorState = _editorState;
    if (editorState == null) return const SizedBox.shrink();

    // Only the layout options; title/updated_at changes must not rebuild
    // the editor (#002).
    final layout = ref.watch(
      pageProvider(widget.pageId).select((a) {
        final p = a.value;
        return p == null
            ? null
            : _Layout(p.fontStyle, p.smallText, p.fullWidth, p.isTemplate);
      }),
    );
    final colors = context.noteColors;
    final l = layout ?? const _Layout('default', false, false, false);
    if (_config == null || _configColors != colors || _configLayout != l) {
      _config = EditorConfig.build(
        colors: colors,
        mobile: _isMobile,
        padding: l.padding,
        maxWidth: l.maxWidth,
        fontFamilies: l.fontFamilies,
        fontSize: l.smallText ? 14 : 16,
      );
      _configColors = colors;
      _configLayout = l;
    }
    final config = _config!;

    final editor = AppFlowyEditor(
      editorState: editorState,
      editorScrollController: _scroll,
      editorStyle: config.style,
      blockComponentBuilders: config.blockBuilders,
      characterShortcutEvents: config.characterShortcuts,
      commandShortcutEvents: _commands,
      header: _PageHeader(
        pageId: widget.pageId,
        repo: _repo,
        layout: l,
        onSubmitted: _focusEditor,
      ),
      footer: Column(
        children: [
          // Same width as the blocks (see _PageHeader).
          Center(
            child: Container(
              constraints: BoxConstraints(maxWidth: l.maxWidth),
              padding: l.padding.copyWith(top: 0, bottom: 0),
              child: BacklinksPanel(pageId: widget.pageId),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.text,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // The editor clears the selection in a post-frame callback on
              // pointer-down over the footer (IgnoreEditorSelectionGesture).
              // Run after it, or a quick click gets its cursor wiped (#009).
              onTap: () {
                WidgetsBinding.instance
                  ..addPostFrameCallback((_) => _focusEnd(editorState))
                  ..scheduleFrame();
              },
              // A full screen tall: wherever the user clicks under the content,
              // it lands here (a shorter footer left dead space at the bottom).
              child: SizedBox(height: MediaQuery.sizeOf(context).height),
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        PageTopBar(pageId: widget.pageId),
        if (l.isTemplate) const _TemplateBanner(),
        Expanded(
          child: _isMobile
              // Phones: formatting / block / attachment toolbar above the
              // keyboard (desktop uses the slash menu and shortcuts).
              ? MobileToolbarV2(
                  editorState: editorState,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  foregroundColor: colors.textMuted,
                  iconColor: colors.text,
                  toolbarItems: [
                    textDecorationMobileToolbarItemV2,
                    buildTextAndBackgroundColorMobileToolbarItem(),
                    blocksMobileToolbarItem,
                    linkMobileToolbarItem,
                    dividerMobileToolbarItem,
                    attachmentMobileToolbarItem,
                    mathMobileToolbarItem,
                  ],
                  // Long-press menu (what right-click is on a computer).
                  child: MobileFloatingToolbar(
                    editorState: editorState,
                    editorScrollController: _scroll!,
                    floatingToolbarHeight: 48,
                    toolbarBuilder: (context, anchor, close) =>
                        mobileSelectionMenu(
                          context,
                          anchor,
                          close,
                          editorState,
                          openPage: ref.read(screenProvider.notifier).openPage,
                        ),
                    child: editor,
                  ),
                )
              : AttachmentDropZone(
                  editorState: editorState,
                  pageId: widget.pageId,
                  child: editor,
                ),
        ),
      ],
    );
  }
}

/// Per-page "테마와 레이아웃" options that change how the editor is built.
@immutable
class _Layout {
  const _Layout(
    this.fontStyle,
    this.smallText,
    this.fullWidth,
    this.isTemplate,
  );

  final String fontStyle;
  final bool smallText;
  final bool fullWidth;
  final bool isTemplate;

  double get maxWidth => fullWidth ? double.infinity : _maxWidth;
  EdgeInsets get padding => _padding;

  /// First entry is the family, the rest are fallbacks (Korean included).
  List<String>? get fontFamilies => switch (fontStyle) {
    'serif' => const ['Georgia', 'Batang', 'Noto Serif KR', 'serif'],
    'mono' => const ['Consolas', 'D2Coding', 'monospace', 'Malgun Gothic'],
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is _Layout &&
      other.fontStyle == fontStyle &&
      other.smallText == smallText &&
      other.fullWidth == fullWidth &&
      other.isTemplate == isTemplate;

  @override
  int get hashCode => Object.hash(fontStyle, smallText, fullWidth, isTemplate);
}

class _TemplateBanner extends StatelessWidget {
  const _TemplateBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2383E2).withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: const Text(
        '템플릿을 편집하고 있어요. 이 템플릿으로 만드는 새 페이지에 이 내용이 복사돼요.',
        style: TextStyle(fontSize: 13),
      ),
    );
  }
}

/// Breadcrumb, last edit, favorite and the page ⋯ menu.
class PageTopBar extends ConsumerWidget {
  const PageTopBar({super.key, required this.pageId});

  final String pageId;

  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    PageRow page,
    Offset at,
  ) async {
    final repo = ref.read(repositoryProvider);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final stats = await repo.pageStats(page.id);
    if (!context.mounted) return;
    final isInbox = page.id == repo.inboxPageId;
    final result = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 300),
      items: [
        _FontStyleEntry(current: page.fontStyle),
        CheckedPopupMenuItem<Object>(
          value: 'small',
          checked: page.smallText,
          child: const Text('작은 텍스트'),
        ),
        CheckedPopupMenuItem<Object>(
          value: 'wide',
          checked: page.fullWidth,
          child: const Text('전체 너비'),
        ),
        const PopupMenuDivider(),
        ...pageMenuItems(
          page,
          isInbox: isInbox,
          includeAddChild: false,
          includeFavorite: false,
        ),
        PopupMenuItem<Object>(
          value: 'export',
          height: 36,
          child: Row(
            children: [
              Icon(
                Icons.file_download_outlined,
                size: 18,
                color: context.noteColors.text,
              ),
              const SizedBox(width: 10),
              const Text('Markdown으로 내보내기', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<Object>(
          value: 'graph',
          height: 36,
          child: Row(
            children: [
              Icon(
                Icons.hub_outlined,
                size: 18,
                color: context.noteColors.text,
              ),
              const SizedBox(width: 10),
              const Text('로컬 그래프', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<Object>(
          value: 'find',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: context.noteColors.text),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('페이지에서 찾기', style: TextStyle(fontSize: 14)),
              ),
              Text(
                'Ctrl+F',
                style: TextStyle(
                  fontSize: 12,
                  color: context.noteColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<Object>(
          value: 'assets',
          height: 36,
          child: Row(
            children: [
              Icon(
                Icons.perm_media_outlined,
                size: 18,
                color: context.noteColors.text,
              ),
              const SizedBox(width: 10),
              const Text('로컬 자료실', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<Object>(
          value: 'history',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.history, size: 18, color: context.noteColors.text),
              const SizedBox(width: 10),
              const Text('변경 기록', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          height: 52,
          child: DefaultTextStyle(
            style: TextStyle(fontSize: 12, color: context.noteColors.textMuted),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${stats.words}개의 단어, ${stats.chars}자'),
                Text(formatEdited(page.updatedAt).replaceAll(' 편집', ' 최종 편집')),
              ],
            ),
          ),
        ),
      ],
    );
    if (result == null || !context.mounted) return;
    switch (result) {
      case 'small':
        await repo.updatePage(page.id, smallText: !page.smallText);
      case 'wide':
        await repo.updatePage(page.id, fullWidth: !page.fullWidth);
      case 'history':
        await showHistoryDialog(context, page.id);
      case 'export':
        await exportMarkdownFlow(context, ref, rootPageId: page.id);
      case 'graph':
        await showDialog<void>(
          context: context,
          builder: (dialog) => Dialog(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 760,
              height: 560,
              child: GraphView(
                focusPageId: page.id,
                onOpen: () => Navigator.pop(dialog),
              ),
            ),
          ),
        );
      case 'find':
        pageFindRequest.value = page.id;
      case 'assets':
        // 로컬 자료실: full screen on a phone, a large dialog on a computer.
        final narrow = MediaQuery.sizeOf(context).width < 600;
        await showDialog<void>(
          context: context,
          builder: (dialog) => narrow
              ? Dialog.fullscreen(
                  child: Scaffold(
                    appBar: AppBar(
                      leading: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(dialog),
                      ),
                    ),
                    body: AssetsView(rootPageId: page.id),
                  ),
                )
              : Dialog(
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: 900,
                    height: 640,
                    child: AssetsView(rootPageId: page.id),
                  ),
                ),
        );
      case String font when font.startsWith('font:'):
        await repo.updatePage(page.id, fontStyle: font.substring(5));
      case PageAction action:
        await runPageAction(context, ref, page, action);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(pageProvider(pageId)).value;
    if (page == null) return const SizedBox(height: 44);
    final colors = context.noteColors;
    final repo = ref.watch(repositoryProvider);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: FutureBuilder(
              // Re-resolved when the parent changes (page row emits).
              future: repo.ancestors(pageId),
              builder: (context, snap) {
                final chain = [...?snap.data, page];
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < chain.length; i++) ...[
                        if (i > 0)
                          Text(
                            ' / ',
                            style: TextStyle(color: colors.textMuted),
                          ),
                        _Crumb(page: chain[i]),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          Text(
            formatEdited(page.updatedAt),
            style: TextStyle(fontSize: 13, color: colors.textMuted),
          ),
          IconButton(
            tooltip: page.favorite ? '즐겨찾기에서 제거' : '즐겨찾기에 추가',
            iconSize: 19,
            icon: Icon(
              page.favorite ? Icons.star : Icons.star_border,
              color: page.favorite ? const Color(0xFFF5B400) : colors.textMuted,
            ),
            onPressed: () => repo.updatePage(page.id, favorite: !page.favorite),
          ),
          Builder(
            builder: (anchor) => IconButton(
              tooltip: '더 보기',
              iconSize: 19,
              icon: Icon(Icons.more_horiz, color: colors.textMuted),
              onPressed: () {
                final box = anchor.findRenderObject()! as RenderBox;
                _showMenu(
                  context,
                  ref,
                  page,
                  box.localToGlobal(Offset(0, box.size.height)),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _Crumb extends ConsumerWidget {
  const _Crumb({required this.page});

  final PageRow page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => ref.read(screenProvider.notifier).openPage(page.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          '${(page.icon?.isNotEmpty ?? false) ? '${page.icon} ' : ''}'
          '${page.title.isEmpty ? '제목 없음' : page.title}',
          style: TextStyle(fontSize: 14, color: context.noteColors.text),
        ),
      ),
    );
  }
}

/// "글꼴 스타일": 기본 / 세리프 / 모노 (Notion's three Ag buttons).
class _FontStyleEntry extends PopupMenuEntry<Object> {
  const _FontStyleEntry({required this.current});

  final String current;

  @override
  double get height => 96;

  @override
  bool represents(Object? value) => false;

  @override
  State<_FontStyleEntry> createState() => _FontStyleEntryState();
}

class _FontStyleEntryState extends State<_FontStyleEntry> {
  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    Widget option(String value, String label, List<String>? family) {
      final selected = widget.current == value;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => Navigator.pop(context, 'font:$value'),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? colors.hover : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                Text(
                  'Ag',
                  style: TextStyle(
                    fontSize: 24,
                    fontFamily: family?.first,
                    fontFamilyFallback: family?.skip(1).toList(),
                    color: selected ? const Color(0xFF2383E2) : colors.text,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 4),
            child: Text(
              '글꼴 스타일',
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ),
          Row(
            children: [
              option('default', '기본', null),
              option('serif', '세리프', const ['Georgia', 'Batang']),
              option('mono', '모노', const ['Consolas', 'D2Coding']),
            ],
          ),
        ],
      ),
    );
  }
}

/// Icon + title. Rebuilds only when the title or icon changes.
class _PageHeader extends ConsumerStatefulWidget {
  const _PageHeader({
    required this.pageId,
    required this.repo,
    required this.layout,
    required this.onSubmitted,
  });

  final String pageId;
  final NotesRepository repo;
  final _Layout layout;
  final VoidCallback onSubmitted;

  @override
  ConsumerState<_PageHeader> createState() => _PageHeaderState();
}

class _PageHeaderState extends ConsumerState<_PageHeader> {
  final _title = TextEditingController();
  Timer? _titleTimer;
  bool _loaded = false;

  @override
  void dispose() {
    if (_titleTimer?.isActive ?? false) {
      _titleTimer!.cancel();
      widget.repo.updatePage(widget.pageId, title: _title.text);
    }
    _title.dispose();
    super.dispose();
  }

  void _onTitleChanged(String value) {
    // A title is one line: Enter (a hardware or phone keyboard's newline)
    // moves on to the body instead of breaking the title.
    if (value.contains('\n')) {
      value = value.replaceAll('\n', '');
      _title.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      widget.onSubmitted();
    }
    _titleTimer?.cancel();
    _titleTimer = Timer(const Duration(milliseconds: 400), () {
      widget.repo.updatePage(widget.pageId, title: value);
    });
  }

  Future<void> _pickIcon() async {
    final result = await showIconPicker(context);
    if (result == null) return;
    await widget.repo.updatePage(widget.pageId, icon: result);
  }

  @override
  Widget build(BuildContext context) {
    final meta = ref.watch(
      pageProvider(widget.pageId).select(
        (a) => a.hasValue
            ? (
                a.value?.title ?? '',
                a.value?.icon,
                a.value?.kind,
                a.value?.parentId,
                a.value?.createdAt ?? 0,
              )
            : null,
      ),
    );
    if (meta == null) return const SizedBox(height: 120);
    final (title, rawIcon, kind, parentId, createdAt) = meta;
    // Type the title right away only on a page just made. An old untitled
    // page opened from the sidebar keeps focus there (Delete / F2).
    final justCreated =
        DateTime.now().millisecondsSinceEpoch - createdAt < 10000;
    // Renamed elsewhere (sidebar F2, another device) → follow, unless an
    // edit typed here is still waiting to be saved.
    if (!_loaded ||
        (title != _title.text && !(_titleTimer?.isActive ?? false))) {
      _title.text = title;
      _loaded = true;
    }
    final icon = (rawIcon?.isEmpty ?? true) ? null : rawIcon;
    final colors = context.noteColors;

    // Blocks are laid out centered with maxWidth + padding; match that.
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: widget.layout.maxWidth),
        padding: widget.layout.padding.copyWith(
          top: _isMobile ? 16 : 48,
          bottom: 8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null)
              InkWell(
                onTap: _pickIcon,
                borderRadius: BorderRadius.circular(6),
                child: Text(icon, style: const TextStyle(fontSize: 56)),
              )
            else
              TextButton.icon(
                onPressed: _pickIcon,
                icon: Icon(
                  Icons.emoji_emotions_outlined,
                  size: 16,
                  color: colors.textMuted,
                ),
                label: Text(
                  '아이콘 추가',
                  style: TextStyle(color: colors.textMuted, fontSize: 13),
                ),
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
              ),
            InEditorTextField(
              child: TextField(
                controller: _title,
                autofocus: title.isEmpty && justCreated,
                onChanged: _onTitleChanged,
                onSubmitted: (_) => widget.onSubmitted(),
                maxLines: null,
                textInputAction: TextInputAction.next,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                  height: 1.2,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: '제목 없음',
                  hintStyle: TextStyle(
                    color: colors.textMuted.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            if (kind == 'row' && parentId != null)
              RowProperties(rowId: widget.pageId, databaseId: parentId),
          ],
        ),
      ),
    );
  }
}

/// A full-page database: title header, then its views (no text editor).
class DatabasePage extends ConsumerWidget {
  const DatabasePage({super.key, required this.pageId});

  final String pageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    const layout = _Layout('default', false, true, false);
    return Column(
      children: [
        PageTopBar(pageId: pageId),
        Expanded(
          child: ListView(
            children: [
              _PageHeader(
                pageId: pageId,
                repo: repo,
                layout: layout,
                onSubmitted: () {},
              ),
              Padding(
                padding: layout.padding.copyWith(bottom: 48),
                child: DatabaseView(databaseId: pageId),
              ),
              Padding(
                padding: layout.padding.copyWith(top: 0, bottom: 48),
                child: BacklinksPanel(pageId: pageId),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Full-page 사진 보관함, with the same header as other pages.
/// A 계획 지도 page: its title, then the map filling the rest.
class PlanMapPage extends ConsumerWidget {
  const PlanMapPage({super.key, required this.pageId});

  final String pageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    const layout = _Layout('default', false, true, false);
    return Column(
      children: [
        PageTopBar(pageId: pageId),
        _PageHeader(
          pageId: pageId,
          repo: repo,
          layout: layout,
          onSubmitted: () {},
        ),
        Divider(height: 1, color: context.noteColors.divider),
        Expanded(child: PlanMapCanvas(pageId: pageId)),
      ],
    );
  }
}

class AlbumPage extends ConsumerWidget {
  const AlbumPage({super.key, required this.pageId});

  final String pageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    const layout = _Layout('default', false, true, false);
    return Column(
      children: [
        PageTopBar(pageId: pageId),
        Expanded(
          child: ListView(
            children: [
              _PageHeader(
                pageId: pageId,
                repo: repo,
                layout: layout,
                onSubmitted: () {},
              ),
              Padding(
                padding: layout.padding.copyWith(bottom: 48),
                child: AlbumView(albumId: pageId),
              ),
              Padding(
                padding: layout.padding.copyWith(top: 0, bottom: 48),
                child: BacklinksPanel(pageId: pageId),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
