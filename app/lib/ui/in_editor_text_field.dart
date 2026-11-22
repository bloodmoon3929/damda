import 'package:flutter/widgets.dart';

/// Wrap any text field that lives *inside* the AppFlowyEditor widget tree
/// (page title, database cells, ...).
///
/// Desktop editing keys (Backspace, Delete, arrows, Ctrl+A, ...) are
/// Shortcuts that resolve while the key event bubbles up to the app root.
/// The editor's own focus handler sits in between and consumes those keys,
/// so a plain TextField inside the editor cannot delete text (ISSUES.md #013).
/// Re-declaring the default text-editing shortcuts here handles them before
/// the event reaches the editor.
class InEditorTextField extends StatelessWidget {
  const InEditorTextField({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      DefaultTextEditingShortcuts(child: child);
}
