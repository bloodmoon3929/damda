import 'dart:io';

import 'package:flutter/material.dart';

import '../data/album_repository.dart';
import '../data/asset_repository.dart';
import '../data/database.dart';
import '../data/notes_repository.dart';
import '../editor/attachment_blocks.dart' show pickFilePaths;
import 'theme.dart';

/// Picks a photo for something on [pageId] (a map card, an image block).
///
/// When a 사진 보관함 covers [pageId] (one sitting under it or under one of
/// its parent pages) it shows that album's photos — which include every
/// photo used in the notes around it — with a tab per album and "전체",
/// plus "파일에서 가져오기". Otherwise it goes straight to the file
/// picker. A photo from a file is stored on [pageId], so it shows up in
/// those albums by itself.
Future<AssetRow?> pickPhoto(
  BuildContext context,
  NotesRepository repo,
  String pageId,
) async {
  final albums = await repo.albumsFor(pageId);
  if (albums.isEmpty) return _fromFile(repo, pageId);
  if (!context.mounted) return null;
  return showDialog<AssetRow>(
    context: context,
    builder: (_) =>
        _PhotoPickerDialog(repo: repo, pageId: pageId, albums: albums),
  );
}

Future<AssetRow?> _fromFile(NotesRepository repo, String pageId) async {
  final paths = await pickFilePaths(imagesOnly: true, title: '사진 고르기');
  if (paths.isEmpty) return null;
  final asset = await repo.importAsset(paths.first, pageId: pageId);
  return assetKind(asset.mime) == AssetKind.image ? asset : null;
}

class _PhotoPickerDialog extends StatefulWidget {
  const _PhotoPickerDialog({
    required this.repo,
    required this.pageId,
    required this.albums,
  });

  final NotesRepository repo;
  final String pageId;
  final List<PageRow> albums;

  @override
  State<_PhotoPickerDialog> createState() => _PhotoPickerDialogState();
}

class _PhotoPickerDialogState extends State<_PhotoPickerDialog> {
  /// -1: 전체, otherwise an index into the albums.
  late int _tab = widget.albums.length > 1 ? -1 : 0;
  late Stream<List<AlbumItem>> _items = _watch();

  Stream<List<AlbumItem>> _watch() => widget.repo.watchAlbumView([
    if (_tab < 0)
      for (final a in widget.albums) a.id
    else
      widget.albums[_tab].id,
  ]);

  void _select(int tab) => setState(() {
    _tab = tab;
    _items = _watch();
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    String name(PageRow a) => a.title.isEmpty ? '사진 보관함' : a.title;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '사진 고르기',
                style: Theme.of(context).dialogTheme.titleTextStyle,
              ),
              const SizedBox(height: 10),
              if (widget.albums.length > 1)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = -1; i < widget.albums.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(i < 0 ? '전체' : name(widget.albums[i])),
                            visualDensity: VisualDensity.compact,
                            selected: _tab == i,
                            onSelected: (_) => _select(i),
                          ),
                        ),
                    ],
                  ),
                )
              else
                Text(
                  name(widget.albums.single),
                  style: TextStyle(color: colors.textMuted),
                ),
              const SizedBox(height: 10),
              Flexible(
                child: StreamBuilder<List<AlbumItem>>(
                  stream: _items,
                  builder: (context, snap) {
                    final photos = [
                      for (final item in snap.data ?? const <AlbumItem>[])
                        if (assetKind(item.asset.mime) == AssetKind.image)
                          item.asset,
                    ];
                    if (snap.hasData && photos.isEmpty) {
                      return Container(
                        height: 160,
                        alignment: Alignment.center,
                        child: Text(
                          '이 보관함에는 아직 사진이 없어요',
                          style: TextStyle(color: colors.textMuted),
                        ),
                      );
                    }
                    return GridView.builder(
                      shrinkWrap: true,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 120,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                          ),
                      itemCount: photos.length,
                      itemBuilder: (context, i) => _Thumb(
                        asset: photos[i],
                        onTap: () => Navigator.pop(context, photos[i]),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.upload_file_outlined, size: 18),
                    label: const Text('파일에서 가져오기…'),
                    onPressed: () async {
                      final asset = await _fromFile(widget.repo, widget.pageId);
                      if (asset != null && context.mounted) {
                        Navigator.pop(context, asset);
                      }
                    },
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.asset, required this.onTap});

  final AssetRow asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = resolveAssetUrl(assetUrl(asset.id));
    return Material(
      color: context.noteColors.hover,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: path == null
            ? const Icon(Icons.image_outlined)
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                cacheWidth: 240,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              ),
      ),
    );
  }
}
