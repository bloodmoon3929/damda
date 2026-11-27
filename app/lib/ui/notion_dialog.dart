import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import '../notion/notion_import.dart';
import '../providers.dart';
import 'theme.dart';

/// Notion → here, one way: token → list of top-level pages → choose →
/// import. The token is kept only if the user asks, and then in the OS key
/// store (Windows Credential Manager / Android Keystore), never in the
/// notes DB or synced.
// macOS: the data-protection keychain (the plugin's default) needs a
// Developer ID team in the signature; the release is ad-hoc signed, so
// every write failed with -34018. The login keychain works without one.
const _secure = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
const _tokenKey = 'notion_token';

Future<void> showNotionImport(BuildContext context, WidgetRef ref) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _NotionDialog(),
    );

enum _Step { token, scanning, choose, importing, done }

class _NotionDialog extends ConsumerStatefulWidget {
  const _NotionDialog();

  @override
  ConsumerState<_NotionDialog> createState() => _NotionDialogState();
}

class _NotionDialogState extends ConsumerState<_NotionDialog> {
  final _token = TextEditingController();
  _Step _step = _Step.token;
  NotionApi? _api;
  NotionImporter? _importer;
  List<NotionItem> _items = const [];
  final _chosen = <String>{};
  String _message = '';
  int _done = 0;
  int _total = 0;
  String? _error;
  NotionReport? _report;
  bool _remember = true;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _secure.read(key: _tokenKey).then((t) {
      if (t != null && mounted) {
        setState(() {
          _token.text = t;
          _saved = true;
        });
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _token.dispose();
    _api?.close();
    super.dispose();
  }

  Future<void> _forget() async {
    await _secure.delete(key: _tokenKey);
    if (mounted) {
      setState(() {
        _token.clear();
        _saved = false;
      });
    }
  }

  void _onProgress(String m, int d, int t) {
    if (!mounted) return;
    setState(() {
      _message = m;
      _done = d;
      _total = t;
    });
  }

  Future<void> _scan() async {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _error = '토큰을 붙여넣으세요');
      return;
    }
    _api?.close();
    final api = _api = NotionApi(token);
    final importer = _importer = NotionImporter(
      ref.read(repositoryProvider),
      api,
      onProgress: _onProgress,
    );
    setState(() {
      _step = _Step.scanning;
      _error = null;
    });
    try {
      final items = await importer.scan();
      // Only a token that worked is kept.
      try {
        if (_remember) {
          await _secure.write(key: _tokenKey, value: token);
          _saved = true;
        } else if (_saved) {
          await _secure.delete(key: _tokenKey);
          _saved = false;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = items;
        _chosen
          ..clear()
          ..addAll(items.map((i) => i.id));
        _step = _Step.choose;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is NotionException ? e.message : '$e';
          _step = _Step.token;
        });
      }
    }
  }

  Future<void> _import() async {
    final importer = _importer!;
    setState(() => _step = _Step.importing);
    try {
      final r = await importer.run(only: {..._chosen});
      if (mounted) {
        setState(() {
          _report = r;
          _step = _Step.done;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is NotionException ? e.message : '$e';
          _step = _Step.choose;
        });
      }
    }
  }

  void _finish() {
    final root = _report?.rootPageId;
    Navigator.pop(context);
    if (root != null) ref.read(screenProvider.notifier).openPage(root);
  }

  Widget _tokenStep(NoteColors colors) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '1. Notion 통합 페이지에서 "내부 통합"을 만들고 시크릿(토큰)을 복사하세요.\n'
        '2. 가져올 최상위 페이지마다 ⋯ → 연결(Connections) → 그 통합을 추가하세요. '
        '하위 페이지와 데이터베이스는 함께 들어와요.\n'
        '3. 토큰을 붙여넣고 "목록 불러오기" → 가져올 것을 고르세요.',
      ),
      TextButton.icon(
        icon: const Icon(Icons.open_in_new, size: 16),
        label: const Text('Notion 통합 페이지 열기'),
        onPressed: () =>
            launchUrl(Uri.parse('https://www.notion.so/profile/integrations')),
      ),
      TextField(
        controller: _token,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '통합 시크릿 (ntn_… 또는 secret_…)',
        ),
        onSubmitted: (_) => _scan(),
      ),
      Row(
        children: [
          Checkbox(
            value: _remember,
            onChanged: (v) => setState(() => _remember = v ?? false),
          ),
          const Expanded(
            child: Text(
              '이 기기에 기억하기 (Windows 자격 증명 관리자 / Android 키 저장소)',
              style: TextStyle(fontSize: 13),
            ),
          ),
          if (_saved) TextButton(onPressed: _forget, child: const Text('지우기')),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        '페이지·하위 페이지·데이터베이스(속성·선택지 색·항목·보기)·첨부를 가져와요. '
        '다시 가져오면 같은 페이지를 갱신해요(중복 없음).',
        style: TextStyle(fontSize: 12, color: colors.textMuted),
      ),
    ],
  );

  Widget _chooseStep(NoteColors colors) {
    final all = _chosen.length == _items.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: all ? true : (_chosen.isEmpty ? false : null),
          tristate: true,
          title: Text('전체 (${_items.length}개)'),
          onChanged: (_) => setState(() {
            if (all) {
              _chosen.clear();
            } else {
              _chosen.addAll(_items.map((i) => i.id));
            }
          }),
        ),
        Divider(height: 1, color: colors.divider),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 340),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final item in _items)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _chosen.contains(item.id),
                  onChanged: (v) => setState(() {
                    v == true ? _chosen.add(item.id) : _chosen.remove(item.id);
                  }),
                  secondary: Text(
                    item.icon ?? (item.isDatabase ? '🗂' : '📄'),
                    style: const TextStyle(fontSize: 18),
                  ),
                  title: Text(
                    item.title.isEmpty ? '제목 없음' : item.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: item.inside == 0
                      ? null
                      : Text('안에 ${item.inside}개 포함'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '목록에 없는 페이지는 Notion에서 그 페이지에 통합을 연결해야 보여요.',
          style: TextStyle(fontSize: 12, color: colors.textMuted),
        ),
      ],
    );
  }

  Widget _progressStep(NoteColors colors) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
      const SizedBox(height: 12),
      Text(
        _message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.textMuted),
      ),
    ],
  );

  Widget _doneStep() {
    final r = _report!;
    return Text(
      [
        '새 페이지 ${r.pages}개, 데이터베이스 ${r.databases}개(보기 ${r.views}개), 항목 ${r.rows}개',
        if (r.updated > 0) '이미 가져온 것 ${r.updated}개는 갱신',
        '첨부 ${r.attachments}개'
            '${r.failedAttachments > 0 ? ' (실패 ${r.failedAttachments}개)' : ''}',
        if (r.skippedBlocks > 0) '지원하지 않는 블록 ${r.skippedBlocks}개는 건너뜀',
      ].join('\n'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final body = switch (_step) {
      _Step.token => _tokenStep(colors),
      _Step.choose => _chooseStep(colors),
      _Step.scanning || _Step.importing => _progressStep(colors),
      _Step.done => _doneStep(),
    };
    return AlertDialog(
      title: const Text('Notion에서 가져오기'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            body,
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: switch (_step) {
        _Step.token => [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(onPressed: _scan, child: const Text('목록 불러오기')),
        ],
        _Step.choose => [
          TextButton(
            onPressed: () => setState(() => _step = _Step.token),
            child: const Text('뒤로'),
          ),
          FilledButton(
            onPressed: _chosen.isEmpty ? null : _import,
            child: Text('가져오기 (${_chosen.length}개)'),
          ),
        ],
        _Step.scanning => [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
        ],
        _Step.importing => [
          TextButton(
            onPressed: () => _importer?.cancel(),
            child: const Text('멈추기'),
          ),
        ],
        _Step.done => [
          FilledButton(onPressed: _finish, child: const Text('확인')),
        ],
      },
    );
  }
}
