import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

/// 토글 (Notion "toggle"): a line whose ▶ folds the blocks under it.
/// The children are the toggle's content; `collapsed` is saved with it.
class ToggleBlockKeys {
  const ToggleBlockKeys._();

  static const type = 'toggle_list';
  static const collapsed = 'collapsed';
}

Node toggleNode({
  Delta? delta,
  bool collapsed = false,
  Iterable<Node>? children,
}) => Node(
  type: ToggleBlockKeys.type,
  attributes: {
    blockComponentDelta: (delta ?? Delta()).toJson(),
    ToggleBlockKeys.collapsed: collapsed,
  },
  children: children ?? [],
);

/// 콜아웃 (Notion callout, Obsidian `> [!note]`): a box with an icon.
class CalloutBlockKeys {
  const CalloutBlockKeys._();

  static const type = 'callout';
  static const icon = 'icon';
}

/// Tapping a callout's icon goes to the next one.
const calloutIcons = ['💡', '⚠️', '✅', '📌', '❗', '📝'];

Node calloutNode({Delta? delta, String icon = '💡'}) => Node(
  type: CalloutBlockKeys.type,
  attributes: {
    blockComponentDelta: (delta ?? Delta()).toJson(),
    CalloutBlockKeys.icon: icon,
  },
);

/// Enter on a toggle's line (like Notion): an open toggle gets a new first
/// line inside it, a folded one gets a new toggle after it, and an empty
/// toggle turns back into a plain line.
final CharacterShortcutEvent enterInToggle = CharacterShortcutEvent(
  key: 'enter in a toggle',
  character: '\n',
  handler: (editorState) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final node = editorState.getNodeAtPath(selection.end.path);
    final delta = node?.delta;
    if (node == null || delta == null || node.type != ToggleBlockKeys.type) {
      return false;
    }
    final path = node.path;
    final t = editorState.transaction;
    if (delta.isEmpty) {
      t
        ..insertNode(path, paragraphNode())
        ..insertNodes(path.next, node.children.map((c) => c.copyWith()))
        ..deleteNode(node)
        ..afterSelection = Selection.collapsed(Position(path: path));
      await editorState.apply(t);
      return true;
    }
    final offset = selection.end.offset.clamp(0, delta.length);
    final rest = delta.slice(offset);
    if (offset < delta.length) {
      t.deleteText(node, offset, delta.length - offset);
    }
    final collapsed = node.attributes[ToggleBlockKeys.collapsed] == true;
    final at = collapsed ? path.next : path.child(0);
    t
      ..insertNode(
        at,
        collapsed ? toggleNode(delta: rest) : paragraphNode(delta: rest),
      )
      ..afterSelection = Selection.collapsed(Position(path: at));
    await editorState.apply(t);
    return true;
  },
);

// ---- slash menu ----

SelectionMenuItem _menuItem(
  String name,
  IconData icon,
  List<String> keywords,
  Node Function() make,
) => SelectionMenuItem(
  getName: () => name,
  icon: (editorState, isSelected, style) =>
      SelectionMenuIconWidget(icon: icon, isSelected: isSelected, style: style),
  keywords: keywords,
  handler: (editorState, _, _) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null) return;
    final empty = node.delta?.isEmpty ?? false;
    final at = empty ? node.path : node.path.next;
    final t = editorState.transaction..insertNode(at, make());
    if (empty) t.deleteNode(node);
    t.afterSelection = Selection.collapsed(Position(path: at));
    await editorState.apply(t);
  },
);

final toggleMenuItem = _menuItem('토글', Icons.arrow_right, [
  'toggle',
  'details',
  '토글',
  '접기',
], toggleNode);

final calloutMenuItem = _menuItem('콜아웃', Icons.lightbulb_outline, [
  'callout',
  'note',
  '콜아웃',
  '강조',
], calloutNode);

// ---- blocks ----

class ToggleBlockComponentBuilder extends BlockComponentBuilder {
  ToggleBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return _TextBlockWidget(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      kind: _Kind.toggle,
    );
  }

  @override
  BlockComponentValidate get validate =>
      (node) => node.delta != null;
}

class CalloutBlockComponentBuilder extends BlockComponentBuilder {
  CalloutBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return _TextBlockWidget(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      kind: _Kind.callout,
    );
  }

  @override
  BlockComponentValidate get validate =>
      (node) => node.delta != null;
}

enum _Kind { toggle, callout }

class _TextBlockWidget extends BlockComponentStatefulWidget {
  const _TextBlockWidget({
    super.key,
    required super.node,
    required this.kind,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  final _Kind kind;

  @override
  State<_TextBlockWidget> createState() => _TextBlockWidgetState();
}

class _TextBlockWidgetState extends State<_TextBlockWidget>
    with
        SelectableMixin,
        DefaultSelectableMixin,
        BlockComponentConfigurable,
        BlockComponentBackgroundColorMixin,
        NestedBlockComponentStatefulWidgetMixin,
        BlockComponentTextDirectionMixin,
        BlockComponentAlignMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'flowy_rich_text');

  @override
  GlobalKey<State<StatefulWidget>> get containerKey => widget.node.key;

  @override
  GlobalKey<State<StatefulWidget>> blockComponentKey = GlobalKey(
    debugLabel: 'toggle_callout',
  );

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  bool get _collapsed => node.attributes[ToggleBlockKeys.collapsed] == true;

  Future<void> _flip() async {
    final t = editorState.transaction
      ..updateNode(node, {ToggleBlockKeys.collapsed: !_collapsed});
    await editorState.apply(t);
  }

  Future<void> _nextIcon() async {
    final now = node.attributes[CalloutBlockKeys.icon] as String? ?? '💡';
    final i = calloutIcons.indexOf(now);
    final t = editorState.transaction
      ..updateNode(node, {
        CalloutBlockKeys.icon: calloutIcons[(i + 1) % calloutIcons.length],
      });
    await editorState.apply(t);
  }

  /// A folded toggle shows only its own line.
  @override
  Widget build(BuildContext context) {
    if (widget.kind == _Kind.toggle && _collapsed) {
      return Padding(
        padding: configuration.margin(node),
        child: buildComponent(context),
      );
    }
    return super.build(context);
  }

  @override
  Widget buildComponent(
    BuildContext context, {
    bool withBackgroundColor = true,
  }) {
    final textDirection = calculateTextDirection(
      layoutDirection: Directionality.maybeOf(context),
    );
    final theme = Theme.of(context);
    final scale = editorState.editorStyle.textScaleFactor;
    final leading = switch (widget.kind) {
      _Kind.toggle => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _flip,
        child: SizedBox(
          width: 26 * scale,
          height: 26 * scale,
          child: Icon(
            _collapsed ? Icons.arrow_right : Icons.arrow_drop_down,
            size: 22 * scale,
            color: theme.hintColor,
          ),
        ),
      ),
      _Kind.callout => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _nextIcon,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            node.attributes[CalloutBlockKeys.icon] as String? ?? '💡',
            style: TextStyle(fontSize: 18 * scale),
          ),
        ),
      ),
    };

    Widget child = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      textDirection: textDirection,
      children: [
        leading,
        Flexible(
          child: AppFlowyRichText(
            key: forwardKey,
            delegate: this,
            node: widget.node,
            editorState: editorState,
            textAlign: alignment?.toTextAlign ?? textAlign,
            placeholderText: widget.kind == _Kind.toggle ? '토글' : '내용을 입력하세요',
            textSpanDecorator: (textSpan) => textSpan.updateTextStyle(
              textStyleWithTextSpan(textSpan: textSpan),
            ),
            placeholderTextSpanDecorator: (textSpan) =>
                textSpan.updateTextStyle(
                  placeholderTextStyleWithTextSpan(textSpan: textSpan),
                ),
            textDirection: textDirection,
            cursorColor: editorState.editorStyle.cursorColor,
            selectionColor: editorState.editorStyle.selectionColor,
            cursorWidth: editorState.editorStyle.cursorWidth,
          ),
        ),
      ],
    );

    if (widget.kind == _Kind.callout) {
      child = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );
    } else {
      child = Container(
        width: double.infinity,
        alignment: alignment,
        child: child,
      );
    }

    child = Container(
      decoration: withBackgroundColor ? decoration : null,
      key: blockComponentKey,
      padding: padding,
      child: child,
    );

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
    return child;
  }
}
