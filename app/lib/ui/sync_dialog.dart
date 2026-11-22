import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sync_engine.dart';
import '../providers.dart';
import 'theme.dart';

/// Icon and one-line label for the sidebar's sync row.
(IconData, String) syncLabel(SyncStatus s) => switch (s.phase) {
  SyncPhase.off => (Icons.cloud_off_outlined, '동기화 꺼짐'),
  SyncPhase.syncing => (Icons.cloud_sync_outlined, s.detail ?? '동기화 중…'),
  SyncPhase.error => (Icons.cloud_off, '동기화 오류'),
  SyncPhase.idle => (
    Icons.cloud_done_outlined,
    s.lastSync == null ? '동기화 대기' : '${_ago(s.lastSync!)} 동기화됨',
  ),
};

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '방금';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  return '${t.month}/${t.day}';
}

Future<void> showSyncDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SyncDialog());

class _SyncDialog extends ConsumerStatefulWidget {
  const _SyncDialog();

  @override
  ConsumerState<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends ConsumerState<_SyncDialog> {
  final _url = TextEditingController();
  final _admin = TextEditingController();
  final _name = TextEditingController(
    text: switch (Platform.operatingSystem) {
      'windows' => 'Windows PC',
      'macos' => 'Mac',
      'linux' => 'Linux',
      'android' => 'Android',
      final os => os,
    },
  );
  bool _busy = false;
  bool _showToken = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _admin.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      _error = e is SyncException ? e.message : '연결 실패: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(syncEngineProvider);
    final status = ref.watch(syncStatusProvider);
    final colors = context.noteColors;

    final content = engine.connected
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '서버',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              SelectableText(engine.url ?? ''),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(syncLabel(status).$1, size: 18, color: colors.textMuted),
                  const SizedBox(width: 6),
                  Text(syncLabel(status).$2),
                ],
              ),
              if (status.error != null) ...[
                const SizedBox(height: 6),
                Text(
                  status.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '편집 내용은 이 기기에 먼저 저장되고, 연결되면 몇 초 뒤 서버와 맞춥니다. '
                '같은 블록을 두 기기에서 고치면 나중에 고친 쪽이 남아요.',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '서버 주소',
                  hintText: 'https://…/notes-api',
                ),
              ),
              TextField(
                controller: _admin,
                obscureText: !_showToken,
                decoration: InputDecoration(
                  labelText: '관리자 토큰',
                  helperText: '이 기기 전용 토큰을 받는 데만 쓰고 저장하지 않아요',
                  suffixIcon: IconButton(
                    tooltip: _showToken ? '숨기기' : '보기',
                    icon: Icon(
                      _showToken ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _showToken = !_showToken),
                  ),
                ),
              ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '기기 이름'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          );

    return AlertDialog(
      title: const Text('서버 동기화'),
      content: SizedBox(width: 420, child: content),
      actions: [
        if (engine.connected) ...[
          TextButton(
            onPressed: _busy ? null : () => _run(engine.disconnect),
            child: const Text('연결 끊기'),
          ),
          FilledButton(
            onPressed: status.phase == SyncPhase.syncing
                ? null
                : () => engine.syncNow(),
            child: const Text('지금 동기화'),
          ),
        ] else ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    if (_url.text.trim().isEmpty) {
                      throw SyncException('서버 주소를 입력하세요');
                    }
                    if (_admin.text.trim().isEmpty) {
                      throw SyncException('관리자 토큰을 입력하세요');
                    }
                    await engine.register(
                      _url.text,
                      _admin.text.trim(),
                      _name.text.trim().isEmpty ? '기기' : _name.text.trim(),
                    );
                  }),
            child: Text(_busy ? '연결하는 중…' : '연결'),
          ),
        ],
      ],
    );
  }
}

/// Thin bar along the top of the screen while files sync, filling as they
/// arrive (the sidebar, where the text status lives, is hidden on phones).
class SyncProgressBar extends ConsumerWidget {
  const SyncProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncStatusProvider);
    final progress = s.phase == SyncPhase.syncing ? s.progress : null;
    if (progress == null) return const SizedBox(height: 3);
    return Tooltip(
      message: s.detail ?? '동기화 중',
      child: LinearProgressIndicator(value: progress, minHeight: 3),
    );
  }
}

/// "파일 받는 중 12/513" under the phone's title while files sync.
class SyncDetailText extends ConsumerWidget {
  const SyncDetailText({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncStatusProvider);
    final text = s.phase == SyncPhase.syncing ? s.detail : null;
    if (text == null) return const SizedBox.shrink();
    return Text(
      text,
      style: TextStyle(fontSize: 11, color: context.noteColors.textMuted),
    );
  }
}
