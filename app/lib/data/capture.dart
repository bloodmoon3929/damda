import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:http/http.dart' as http;

import 'asset_repository.dart';
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
  Future<void> appendToInbox(String text) async {
    final lines = [
      for (final l in text.split('\n'))
        if (l.trim().isNotEmpty) l.trimRight(),
    ];
    if (lines.isEmpty) return;
    final doc = await openDocument(inboxPageId);
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

  /// A page of its own for a shared YouTube video, in the 미정리 section:
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
    final id = await createPage(title: title, icon: '▶️', inboxSection: true);
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

  /// Saves something shared from another app right away (no editing):
  /// a YouTube video becomes its own page, anything else goes to the end
  /// of the 미정리 note. Returns what to tell the user.
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
    await appendToInbox(shareText(text, subject));
    return '미정리에 저장했어요';
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
