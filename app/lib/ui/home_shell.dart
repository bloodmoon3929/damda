import 'package:flutter/material.dart' hide PageView;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/update_check.dart';
import '../data/plan_map_repository.dart';
import '../graph/graph_view.dart';
import '../providers.dart';
import 'assets_view.dart';
import 'page_view.dart';
import 'search_dialog.dart';
import 'sidebar.dart';
import 'sync_dialog.dart';
import 'templates_view.dart';
import 'theme.dart';

/// Sidebar beside the page on wide screens, sidebar in a drawer on phones.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _wideBreakpoint = 720.0;
  bool _searchOpen = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Starts server sync (if set up) and syncs whenever the app comes back.
    final sync = ref.read(syncEngineProvider);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        sync.syncNow();
        // The quick memo window (share / widget) writes 미정리 through its
        // own connection: show its lines if 미정리 is open.
        sync.notifyPageChanged(ref.read(inboxIdProvider));
      },
    );
    // Global, so Ctrl+P works wherever focus is (even nowhere). A Shortcuts
    // widget only sees keys while something below it has focus. Ctrl+K is
    // left to the editor (insert link), like Notion.
    HardwareKeyboard.instance.addHandler(_onKey);
    // A newer version on GitHub: say so once, a little after start.
    Future.delayed(const Duration(seconds: 4), _checkForUpdate);
  }

  Future<void> _checkForUpdate() async {
    final info = await PackageInfo.fromPlatform();
    final update = await checkForUpdate(info.version);
    if (update == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('새 버전 ${update.version}'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: '받기',
          onPressed: () => launchUrl(
            Uri.parse(update.downloadUrl ?? update.pageUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lifecycle.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyP) {
      _search();
      return true;
    }
    return false;
  }

  Future<void> _search() async {
    if (_searchOpen || !mounted) return;
    _searchOpen = true;
    try {
      await showSearchDialog(context, ref);
    } finally {
      _searchOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = ref.watch(screenProvider);
    // Sync merged this device's 미정리 into another device's: follow it.
    ref.listen(inboxIdProvider, (prev, next) {
      final s = ref.read(screenProvider);
      if (s is PageScreen && s.pageId == prev) {
        ref.read(screenProvider.notifier).openPage(next);
      }
    });
    final kind = screen is PageScreen
        ? ref.watch(pageProvider(screen.pageId).select((a) => a.value?.kind))
        : null;
    final body = switch (screen) {
      PageScreen(:final pageId) when kind == 'database' => DatabasePage(
        key: ValueKey('db$pageId'),
        pageId: pageId,
      ),
      PageScreen(:final pageId) when kind == planMapKind => PlanMapPage(
        key: ValueKey('map$pageId'),
        pageId: pageId,
      ),
      PageScreen(:final pageId) when kind == 'album' => AlbumPage(
        key: ValueKey('album$pageId'),
        pageId: pageId,
      ),
      PageScreen(:final pageId) => PageView(
        key: ValueKey(pageId),
        pageId: pageId,
      ),
      TemplatesScreen() => const TemplatesView(),
      AssetsScreen() => const AssetsView(),
      GraphScreen() => const GraphView(),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _wideBreakpoint) {
          return Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 260, child: Sidebar()),
                VerticalDivider(width: 1, color: context.noteColors.divider),
                Expanded(
                  child: Column(
                    children: [
                      const SyncProgressBar(),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        final pageId = screen is PageScreen ? screen.pageId : null;
        final page = pageId == null
            ? null
            : ref.watch(pageProvider(pageId)).value;
        // Back button (the drawer closes itself first): the previous
        // screen, and only a second press in a row leaves the app.
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) => _onBack(didPop),
          child: Scaffold(
            appBar: AppBar(
              elevation: 0,
              scrolledUnderElevation: 0,
              bottom: const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: SyncProgressBar(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    screen is TemplatesScreen
                        ? '템플릿'
                        : screen is GraphScreen
                        ? '그래프'
                        : page == null
                        ? ''
                        : '${page.icon ?? ''} ${page.title.isEmpty ? '제목 없음' : page.title}'
                              .trim(),
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SyncDetailText(),
                ],
              ),
              actions: [
                IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ],
            ),
            drawer: Drawer(
              child: Builder(
                builder: (context) =>
                    Sidebar(onNavigate: () => Navigator.of(context).pop()),
              ),
            ),
            body: body,
          ),
        );
      },
    );
  }

  DateTime? _lastBack;

  void _onBack(bool didPop) {
    if (didPop) return;
    if (ref.read(screenProvider.notifier).back()) return;
    final now = DateTime.now();
    if (_lastBack != null &&
        now.difference(_lastBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('한 번 더 누르면 종료돼요'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
