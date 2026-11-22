import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ui/text_prompt.dart';
import 'code_runner.dart';

/// Code block (``` in Markdown): monospace text on a tinted background.
/// Enter adds a line inside the block; Enter on an empty last line leaves
/// it. The language is only a label (kept for .md round trips).
class CodeBlockKeys {
  const CodeBlockKeys._();

  static const type = 'code';
  static const language = 'language';
}

Node codeNode({String text = '', String language = ''}) => Node(
  type: CodeBlockKeys.type,
  attributes: {
    'delta': (Delta()..insert(text)).toJson(),
    CodeBlockKeys.language: language,
  },
);

const _mono = ['Consolas', 'D2Coding', 'Menlo', 'monospace', 'Malgun Gothic'];

/// Typing ``` at the start of an empty line turns it into a code block.
final CharacterShortcutEvent backticksToCodeBlock = CharacterShortcutEvent(
  key: 'type ``` for a code block',
  character: '`',
  handler: (editorState) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null ||
        node.type != ParagraphBlockKeys.type ||
        node.delta?.toPlainText() != '``' ||
        selection.end.offset != 2) {
      return false;
    }
    final transaction = editorState.transaction
      ..insertNode(node.path, codeNode())
      ..deleteNode(node)
      ..afterSelection = Selection.collapsed(Position(path: node.path));
    await editorState.apply(transaction);
    return true;
  },
);

/// Enter inside a code block.
final CharacterShortcutEvent newLineInCodeBlock = CharacterShortcutEvent(
  key: 'new line inside a code block',
  character: '\n',
  handler: (editorState) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isSingle) return false;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null || node.type != CodeBlockKeys.type) return false;
    final text = node.delta?.toPlainText() ?? '';
    final start = selection.startIndex;
    final end = selection.endIndex;
    // Enter on an empty last line: drop that line, continue below.
    if (selection.isCollapsed && end == text.length && text.endsWith('\n')) {
      final transaction = editorState.transaction
        ..deleteText(node, text.length - 1, 1)
        ..insertNode(node.path.next, paragraphNode())
        ..afterSelection = Selection.collapsed(Position(path: node.path.next));
      await editorState.apply(transaction);
      return true;
    }
    final transaction = editorState.transaction;
    if (end > start) transaction.deleteText(node, start, end - start);
    transaction
      ..insertText(node, start, '\n')
      ..afterSelection = Selection.collapsed(
        Position(path: node.path, offset: start + 1),
      );
    await editorState.apply(transaction);
    return true;
  },
);

final SelectionMenuItem codeMenuItem = SelectionMenuItem(
  getName: () => '코드',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.code,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['code', 'snippet', '코드', '```'],
  handler: (editorState, _, _) async {
    final selection = editorState.selection;
    if (selection == null) return;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null) return;
    final replace = node.delta?.isEmpty ?? false;
    final at = replace ? node.path : node.path.next;
    final transaction = editorState.transaction..insertNode(at, codeNode());
    if (replace) transaction.deleteNode(node);
    transaction.afterSelection = Selection.collapsed(Position(path: at));
    await editorState.apply(transaction);
  },
);

class CodeBlockComponentBuilder extends BlockComponentBuilder {
  CodeBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return CodeBlockComponentWidget(
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
      (node) => node.delta != null;
}

class CodeBlockComponentWidget extends BlockComponentStatefulWidget {
  const CodeBlockComponentWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<CodeBlockComponentWidget> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlockComponentWidget>
    with SelectableMixin, DefaultSelectableMixin, BlockComponentConfigurable {
  @override
  final forwardKey = GlobalKey(debugLabel: 'code_rich_text');

  @override
  GlobalKey<State<StatefulWidget>> get containerKey => widget.node.key;

  @override
  GlobalKey<State<StatefulWidget>> blockComponentKey = GlobalKey(
    debugLabel: CodeBlockKeys.type,
  );

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  late final editorState = Provider.of<EditorState>(context, listen: false);

  // Last run (not saved with the page, like Obsidian's Execute Code).
  CodeRun? _running;
  CodeRunResult? _result;
  String? _runError;

  Future<void> _run() async {
    final language = node.attributes[CodeBlockKeys.language] as String? ?? '';
    final run = runCode(language, node.delta?.toPlainText() ?? '');
    setState(() {
      _running = run;
      _runError = null;
    });
    try {
      final r = await run.result;
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = null;
          _runError = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _editLanguage() async {
    final current = node.attributes[CodeBlockKeys.language] as String? ?? '';
    final value = await askText(
      context,
      '코드 언어',
      current,
      hint: 'bash, python, dart …',
    );
    if (value == null || value == current) return;
    await editorState.apply(
      editorState.transaction
        ..updateNode(node, {CodeBlockKeys.language: value.trim()}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = node.attributes[CodeBlockKeys.language] as String? ?? '';
    final base = editorState.editorStyle.textStyleConfiguration.text;
    final mono = base.copyWith(
      fontFamily: _mono.first,
      fontFamilyFallback: _mono.skip(1).toList(),
      fontSize: (base.fontSize ?? 16) * 0.88,
      height: 1.45,
    );

    Widget child = Container(
      key: blockComponentKey,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          AppFlowyRichText(
            key: forwardKey,
            delegate: this,
            node: node,
            editorState: editorState,
            placeholderText: '코드',
            textSpanDecorator: (span) => span.updateTextStyle(mono),
            placeholderTextSpanDecorator: (span) =>
                span.updateTextStyle(mono.copyWith(color: theme.hintColor)),
            cursorColor: editorState.editorStyle.cursorColor,
            selectionColor: editorState.editorStyle.selectionColor,
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (codeRunSupported && runnableLanguage(language) != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _running == null
                        ? _TinyButton(
                            icon: Icons.play_arrow,
                            tooltip: '실행',
                            onTap: _run,
                          )
                        : _TinyButton(
                            icon: Icons.stop,
                            tooltip: '멈추기',
                            onTap: () => _running?.stop(),
                          ),
                  ),
                GestureDetector(
                  onTap: _editLanguage,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      language.isEmpty ? '언어' : language,
                      style: TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (_running != null || _result != null || _runError != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          child,
          _OutputPanel(
            running: _running != null,
            result: _result,
            error: _runError,
            style: mono,
            onClose: () => setState(() {
              _result = null;
              _runError = null;
            }),
          ),
        ],
      );
    }

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
}

class _TinyButton extends StatelessWidget {
  const _TinyButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Icon(icon, size: 18, color: Theme.of(context).hintColor),
      ),
    );
  }
}

/// Output of the last run under a code block.
class _OutputPanel extends StatelessWidget {
  const _OutputPanel({
    required this.running,
    required this.result,
    required this.error,
    required this.style,
    required this.onClose,
  });

  final bool running;
  final CodeRunResult? result;
  final String? error;
  final TextStyle style;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    final errorColor = theme.colorScheme.error;
    final String status;
    if (running) {
      status = '실행 중…';
    } else if (error != null) {
      status = '실행 못 함';
    } else if (r!.compileFailed) {
      status = '컴파일 오류';
    } else if (r.timedOut) {
      status = '시간 초과로 멈춤 (${r.elapsed.inSeconds}초)';
    } else if (r.exitCode == null) {
      status = '멈춤';
    } else {
      status = '종료 코드 ${r.exitCode} · ${r.elapsed.inMilliseconds}ms';
    }
    final small = style.copyWith(fontSize: (style.fontSize ?? 14) * 0.95);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '출력 · $status',
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
              const Spacer(),
              if (!running)
                _TinyButton(icon: Icons.close, tooltip: '지우기', onTap: onClose),
            ],
          ),
          if (error != null)
            Text(error!, style: small.copyWith(color: errorColor)),
          if (r != null && r.stdout.isNotEmpty)
            Text(r.stdout.trimRight(), style: small),
          if (r != null && r.stderr.isNotEmpty)
            Text(
              r.stderr.trimRight(),
              style: small.copyWith(color: errorColor),
            ),
          if (r != null && r.stdout.isEmpty && r.stderr.isEmpty && !running)
            Text('(출력 없음)', style: small.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }
}
