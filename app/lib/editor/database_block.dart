import 'package:appflowy_editor/appflowy_editor.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/block_component/base_component/widget/ignore_parent_gesture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

import '../data/album_repository.dart';
import '../data/database_repository.dart';
import '../db_ui/database_view.dart';
import '../providers.dart';
import '../ui/album_view.dart';

/// Inline Notion database inside a page. The database itself is a child
/// page (kind 'database'); this block only points at it.
class DatabaseBlockKeys {
  const DatabaseBlockKeys._();

  static const type = 'database';
  static const databaseId = 'databaseId';
}

/// Inline 사진 보관함: a child page of kind 'album', rendered by the same
/// block widget as an inline database.
class AlbumBlockKeys {
  const AlbumBlockKeys._();

  static const type = 'album';
  static const albumId = 'albumId';
}

final SelectionMenuItem albumMenuItem = SelectionMenuItem(
  getName: () => '사진 보관함',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.photo_library_outlined,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['album', 'gallery', 'photo', '사진', '보관함', '앨범', '갤러리'],
  handler: (editorState, _, context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final pageId = container.read(selectedPageProvider);
    if (pageId == null || editorState.selection == null) return;
    final albumId = await container
        .read(repositoryProvider)
        .createAlbum(parentId: pageId, title: '사진 보관함');
    await _insertLinkedBlock(
      editorState,
      Node(
        type: AlbumBlockKeys.type,
        attributes: {AlbumBlockKeys.albumId: albumId},
      ),
    );
  },
);

/// Puts [block] at the cursor (replacing an empty line) plus a line after.
Future<void> _insertLinkedBlock(EditorState editorState, Node block) async {
  final selection = editorState.selection;
  if (selection == null) return;
  final path = selection.end.path;
  final node = editorState.getNodeAtPath(path);
  final replace = node?.delta?.isEmpty ?? false;
  final at = replace ? path : path.next;
  final transaction = editorState.transaction
    ..insertNode(at, block)
    ..insertNode(at.next, paragraphNode());
  if (replace && node != null) transaction.deleteNode(node);
  transaction.afterSelection = Selection.collapsed(Position(path: at.next));
  await editorState.apply(transaction);
}

final SelectionMenuItem databaseMenuItem = SelectionMenuItem(
  getName: () => '데이터베이스',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.table_chart_outlined,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['database', 'db', 'table', 'board', '데이터베이스', '보드', '디비'],
  handler: (editorState, _, context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final pageId = container.read(selectedPageProvider);
    if (pageId == null || editorState.selection == null) return;
    final repo = container.read(repositoryProvider);
    final dbId = await repo.createDatabase(parentId: pageId, title: '새 데이터베이스');
    await _insertLinkedBlock(
      editorState,
      Node(
        type: DatabaseBlockKeys.type,
        attributes: {DatabaseBlockKeys.databaseId: dbId},
      ),
    );
  },
);

class DatabaseBlockComponentBuilder extends BlockComponentBuilder {
  DatabaseBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return DatabaseBlockWidget(
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

class DatabaseBlockWidget extends BlockComponentStatefulWidget {
  const DatabaseBlockWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<DatabaseBlockWidget> createState() => _DatabaseBlockWidgetState();
}

class _DatabaseBlockWidgetState extends State<DatabaseBlockWidget>
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
    final dbId = node.attributes[DatabaseBlockKeys.databaseId] as String?;
    final albumId = node.attributes[AlbumBlockKeys.albumId] as String?;

    Widget child = Container(
      key: _boxKey,
      padding: const EdgeInsets.symmetric(vertical: 4),
      // Clicks and typing inside the database belong to it, not to the
      // editor's text selection.
      child: IgnoreEditorSelectionGesture(
        child: node.type == AlbumBlockKeys.type
            ? albumId == null
                  ? const Text('보관함을 찾을 수 없어요')
                  : AlbumView(albumId: albumId, inline: true)
            : dbId == null
            ? const Text('데이터베이스를 찾을 수 없어요')
            : DatabaseView(databaseId: dbId, inline: true),
      ),
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
