import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/database_repository.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/db_ui/database_view.dart';
import 'package:notes/providers.dart';
import 'package:notes/ui/theme.dart';

void main() {
  Future<(AppDatabase, NotesRepository, String)> setUpDb(
    WidgetTester tester,
    String viewType,
  ) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final repo = NotesRepository(db);
    late String dbId;
    await tester.runAsync(() async {
      await repo.init();
      dbId = await repo.createDatabase(title: '살 것');
      final kind = await repo.addProperty(dbId, '분류', PropType.select);
      final snap = (await repo.loadDatabase(dbId))!;
      final o = await repo.addSelectOption(snap.property(kind)!, '과자');
      await repo.addRow(dbId, title: '곤약젤리', values: {kind: o.id});
      await repo.addRow(dbId, title: '킷캣', values: {kind: o.id});
      final views = (await repo.loadDatabase(dbId))!.views;
      await repo.deleteView(views.single.id);
      await repo.addView(dbId, viewType, config: {'groupBy': kind});
    });
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(child: DatabaseView(databaseId: dbId)),
          ),
        ),
      ),
    );
    return (db, repo, dbId);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Future<void> close(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  }

  testWidgets('table: right-click a row → 휴지통으로 이동, then 되돌리기', (tester) async {
    final (db, repo, _) = await setUpDb(tester, ViewType.table);
    await settle(tester);
    expect(find.text('곤약젤리'), findsOneWidget);

    await tester.tap(find.text('곤약젤리'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('열기'), findsWidgets);
    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pump();
    await settle(tester);
    expect(find.text('곤약젤리'), findsNothing);
    expect(find.text('킷캣'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500)); // snackbar in
    await tester.tap(find.text('되돌리기'));
    await settle(tester);
    expect(find.text('곤약젤리'), findsOneWidget);
    await close(tester, db);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('table on a phone: long-press a row opens the same menu', (
    tester,
  ) async {
    final (db, _, _) = await setUpDb(tester, ViewType.table);
    await settle(tester);
    await tester.longPress(find.text('킷캣'));
    await tester.pumpAndSettle();
    expect(find.text('휴지통으로 이동'), findsOneWidget);
    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pump();
    await settle(tester);
    expect(find.text('킷캣'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 5)); // snackbar away
    await close(tester, db);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('board: right-click a card → 복제', (tester) async {
    final (db, _, _) = await setUpDb(tester, ViewType.board);
    await settle(tester);
    await tester.tap(find.text('킷캣'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('복제'));
    await tester.pump();
    await settle(tester);
    expect(find.text('킷캣 (사본)'), findsOneWidget);
    await close(tester, db);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
