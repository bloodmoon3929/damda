import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/links.dart';
import 'rich_clipboard.dart';

/// Phones: the menu over a long-pressed selection (what right-click is on
/// a computer): copy, cut, paste, select all, and for a link or a page
/// mention, open it / copy it.
Widget mobileSelectionMenu(
  BuildContext context,
  Offset anchor,
  VoidCallback close,
  EditorState editorState, {
  required void Function(String pageId) openPage,
}) {
  final link = linkAtSelection(editorState);
  final items = <(String, VoidCallback)>[
    if (link?.pageId case final id?) ('페이지로 이동', () => openPage(id)),
    if (link?.url case final url?) ('링크 열기', () => _open(url)),
    if (link?.url case final url?)
      ('링크 복사', () => Clipboard.setData(ClipboardData(text: url))),
    if (!(editorState.selection?.isCollapsed ?? true)) ...[
      ('복사', () => richCopyCommand.handler(editorState)),
      ('잘라내기', () => richCutCommand.handler(editorState)),
    ],
    ('붙여넣기', () => _paste(editorState)),
    ('전체 선택', () => selectAllCommand.handler(editorState)),
  ];
  final screen = MediaQuery.sizeOf(context);
  return Positioned(
    // Above the selection, kept on screen.
    top: (anchor.dy - 56).clamp(40.0, screen.height - 120),
    left: 8,
    right: 8,
    child: Center(
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.inverseSurface,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, action) in items)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context)
                        .colorScheme
                        .onInverseSurface,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () {
                    close();
                    action();
                  },
                  child: Text(label),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The web link or page mention under the selection's start, if any.
({String? url, String? pageId})? linkAtSelection(EditorState editorState) {
  final selection = editorState.selection?.normalized;
  if (selection == null) return null;
  final node = editorState.getNodeAtPath(selection.start.path);
  final delta = node?.delta;
  if (delta == null) return null;
  var at = 0;
  final offset = selection.start.offset;
  for (final op in delta) {
    final end = at + op.length;
    // The character after the cursor, or the one before at a word's end.
    if (offset < end || (offset == end && selection.isCollapsed)) {
      final a = op.attributes;
      final url = a?[AppFlowyRichTextKeys.href] as String?;
      final page = a?[pageLinkKey] as String?;
      if (url != null || page != null) {
        return (url: url, pageId: page);
      }
      if (offset < end) return null;
    }
    at = end;
  }
  return null;
}

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> _paste(EditorState editorState) async {
  if (await pasteRichCopy(editorState)) return;
  if (await pasteTextSmart(editorState)) return;
  pasteCommand.handler(editorState);
}
