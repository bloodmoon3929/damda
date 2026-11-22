import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/providers.dart';
import 'package:notes/ui/home_shell.dart';
import 'package:notes/ui/theme.dart';

/// Phone: the back button goes to the previous screen; leaving the app
/// takes a second press.
void main() {
  testWidgets('back goes to the previous page, then asks before leaving', (
    tester,
  ) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    final repo = NotesRepository(db);
    late String trip, day;
    await tester.runAsync(() async {
      await repo.init();
      trip = await repo.createPage(title: '오사카 여행');
      day = await repo.createPage(parentId: trip, title: '1일차');
    });
    // The phone editor listens for the keyboard height (a plugin).
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('keyboardHeightEventChannel'),
      (_) async => null,
    );
    var left = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') left = true;
        return null;
      },
    );

    await tester.binding.setSurfaceSize(const Size(400, 800));
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const HomeShell(),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Screen screen() => container.read(screenProvider);
    final screens = container.read(screenProvider.notifier);
    screens.openPage(trip);
    screens.openPage(day);
    await settle();

    await tester.binding.handlePopRoute();
    await settle();
    expect(screen(), PageScreen(trip));
    await tester.binding.handlePopRoute();
    await settle();
    expect(screen(), PageScreen(repo.inboxPageId));

    // Nothing left: first press only warns, the second one leaves.
    await tester.binding.handlePopRoute();
    await settle();
    expect(find.text('한 번 더 누르면 종료돼요'), findsOneWidget);
    expect(left, isFalse);
    await tester.binding.handlePopRoute();
    await settle();
    expect(left, isTrue);

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(db.close);
  });
}
