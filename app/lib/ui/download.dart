import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/asset_repository.dart';
import '../data/database.dart';
import '../data/notes_repository.dart';

bool get canDownloadMany =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// Saves attachments (photos, videos…) outside the app, under their
/// original names.
/// - One: the system "save as" window (on a phone, the system picker).
/// - Several (computers): a folder is chosen and they are copied there;
///   names already in it get " (2)", " (3)"…
Future<void> downloadAssets(
  BuildContext context,
  NotesRepository repo,
  List<AssetRow> assets,
) async {
  if (assets.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) =>
      messenger?.showSnackBar(SnackBar(content: Text(text), persist: false));
  final present = [
    for (final a in assets)
      if (File(repo.assetPath(a)).existsSync()) a,
  ];
  if (present.isEmpty) {
    say('이 기기에 아직 받지 않은 파일이에요. 동기화 후 다시 해 주세요');
    return;
  }
  try {
    if (present.length == 1 || !canDownloadMany) {
      final a = present.first;
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: '저장',
        fileName: a.name,
        bytes: await File(repo.assetPath(a)).readAsBytes(),
      );
      if (saved != null) say('저장했어요');
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '${present.length}개를 저장할 폴더',
    );
    if (dir == null) return;
    for (final a in present) {
      await File(repo.assetPath(a)).copy(freeFileName(dir, a.name));
    }
    final missing = assets.length - present.length;
    say(
      '${present.length}개를 저장했어요'
      '${missing > 0 ? ' (이 기기에 없는 $missing개 제외)' : ''}',
    );
  } catch (e) {
    say('저장하지 못했어요: $e');
  }
}

/// A path in [dir] for [name] that doesn't exist yet: `a.png`,
/// `a (2).png`, `a (3).png`…
String freeFileName(String dir, String name) {
  final base = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  var candidate = p.join(dir, name);
  for (var i = 2; File(candidate).existsSync(); i++) {
    candidate = p.join(dir, '$base ($i)$ext');
  }
  return candidate;
}

/// A copy of [path] named [name] in a temp folder (kept a day), for
/// handing a file to another app under its real name.
Future<String> namedTempCopy(String path, String name) async {
  final dir = Directory(p.join(Directory.systemTemp.path, 'damda-drag'));
  await dir.create(recursive: true);
  final old = DateTime.now().subtract(const Duration(days: 1));
  for (final f in dir.listSync().whereType<File>()) {
    try {
      if (f.lastModifiedSync().isBefore(old)) f.deleteSync();
    } catch (_) {}
  }
  final out = freeFileName(dir.path, name);
  await File(path).copy(out);
  return out;
}
