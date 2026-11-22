import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/editor_config.dart';
import 'package:notes/editor/inline_math.dart';

void main() {
  test(r'#007 typing $ at the start of a line never throws', () {
    expect(findInlineMathOpen('', 0), isNull);
    expect(findInlineMathOpen('abc', 0), isNull);
    expect(findInlineMathOpen(r'$', 1), isNull);
    expect(findInlineMathOpen('x', 1), isNull);
    expect(findInlineMathOpen('abc', 99), isNull);
  });

  test(r'$...$ detection', () {
    expect(findInlineMathOpen(r'area $\pi r^2', 13), 5);
    expect(findInlineMathOpen(r'a $ b', 5), isNull); // starts with space
    expect(findInlineMathOpen(r'$$', 2), isNull); // empty formula
    expect(findInlineMathOpen(r'price 3', 7), isNull); // no opening $
  });

  test('#007 guarded shortcut turns an exception into "not handled"', () async {
    final boom = CharacterShortcutEvent(
      key: 'boom',
      character: 'x',
      handler: (_) async => throw StateError('boom'),
    );
    final safe = EditorConfig.guarded(boom);
    expect(await safe.handler(EditorState.blank()), isFalse);
  });
}
