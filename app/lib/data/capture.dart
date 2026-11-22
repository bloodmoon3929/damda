import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:http/http.dart' as http;

import 'asset_repository.dart';
import 'database.dart';
import 'database_repository.dart' show stableId;
import 'notes_repository.dart';

final _url = RegExp(r'https?://[^\s<>"]+');

final _youtube = RegExp(
  r'https?://(?:www\.|m\.|music\.)?'
  r'(?:youtube\.com/(?:watch\?\S*?v=|shorts/|live/)|youtu\.be/)'
  r'([\w-]{11})\S*',
);

/// The first YouTube video address in [text], if any.
String? youtubeLink(String text) => _youtube.firstMatch(text)?[0];

/// What YouTube's oEmbed endpoint (public, no key) says about a video.
typedef YoutubeInfo = ({String title, String author, String thumbnail});

Future<YoutubeInfo?> fetchYoutubeInfo(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(
          Uri.https('www.youtube.com', '/oembed', {
            'url': url,
            'format': 'json',
          }),
        )
        .timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (
      title: (j['title'] as String?) ?? '',
      author: (j['author_name'] as String?) ?? '',
      thumbnail: (j['thumbnail_url'] as String?) ?? '',
    );
  } catch (_) {
    return null; // offline: the page still gets made, with the link
  } finally {
    if (client == null) c.close();
  }
}

/// [line] as text with its web addresses clickable.
Delta linkify(String line) {
  final d = Delta();
  var at = 0;
  for (final m in _url.allMatches(line)) {
    if (m.start > at) d.insert(line.substring(at, m.start));
    d.insert(m[0]!, attributes: {'href': m[0]!});
    at = m.end;
  }
  if (at < line.length) d.insert(line.substring(at));
  return d;
}

/// Capture: things saved from outside (share sheet, memo widget) land at
/// the end of 미정리, to be sorted later by the user.
extension Capture on NotesRepository {
  /// Adds the non-empty lines of [text] to the end of 미정리.
  Future<void> appendToInbox(String text) => _appendLines(inboxPageId, text);

  /// The same id on every device, so syncing two devices that both made
  /// "공유된 페이지" gives one page, not two.
  static final sharedPageId = stableId('damda/shared-page');

  /// "공유된 페이지" in the 미정리 section (beside the 미정리 note): what
  /// other apps share lands under it instead of filling 미정리. Made on
  /// first use, and brought back if it was deleted. If the user moved or
  /// renamed it, it stays that way.
  Future<String> ensureSharedPage() async {
    final id = sharedPageId;
    final page = await getPage(id);
    if (page == null) {
      await createPage(
        id: id,
        title: '공유된 페이지',
        icon: '📤',
        inboxSection: true,
      );
    } else if (page.deleted || page.trashedAt != null) {
      await (db.update(db.pages)..where((p) => p.id.equals(id))).write(
        PagesCompanion(
          deleted: const Value(false),
          trashedAt: const Value(null),
          updatedAt: Value(clock.tick()),
          deviceId: Value(deviceId),
          dirty: const Value(true),
        ),
      );
    }
    return id;
  }

  /// Once per device (1.0.23): YouTube pages shared before 공유된 페이지
  /// existed sit at the top of the 미정리 section; move them under it, in
  /// their order. Only top-level ▶️ pages there whose text has a YouTube
  /// link. Returns how many moved.
  Future<int> moveOldYoutubeSharesOnce() async {
    const flag = 'moved_old_youtube_shares_v1';
    if (await db.getMeta(flag) != null) return 0;
    final candidates =
        await (db.select(db.pages)
              ..where(
                (p) =>
                    p.deleted.equals(false) &
                    p.trashedAt.isNull() &
                    p.parentId.isNull() &
                    p.icon.equals('▶️'),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.sortKey)]))
            .get();
    var moved = 0;
    String? target;
    for (final page in candidates) {
      if (!await isInInboxSection(page.id)) continue;
      final youtube =
          await (db.select(db.blocks)
                ..where(
                  (b) =>
                      b.pageId.equals(page.id) &
                      b.deleted.equals(false) &
                      b.data.like('%youtu%'),
                )
                ..limit(1))
              .getSingleOrNull();
      if (youtube == null) continue;
      target ??= await ensureSharedPage();
      await movePage(page.id, parentId: target);
      moved++;
    }
    await db.setMeta(flag, '$moved');
    return moved;
  }

  Future<void> _appendLines(String pageId, String text) async {
    final lines = [
      for (final l in text.split('\n'))
        if (l.trim().isNotEmpty) l.trimRight(),
    ];
    if (lines.isEmpty) return;
    final doc = await openDocument(pageId);
    final root = doc.document.root;
    var at = root.children.length;
    // A trailing empty line (a new page has one) is replaced, so captures
    // stack up without gaps.
    final last = root.children.lastOrNull;
    if (last != null &&
        last.type == ParagraphBlockKeys.type &&
        (last.delta?.isEmpty ?? false)) {
      doc.document.delete([at - 1]);
      at--;
    }
    doc.document.insert(
      [at],
      [for (final l in lines) paragraphNode(delta: linkify(l))],
    );
    await doc.save();
  }

  /// A page of its own for a shared YouTube video, under 공유된 페이지:
  /// the video title, its thumbnail, the link and the channel. Returns the
  /// page id and title.
  Future<({String id, String title})> saveYoutubePage(
    String url, {
    String subject = '',
    http.Client? client,
  }) async {
    final info = await fetchYoutubeInfo(url, client: client);
    final title = info?.title.isNotEmpty ?? false
        ? info!.title
        : (subject.trim().isNotEmpty ? subject.trim() : 'YouTube 영상');
    final id = await createPage(
      parentId: await ensureSharedPage(),
      title: title,
      icon: '▶️',
    );
    final nodes = <Node>[];
    if (info != null && info.thumbnail.isNotEmpty) {
      try {
        final c = client ?? http.Client();
        try {
          final res = await c
              .get(Uri.parse(info.thumbnail))
              .timeout(const Duration(seconds: 8));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            final videoId = _youtube.firstMatch(url)![1];
            final asset = await importAssetBytes(
              res.bodyBytes,
              'youtube-$videoId.jpg',
              pageId: id,
            );
            nodes.add(imageNode(url: assetUrl(asset.id)));
          }
        } finally {
          if (client == null) c.close();
        }
      } catch (_) {} // no thumbnail is fine
    }
    nodes.add(paragraphNode(delta: linkify(url)));
    if (info != null && info.author.isNotEmpty) {
      nodes.add(paragraphNode(text: '채널: ${info.author}'));
    }
    final doc = await openDocument(id);
    final root = doc.document.root;
    final empty = root.children.length;
    doc.document.insert([0], nodes);
    // Drop the empty line a new page starts with.
    for (var i = empty; i > 0; i--) {
      final n = root.children[nodes.length + i - 1];
      if (n.type == ParagraphBlockKeys.type && (n.delta?.isEmpty ?? false)) {
        doc.document.delete([nodes.length + i - 1]);
      }
    }
    await doc.save();
    return (id: id, title: title);
  }

  /// Saves something shared from another app right away (no editing),
  /// under 공유된 페이지 in the 미정리 section: a YouTube video becomes its
  /// own page there, anything else goes to the end of that page. Memos
  /// from the widget still go to the 미정리 note. Returns what to tell
  /// the user.
  Future<String> saveShared(
    String text,
    String subject, {
    http.Client? client,
  }) async {
    final youtube = youtubeLink(text);
    if (youtube != null) {
      final page = await saveYoutubePage(
        youtube,
        subject: subject,
        client: client,
      );
      return '"${page.title}" 페이지를 만들었어요';
    }
    await _appendLines(await ensureSharedPage(), shareText(text, subject));
    return '공유된 페이지에 저장했어요';
  }
}

/// Text for the quick memo box from a share: "제목\n주소", or just the
/// shared text when the title is empty or already in it.
String shareText(String text, String subject) {
  final t = text.trim();
  final s = subject.trim();
  if (s.isEmpty || t.contains(s)) return t;
  return '$s\n$t';
}
