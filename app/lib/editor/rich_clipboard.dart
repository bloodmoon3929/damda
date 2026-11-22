import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;

import '../data/asset_repository.dart';
import '../data/links.dart';
import '../md/markdown_codec.dart';

/// Copy / cut / paste inside the app keeps the blocks themselves.
///
/// The editor's own clipboard goes through HTML, which drops tables,
/// images, files, code and math ("only the text came back"). So copy and
/// cut also remember the selected blocks; a paste whose clipboard content
/// is still that copy inserts those blocks as they were. Anything copied
/// from another app pastes the usual way.
class _Copied {
  _Copied(this.text, this.html, this.nodes);
  final String text;
  final String html;
  final List<Map<String, Object>> nodes;
}

_Copied? _last;

String _normalize(String? s) => (s ?? '').replaceAll('\r\n', '\n').trim();

void _remember(EditorState s) {
  final selection = s.selection?.normalized;
  if (selection == null || selection.isCollapsed) return;
  final nodes = s.getSelectedNodes(selection: selection);
  // The same text and HTML the editor puts on the system clipboard, to
  // recognise our own copy at paste time.
  _last = _Copied(
    _normalize(s.getTextInSelection(selection).join('\n')),
    _normalize(documentToHTML(Document.blank()..insert([0], nodes))),
    [for (final n in nodes) n.toJson()],
  );
}

/// Whether the clipboard still holds [c]. Windows wraps HTML in a
/// "Version:0.9 StartHTML…" header, so the HTML only has to be inside.
bool _stillOnClipboard(_Copied c, String? text, String? html) {
  final t = _normalize(text);
  if (c.text.isNotEmpty) return t == c.text;
  return c.html.isNotEmpty && _normalize(html).contains(c.html);
}

// ---- a picture on its own: copied as a file ----

/// The picture being copied: clicking one puts the caret beside it (an
/// empty selection, which the editor's copy ignores), or it is the only
/// block selected.
Node? _selectedImage(EditorState s) {
  final selection = s.selection?.normalized;
  if (selection == null) return null;
  final nodes = selection.isCollapsed
      ? [?s.getNodeAtPath(selection.start.path)]
      : s.getSelectedNodes(selection: selection);
  if (nodes.length != 1 || nodes.single.type != ImageBlockKeys.type) {
    return null;
  }
  return nodes.single;
}

/// Local file of [image], if it is on this device.
String? _imageFile(Node image) {
  final url = image.attributes[ImageBlockKeys.url] as String? ?? '';
  final path = resolveAssetUrl(url) ?? url;
  return path.isNotEmpty && File(path).existsSync() ? path : null;
}

/// Puts the picture on the system clipboard as a file (like copying it in
/// Explorer), so it pastes into another page, a 사진 보관함, a chat app…
/// A copy with a readable name is used, kept in a temp folder for a day.
Future<bool> _copyImageFile(String path) async {
  final dir = Directory(p.join(Directory.systemTemp.path, 'damda-copy'));
  dir.createSync(recursive: true);
  final old = DateTime.now().subtract(const Duration(days: 1));
  for (final f in dir.listSync().whereType<File>()) {
    try {
      if (f.lastModifiedSync().isBefore(old)) f.deleteSync();
    } catch (_) {}
  }
  final stamp = DateTime.now()
      .toIso8601String()
      .substring(0, 19)
      .replaceAll(':', '')
      .replaceAll('-', '')
      .replaceAll('T', '-');
  final ext = p.extension(path).isEmpty ? '.png' : p.extension(path);
  final out = p.join(dir.path, '담다 이미지 $stamp$ext');
  File(path).copySync(out);
  return Pasteboard.writeFiles([out]);
}

/// Ctrl+C / Ctrl+X on a picture (desktop): the file goes on the clipboard.
/// Returns null when this isn't that case.
KeyEventResult? _copyImage(EditorState s, {required bool cut}) {
  if (defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.linux) {
    return null;
  }
  final image = _selectedImage(s);
  final path = image == null ? null : _imageFile(image);
  if (image == null || path == null) return null;
  _last = null; // the clipboard now holds a file, not our blocks
  () async {
    try {
      if (!await _copyImageFile(path)) return;
      if (cut) {
        await s.apply(s.transaction..deleteNode(image));
      }
    } catch (e) {
      debugPrint('image copy failed: $e');
    }
  }();
  return KeyEventResult.handled;
}

// ---- whole blocks picked with the ⋮⋮ handle ----

/// Blocks selected with the drag handle (a block selection, often empty),
/// or null for a normal text selection.
List<Node>? _handleSelectedBlocks(EditorState s) {
  final selection = s.selection?.normalized;
  if (selection == null || s.selectionType != SelectionType.block) {
    return null;
  }
  final nodes = selection.isCollapsed
      ? [?s.getNodeAtPath(selection.start.path)]
      : s.getNodesInSelection(selection);
  return nodes.isEmpty ? null : nodes;
}

String _plainText(Node n) => [
  if (n.delta case final d?) d.toPlainText(),
  for (final c in n.children) _plainText(c),
].where((t) => t.isNotEmpty).join('\n');

/// Copies whole handle-selected blocks: remembered as blocks for pasting
/// here, their text and HTML on the system clipboard for other apps.
KeyEventResult? _copyBlocks(EditorState s, {required bool cut}) {
  final nodes = _handleSelectedBlocks(s);
  if (nodes == null) return null;
  final copies = [for (final n in nodes) Node.fromJson(n.toJson())];
  // The editor's clipboard carries text only: blocks without any (a
  // divider, pictures) get an invisible mark so the paste knows them.
  var text = copies.map(_plainText).where((t) => t.isNotEmpty).join('\n');
  if (text.trim().isEmpty) text = '​';
  final html = documentToHTML(
    Document.blank()
      ..insert([0], [for (final n in copies) Node.fromJson(n.toJson())]),
  );
  _last = _Copied(_normalize(text), _normalize(html), [
    for (final n in copies) n.toJson(),
  ]);
  () async {
    try {
      await AppFlowyClipboard.setData(text: text, html: html);
      if (cut) await s.apply(s.transaction..deleteNodes(nodes));
    } catch (e) {
      debugPrint('block copy failed: $e');
    }
  }();
  return KeyEventResult.handled;
}

// ---- a selection over several lines: markdown for other apps ----

/// Copies a selection over several lines (Notion): other apps get it as
/// markdown (`# 제목`, `- 항목`, `- [ ] 할 일`), with HTML beside it; this
/// app pastes the blocks themselves. Within one line: the usual copy.
KeyEventResult? _copyAsMarkdown(EditorState s, {required bool cut}) {
  final selection = s.selection?.normalized;
  if (selection == null || selection.isCollapsed || selection.isSingle) {
    return null;
  }
  final nodes = s.getSelectedNodes(selection: selection);
  if (nodes.isEmpty) return null;
  final markdown = nodesToMarkdown([
    for (final n in nodes) n.deepCopy(),
  ], MdExportContext(linkTarget: (_) => null, assetPath: (_) => null)).trim();
  if (markdown.isEmpty) return null;
  final html = documentToHTML(
    Document.blank()..insert([0], [for (final n in nodes) n.deepCopy()]),
  );
  _last = _Copied(_normalize(markdown), _normalize(html), [
    for (final n in nodes) n.toJson(),
  ]);
  () async {
    try {
      await AppFlowyClipboard.setData(text: markdown, html: html);
      if (cut) await deleteSelectedContent(s);
    } catch (e) {
      debugPrint('copy failed: $e');
    }
  }();
  return KeyEventResult.handled;
}

final CommandShortcutEvent richCopyCommand = CommandShortcutEvent(
  key: 'copy the selected content (keeping blocks)',
  getDescription: () => '복사',
  command: 'ctrl+c',
  macOSCommand: 'cmd+c',
  handler: (editorState) {
    final image = _copyImage(editorState, cut: false);
    if (image != null) return image;
    final blocks = _copyBlocks(editorState, cut: false);
    if (blocks != null) return blocks;
    final markdown = _copyAsMarkdown(editorState, cut: false);
    if (markdown != null) return markdown;
    _remember(editorState);
    return copyCommand.handler(editorState);
  },
);

final CommandShortcutEvent richCutCommand = CommandShortcutEvent(
  key: 'cut the selected content (keeping blocks)',
  getDescription: () => '잘라내기',
  command: 'ctrl+x',
  macOSCommand: 'cmd+x',
  handler: (editorState) {
    final image = _copyImage(editorState, cut: true);
    if (image != null) return image;
    final blocks = _copyBlocks(editorState, cut: true);
    if (blocks != null) return blocks;
    final markdown = _copyAsMarkdown(editorState, cut: true);
    if (markdown != null) return markdown;
    _remember(editorState);
    return cutCommand.handler(editorState);
  },
);

/// Pastes our own last copy as blocks when the clipboard still holds it.
/// Returns false when the clipboard has something else.
Future<bool> pasteRichCopy(EditorState editorState) async {
  final selection = editorState.selection;
  if (selection == null) return false;
  final data = await AppFlowyClipboard.getData();
  // A page's "링크 복사": a mention of that page.
  final linked = pageIdFromLink(data.text);
  if (linked != null) {
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node?.delta != null) {
      final t = editorState.transaction
        ..insertText(
          node!,
          selection.start.offset,
          '@',
          attributes: {pageLinkKey: linked},
        )
        ..afterSelection = Selection.collapsed(
          selection.start.copyWith(offset: selection.start.offset + 1),
        );
      await editorState.apply(t);
      return true;
    }
  }
  final copied = _last;
  if (copied == null) return false;
  if (!_stillOnClipboard(copied, data.text, data.html)) return false;
  final nodes = [for (final j in copied.nodes) Node.fromJson(j)];
  if (nodes.length == 1 && nodes.single.delta != null) {
    await editorState.pasteSingleLineNode(nodes.single);
  } else if (nodes.length == 1) {
    // One block without text (divider, table, file…): goes below the
    // current line, or takes the place of an empty one.
    final path = editorState.selection!.start.path;
    final here = editorState.getNodeAtPath(path);
    final empty =
        here != null &&
        here.type == ParagraphBlockKeys.type &&
        (here.delta?.isEmpty ?? false);
    final transaction = editorState.transaction
      ..insertNode(empty ? path : path.next, nodes.single);
    if (empty) transaction.deleteNode(here);
    await editorState.apply(transaction);
  } else {
    await editorState.pasteMultiLineNodes(nodes);
  }
  return true;
}

// ---- text from other apps ----

final _url = RegExp(r'^(https?://|www\.)\S+$');
final _markdownLine = RegExp(
  r'^\s*(#{1,6} |[-*+] |\d+[.)] |> |- ?\[[ xX]?\] |\[[ xX]?\] |```|\|.*\|\s*$)',
  multiLine: true,
);
final _formattedHtml = RegExp(
  r'<(h[1-6]|ul|ol|li|table|strong|b|em|i|a\s|img|pre|blockquote)[\s>]',
  caseSensitive: false,
);

/// Pasting text copied elsewhere, the Notion way. Returns false when the
/// stock paste should handle it.
/// - A URL over selected text makes that text a link.
/// - Plain markdown (no formatted HTML beside it) becomes blocks:
///   headings, lists, to-dos, quotes, tables, code.
Future<bool> pasteTextSmart(EditorState editorState) async {
  final selection = editorState.selection;
  if (selection == null) return false;
  final data = await AppFlowyClipboard.getData();
  final text = data.text?.replaceAll('\r\n', '\n');
  if (text == null || text.trim().isEmpty) return false;
  final trimmed = text.trim();

  if (!selection.isCollapsed && _url.hasMatch(trimmed)) {
    final href = trimmed.startsWith('www.') ? 'https://$trimmed' : trimmed;
    await editorState.formatDelta(selection.normalized, {
      AppFlowyRichTextKeys.href: href,
    });
    return true;
  }

  final html = data.html ?? '';
  if (_formattedHtml.hasMatch(html)) return false;
  if (!_markdownLine.hasMatch(text)) return false;
  final nodes = parseMarkdown(text).nodes;
  if (nodes.isEmpty || nodes.every((n) => n.type == ParagraphBlockKeys.type)) {
    return false;
  }
  if (!selection.isCollapsed) await deleteSelectedContent(editorState);
  if (nodes.length == 1 && nodes.single.delta != null) {
    await editorState.pasteSingleLineNode(nodes.single);
  } else {
    await editorState.pasteMultiLineNodes(nodes);
  }
  return true;
}
