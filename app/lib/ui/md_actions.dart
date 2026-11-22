import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../editor/attachment_blocks.dart' show pickFilePaths, testPickOverride;
import '../md/vault.dart';
import '../providers.dart';

/// Menus for `.md` import / export (see md/vault.dart for the format).

Future<String?> _pickFolder(String title) async {
  final override = testPickOverride;
  if (override != null) {
    return override.where(FileSystemEntity.isDirectorySync).firstOrNull;
  }
  return FilePicker.platform.getDirectoryPath(dialogTitle: title);
}

/// Runs [work] behind a small "working…" dialog.
Future<T?> _busy<T>(
  BuildContext context,
  String label,
  Future<T> Function() work,
) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 16),
          Text(label),
        ],
      ),
    ),
  );
  try {
    return await work();
  } finally {
    nav.pop();
  }
}

void _report(BuildContext context, String text, {String? folder}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 6),
      persist: false,
      action: folder == null
          ? null
          : SnackBarAction(
              label: '폴더 열기',
              onPressed: () => launchUrl(Uri.file(folder)),
            ),
    ),
  );
}

/// Imports a `.md` file or a folder (Obsidian vault).
Future<void> importMarkdownFlow(
  BuildContext context,
  WidgetRef ref, {
  String? parentId,
}) async {
  final kind = await showDialog<String>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: const Text('Markdown 가져오기'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialog, 'folder'),
          child: const ListTile(
            leading: Icon(Icons.folder_open_outlined),
            title: Text('폴더 (Obsidian 보관함)'),
            subtitle: Text('하위 폴더는 하위 페이지로, [[링크]]와 첨부도 함께'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialog, 'file'),
          child: const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('.md 파일 하나'),
          ),
        ),
      ],
    ),
  );
  if (kind == null || !context.mounted) return;
  final String? path;
  if (kind == 'folder') {
    path = await _pickFolder('가져올 폴더');
  } else {
    final files = await pickFilePaths(title: '가져올 .md 파일');
    path = files.where((f) => f.toLowerCase().endsWith('.md')).firstOrNull;
  }
  if (path == null || !context.mounted) return;
  final repo = ref.read(repositoryProvider);
  try {
    final r = await _busy(
      context,
      '가져오는 중…',
      () => repo.importMarkdown(path!, parentId: parentId),
    );
    if (r == null || !context.mounted) return;
    final parts = [
      '페이지 ${r.pages}개',
      if (r.updated > 0) '(기존 ${r.updated}개 갱신)',
      if (r.attachments > 0) '첨부 ${r.attachments}개',
      if (r.missingAttachments > 0) '못 찾은 첨부 ${r.missingAttachments}개',
      if (r.placeholderPages > 0) '빈 링크 페이지 ${r.placeholderPages}개',
    ];
    _report(context, '가져왔어요: ${parts.join(', ')}');
    final open = r.rootPageId;
    if (open != null) ref.read(screenProvider.notifier).openPage(open);
  } catch (e) {
    if (context.mounted) _report(context, '가져오기 실패: $e');
  }
}

/// Exports one page with its sub-pages, or everything when [rootPageId] is
/// null, into a new folder inside the chosen one.
Future<void> exportMarkdownFlow(
  BuildContext context,
  WidgetRef ref, {
  String? rootPageId,
}) async {
  final target = await _pickFolder('내보낼 위치');
  if (target == null || !context.mounted) return;
  final repo = ref.read(repositoryProvider);
  final now = DateTime.now();
  final stamp =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final page = rootPageId == null ? null : await repo.getPage(rootPageId);
  var folder = p.join(
    target,
    page == null
        ? '노트 내보내기 $stamp'
        : '${page.title.isEmpty ? '제목 없음' : page.title} $stamp'.replaceAll(
            RegExp(r'[\\/:*?"<>|]'),
            ' ',
          ),
  );
  for (var i = 2; Directory(folder).existsSync(); i++) {
    folder = '${folder.replaceAll(RegExp(r' \(\d+\)$'), '')} ($i)';
  }
  if (!context.mounted) return;
  try {
    final r = await _busy(
      context,
      '내보내는 중…',
      () => repo.exportMarkdown(folder, rootPageId: rootPageId),
    );
    if (r == null || !context.mounted) return;
    _report(
      context,
      '내보냈어요: 페이지 ${r.pages}개, 첨부 ${r.attachments}개'
      '${r.missingAttachments > 0 ? ' (이 기기에 없는 첨부 ${r.missingAttachments}개)' : ''}',
      folder: folder,
    );
  } catch (e) {
    if (context.mounted) _report(context, '내보내기 실패: $e');
  }
}
