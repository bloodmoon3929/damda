import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../data/album_repository.dart';
import '../data/asset_repository.dart';
import '../data/database.dart';
import '../editor/attachment_blocks.dart';
import '../providers.dart';
import 'download.dart';
import 'file_drop.dart';
import 'theme.dart';

final albumProvider = StreamProvider.family<List<AlbumItem>, String>(
  (ref, id) => ref.watch(repositoryProvider).watchAlbum(id),
);

/// An album's tabs: its items, its parent page's and the sub-pages'
/// photos, albums inside it ([AlbumRepository.watchAlbumGroups]).
final albumGroupsProvider = StreamProvider.family<List<AlbumGroup>, String>(
  (ref, id) => ref.watch(repositoryProvider).watchAlbumGroups(id),
);

/// 사진 보관함 page (kind 'album'): its own photos and videos as a
/// date-grouped gallery, like a phone's photo app. Used as a full page and
/// inline inside other pages. Grouped by the date added; step 8 switches to
/// the EXIF capture date.
class AlbumView extends ConsumerStatefulWidget {
  const AlbumView({super.key, required this.albumId, this.inline = false});

  final String albumId;
  final bool inline;

  @override
  ConsumerState<AlbumView> createState() => _AlbumViewState();
}

enum _Filter { all, photos, videos }

class _AlbumViewState extends ConsumerState<AlbumView> {
  _Filter _filter = _Filter.all;

  /// With albums inside this one: whose photos are shown. null = 전체,
  /// otherwise an album id (this one or one inside).
  String? _tab;

  /// Where new photos go: the open tab's album, or this one for 전체.
  String get _target => _tab != null && _tabIsAlbum ? _tab! : widget.albumId;

  /// The open tab is an album (photos can be added to it).
  bool _tabIsAlbum = false;
  bool _adding = false;
  bool _dragging = false;

  Future<void> _addPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    setState(() => _adding = true);
    try {
      final repo = ref.read(repositoryProvider);
      final assets = <AssetRow>[];
      for (final path in paths) {
        final a = await repo.importAsset(path, pageId: _target);
        final kind = assetKind(a.mime);
        if (kind == AssetKind.image || kind == AssetKind.video) assets.add(a);
      }
      final skipped = paths.length - assets.length;
      await repo.addToAlbum(_target, assets);
      if (skipped > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('사진·영상이 아닌 파일 $skipped개는 자료실에만 넣었어요')),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _pick() async =>
      _addPaths(await pickFilePaths(mediaOnly: true, title: '사진·영상 추가'));

  // ---- Ctrl+V: photos copied elsewhere (files or an image) ----

  @override
  void initState() {
    super.initState();
    if (!widget.inline) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Ctrl+V anywhere on the album page, unless typing in a text field (the
  /// title): focus is often still on the sidebar after opening the page.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyV) {
      return false;
    }
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return false;
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    _paste();
    return true;
  }

  Future<void> _paste() async {
    if (_adding) return;
    setState(() => _adding = true);
    var added = 0;
    var found = 0;
    try {
      final repo = ref.read(repositoryProvider);
      final jobs = await clipboardAttachments(repo, _target);
      final assets = <AssetRow>[];
      for (final job in jobs) {
        final a = await job.load();
        final kind = assetKind(a.mime);
        if (kind == AssetKind.image || kind == AssetKind.video) assets.add(a);
      }
      found = assets.length;
      added = await repo.addToAlbum(_target, assets);
    } catch (e) {
      debugPrint('album paste failed: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
    if (added == 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            found > 0 ? '이미 이 보관함에 있는 사진이에요' : '클립보드에 붙여넣을 사진이나 영상이 없어요',
          ),
        ),
      );
    }
  }

  Future<void> _itemMenu(AlbumItem item, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'download', child: Text('다운로드')),
        if (item.blockId.isEmpty)
          // Shown because a note around this album uses it.
          PopupMenuItem(
            enabled: false,
            height: 36,
            child: Row(
              children: [
                Icon(
                  Icons.block,
                  size: 16,
                  color: context.noteColors.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  '노트 사진 · 빼기 불가',
                  style: TextStyle(color: context.noteColors.textMuted),
                ),
              ],
            ),
          )
        else
          const PopupMenuItem(value: 'remove', child: Text('보관함에서 빼기')),
      ],
    );
    if (choice == 'download' && mounted) {
      await downloadAssets(context, ref.read(repositoryProvider), [item.asset]);
    }
    if (choice == 'remove') {
      await ref.read(repositoryProvider).removeFromAlbum(item.blockId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final tabGroups =
        ref.watch(albumGroupsProvider(widget.albumId)).value ??
        const <AlbumGroup>[];
    final current = tabGroups.where((g) => g.id == _tab).firstOrNull;
    if (_tab != null && current == null && tabGroups.isNotEmpty) {
      _tab = null; // that page or album has no photos any more
    }
    _tabIsAlbum = current?.album ?? false;
    // 전체: every group, each file once.
    final seen = <String>{};
    final all = [
      for (final g in current == null ? tabGroups : [current])
        for (final item in g.items)
          if (seen.add(item.asset.id)) item,
    ];
    final tabs = tabGroups.length < 2
        ? null
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (id, label) in [
                  (null, '전체'),
                  for (final g in tabGroups) (g.id, g.label),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6, bottom: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      visualDensity: VisualDensity.compact,
                      selected: _tab == id,
                      onSelected: (_) => setState(() => _tab = id),
                    ),
                  ),
              ],
            ),
          );
    final hasVideos = all.any(
      (i) => assetKind(i.asset.mime) == AssetKind.video,
    );
    if (!hasVideos) _filter = _Filter.all;
    final media = [
      for (final item in all)
        if (switch (assetKind(item.asset.mime)) {
          AssetKind.image => _filter != _Filter.videos,
          AssetKind.video => _filter != _Filter.photos,
          _ => false,
        })
          item,
    ]..sort((a, b) => b.asset.createdAt.compareTo(a.asset.createdAt));

    final groups = <String, List<AlbumItem>>{};
    for (final item in media) {
      final d = DateTime.fromMillisecondsSinceEpoch(item.asset.createdAt);
      groups
          .putIfAbsent('${d.year}년 ${d.month}월 ${d.day}일', () => [])
          .add(item);
    }

    final toolbar = Row(
      children: [
        if (widget.inline)
          Flexible(child: _InlineTitle(albumId: widget.albumId))
        else
          Text('${media.length}개', style: TextStyle(color: colors.textMuted)),
        const Spacer(),
        // Photo / video filter only when there are videos to tell apart
        // (and "모두", not a second "전체" next to the page tabs).
        if (hasVideos)
          for (final (f, label) in const [
            (_Filter.all, '모두'),
            (_Filter.photos, '사진'),
            (_Filter.videos, '영상'),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(label),
                visualDensity: VisualDensity.compact,
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        if (canDownloadMany && media.isNotEmpty)
          IconButton(
            tooltip: '보이는 ${media.length}개 모두 다운로드',
            icon: const Icon(Icons.download_outlined, size: 20),
            onPressed: () => downloadAssets(
              context,
              ref.read(repositoryProvider),
              [for (final m in media) m.asset],
            ),
          ),
        const SizedBox(width: 4),
        FilledButton.icon(
          icon: _adding
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.add_photo_alternate_outlined, size: 18),
          label: Text(_adding ? '추가하는 중…' : '추가'),
          onPressed: _adding ? null : _pick,
        ),
      ],
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Inline: the album's title row first, then its tabs.
        if (!widget.inline) ?tabs,
        toolbar,
        if (widget.inline && tabs != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: tabs),
        if (media.isEmpty)
          Container(
            height: widget.inline ? 120 : 220,
            margin: const EdgeInsets.only(top: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: colors.divider),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              all.isNotEmpty
                  ? '이 종류는 아직 없어요'
                  : widget.inline
                  ? '"추가"를 눌러 사진·영상을 넣으세요'
                  : '사진이나 영상을 여기로 끌어다 놓거나 "추가"를 누르세요',
              style: TextStyle(color: colors.textMuted),
            ),
          ),
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              entry.key,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 170,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: entry.value.length,
            itemBuilder: (context, i) {
              final item = entry.value[i];
              return _Tile(
                asset: item.asset,
                onTap: () => showMediaViewer(context, [
                  for (final m in media) m.asset,
                ], media.indexOf(item)),
                onMenu: (at) => _itemMenu(item, at),
              );
            },
          ),
        ],
      ],
    );

    if (widget.inline) return body;
    return FileDropTarget(
      onDragEntered: () => setState(() => _dragging = true),
      onDragExited: () => setState(() => _dragging = false),
      onDragDone: (paths, _) {
        setState(() => _dragging = false);
        _addPaths([
          for (final path in paths)
            if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file)
              path,
        ]);
      },
      child: Container(
        padding: _dragging ? const EdgeInsets.all(4) : EdgeInsets.zero,
        decoration: _dragging
            ? BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(6),
              )
            : null,
        child: body,
      ),
    );
  }
}

/// Title row of an inline album (click to open it as a full page).
class _InlineTitle extends ConsumerWidget {
  const _InlineTitle({required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final page = ref.watch(pageProvider(albumId)).value;
    return InkWell(
      onTap: () => ref.read(screenProvider.notifier).openPage(albumId),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            (page?.icon?.isNotEmpty ?? false) ? '${page!.icon} ' : '🖼 ',
            style: const TextStyle(fontSize: 20),
          ),
          Flexible(
            child: Text(
              (page?.title.isEmpty ?? true) ? '제목 없는 보관함' : page!.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.open_in_new, size: 14, color: colors.textMuted),
        ],
      ),
    );
  }
}

class _Tile extends ConsumerWidget {
  const _Tile({required this.asset, required this.onTap, required this.onMenu});

  final AssetRow asset;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final path = ref.read(repositoryProvider).assetPath(asset);
    final isVideo = assetKind(asset.mime) == AssetKind.video;
    final tile = GestureDetector(
      onSecondaryTapDown: (d) => onMenu(d.globalPosition),
      onLongPressStart: (d) => onMenu(d.globalPosition),
      child: Material(
        color: colors.hover,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (isVideo)
                const ColoredBox(color: Color(0xFF202020))
              else
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: 340,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: colors.textMuted,
                  ),
                ),
              if (isVideo) ...[
                const Center(
                  child: Icon(
                    Icons.play_circle_outline,
                    size: 44,
                    color: Colors.white70,
                  ),
                ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: Text(
                    asset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!canDownloadMany || !File(path).existsSync()) return tile;
    // Computers: drag a photo out to the desktop or a folder (a copy with
    // its original name).
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: (_) async {
        final out = await namedTempCopy(path, asset.name);
        return DragItem(suggestedName: asset.name)
          ..add(Formats.fileUri(Uri.file(out)));
      },
      child: DraggableWidget(child: tile),
    );
  }
}

/// Full-screen viewer: ←/→ (or the arrow buttons) to move, Esc to close,
/// pinch / wheel zoom on photos, videos play in place.
Future<void> showMediaViewer(
  BuildContext context,
  List<AssetRow> items,
  int index,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _MediaViewer(items: items, initial: index),
  );
}

class _MediaViewer extends ConsumerStatefulWidget {
  const _MediaViewer({required this.items, required this.initial});

  final List<AssetRow> items;
  final int initial;

  @override
  ConsumerState<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends ConsumerState<_MediaViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  final _focus = FocusNode();

  @override
  void dispose() {
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
    if (next != _index) {
      _pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider);
    final asset = widget.items[_index];
    final d = DateTime.fromMillisecondsSinceEpoch(asset.createdAt);
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) _go(1);
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) _go(-1);
      },
      child: Dialog.fullscreen(
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            PageView.builder(
              controller: _pages,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final a = widget.items[i];
                final path = repo.assetPath(a);
                if (!File(path).existsSync()) {
                  return Center(
                    child: MissingAssetButton(
                      assetId: a.id,
                      large: true,
                      onDone: () => setState(() {}),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(72, 56, 72, 72),
                  child: Center(
                    child: assetKind(a.mime) == AssetKind.video
                        ? ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1100),
                            child: InlineVideo(key: ValueKey(a.id), path: path),
                          )
                        : InteractiveViewer(
                            maxScale: 5,
                            child: Image.file(File(path), fit: BoxFit.contain),
                          ),
                  ),
                );
              },
            ),
            Positioned(
              top: 12,
              right: 60,
              child: IconButton(
                tooltip: '다운로드',
                color: Colors.white,
                icon: const Icon(Icons.download),
                onPressed: () => downloadAssets(context, repo, [asset]),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton(
                tooltip: '닫기 (Esc)',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            if (_index > 0)
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton(
                    tooltip: '이전 (←)',
                    iconSize: 36,
                    color: Colors.white,
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _go(-1),
                  ),
                ),
              ),
            if (_index < widget.items.length - 1)
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton(
                    tooltip: '다음 (→)',
                    iconSize: 36,
                    color: Colors.white,
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _go(1),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 20,
              child: Text(
                '${asset.name}  ·  ${d.year}.${d.month}.${d.day}  ·  '
                '${formatBytes(asset.size)}  ·  ${_index + 1} / ${widget.items.length}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
