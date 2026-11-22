import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/providers.dart';
import 'package:notes/ui/sidebar.dart';
import 'package:notes/ui/theme.dart';

void main() {
  testWidgets('#014 sidebar renders the page tree (desktop drag wrappers)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // closeStreamsSynchronously: otherwise drift's stream cleanup timers
    // keep the widget test (fake async) from finishing.
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final repo = NotesRepository(db);
    await tester.runAsync(() async {
      await repo.init();
      final a = await repo.createPage(title: '여행');
      await repo.createPage(parentId: a, title: '일정');
      await repo.updatePage(a, favorite: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: SizedBox(width: 260, child: Sidebar())),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('미정리'), findsNWidgets(2)); // section label + page
    expect(find.text('여행'), findsNWidgets(2)); // favorites + tree
    expect(find.text('즐겨찾기'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: 미정리 section holds real top-level pages; drags', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final repo = NotesRepository(db);
    late String trip;
    late String memo;
    await tester.runAsync(() async {
      await repo.init();
      trip = await repo.createPage(title: '여행');
      memo = await repo.createPage(title: '메모', inboxSection: true);
      await repo.createPage(parentId: repo.inbox.value, title: '하위');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: SizedBox(width: 260, child: Sidebar())),
        ),
      ),
    );
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> longDrag(String from, Offset to) async {
      final d = await tester.startGesture(tester.getCenter(find.text(from)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await d.moveTo(to - const Offset(0, 20));
      await tester.pump();
      await d.moveTo(to);
      await tester.pump();
      await d.up();
      await settle();
    }

    await settle();

    // 메모 is a real top-level page, listed in 미정리 beside the note.
    final note = find.text('미정리').last;
    expect(tester.getTopLeft(find.text('메모')).dx, tester.getTopLeft(note).dx);
    expect(
      tester.getTopLeft(find.text('메모')).dy,
      lessThan(tester.getTopLeft(find.text('개인 페이지')).dy),
    );
    expect((await tester.runAsync(() => repo.getPage(memo)))!.parentId, isNull);
    // The note's own sub-page stays folded inside it.
    expect(find.text('하위'), findsNothing);

    // Long-press and let go without moving → the page menu.
    final g = await tester.startGesture(tester.getCenter(find.text('메모')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('옮기기'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 여행 (개인 페이지) → upper edge of 메모 = into the 미정리 section.
    await longDrag(
      '여행',
      tester.getTopLeft(find.text('메모')) + const Offset(10, -6),
    );
    var moved = await tester.runAsync(() => repo.getPage(trip));
    expect(moved!.parentId, isNull);
    expect(await tester.runAsync(() => repo.isInInboxSection(trip)), isTrue);
    expect(find.text('옮기기'), findsNothing); // a real drag opens no menu

    // 여행 → middle of the 미정리 note = a sub-page of the note.
    await longDrag('여행', tester.getCenter(note));
    moved = await tester.runAsync(() => repo.getPage(trip));
    expect(moved!.parentId, repo.inbox.value);
    expect(await tester.runAsync(() => repo.isInInboxSection(trip)), isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone drawer: the viewed page shows; open stays open', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final repo = NotesRepository(db);
    late String deep;
    late String other;
    await tester.runAsync(() async {
      await repo.init();
      final a = await repo.createPage(title: '공부');
      final b = await repo.createPage(parentId: a, title: '알고리즘');
      deep = await repo.createPage(parentId: b, title: '정렬');
      other = await repo.createPage(title: '취미');
      await repo.createPage(parentId: other, title: '사진');
    });
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    container.read(screenProvider.notifier).openPage(deep);

    // The drawer: a new Sidebar each time it opens.
    Future<void> openDrawer() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: SizedBox(width: 260, child: Sidebar())),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    await openDrawer();
    expect(find.text('정렬'), findsOneWidget); // parents opened by themselves

    // Open 취미 by hand, close the drawer, open it again.
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(of: find.text('취미'), matching: find.byType(Row))
            .first,
        matching: find.byIcon(Icons.keyboard_arrow_right),
      ),
    );
    await tester.pump();
    expect(find.text('사진'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await openDrawer();
    expect(find.text('사진'), findsOneWidget);
    expect(find.text('정렬'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    container.dispose(); // its watches would keep db.close waiting
    await tester.runAsync(db.close);
    debugDefaultTargetPlatformOverride = null;
  });
}
