import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/block_component/base_component/widget/ignore_parent_gesture.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/album_repository.dart';
import '../data/asset_repository.dart';
import '../data/database.dart';
import '../data/notes_repository.dart';
import 'atomic_block.dart';
import 'rich_clipboard.dart';
import '../ui/file_drop.dart';
import '../ui/photo_picker.dart';
import '../providers.dart';

/// A non-image attachment shown as a card (PDF, video, audio, ...).
class FileBlockKeys {
  const FileBlockKeys._();

  static const type = 'file';
  static const url = 'url'; // asset://<id>
  static const name = 'name';
  static const size = 'size';
  static const mime = 'mime';
}

IconData assetIcon(String mime) => switch (assetKind(mime)) {
  AssetKind.image => Icons.image_outlined,
  AssetKind.video => Icons.movie_outlined,
  AssetKind.audio => Icons.audiotrack_outlined,
  AssetKind.pdf => Icons.picture_as_pdf_outlined,
  AssetKind.other => Icons.insert_drive_file_outlined,
};

/// Opens an attachment with the OS default app.
Future<void> openAssetFile(String path) =>
    launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);

/// Test runs only (`--data-dir` + `--test-pick=<file>`): file pickers return
/// these paths instead of opening the OS dialog. Automated UI tests must not
/// drive the real dialog — keystrokes there once picked a private file from
/// the user's Pictures folder (ISSUES.md #020).
List<String>? testPickOverride;

/// Opens the OS file picker (or returns [testPickOverride]).
Future<List<String>> pickFilePaths({
  bool imagesOnly = false,
  bool mediaOnly = false,
  String? title,
}) async {
  final override = testPickOverride;
  if (override != null) return override;
  final result = await FilePicker.platform.pickFiles(
    type: imagesOnly
        ? FileType.image
        : (mediaOnly ? FileType.media : FileType.any),
    allowMultiple: true,
    dialogTitle: title,
  );
  return [...?result?.files.map((f) => f.path).whereType<String>()];
}

/// Picks files, stores them as assets and inserts image / file blocks/// after the cursor.
Future<void> insertAttachments(
  EditorState editorState,
  BuildContext context, {
  required bool imagesOnly,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final repo = container.read(repositoryProvider);
  final pageId = container.read(selectedPageProvider);
  final selection = editorState.selection;
  if (selection == null || pageId == null) return;

  // A page with 사진 보관함 under it: choose from their photos (or a file,
  // which also goes into the album).
  if (imagesOnly && (await repo.albumsFor(pageId)).isNotEmpty) {
    if (!context.mounted) return;
    final asset = await pickPhoto(context, repo, pageId);
    if (asset != null) await _insertNodes(editorState, [assetNode(asset)]);
    return;
  }

  final paths = await pickFilePaths(
    imagesOnly: imagesOnly,
    title: imagesOnly ? '이미지 추가' : '파일 첨부',
  );
  if (paths.isEmpty) return;

  await attachWithPlaceholders(editorState, [
    for (final path in paths)
      (
        name: p.basename(path),
        load: () => repo.importAsset(path, pageId: pageId),
      ),
  ]);
}

/// Block for an asset: image block for images, file card otherwise.
Node assetNode(AssetRow asset) => assetKind(asset.mime) == AssetKind.image
    ? imageNode(url: assetUrl(asset.id), align: 'left')
    : Node(
        type: FileBlockKeys.type,
        attributes: {
          FileBlockKeys.url: assetUrl(asset.id),
          FileBlockKeys.name: asset.name,
          FileBlockKeys.size: asset.size,
          FileBlockKeys.mime: asset.mime,
        },
      );

/// Inserts [nodes] after the cursor (or at the end of the page when nothing
/// is selected), followed by an empty line.
Future<void> _insertNodes(EditorState editorState, List<Node> nodes) async {
  if (nodes.isEmpty) return;
  final root = editorState.document.root;
  final path = editorState.selection?.end.path ?? [root.children.length - 1];
  final current = editorState.getNodeAtPath(path);
  final replace =
      current?.type == ParagraphBlockKeys.type &&
      (current?.delta?.isEmpty ?? false);
  final at = replace ? path : path.next;
  final transaction = editorState.transaction
    ..insertNodes(at, [...nodes, paragraphNode()]);
  if (replace) transaction.deleteNode(current!);
  transaction.afterSelection = Selection.collapsed(
    Position(path: at.nextNPath(nodes.length)),
  );
  await editorState.apply(transaction);
}

/// One file to attach: shown name and the (slow) import.
typedef AttachJob = ({String name, Future<AssetRow> Function() load});

var _placeholderSeq = 0;

/// Shows an "업로드 중" skeleton for each job right away, then swaps each
/// for its image / file block as its import finishes (or a failure line).
/// Placeholders are never saved (see [transientBlockTypes]).
Future<void> attachWithPlaceholders(
  EditorState editorState,
  List<AttachJob> jobs,
) async {
  if (jobs.isEmpty) return;
  final uids = [
    for (final _ in jobs)
      'up${DateTime.now().microsecondsSinceEpoch}-${_placeholderSeq++}',
  ];
  await _insertNodes(editorState, [
    for (var i = 0; i < jobs.length; i++)
      Node(
        type: UploadPlaceholderKeys.type,
        attributes: {
          UploadPlaceholderKeys.uid: uids[i],
          UploadPlaceholderKeys.name: jobs[i].name,
        },
      ),
  ]);
  for (var i = 0; i < jobs.length; i++) {
    Node replacement;
    try {
      replacement = assetNode(await jobs[i].load());
    } catch (e) {
      debugPrint('attach "${jobs[i].name}" failed: $e');
      replacement = paragraphNode(text: '⚠ 첨부 실패: ${jobs[i].name}');
    }
    final placeholder = _findPlaceholder(editorState.document.root, uids[i]);
    if (placeholder == null) continue; // the user deleted it meanwhile
    final transaction = editorState.transaction
      ..insertNode(placeholder.path, replacement)
      ..deleteNode(placeholder);
    await editorState.apply(transaction);
  }
}

Node? _findPlaceholder(Node node, String uid) {
  for (final child in node.children) {
    if (child.type == UploadPlaceholderKeys.type &&
        child.attributes[UploadPlaceholderKeys.uid] == uid) {
      return child;
    }
    final found = _findPlaceholder(child, uid);
    if (found != null) return found;
  }
  return null;
}

class UploadPlaceholderKeys {
  const UploadPlaceholderKeys._();

  static const type = uploadPlaceholderType;
  static const uid = 'uid';
  static const name = 'name';
}

/// What Ctrl+V should take from the clipboard: copied files (Explorer) or
/// an image become attachments; text keeps the normal paste. Real text
/// wins over an image (Word puts a picture of the text next to it), but an
/// image that only comes with its address or file name ("이미지 복사" in a
/// browser, some viewers) is pasted as the image.
bool clipboardPrefersImage(String? text) {
  final t = text?.trim() ?? '';
  return t.isEmpty || !t.contains(RegExp(r'\s'));
}

/// Reads copied files or an image from the clipboard, as attachment jobs.
/// Empty when the clipboard holds text to paste instead.
Future<List<AttachJob>> clipboardAttachments(
  NotesRepository repo,
  String? pageId,
) async {
  // Copied files always win: some apps (and our own picture copy) put the
  // file's path next to it as text.
  final files = await Pasteboard.files();
  Uint8List? image;
  if (files.isEmpty) {
    if (!clipboardPrefersImage(await Pasteboard.text)) return const [];
    image = await Pasteboard.image;
  }
  final stamp = DateTime.now()
      .toIso8601String()
      .substring(0, 19)
      .replaceAll(':', '-');
  return [
    for (final f in files)
      if (File(f).existsSync())
        (name: p.basename(f), load: () => repo.importAsset(f, pageId: pageId)),
    if (image case final bytes?)
      (
        name: '붙여넣은 이미지',
        load: () =>
            repo.importAssetBytes(bytes, '붙여넣은 이미지 $stamp.png', pageId: pageId),
      ),
  ];
}

/// Ctrl+V in the editor: see [clipboardAttachments].
CommandShortcutEvent attachmentPasteCommand(
  NotesRepository repo,
  String pageId,
) => CommandShortcutEvent(
  key: 'paste files or images as attachments',
  getDescription: () => '붙여넣기',
  command: 'ctrl+v',
  macOSCommand: 'cmd+v',
  handler: (editorState) {
    if (editorState.selection == null) return KeyEventResult.ignored;
    () async {
      // Our own copy/cut: paste the blocks themselves (tables, images…).
      try {
        if (await pasteRichCopy(editorState)) return;
      } catch (e) {
        debugPrint('block paste failed: $e');
      }
      try {
        final jobs = await clipboardAttachments(repo, pageId);
        if (jobs.isNotEmpty) {
          await attachWithPlaceholders(editorState, jobs);
          return;
        }
      } catch (e) {
        debugPrint('attachment paste failed: $e');
      }
      try {
        if (await pasteTextSmart(editorState)) return;
      } catch (e) {
        debugPrint('text paste failed: $e');
      }
      pasteCommand.handler(editorState);
    }();
    return KeyEventResult.handled;
  },
);

/// Accepts files dragged in from the OS and attaches them to the page.
class AttachmentDropZone extends ConsumerStatefulWidget {
  const AttachmentDropZone({
    super.key,
    required this.editorState,
    required this.pageId,
    required this.child,
  });

  final EditorState editorState;
  final String pageId;
  final Widget child;

  @override
  ConsumerState<AttachmentDropZone> createState() => _AttachmentDropZoneState();
}

class _AttachmentDropZoneState extends ConsumerState<AttachmentDropZone> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return FileDropTarget(
      onDragEntered: () => setState(() => _dragging = true),
      onDragExited: () => setState(() => _dragging = false),
      onDragDone: (paths, _) async {
        setState(() => _dragging = false);
        final repo = ref.read(repositoryProvider);
        await attachWithPlaceholders(widget.editorState, [
          for (final path in paths)
            if (File(path).existsSync() &&
                FileSystemEntity.typeSync(path) == FileSystemEntityType.file)
              (
                name: p.basename(path),
                load: () => repo.importAsset(path, pageId: widget.pageId),
              ),
        ]);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2383E2).withValues(alpha: 0.08),
                    border: Border.all(
                      color: const Color(0xFF2383E2),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '여기에 놓으면 첨부돼요',
                    style: TextStyle(fontSize: 18, color: Color(0xFF2383E2)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final SelectionMenuItem imageMenuItem = SelectionMenuItem(
  getName: () => '이미지',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.image_outlined,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['image', 'photo', 'picture', '이미지', '사진', '그림'],
  handler: (editorState, _, context) =>
      insertAttachments(editorState, context, imagesOnly: true),
);

final SelectionMenuItem fileMenuItem = SelectionMenuItem(
  getName: () => '파일 첨부',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.attach_file,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['file', 'attach', 'pdf', 'video', '파일', '첨부', '영상', '동영상'],
  handler: (editorState, _, context) =>
      insertAttachments(editorState, context, imagesOnly: false),
);

class FileBlockComponentBuilder extends BlockComponentBuilder {
  FileBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return FileBlockWidget(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate =>
      (node) => node.children.isEmpty;
}

class FileBlockWidget extends BlockComponentStatefulWidget {
  const FileBlockWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<FileBlockWidget> createState() => _FileBlockWidgetState();
}

class _FileBlockWidgetState extends State<FileBlockWidget>
    with SelectableMixin, BlockComponentConfigurable {
  final _boxKey = GlobalKey();

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  @override
  Widget build(BuildContext context) {
    final editorState = context.read<EditorState>();
    final theme = Theme.of(context);
    final url = node.attributes[FileBlockKeys.url] as String? ?? '';
    final name = node.attributes[FileBlockKeys.name] as String? ?? '파일';
    final size = node.attributes[FileBlockKeys.size] as int? ?? 0;
    final mime = node.attributes[FileBlockKeys.mime] as String? ?? '';
    final path = resolveAssetUrl(url);
    final missing = path == null || !File(path).existsSync();

    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: missing ? null : () => openAssetFile(path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(assetIcon(mime), size: 22, color: theme.hintColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                if (missing)
                  MissingAssetButton(
                    assetId: assetIdFromUrl(url),
                    onDone: () {
                      if (mounted) setState(() {});
                    },
                  )
                else
                  Text(
                    formatBytes(size),
                    style: TextStyle(fontSize: 12, color: theme.hintColor),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    Widget child = KeyedSubtree(
      key: _boxKey,
      child: assetKind(mime) == AssetKind.video && !missing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InlineVideo(path: path),
                card,
              ],
            )
          : card,
    );
    child = Padding(padding: padding, child: child);
    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      child: child,
    );
    if (widget.showActions && widget.actionBuilder != null) {
      child = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        child: child,
      );
    }
    return Padding(padding: margin, child: child);
  }

  @override
  Position start() => Position(path: node.path);

  @override
  Position end() => Position(path: node.path, offset: 1);

  @override
  Position getPositionInOffset(Offset start) => end();

  @override
  bool get shouldCursorBlink => false;

  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) =>
      getRectsInSelection(Selection.invalid()).first;

  @override
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) return null;
    return getRectsInSelection(
      Selection.collapsed(position),
      shiftWithBaseOffset: shiftWithBaseOffset,
    ).firstOrNull;
  }

  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) {
    final parentBox = _renderBox;
    if (parentBox == null) return [];
    final box = _boxKey.currentContext?.findRenderObject();
    if (box is RenderBox) {
      return [
        (shiftWithBaseOffset
                ? box.localToGlobal(Offset.zero, ancestor: parentBox)
                : Offset.zero) &
            box.size,
      ];
    }
    return [Offset.zero & parentBox.size];
  }

  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: node.path, startOffset: 0, endOffset: 1);

  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      _renderBox!.localToGlobal(offset);

  @override
  TextDirection textDirection() => TextDirection.ltr;
}

/// Phone toolbar button: attach photos / files.
final attachmentMobileToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (context, _, _) =>
      Icon(Icons.attach_file, color: MobileToolbarTheme.of(context).iconColor),
  actionHandler: (context, editorState) =>
      insertAttachments(editorState, context, imagesOnly: false),
);

/// Skeleton shown while a file is being attached (pulsing box, spinner,
/// file name). Replaced by the real block when the import finishes.
class UploadPlaceholderWidget extends BlockComponentStatefulWidget {
  const UploadPlaceholderWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<UploadPlaceholderWidget> createState() =>
      _UploadPlaceholderWidgetState();
}

class _UploadPlaceholderWidgetState
    extends AtomicBlockState<UploadPlaceholderWidget>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final name = node.attributes[UploadPlaceholderKeys.name] as String? ?? '';
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
      child: Container(
        height: 96,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '업로드 중… $name',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.hintColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

BlockComponentBuilder uploadPlaceholderBuilder() => AtomicBlockBuilder(
  (node, configuration, showActions, actionBuilder) => UploadPlaceholderWidget(
    key: node.key,
    node: node,
    configuration: configuration,
    showActions: showActions,
    actionBuilder: actionBuilder,
  ),
);

/// Plays a local video inside the page (media_kit: Windows, macOS, Linux,
/// Android). Paused until the user presses play.
class InlineVideo extends StatefulWidget {
  const InlineVideo({super.key, required this.path});

  final String path;

  @override
  State<InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<InlineVideo> {
  late final _player = Player();
  late final _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(Uri.file(widget.path).toString()), play: false);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            // Taps on the player controls belong to the player, not to the
            // editor's selection.
            child: IgnoreEditorSelectionGesture(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(controller: _controller),
                  // Big play button while paused, visible without hovering
                  // (touch screens, and the controls bar only shows on hover).
                  StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    initialData: _player.state.playing,
                    builder: (context, snap) => snap.data == true
                        ? const SizedBox.shrink()
                        : Center(
                            child: Material(
                              color: Colors.black54,
                              shape: const CircleBorder(),
                              child: IconButton(
                                iconSize: 44,
                                color: Colors.white,
                                tooltip: '재생',
                                icon: const Icon(Icons.play_arrow_rounded),
                                onPressed: _player.play,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown where an attachment's file is not on this device yet (a big video
/// on a phone is fetched only when wanted). Without a server it just says
/// the file is missing.
class MissingAssetButton extends ConsumerStatefulWidget {
  const MissingAssetButton({
    super.key,
    required this.assetId,
    required this.onDone,
    this.large = false,
  });

  final String? assetId;
  final VoidCallback onDone;
  final bool large;

  @override
  ConsumerState<MissingAssetButton> createState() => _MissingAssetButtonState();
}

class _MissingAssetButtonState extends ConsumerState<MissingAssetButton> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _download() async {
    setState(() => _busy = true);
    final ok = await ref.read(syncEngineProvider).download(widget.assetId!);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
    });
    if (ok) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canFetch =
        widget.assetId != null && ref.watch(syncEngineProvider).connected;
    if (!canFetch) {
      return Text(
        '파일 없음',
        style: TextStyle(
          fontSize: widget.large ? 14 : 12,
          color: widget.large ? Colors.white70 : theme.colorScheme.error,
        ),
      );
    }
    if (_busy) {
      return SizedBox(
        width: widget.large ? 32 : 14,
        height: widget.large ? 32 : 14,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final label = _failed ? '받기 실패 · 다시' : '서버에서 받기';
    return widget.large
        ? FilledButton.icon(
            icon: const Icon(Icons.download),
            label: Text(label),
            onPressed: _download,
          )
        : TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.download, size: 16),
            label: Text(label),
            onPressed: _download,
          );
  }
}

/// Image block whose file isn't on this device yet (still syncing, or a
/// big file waiting to be fetched): a placeholder that turns into the image
/// as soon as the file arrives.
Widget pendingImage(BuildContext context, String url) =>
    _PendingImage(url: url);

class _PendingImage extends StatelessWidget {
  const _PendingImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: assetFilesChanged,
      builder: (context, _, _) {
        final path = resolveAssetUrl(url);
        if (path != null && File(path).existsSync()) {
          return Image.file(File(path));
        }
        return Container(
          height: 140,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, color: theme.hintColor),
              const SizedBox(height: 6),
              Text(
                '이미지를 받는 중이에요',
                style: TextStyle(fontSize: 13, color: theme.hintColor),
              ),
              const SizedBox(height: 4),
              MissingAssetButton(
                assetId: assetIdFromUrl(url),
                onDone: () => assetFilesChanged.value++,
              ),
            ],
          ),
        );
      },
    );
  }
}
