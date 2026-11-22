import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:provider/provider.dart';

import 'math_block.dart';

/// Inline TeX (`$x^2$` inside a line). Stored as a single '$' character
/// carrying a `formula` attribute, rendered as a widget.
const inlineFormulaKey = 'formula';

/// Typing the closing `$` of `$...$` turns the span into an inline formula.
final CharacterShortcutEvent dollarToInlineMath = CharacterShortcutEvent(
  key: 'convert \$...\$ to inline math',
  character: r'$',
  handler: (editorState) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final node = editorState.getNodeAtPath(selection.end.path);
    final delta = node?.delta;
    if (node == null || delta == null) return false;

    final end = selection.end.offset;
    final open = findInlineMathOpen(delta.toPlainText(), end);
    if (open == null) return false;
    // The opening '$' must be plain text, not an earlier formula.
    final openAttrs = delta.slice(open, open + 1).firstOrNull?.attributes;
    if (openAttrs?[inlineFormulaKey] != null) return false;
    final formula = delta.toPlainText().substring(open + 1, end);

    final transaction = editorState.transaction
      ..replaceText(
        node,
        open,
        end - open,
        r'$',
        attributes: {inlineFormulaKey: formula},
      )
      ..afterSelection = Selection.collapsed(
        Position(path: node.path, offset: open + 1),
      );
    await editorState.apply(transaction);
    return true;
  },
);

/// Index of the opening `$` when a closing `$` is typed at [end], or null.
/// Must never throw: an exception inside a shortcut handler kills keyboard
/// input until the user clicks again (ISSUES.md #007).
int? findInlineMathOpen(String text, int end) {
  if (end < 2 || end > text.length) return null;
  final open = text.lastIndexOf(r'$', end - 1);
  if (open < 0 || end - open < 2) return null;
  final formula = text.substring(open + 1, end);
  if (formula.trim().isEmpty || formula.startsWith(' ')) return null;
  return open;
}

/// Wraps the editor's default decorator to render inline formulas.
TextSpanDecoratorForAttribute inlineMathDecorator(
  TextSpanDecoratorForAttribute fallback,
) {
  return (context, node, index, text, before, after) {
    final formula = text.attributes?[inlineFormulaKey];
    if (formula is! String) {
      return fallback(context, node, index, text, before, after);
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _InlineMath(node: node, index: index, formula: formula),
    );
  };
}

class _InlineMath extends StatelessWidget {
  const _InlineMath({
    required this.node,
    required this.index,
    required this.formula,
  });

  final Node node;
  final int index;
  final String formula;

  Future<void> _edit(BuildContext context) async {
    final editorState = context.read<EditorState>();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => MathEditDialog(initial: formula, inline: true),
    );
    if (result == null || result == formula) return;
    final transaction = editorState.transaction;
    if (result.trim().isEmpty) {
      transaction.deleteText(node, index, 1);
    } else {
      transaction.formatText(node, index, 1, {inlineFormulaKey: result});
    }
    await editorState.apply(transaction);
  }

  @override
  Widget build(BuildContext context) {
    final editorState = context.read<EditorState>();
    final style = editorState.editorStyle.textStyleConfiguration.text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _edit(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Math.tex(
            formula,
            mathStyle: MathStyle.text,
            textStyle: style.copyWith(height: 1),
            onErrorFallback: (e) => Text(
              formula,
              style: style.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ),
    );
  }
}
