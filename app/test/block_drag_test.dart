import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/block_drag_handle.dart';

void main() {
  test('#017 dropping on text inside a table targets the table', () {
    final inCell = paragraphNode(text: 'cell');
    final table = Node(
      type: TableBlockKeys.type,
      children: [
        Node(type: TableCellBlockKeys.type, children: [inCell]),
      ],
    );
    final outside = paragraphNode(text: 'outside');
    Node(type: 'page', children: [table, outside]);

    expect(dropTarget(inCell), same(table));
    expect(dropTarget(table), same(table));
    expect(dropTarget(outside), same(outside));
  });
}
