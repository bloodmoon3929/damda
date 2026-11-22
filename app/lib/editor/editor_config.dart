import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'attachment_blocks.dart';
import 'block_drag_handle.dart';
import 'database_block.dart';
import 'code_block.dart';
import 'inline_math.dart';
import 'page_link.dart';
import 'math_block.dart';
import 'notion_keys.dart';
import 'toggle_callout.dart';

/// Editor style, block renderers and shortcuts. Built once per theme, never
/// per frame: handing AppFlowyEditor fresh builders re-renders every block.
class EditorConfig {
  const EditorConfig._({
    required this.style,
    required this.blockBuilders,
    required this.characterShortcuts,
  });

  final EditorStyle style;
  final Map<String, BlockComponentBuilder> blockBuilders;
  final List<CharacterShortcutEvent> characterShortcuts;

  static List<SelectionMenuItem> get slashMenuItems => [
    // The stock image item asks for a URL; ours stores the file as an asset.
    for (final item in standardSelectionMenuItems)
      if (!item.keywords.contains('image')) item,
    imageMenuItem,
    fileMenuItem,
    mathMenuItem,
    pageLinkMenuItem,
    codeMenuItem,
    databaseMenuItem,
    albumMenuItem,
    toggleMenuItem,
    calloutMenuItem,
  ];

  factory EditorConfig.build({
    required NoteColors colors,
    required bool mobile,
    required EdgeInsets padding,
    required double maxWidth,
    // Per-page "테마와 레이아웃" options.
    List<String>? fontFamilies,
    double fontSize = 16,
  }) {
    // On desktop every block reserves a drag-handle column on its left;
    // take it out of the padding so text stays aligned with the title.
    final editorPadding = mobile
        ? padding
        : padding.copyWith(
            left: (padding.left - blockHandleWidth).clamp(0, double.infinity),
          );
    final family = fontFamilies?.first;
    final fallback = fontFamilies?.skip(1).toList();
    final textStyle = TextStyleConfiguration(
      text: TextStyle(
        fontSize: fontSize,
        color: colors.text,
        height: 1.5,
        fontFamily: family,
        fontFamilyFallback: fallback,
      ),
      code: TextStyle(
        fontFamily: 'Consolas',
        color: const Color(0xFFEB5757),
        backgroundColor: colors.hover,
      ),
    );
    final style = mobile
        ? EditorStyle.mobile(
            padding: editorPadding,
            cursorColor: const Color(0xFF2383E2),
            dragHandleColor: const Color(0xFF2383E2),
            textStyleConfiguration: textStyle,
            textSpanDecorator: pageLinkDecorator(
              inlineMathDecorator(mobileTextSpanDecoratorForAttribute),
            ),
            maxWidth: maxWidth,
          )
        : EditorStyle.desktop(
            padding: editorPadding,
            cursorColor: colors.text,
            selectionColor: const Color(0x552383E2),
            textStyleConfiguration: textStyle,
            textSpanDecorator: pageLinkDecorator(
              inlineMathDecorator(defaultTextSpanDecoratorForAttribute),
            ),
            maxWidth: maxWidth,
          );

    const headingSizes = [30.0, 24.0, 20.0, 18.0, 16.0, 16.0];
    // Table cells: keep the editor's default paragraph padding (the table's
    // row-height math assumes it) and no placeholder — a wrapping placeholder
    // makes the focused cell taller and knocks its column out of line.
    // See ISSUES.md#001.
    EdgeInsets blockPadding(Node node) => _inTable(node)
        ? const EdgeInsets.symmetric(vertical: 4)
        : const EdgeInsets.symmetric(vertical: 3);
    final builders = <String, BlockComponentBuilder>{
      ...standardBlockComponentBuilderMap,
      ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
        // Show the hint on the focused line, and also on the single empty
        // line of a blank page so it's obvious where to start (#010).
        showPlaceholder: (editorState, node) {
          if (_inTable(node)) return false;
          final sel = editorState.selection;
          final focused =
              sel != null && sel.isSingle && sel.start.path.equals(node.path);
          final parent = node.parent;
          final onlyLine =
              parent != null &&
              parent.type == 'page' &&
              parent.children.length == 1 &&
              (node.delta?.isEmpty ?? false);
          return focused || onlyLine;
        },
        configuration: BlockComponentConfiguration(
          placeholderText: (node) => _inTable(node) ? ' ' : "명령어는 '/' 입력",
        ),
      ),
      HeadingBlockKeys.type: HeadingBlockComponentBuilder(
        textStyleBuilder: (level) => TextStyle(
          fontSize: headingSizes[(level - 1).clamp(0, 5)] * fontSize / 16,
          fontWeight: FontWeight.w600,
          color: colors.text,
          fontFamily: family,
          fontFamilyFallback: fallback,
        ),
      ),
      MathBlockKeys.type: MathBlockComponentBuilder(),
      DatabaseBlockKeys.type: DatabaseBlockComponentBuilder(),
      CodeBlockKeys.type: CodeBlockComponentBuilder(),
      AlbumBlockKeys.type: DatabaseBlockComponentBuilder(),
      FileBlockKeys.type: FileBlockComponentBuilder(),
      UploadPlaceholderKeys.type: uploadPlaceholderBuilder(),
      ToggleBlockKeys.type: ToggleBlockComponentBuilder(),
      CalloutBlockKeys.type: CalloutBlockComponentBuilder(),
    };
    for (final entry in builders.entries) {
      final builder = entry.value;
      if (entry.key == TableCellBlockKeys.type ||
          entry.key == PageBlockKeys.type) {
        continue;
      }
      // ⋮⋮ drag handle on hover (Notion/Obsidian style), not inside tables.
      builder.showActions = (node) => !mobile && !_inTable(node);
      builder.actionBuilder = (context, state) =>
          BlockDragHandle(blockComponentContext: context, builder: builder);
      if (entry.key == TableBlockKeys.type) continue;
      // Korean hint text for empty blocks (the editor's are hard-coded
      // English: "List item", "Heading 1", ...).
      final hint = switch (entry.key) {
        BulletedListBlockKeys.type || NumberedListBlockKeys.type => '목록',
        TodoListBlockKeys.type => '할 일',
        QuoteBlockKeys.type => '인용',
        HeadingBlockKeys.type => null, // per level, below
        _ => null,
      };
      builder.configuration = builder.configuration.copyWith(
        padding: blockPadding,
        placeholderText: entry.key == HeadingBlockKeys.type
            ? (node) => '제목 ${node.attributes[HeadingBlockKeys.level] ?? 1}'
            : hint == null
            ? null
            : (_) => hint,
      );
    }

    final shortcuts = <CharacterShortcutEvent>[
      // Before the stock Enter handler, which would split the block.
      guarded(newLineInCodeBlock),
      guarded(enterInToggle),
      for (final e in standardCharacterShortcutEvents)
        if (e != slashCommand && !_blockMarkdownShortcuts.contains(e)) e,
      slashOnlyAtWordStart(customSlashCommand(slashMenuItems)),
      // Our own handlers are guarded: an exception inside a shortcut stops
      // keyboard input until the user clicks again (ISSUES.md #007).
      guarded(dollarsToMath),
      guarded(dollarToInlineMath),
      guarded(doubleBracketToPageLink),
      guarded(backticksToCodeBlock),
    ];

    return EditorConfig._(
      style: style,
      blockBuilders: builders,
      characterShortcuts: shortcuts,
    );
  }

  /// Same shortcut, but an exception means "not handled" instead of
  /// breaking text input.
  static CharacterShortcutEvent guarded(CharacterShortcutEvent e) {
    return CharacterShortcutEvent(
      key: e.key,
      character: e.character,
      handler: (editorState) async {
        try {
          return await e.handler(editorState);
        } catch (error, stack) {
          debugPrint('shortcut "${e.key}" failed: $error\n$stack');
          return false;
        }
      },
    );
  }

  /// Line-start markdown is converted by `attachMarkdownAutoFormat` on
  /// every device (one rule set, and the conversion is its own undo step).
  static final _blockMarkdownShortcuts = <CharacterShortcutEvent>{
    formatAsteriskToBulletedList,
    formatMinusToBulletedList,
    formatNumberToNumberedList,
    formatDoubleQuoteToQuote,
    formatSignToHeading,
    formatEmptyBracketsToUncheckedBox,
    formatHyphenEmptyBracketsToUncheckedBox,
    formatFilledBracketsToCheckedBox,
    formatHyphenFilledBracketsToCheckedBox,
    convertMinusesToDivider,
    convertStarsToDivider,
    convertUnderscoreToDivider,
  };

  static bool _inTable(Node node) =>
      node.parent?.type == TableCellBlockKeys.type;
}
