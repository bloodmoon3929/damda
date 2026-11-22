import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/asset_repository.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/data/sync_engine.dart';
import 'package:notes/editor/attachment_blocks.dart';
import 'package:notes/providers.dart';
import 'package:notes/ui/sync_dialog.dart';
import 'package:notes/ui/theme.dart';

Widget _host(SyncStatus status, Widget child, {NotesRepository? repo}) =>
    ProviderScope(
      overrides: [
        syncStatusProvider.overrideWithValue(status),
        if (repo != null) repositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Column(children: [child])),
      ),
    );

void main() {
  testWidgets('a progress bar and "12/513" while files download', (t) async {
    const syncing = SyncStatus(
      phase: SyncPhase.syncing,
      detail: '파일 받는 중 12/513',
      progress: 11 / 513,
    );
    await t.pumpWidget(
      _host(
        syncing,
        const Column(children: [SyncProgressBar(), SyncDetailText()]),
      ),
    );
    final bar = t.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(11 / 513, 1e-9));
    expect(find.text('파일 받는 중 12/513'), findsOneWidget);

    // Nothing moving: no bar, no text.
    await t.pumpWidget(
      _host(
        const SyncStatus(phase: SyncPhase.idle),
        const Column(children: [SyncProgressBar(), SyncDetailText()]),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('파일'), findsNothing);
  });

  testWidgets('an image whose file is still coming shows itself on arrival', (
    t,
  ) async {
    final dir = Directory.systemTemp.createTempSync('pending_img');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}a.png';
    assetPathIndex['img1'] = path;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = NotesRepository(db);
    await t.runAsync(repo.init);
    await t.pumpWidget(
      _host(
        const SyncStatus(phase: SyncPhase.syncing),
        Builder(builder: (c) => pendingImage(c, assetUrl('img1'))),
        repo: repo,
      ),
    );
    expect(find.text('이미지를 받는 중이에요'), findsOneWidget);

    // The file lands (as a sync download would) → the image replaces it.
    File(path).writeAsBytesSync(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ]);
    assetFilesChanged.value++;
    await t.pump();
    expect(find.text('이미지를 받는 중이에요'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });
}
