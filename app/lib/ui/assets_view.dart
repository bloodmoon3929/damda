import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/asset_repository.dart';
import '../data/database.dart';
import '../editor/attachment_blocks.dart';
import '../providers.dart';
import 'page_actions.dart';
import 'theme.dart';

/// 자료실: every attachment in one place, filterable by kind and usage.
/// With [rootPageId] it is the page's 로컬 자료실: only the files used in
/// that page and the pages under it.
class AssetsView extends ConsumerStatefulWidget {
  const AssetsView({super.key, this.rootPageId});

  final String? rootPageId;

  @override
  ConsumerState<AssetsView> createState() => _AssetsViewState();
}

class _AssetsViewState extends ConsumerState<AssetsView> {
  AssetKind? _kind;
  bool _unusedOnly = false;
  String _query = '';
  Set<String>? _unused;

  /// 로컬 자료실: the files under the page (null until loaded).
  Set<String>? _local;

  @override
  void initState() {
    super.initState();
    _refreshUnused();
  }

  Future<void> _refreshUnused() async {
    final repo = ref.read(repositoryProvider);
    final ids = await repo.unusedAssetIds();
    final root = widget.rootPageId;
    final local = root == null ? null : await repo.assetIdsUnder(root);
    if (mounted) {
      setState(() {
        _unused = ids;
        _local = local;
      });
    }
  }

  Future<void> _addFiles() async {
    final paths = await pickFilePaths(title: '자료실에 추가');
    final repo = ref.read(repositoryProvider);
    for (final path in paths) {
      await repo.importAsset(path, pageId: widget.rootPageId);
    }
    await _refreshUnused();
  }

  static String _kindLabel(AssetKind? k) => switch (k) {
    null => '전체',
    AssetKind.image => '이미지',
    AssetKind.video => '영상',
    AssetKind.audio => '오디오',
    AssetKind.pdf => 'PDF',
    AssetKind.other => '기타',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    // A file added or synced meanwhile: work the local set out again.
    ref.listen(assetsProvider, (_, _) => _refreshUnused());
    final every = ref.watch(assetsProvider).value ?? const <AssetRow>[];
    final local = _local;
    final isLocal = widget.rootPageId != null;
    final all = !isLocal
        ? every
        : [
            for (final a in every)
              if (local?.contains(a.id) ?? false) a,
          ];
    final rootTitle = isLocal
        ? ref.watch(pageProvider(widget.rootPageId!)).value?.title ?? ''
        : '';
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final a in all)
        if ((_kind == null || assetKind(a.mime) == _kind) &&
            (!_unusedOnly || (_unused?.contains(a.id) ?? false)) &&
            (q.isEmpty || a.name.toLowerCase().contains(q)))
          a,
    ];
    final total = all.fold<int>(0, (s, a) => s + a.size);

    final narrow = MediaQuery.sizeOf(context).width < 600;
    return ListView(
      padding: narrow
          ? const EdgeInsets.fromLTRB(16, 20, 16, 32)
          : const EdgeInsets.fromLTRB(32, 40, 32, 48),
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(isLocal ? '📎' : '🗂', style: const TextStyle(fontSize: 36)),
            Text(
              isLocal
                  ? '${rootTitle.isEmpty ? '제목 없음' : rootTitle}의 자료'
                  : '자료실',
              style: TextStyle(
                fontSize: narrow ? 24 : 32,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
            Text(
              isLocal
                  ? '하위 페이지 포함 ${all.length}개 · ${formatBytes(total)}'
                  : '${all.length}개 · ${formatBytes(total)}',
              style: TextStyle(color: colors.textMuted),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('파일 추가'),
              onPressed: _addFiles,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final k in [null, ...AssetKind.values])
              ChoiceChip(
                label: Text(_kindLabel(k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
            if (!isLocal)
              FilterChip(
                label: const Text('사용 안 됨'),
                selected: _unusedOnly,
                onSelected: (v) {
                  setState(() => _unusedOnly = v);
                  _refreshUnused();
                },
              ),
            SizedBox(
              width: 200,
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: '이름 검색',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                isLocal && local == null
                    ? '불러오는 중…'
                    : all.isEmpty
                    ? (isLocal
                          ? '이 페이지와 하위 페이지에 첨부된 파일이 없어요.'
                          : '아직 첨부 파일이 없어요. 페이지에서 /이미지, /파일 첨부로 넣거나 여기서 추가하세요.')
                    : '조건에 맞는 파일이 없어요',
                style: TextStyle(color: colors.textMuted),
              ),
            ),
          )
        else
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final a in shown)
                _AssetCard(
                  asset: a,
                  unused: _unused?.contains(a.id) ?? false,
                  onTap: () async {
                    await showAssetDetail(context, ref, a);
                    await _refreshUnused();
                  },
                ),
            ],
          ),
      ],
    );
  }
}

class _AssetCard extends ConsumerWidget {
  const _AssetCard({
    required this.asset,
    required this.unused,
    required this.onTap,
  });

  final AssetRow asset;
  final bool unused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final path = ref.read(repositoryProvider).assetPath(asset);
    final isImage = assetKind(asset.mime) == AssetKind.image;
    return SizedBox(
      width: 180,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 130,
                width: 180,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: colors.hover,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.divider),
                ),
                child: isImage
                    ? Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        cacheWidth: 360,
                        errorBuilder: (_, _, _) =>
                            Icon(Icons.broken_image, color: colors.textMuted),
                      )
                    : Icon(
                        assetIcon(asset.mime),
                        size: 48,
                        color: colors.textMuted,
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                asset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.text),
              ),
              Text(
                '${formatBytes(asset.size)}${unused ? ' · 사용 안 됨' : ''}',
                style: TextStyle(fontSize: 11, color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Preview, info, where it's used, open / delete.
Future<void> showAssetDetail(
  BuildContext context,
  WidgetRef ref,
  AssetRow asset,
) async {
  final repo = ref.read(repositoryProvider);
  final usage = await repo.assetUsage(asset.id);
  if (!context.mounted) return;
  final path = repo.assetPath(asset);
  final isImage = assetKind(asset.mime) == AssetKind.image;
  final colors = context.noteColors;

  Widget info(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label, style: TextStyle(color: colors.textMuted)),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(asset.name, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isImage)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text('이미지를 열 수 없어요'),
                  ),
                ),
              const SizedBox(height: 12),
              info('종류', asset.mime),
              info('크기', formatBytes(asset.size)),
              if (asset.width != null)
                info('해상도', '${asset.width} × ${asset.height}'),
              info('추가', formatEdited(asset.createdAt).replaceAll(' 편집', '')),
              const Divider(height: 24),
              Text(
                usage.isEmpty
                    ? '어느 페이지에서도 쓰이지 않아요'
                    : '사용된 페이지 ${usage.length}개',
                style: TextStyle(color: colors.textMuted),
              ),
              for (final page in usage)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(
                    (page.icon?.isNotEmpty ?? false) ? page.icon! : '📄',
                  ),
                  title: Text(page.title.isEmpty ? '제목 없음' : page.title),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    ref.read(screenProvider.notifier).openPage(page.id);
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('삭제'),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: dialogContext,
              builder: (c) => AlertDialog(
                content: Text(
                  usage.isEmpty
                      ? '"${asset.name}"을(를) 삭제할까요?'
                      : '"${asset.name}"은(는) 페이지 ${usage.length}개에서 쓰이고 있어요. '
                            '삭제하면 그 페이지에서 "파일 없음"으로 보여요. 삭제할까요?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('삭제'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            await repo.deleteAsset(asset);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
        ),
        TextButton.icon(
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('열기'),
          onPressed: () => openAssetFile(path),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('닫기'),
        ),
      ],
    ),
  );
}
