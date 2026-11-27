import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/capture.dart';
import 'data/asset_repository.dart';
import 'data/database.dart';
import 'data/database_repository.dart';
import 'data/links.dart';
import 'data/notes_repository.dart';
import 'editor/notion_keys.dart';
import 'editor/page_link.dart';
import 'editor/attachment_blocks.dart';
import 'providers.dart';
import 'ui/home_shell.dart';
import 'ui/quick_memo.dart';
import 'ui/theme.dart';

/// `--data-dir=<folder>` runs against a separate database (for testing).
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // inline video playback
  const flag = '--data-dir=';
  final dataDir = args
      .where((a) => a.startsWith(flag))
      .map((a) => a.substring(flag.length))
      .firstOrNull;
  // Test hook, only together with --data-dir (never on real notes).
  const pickFlag = '--test-pick=';
  final testPicks = [
    for (final a in args)
      if (a.startsWith(pickFlag)) a.substring(pickFlag.length),
  ];
  if (dataDir != null && testPicks.isNotEmpty) testPickOverride = testPicks;

  final repo = await openRepository(dataDir: dataDir);
  await repo.ensureLinkIndex();

  // Image blocks store `asset://<id>`; resolve to this device's file.
  final assets = repo.watchAssets();
  void index(List<AssetRow> rows) => assetPathIndex
    ..clear()
    ..addEntries(rows.map((a) => MapEntry(a.id, repo.assetPath(a))));
  index(await assets.first);
  assets.listen(index);
  imageSourceResolver = resolveAssetUrl;
  missingImageBuilder = pendingImage;
  installInlineObjectSlicing();
  installNotionBlockRules();
  runApp(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: const NotesApp(),
    ),
  );
}

/// The notes database and attachment folder (the app's data folder, or
/// [dataDir] for test runs).
Future<NotesRepository> openRepository({String? dataDir}) async {
  final base = dataDir ?? (await getApplicationSupportDirectory()).path;
  final repo = NotesRepository(
    AppDatabase(null, dataDir),
    assetsDir: p.join(base, 'assets'),
  );
  await repo.init();
  // Databases copied by older versions lacked their columns (ISSUES #044).
  try {
    await repo.repairCopiedDatabases();
  } catch (e) {
    debugPrint('database repair failed: $e');
  }
  // Notion: trashed pages go for good after 30 days.
  try {
    await repo.purgeOldTrash();
  } catch (e) {
    debugPrint('trash purge failed: $e');
  }
  // 1.0.23: old YouTube shares go under 공유된 페이지 (once).
  try {
    await repo.moveOldYoutubeSharesOnce();
  } catch (e) {
    debugPrint('moving old YouTube shares failed: $e');
  }
  return repo;
}

/// Android QuickMemoActivity (share sheet / memo widget): a small window
/// that saves one memo to 미정리 without starting the whole app.
@pragma('vm:entry-point')
Future<void> quickMemoMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = await openRepository();
  Map<String, String>? shared;
  try {
    shared = await quickChannel.invokeMapMethod<String, String>('sharedText');
  } on PlatformException catch (_) {}
  runApp(
    QuickMemoApp(
      repo: repo,
      shared: shared == null
          ? null
          : (text: shared['text'] ?? '', subject: shared['subject'] ?? ''),
    ),
  );
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '나무',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      localizationsDelegates: const [
        AppFlowyEditorLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ko'), Locale('en')],
      locale: const Locale('ko'),
      home: const HomeShell(),
    );
  }
}
