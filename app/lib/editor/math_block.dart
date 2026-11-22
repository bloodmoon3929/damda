import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:provider/provider.dart';

/// Block-level TeX equation (Notion "수식 블록", Obsidian `$$ ... $$`).
class MathBlockKeys {
  const MathBlockKeys._();

  static const type = 'math_equation';
  static const formula = 'formula';
}

Node mathNode({String formula = ''}) => Node(
  type: MathBlockKeys.type,
  attributes: {MathBlockKeys.formula: formula},
);

/// Where the user just inserted an equation; that block opens its editor on
/// mount. (A path, not the node: the transaction inserts a copy.)
(EditorState, Path)? _openOnMount;

Future<void> _insertMath(
  EditorState editorState, {
  required bool replace,
}) async {
  final selection = editorState.selection;
  if (selection == null || !selection.isCollapsed) return;
  final path = selection.end.path;
  final node = editorState.getNodeAtPath(path);
  if (node == null) return;
  final math = mathNode();
  final at = replace || (node.delta?.isEmpty ?? false) ? path : path.next;
  _openOnMount = (editorState, at);
  final transaction = editorState.transaction
    ..insertNode(at, math)
    ..insertNode(at.next, paragraphNode());
  if (replace || (node.delta?.isEmpty ?? false)) transaction.deleteNode(node);
  transaction.afterSelection = Selection.collapsed(Position(path: at.next));
  await editorState.apply(transaction);
}

/// Turns the current (empty) line into an equation and opens its editor.
Future<void> insertMathBlock(EditorState editorState) =>
    _insertMath(editorState, replace: true);

/// Typing `$$` in an otherwise empty paragraph turns it into an equation.
final CharacterShortcutEvent dollarsToMath = CharacterShortcutEvent(
  key: 'convert \$\$ to a math equation',
  character: r'$',
  handler: (editorState) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null || node.type != ParagraphBlockKeys.type) return false;
    if (node.delta?.toPlainText() != r'$' || selection.end.offset != 1) {
      return false;
    }
    await _insertMath(editorState, replace: true);
    return true;
  },
);

final SelectionMenuItem mathMenuItem = SelectionMenuItem(
  getName: () => '수식',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.functions,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['math', 'equation', 'latex', 'tex', '수식'],
  handler: (editorState, _, _) => _insertMath(editorState, replace: false),
);

class MathBlockComponentBuilder extends BlockComponentBuilder {
  MathBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return MathBlockWidget(
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

class MathBlockWidget extends BlockComponentStatefulWidget {
  const MathBlockWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<MathBlockWidget> createState() => _MathBlockWidgetState();
}

class _MathBlockWidgetState extends State<MathBlockWidget>
    with SelectableMixin, BlockComponentConfigurable {
  final _boxKey = GlobalKey();
  bool _hover = false;

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  String get _formula =>
      node.attributes[MathBlockKeys.formula] as String? ?? '';

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  @override
  void initState() {
    super.initState();
    final pending = _openOnMount;
    if (pending != null &&
        pending.$1 == context.read<EditorState>() &&
        pending.$2.equals(node.path)) {
      _openOnMount = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _edit());
    }
  }

  Future<void> _edit() async {
    if (!mounted) return;
    final editorState = context.read<EditorState>();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => MathEditDialog(initial: _formula),
    );
    if (result == null || result == _formula) return;
    final transaction = editorState.transaction;
    if (result.trim().isEmpty) {
      // Emptied and confirmed: the equation goes, like Notion.
      transaction
        ..deleteNode(node)
        ..afterSelection = Selection.collapsed(Position(path: node.path));
      if (node.next == null) transaction.insertNode(node.path, paragraphNode());
    } else {
      transaction.updateNode(node, {MathBlockKeys.formula: result});
    }
    await editorState.apply(transaction);
  }

  @override
  Widget build(BuildContext context) {
    final editorState = context.read<EditorState>();
    final theme = Theme.of(context);
    final textColor = editorState.editorStyle.textStyleConfiguration.text.color;

    Widget child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _edit,
        child: Container(
          key: _boxKey,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            color: _hover
                ? theme.colorScheme.onSurface.withValues(alpha: 0.05)
                : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: _formula.trim().isEmpty
              ? Row(
                  children: [
                    Icon(Icons.functions, size: 18, color: theme.hintColor),
                    const SizedBox(width: 8),
                    Text('TeX 수식 추가', style: TextStyle(color: theme.hintColor)),
                  ],
                )
              : Center(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Math.tex(
                      _formula,
                      mathStyle: MathStyle.display,
                      textStyle: TextStyle(fontSize: 18, color: textColor),
                      onErrorFallback: (e) => Text(
                        e.message,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );

    child = Padding(padding: padding, child: child);
    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      cursorColor: editorState.editorStyle.cursorColor,
      selectionColor: editorState.editorStyle.selectionColor,
      supportTypes: const [
        BlockSelectionType.block,
        BlockSelectionType.cursor,
        BlockSelectionType.selection,
      ],
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

  // ---- SelectableMixin: treat the whole equation as one selectable unit ----

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

/// TeX input with a live preview. Returns the new formula, or null.
class MathEditDialog extends StatefulWidget {
  const MathEditDialog({super.key, required this.initial, this.inline = false});

  final String initial;
  final bool inline;

  @override
  State<MathEditDialog> createState() => _MathEditDialogState();
}

class _MathEditDialogState extends State<MathEditDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.inline ? '인라인 수식 (TeX)' : '수식 (TeX)'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 14),
              decoration: const InputDecoration(
                hintText: r'예: E = mc^2,  \frac{a}{b},  \sum_{i=1}^{n} i',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Container(
              constraints: const BoxConstraints(minHeight: 60),
              alignment: Alignment.center,
              child: _controller.text.trim().isEmpty
                  ? Text('미리보기', style: TextStyle(color: theme.hintColor))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Math.tex(
                        _controller.text,
                        mathStyle: MathStyle.display,
                        textStyle: const TextStyle(fontSize: 18),
                        onErrorFallback: (e) => Text(
                          e.message,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('완료'),
        ),
      ],
    );
  }
}

/// Phone toolbar button: insert an equation block.
final mathMobileToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (context, _, _) =>
      Icon(Icons.functions, color: MobileToolbarTheme.of(context).iconColor),
  actionHandler: (_, editorState) => _insertMath(editorState, replace: false),
);
