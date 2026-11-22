import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Base state for non-text blocks (video, upload skeleton, ...): the whole
/// block is one selectable unit. Subclasses build [buildContent] and wrap
/// it with [wrapBlock].
abstract class AtomicBlockState<T extends BlockComponentStatefulWidget>
    extends State<T>
    with SelectableMixin, BlockComponentConfigurable {
  final boxKey = GlobalKey();

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  Widget buildContent(BuildContext context);

  @override
  Widget build(BuildContext context) =>
      wrapBlock(context, buildContent(context));

  Widget wrapBlock(BuildContext context, Widget content) {
    final editorState = context.read<EditorState>();
    Widget child = KeyedSubtree(key: boxKey, child: content);
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
    final box = boxKey.currentContext?.findRenderObject();
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

/// Builder for an atomic block whose widget is created by [create].
class AtomicBlockBuilder extends BlockComponentBuilder {
  AtomicBlockBuilder(this.create, {super.configuration});

  final BlockComponentStatefulWidget Function(
    Node node,
    BlockComponentConfiguration configuration,
    bool showActions,
    BlockComponentActionBuilder actionBuilder,
  )
  create;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return create(
      node,
      configuration,
      showActions(node),
      (context, state) => actionBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate =>
      (node) => node.children.isEmpty;
}
