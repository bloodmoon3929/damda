import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/editor_config.dart';
import 'package:notes/ui/theme.dart';

// Regression tests for ISSUES.md entries.
void main() {
  final config = EditorConfig.build(
    colors: NoteColors.light,
    mobile: false,
    padding: EdgeInsets.zero,
    maxWidth: 900,
  );
  final paragraph = config.blockBuilders[ParagraphBlockKeys.type]!;

  Node cellParagraph() {
    final p = paragraphNode();
    Node(type: TableCellBlockKeys.type, children: [p]);
    return p;
  }

  test('#001 table cells: no wrapping placeholder, default 4px padding', () {
    final inCell = cellParagraph();
    expect(paragraph.configuration.placeholderText(inCell).trim(), isEmpty);
    expect(
      paragraph.configuration.padding(inCell),
      const EdgeInsets.symmetric(vertical: 4),
    );
  });

  test('#001 normal paragraphs keep the placeholder', () {
    final normal = paragraphNode();
    Node(type: 'page', children: [normal]);
    expect(paragraph.configuration.placeholderText(normal).trim(), isNotEmpty);
  });

  test('#001 table builders are not given custom padding', () {
    for (final type in [TableBlockKeys.type, TableCellBlockKeys.type]) {
      final builder = config.blockBuilders[type]!;
      final node = Node(type: type);
      expect(
        builder.configuration.padding(node),
        const BlockComponentConfiguration().padding(node),
        reason: type,
      );
    }
  });
}
