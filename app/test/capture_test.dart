import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notes/data/capture.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/editor/attachment_blocks.dart';

void main() {
  test('captures stack up at the end of 미정리, links clickable', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = NotesRepository(db);
    await repo.init();

    await repo.appendToInbox('우유 사기');
    await repo.appendToInbox(shareText('https://youtu.be/abc', '오사카 브이로그'));
    await repo.appendToInbox('  \n');

    final doc = await repo.openDocument(repo.inboxPageId);
    final lines = [
      for (final n in doc.document.root.children) n.delta!.toPlainText(),
    ];
    expect(lines, ['우유 사기', '오사카 브이로그', 'https://youtu.be/abc']);
    final link = doc.document.root.children.last.delta!.first;
    expect(link.attributes?['href'], 'https://youtu.be/abc');
    await db.close();
  });

  test('YouTube links are recognised', () {
    for (final u in [
      'https://youtu.be/dQw4w9WgXcQ?si=abc',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10',
      'https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ',
      'https://youtube.com/shorts/dQw4w9WgXcQ',
    ]) {
      expect(youtubeLink('보세요 $u'), u, reason: u);
    }
    expect(youtubeLink('https://www.youtube.com/@channel'), isNull);
    expect(youtubeLink('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
  });

  test('a shared YouTube video becomes its own page in 미정리 section; '
      'other shares go into the 미정리 note', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = NotesRepository(db);
    await repo.init();
    final client = MockClient((req) async {
      if (req.url.path == '/oembed') {
        expect(req.url.queryParameters['url'], 'https://youtu.be/dQw4w9WgXcQ');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'title': '오사카 브이로그',
              'author_name': '여행채널',
              'thumbnail_url': 'https://i.ytimg.com/vi/x/hqdefault.jpg',
            }),
          ),
          200,
        );
      }
      return http.Response('', 404); // thumbnail: skipped
    });

    final msg = await repo.saveShared(
      'https://youtu.be/dQw4w9WgXcQ',
      '',
      client: client,
    );
    expect(msg, '"오사카 브이로그" 페이지를 만들었어요');
    final pages = await repo.watchPages().first;
    final page = pages.singleWhere((p) => p.title == '오사카 브이로그');
    expect(page.parentId, isNull);
    expect(await repo.isInInboxSection(page.id), isTrue);
    final doc = await repo.openDocument(page.id);
    expect(
      [for (final n in doc.document.root.children) n.delta!.toPlainText()],
      ['https://youtu.be/dQw4w9WgXcQ', '채널: 여행채널'],
    );

    // Offline: still a page, named after the share's subject.
    final offline = MockClient((_) async => throw Exception('offline'));
    await repo.saveShared(
      'https://youtu.be/aaaaaaaaaaa',
      '제목만',
      client: offline,
    );
    expect(
      (await repo.watchPages().first).where((p) => p.title == '제목만'),
      hasLength(1),
    );

    // Not YouTube: into the 미정리 note, no new page.
    expect(
      await repo.saveShared('https://news.site/a', '기사', client: client),
      '미정리에 저장했어요',
    );
    final inbox = await repo.openDocument(repo.inboxPageId);
    expect([
      for (final n in inbox.document.root.children) n.delta!.toPlainText(),
    ], containsAllInOrder(['기사', 'https://news.site/a']));
    await db.close();
  });

  test('Ctrl+V: an image with only an address or name is pasted as image', () {
    expect(clipboardPrefersImage(null), isTrue);
    expect(clipboardPrefersImage(''), isTrue);
    expect(clipboardPrefersImage('https://example.com/osaka.png'), isTrue);
    expect(clipboardPrefersImage('IMG_2031.JPG\n'), isTrue);
    // Real text (Word puts a picture of it next to it) stays text.
    expect(clipboardPrefersImage('오사카 여행 일정'), isFalse);
  });

  test('share text', () {
    expect(shareText('https://a.b', ''), 'https://a.b');
    expect(shareText('제목 https://a.b', '제목'), '제목 https://a.b');
    expect(shareText('https://a.b', '제목'), '제목\nhttps://a.b');
    final d = linkify('보기: https://x.y/z?q=1 끝');
    expect(d.toPlainText(), '보기: https://x.y/z?q=1 끝');
    expect(d.toList()[1].attributes?['href'], 'https://x.y/z?q=1');
  });
}
