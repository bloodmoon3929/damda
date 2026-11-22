import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/capture.dart';
import '../data/notes_repository.dart';
import '../data/sync_engine.dart';
import 'theme.dart';

/// Android quick memo window (QuickMemoActivity) over the dimmed screen.
/// From the home-screen widget: a box to type one memo into 미정리.
/// From the share sheet: saved right away (a YouTube video as a page of
/// its own, anything else into 미정리), a short notice, then it closes.
const quickChannel = MethodChannel('kr.bloodmoon.notes/quick');

typedef Shared = ({String text, String subject});

class QuickMemoApp extends StatelessWidget {
  const QuickMemoApp({super.key, required this.repo, this.shared});

  final NotesRepository repo;

  /// What another app shared; null when opened from the widget.
  final Shared? shared;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: shared == null
          ? _QuickMemo(repo: repo)
          : _ShareSaver(repo: repo, shared: shared!),
    );
  }
}

Future<void> _closeWindow() async {
  try {
    await quickChannel.invokeMethod('close');
  } catch (_) {
    await SystemNavigator.pop();
  }
}

/// Sends what was just saved to the server if sync is set up (the app may
/// not be opened for a while). Offline is fine: it goes with the next sync.
Future<void> _syncSoon(NotesRepository repo) async {
  final sync = SyncEngine(repo);
  try {
    await sync.load();
    if (sync.connected) {
      await sync.syncNow().timeout(const Duration(seconds: 6));
    }
  } catch (_) {
  } finally {
    sync.dispose();
  }
}

/// The sheet at the bottom of the screen, tap outside to close.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.child, this.onOutside});

  final Widget child;
  final VoidCallback? onOutside;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOutside,
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {}, // taps inside the sheet stay inside
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(18),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareSaver extends StatefulWidget {
  const _ShareSaver({required this.repo, required this.shared});

  final NotesRepository repo;
  final Shared shared;

  @override
  State<_ShareSaver> createState() => _ShareSaverState();
}

class _ShareSaverState extends State<_ShareSaver> {
  String? _done;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _save();
  }

  Future<void> _save() async {
    try {
      final message = await widget.repo.saveShared(
        widget.shared.text,
        widget.shared.subject,
      );
      if (mounted) setState(() => _done = message);
      await _syncSoon(widget.repo);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await _closeWindow();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return _Sheet(
      onOutside: _done != null || _failed ? _closeWindow : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Row(
          children: [
            if (_done == null && !_failed)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(_failed ? '⚠️' : '📥', style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _failed ? '저장하지 못했어요' : (_done ?? '저장하는 중…'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: colors.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickMemo extends StatefulWidget {
  const _QuickMemo({required this.repo});

  final NotesRepository repo;

  @override
  State<_QuickMemo> createState() => _QuickMemoState();
}

class _QuickMemoState extends State<_QuickMemo> {
  final _text = TextEditingController();
  bool _saving = false;
  bool _saved = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_text.text.trim().isEmpty || _saving) return;
    setState(() => _saving = true);
    await widget.repo.appendToInbox(_text.text);
    await _syncSoon(widget.repo);
    if (!mounted) return;
    setState(() => _saved = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _closeWindow();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    return _Sheet(
      // A tap on the dimmed area outside the sheet cancels.
      onOutside: _saving ? null : _closeWindow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('📥', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Text(
                  '미정리에 저장',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
              ],
            ),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: '한 줄 메모',
                border: InputBorder.none,
              ),
            ),
            Row(
              children: [
                if (_saved)
                  Text('저장했어요', style: TextStyle(color: colors.textMuted)),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : _closeWindow,
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving && !_saved
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('저장'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
