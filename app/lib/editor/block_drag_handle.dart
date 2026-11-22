// Drag handle (⋮⋮) shown left of a hovered block; drag to move the block.
// Adapted from appflowy_editor's example/lib/pages/drag_to_reorder_editor.dart
// (MPL-2.0). Column creation (drop on the right side) is left out.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

const _dropColor = Color(0xFF2383E2);

/// Width of the handle column. The editor's left padding is reduced by this
/// much so block text still lines up with the page title (ISSUES.md #016).
const blockHandleWidth = 22.0;
const _interceptorKey = 'notes_block_drag_handle';

enum _Vertical { top, bottom }

class BlockDragHandle extends StatefulWidget {
  const BlockDragHandle({
    super.key,
    required this.blockComponentContext,
    required this.builder,
  });

  final BlockComponentContext blockComponentContext;
  final BlockComponentBuilder builder;

  @override
  State<BlockDragHandle> createState() => _BlockDragHandleState();
}

class _BlockDragHandleState extends State<BlockDragHandle> {
  late final EditorState editorState = context.read<EditorState>();
  late final SelectionGestureInterceptor _interceptor =
      SelectionGestureInterceptor(
        key: _interceptorKey,
        canTap: (details) => !_isTapInBounds(details.globalPosition),
      );
  Offset? _lastPosition;
  Selection? _beforeSelection;

  Node get _node => widget.blockComponentContext.node;
  RenderBox? get _box => context.findRenderObject() as RenderBox?;

  @override
  void initState() {
    super.initState();
    editorState.selectionService.registerGestureInterceptor(_interceptor);
  }

  @override
  void dispose() {
    editorState.selectionService.unregisterGestureInterceptor(_interceptorKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    return Container(
      // Fixed width = blockHandleWidth, so text lines up with the title.
      width: blockHandleWidth,
      padding: const EdgeInsets.only(top: 4),
      alignment: Alignment.topLeft,
      child: Draggable<Node>(
        data: _node,
        feedback: _feedback(),
        onDragStarted: editorState.selectionService.removeDropTarget,
        onDragUpdate: (details) {
          editorState.selectionService.renderDropTargetForOffset(
            details.globalPosition,
            builder: (context, data) => _dropIndicator(data, _node),
          );
          _lastPosition = details.globalPosition;
          editorState.scrollService?.startAutoScroll(details.globalPosition);
        },
        onDragEnd: (_) {
          editorState.selectionService.removeDropTarget();
          final position = _lastPosition;
          if (position == null) return;
          final data = editorState.selectionService.getDropTargetRenderData(
            position,
          );
          _move(data?.cursorNode?.path, position);
        },
        child: GestureDetector(
          onTap: _selectBlock,
          behavior: HitTestBehavior.translucent,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Tooltip(
              message: '드래그해서 이동\n클릭해서 선택',
              waitDuration: const Duration(milliseconds: 600),
              child: Icon(Icons.drag_indicator_rounded, size: 18, color: muted),
            ),
          ),
        ),
      ),
    );
  }

  void _selectBlock() {
    final path = _node.path;
    final before = _beforeSelection;
    editorState.updateSelectionWithReason(
      before != null && path.inSelection(before)
          ? before
          : Selection.collapsed(Position(path: path)),
      customSelectionType: SelectionType.block,
    );
    // The handle tap doesn't go through the editor, so keyboard focus could
    // still be on the sidebar: Ctrl+C / Ctrl+X / Delete then did nothing.
    editorState.service.keyboardService?.enable();
  }

  bool _isTapInBounds(Offset offset) {
    final box = _box;
    if (box == null) return false;
    final inside = box.paintBounds.contains(box.globalToLocal(offset));
    _beforeSelection = inside ? editorState.selection : null;
    return inside;
  }

  Future<void> _move(Path? targetPath, Offset offset) async {
    if (targetPath == null) return;
    final hit = editorState.getNodeAtPath(targetPath);
    if (hit == null) return;
    final target = dropTarget(hit);
    final vertical = _verticalPosition(target, offset);
    if (vertical == null) return;
    final newPath = vertical == _Vertical.top ? target.path : target.path.next;
    if (_ignoreDrop(_node, newPath)) return;
    final transaction = editorState.transaction..moveNode(newPath, _node);
    await editorState.apply(transaction);
  }

  Widget _feedback() {
    final node = _node;
    final Widget child = node.type == TableBlockKeys.type
        ? Container(
            width: 200,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('표'),
          )
        : IntrinsicWidth(
            child: IntrinsicHeight(
              child: Provider.value(
                value: editorState,
                child: widget.builder.build(
                  BlockComponentContext(
                    widget.blockComponentContext.buildContext,
                    node.copyWith(),
                  ),
                ),
              ),
            ),
          );
    return Opacity(
      opacity: 0.6,
      child: Material(color: Colors.transparent, child: child),
    );
  }
}

Widget _dropIndicator(DragAreaBuilderData data, Node dragNode) {
  final target = dropTarget(data.targetNode);
  final box = target.selectable?.context.findRenderObject() as RenderBox?;
  if (box == null) return const SizedBox.shrink();
  final vertical = _verticalPosition(target, data.dragOffset);
  if (vertical == null) return const SizedBox.shrink();
  final newPath = vertical == _Vertical.top ? target.path : target.path.next;
  if (_ignoreDrop(dragNode, newPath)) return const SizedBox.shrink();
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return Positioned(
    top: (vertical == _Vertical.top ? rect.top : rect.bottom) - 1,
    left: rect.left,
    child: Container(
      height: 3,
      width: rect.width,
      decoration: BoxDecoration(
        color: _dropColor.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// Blocks can't be dropped *into* a table: a cell must hold exactly one
/// paragraph, and a moved block there broke the table and vanished
/// (ISSUES.md #017). Anything inside a table targets the table itself.
Node dropTarget(Node hit) {
  Node? table;
  for (Node? n = hit; n != null; n = n.parent) {
    if (n.type == TableBlockKeys.type) table = n;
  }
  return table ?? hit;
}

_Vertical? _verticalPosition(Node target, Offset offset) {
  final box = target.selectable?.context.findRenderObject() as RenderBox?;
  if (box == null) return null;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  if (offset.dy < rect.top - 4 || offset.dy > rect.bottom + 4) return null;
  return offset.dy < rect.center.dy ? _Vertical.top : _Vertical.bottom;
}

bool _ignoreDrop(Node dragNode, Path newPath) {
  final from = dragNode.path;
  // Dropping right above or right below itself changes nothing.
  if (from.equals(newPath) || from.next.equals(newPath)) return true;
  return from.isAncestorOf(newPath);
}
