import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
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
  testWidgets('#021 calendar view renders rows on their day', (tester) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final repo = NotesRepository(db);
    late String dbId;
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    await tester.runAsync(() async {
      await repo.init();
      dbId = await repo.createDatabase(title: '여행');
      final date = await repo.addProperty(dbId, '날짜', PropType.date);
      await repo.addRow(dbId, title: '유니버설', values: {date: today});
      final views = (await repo.loadDatabase(dbId))!.views;
      await repo.deleteView(views.single.id);
      await repo.addView(dbId, ViewType.calendar, config: {'dateBy': date});
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('유니버설'), findsOneWidget);
    expect(find.text('${now.year}년 ${now.month}월'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  });
}
