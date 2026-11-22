import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/asset_repository.dart';
import 'data/database.dart';
import 'data/database_repository.dart';
import 'data/notes_repository.dart';
import 'data/sync_engine.dart';

/// Overridden in main() with an initialized repository.
final repositoryProvider = Provider<NotesRepository>(
  (ref) => throw UnimplementedError('repositoryProvider not overridden'),
);

/// Rebuilds dependents whenever [notifier] changes.
T _listen<T>(Ref ref, ValueListenable<T> notifier) {
  void changed() => ref.invalidateSelf();
  notifier.addListener(changed);
  ref.onDispose(() => notifier.removeListener(changed));
  return notifier.value;
}

/// The 미정리 page id (changes when sync merges two devices' inboxes).
final inboxIdProvider = Provider<String>(
  (ref) => _listen(ref, ref.watch(repositoryProvider).inbox),
);

/// Server sync; starts itself when a server was set up before.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(ref.watch(repositoryProvider));
  ref.onDispose(engine.dispose);
  engine.load();
  return engine;
});

final syncStatusProvider = Provider<SyncStatus>(
  (ref) => _listen(ref, ref.watch(syncEngineProvider).status),
);

final pagesProvider = StreamProvider<List<PageRow>>(
  (ref) => ref.watch(repositoryProvider).watchPages(),
);

final favoritesProvider = StreamProvider<List<PageRow>>(
  (ref) => ref.watch(repositoryProvider).watchFavorites(),
);

/// Top-level pages shown in the sidebar's 미정리 section.
final inboxSectionProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(repositoryProvider).watchInboxSection(),
);

final trashProvider = StreamProvider<List<PageRow>>(
  (ref) => ref.watch(repositoryProvider).watchTrash(),
);

final templatesProvider = StreamProvider<List<PageRow>>(
  (ref) => ref.watch(repositoryProvider).watchTemplates(),
);

final pageProvider = StreamProvider.family<PageRow?, String>(
  (ref, id) => ref.watch(repositoryProvider).watchPage(id),
);

/// All attachments (자료실).
final assetsProvider = StreamProvider<List<AssetRow>>(
  (ref) => ref.watch(repositoryProvider).watchAssets(),
);

/// A Notion-style database with its columns, views, rows and cells.
final databaseProvider = StreamProvider.family<DbSnapshot?, String>((ref, id) {
  final repo = ref.watch(repositoryProvider);
  // While a database is on screen (table or an item's page), keep its
  // auto-filled properties (and the databases that look it up) filled in.
  // Each change settles the next time round: only differences are written.
  Timer? soon;
  var running = false;
  void refill() {
    soon?.cancel();
    soon = Timer(const Duration(milliseconds: 400), () async {
      if (running) return refill();
      running = true;
      try {
        await repo.refreshAutoFill(id);
      } catch (e) {
        debugPrint('auto-fill failed: $e');
      } finally {
        running = false;
      }
    });
  }

  ref.onDispose(() => soon?.cancel());
  return repo.watchDatabase(id).map((snap) {
    // Also without auto-fill here: others may look this one up.
    if (snap != null) refill();
    return snap;
  });
});

/// What the main area shows.
sealed class Screen {
  const Screen();
}

class PageScreen extends Screen {
  const PageScreen(this.pageId);
  final String pageId;

  @override
  bool operator ==(Object other) =>
      other is PageScreen && other.pageId == pageId;
  @override
  int get hashCode => pageId.hashCode;
}

class TemplatesScreen extends Screen {
  const TemplatesScreen();
  @override
  bool operator ==(Object other) => other is TemplatesScreen;
  @override
  int get hashCode => 1;
}

class AssetsScreen extends Screen {
  const AssetsScreen();
  @override
  bool operator ==(Object other) => other is AssetsScreen;
  @override
  int get hashCode => 2;
}

class GraphScreen extends Screen {
  const GraphScreen();
  @override
  bool operator ==(Object other) => other is GraphScreen;
  @override
  int get hashCode => 4;
}

class ScreenNotifier extends Notifier<Screen> {
  /// Screens shown before this one, for the phone's back button.
  final _back = <Screen>[];

  @override
  Screen build() => PageScreen(ref.watch(repositoryProvider).inboxPageId);

  void _go(Screen next) {
    if (next == state) return;
    _back.add(state);
    if (_back.length > 50) _back.removeAt(0);
    state = next;
  }

  void openPage(String id) => _go(PageScreen(id));
  void openTemplates() => _go(const TemplatesScreen());
  void openAssets() => _go(const AssetsScreen());
  void openGraph() => _go(const GraphScreen());

  bool get canGoBack => _back.isNotEmpty;

  /// Goes to the previous screen; false when there is none.
  bool back() {
    if (_back.isEmpty) return false;
    state = _back.removeLast();
    return true;
  }
}

final screenProvider = NotifierProvider<ScreenNotifier, Screen>(
  ScreenNotifier.new,
);

/// The open page id, or null when a non-page screen is shown.
final selectedPageProvider = Provider<String?>((ref) {
  final screen = ref.watch(screenProvider);
  return screen is PageScreen ? screen.pageId : null;
});

/// Pages grouped by parent id, already in sort order.
final pageTreeProvider = Provider<Map<String?, List<PageRow>>>((ref) {
  final pages = ref.watch(pagesProvider).value ?? const [];
  final tree = <String?, List<PageRow>>{};
  for (final p in pages) {
    tree.putIfAbsent(p.parentId, () => []).add(p);
  }
  return tree;
});
