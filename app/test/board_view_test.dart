import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
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
  testWidgets(
    'board: drag a card above another in its column; a sorted '
    'view asks to turn the sort off first',
    (tester) async {
      final db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
      );
      final repo = NotesRepository(db);
      late String dbId;
      late String viewId;
      await tester.runAsync(() async {
        await repo.init();
        dbId = await repo.createDatabase(title: '여행 시간표');
        final day = await repo.addProperty(dbId, '일차', PropType.select);
        final snap = (await repo.loadDatabase(dbId))!;
        final one = await repo.addSelectOption(snap.property(day)!, '1일차');
        for (final t in ['공항', '호텔', '라멘']) {
          await repo.addRow(dbId, title: t, values: {day: one.id});
        }
        final views = (await repo.loadDatabase(dbId))!.views;
        await repo.deleteView(views.single.id);
        viewId = await repo.addView(
          dbId,
          ViewType.board,
          config: {'groupBy': day, 'sortBy': 'title'},
        );
      });

      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: DatabaseView(databaseId: dbId),
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      }

      double y(String title) => tester.getTopLeft(find.text(title)).dy;
      Future<void> dragAbove(String card, String target) async {
        // Holding first works for both: phones pick a card up by a long-press.
        final g = await tester.startGesture(tester.getCenter(find.text(card)));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await g.moveBy(const Offset(0, -10));
        await tester.pump();
        // Upper edge of the target card (its title is near the top).
        await g.moveTo(
          tester.getTopLeft(find.text(target)) + const Offset(20, -12),
        );
        await tester.pump();
        await g.up();
        await tester.pump();
      }

      await settle();
      // Sorted by name: 공항, 라멘, 호텔.
      expect(y('공항'), lessThan(y('라멘')));
      expect(y('라멘'), lessThan(y('호텔')));

      // 호텔 above 공항 → asked about the sort; turn it off.
      await dragAbove('호텔', '공항');
      expect(find.text('정렬 끄기'), findsOneWidget);
      await tester.tap(find.text('정렬 끄기'));
      await settle();
      final view = (await tester.runAsync(() => repo.loadDatabase(dbId)))!.views
          .singleWhere((v) => v.id == viewId);
      expect(view.sortBy, isNull);
      expect(y('호텔'), lessThan(y('공항')));
      expect(y('공항'), lessThan(y('라멘')));

      // No sort now: 라멘 above 공항 straight away.
      await dragAbove('라멘', '공항');
      await settle();
      expect(find.text('정렬 끄기'), findsNothing);
      expect(y('호텔'), lessThan(y('라멘')));
      expect(y('라멘'), lessThan(y('공항')));

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('board: a card held at the right edge scrolls the board', (
    tester,
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
      dbId = await repo.createDatabase(title: '여행 시간표');
      final day = await repo.addProperty(dbId, '일차', PropType.select);
      String? first;
      for (var i = 1; i <= 8; i++) {
        final snap = (await repo.loadDatabase(dbId))!;
        final o = await repo.addSelectOption(snap.property(day)!, '$i일차');
        first ??= o.id;
      }
      await repo.addRow(dbId, title: '공항', values: {day: first});
      final views = (await repo.loadDatabase(dbId))!.views;
      await repo.deleteView(views.single.id);
      await repo.addView(dbId, ViewType.board, config: {'groupBy': day});
    });

    await tester.binding.setSurfaceSize(const Size(800, 900));
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
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    final startX = tester.getTopLeft(find.text('공항')).dx;
    final g = await tester.startGesture(tester.getCenter(find.text('공항')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveBy(const Offset(20, 0));
    await tester.pump();
    await g.moveTo(const Offset(790, 300)); // right edge, then hold still
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The board moved left under the held card (the original card stays
    // in its column, dimmed, so it moved with the board).
    final heldX = tester.getTopLeft(find.text('공항').first).dx;
    expect(heldX, lessThan(startX - 100));

    await g.moveTo(const Offset(400, 300)); // back to the middle: stops
    await tester.pump(const Duration(milliseconds: 16));
    final stoppedX = tester.getTopLeft(find.text('공항').first).dx;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getTopLeft(find.text('공항').first).dx, stoppedX);
    await g.up();
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
