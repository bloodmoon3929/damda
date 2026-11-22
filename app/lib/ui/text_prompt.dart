import 'package:flutter/material.dart';

/// Asks for one line of text. Returns null when cancelled.
///
/// The dialog owns its TextEditingController and disposes it in
/// State.dispose. Disposing it when showDialog's future completes is too
/// early: the TextField is still on screen during the closing animation and
/// using the disposed controller crashed the app (ISSUES.md #021).
Future<String?> askText(
  BuildContext context,
  String title,
  String initial, {
  String? hint,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPrompt(title: title, initial: initial, hint: hint),
  );
}

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({required this.title, required this.initial, this.hint});

  final String title;
  final String initial;
  final String? hint;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('확인'),
        ),
      ],
    );
  }
}
