import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/links.dart';
import 'package:notes/md/markdown_codec.dart';

const _sample = '''﻿---
id: "abc"
tags: [여행, 일본]
---
# 오사카

첫날은 [[교토 일정|교토]]에 갔다. 자세한 건 [링크](계획/예산.md) 참고.

```bash
sudo apt update
echo "hi"
```

\$\$
E = mc^2
\$\$

인라인 \$x^2\$ 수식.

![[사진.png]]

![[다른 노트]]

| 항목 | 금액 |
|---|---|
| 숙소 | 10만 |

- [ ] 할 일
- 목록
''';

void main() {
  test('parses frontmatter, code, math, links and embeds', () async {
    final parsed = parseMarkdown(_sample);
    expect(parsed.frontmatter['id'], 'abc');
    expect(parsed.frontmatter['tags'], ['여행', '일본']);
    final types = [for (final n in parsed.nodes) n.type];
    expect(types.first, 'heading');
    expect(types, containsAll(['code', 'math_equation', 'table', 'todo_list']));
    final code = parsed.nodes.firstWhere((n) => n.type == 'code');
    expect(code.delta!.toPlainText(), 'sudo apt update\necho "hi"');
    expect(code.attributes['language'], 'bash');
    expect(
      parsed.nodes
          .firstWhere((n) => n.type == 'math_equation')
          .attributes['formula'],
      'E = mc^2',
    );

    final pages = <String>[];
    final embeds = <String>[];
    final nodes = await resolveParsed(
      parsed.nodes,
      pageFor: (t) async {
        pages.add(t);
        return (id: 'id-$t', title: t);
      },
      embed: (t, {required wiki}) async {
        embeds.add(t);
        return imageNode(url: 'asset://img');
      },
    );
    expect(pages, ['교토 일정', '계획/예산', '다른 노트']);
    expect(embeds, ['사진.png']);
    final para = nodes[1].delta!;
    final link = para.whereType<TextInsert>().firstWhere(
      (op) => op.attributes?[pageLinkKey] != null,
    );
    expect(link.attributes![pageLinkKey], 'id-교토 일정');
    expect(nodes.any((n) => n.type == 'image'), isTrue);
  });

  test('exports back to Obsidian markdown', () async {
    final parsed = parseMarkdown(_sample);
    final nodes = await resolveParsed(
      parsed.nodes,
      pageFor: (t) async => (id: 'id-$t', title: t),
      embed: (t, {required wiki}) async => imageNode(url: 'asset://img1'),
    );
    final md = nodesToMarkdown(
      nodes,
      MdExportContext(
        linkTarget: (id) => id.substring(3),
        assetPath: (id) => '_assets/사진.png',
      ),
    );
    expect(md, contains('# 오사카'));
    expect(md, contains('[[교토 일정]]'));
    expect(md, contains('```bash\nsudo apt update\necho "hi"\n```'));
    expect(md, contains('\$\$\nE = mc^2\n\$\$'));
    expect(md, contains('\$x^2\$'));
    expect(md, contains('![[_assets/사진.png]]'));
    expect(md, contains('|숙소|10만|'));
    expect(md, contains('[[계획/예산]] 참고'));
    expect(md, contains('# 오사카\n\n첫날은'));
    expect(md, contains('- [ ] 할 일'));

    // And once more: the same structure comes back.
    final again = parseMarkdown(md);
    expect(
      [for (final n in again.nodes) n.type],
      [for (final n in nodes) n.type],
    );
  });

  test('a quote with several paragraphs and a table keeps them apart', () {
    final parsed = parseMarkdown(
      '> **이유**\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n>\n> 둘째 문단',
    );
    expect([for (final n in parsed.nodes) n.type], ['quote', 'table', 'quote']);
    expect(parsed.nodes.last.delta!.toPlainText(), '둘째 문단');
  });

  test('bold text containing code stays one bold run', () async {
    final parsed = parseMarkdown('**`uv sync` 옵션 설명**');
    final md = nodesToMarkdown(
      parsed.nodes,
      MdExportContext(linkTarget: (_) => null, assetPath: (_) => null),
    );
    expect(md.trim(), '**`uv sync` 옵션 설명**');
  });

  test('footnotes do not stop an import', () {
    final parsed = parseMarkdown('본문[^1] 이어서\n\n[^1]: 각주 내용\n');
    final text = parsed.nodes
        .map((n) => n.delta?.toPlainText() ?? '')
        .join('\n');
    expect(text, contains('본문[^1] 이어서'));
    expect(text, contains('[^1]: 각주 내용'));
    // Regexes in code are untouched.
    final code = parseMarkdown('`[^0-9]` 와\n\n```\nre = "[^a]"\n```');
    expect(code.nodes.first.delta!.toPlainText(), '[^0-9] 와');
    expect(code.nodes.last.delta!.toPlainText(), 're = "[^a]"');
  });

  test('frontmatter output is valid YAML', () {
    final text = frontmatterToString({
      'id': 'x',
      'title': 'a: "b"',
      'tags': ['t1', 't2'],
      'skip': null,
    });
    final parsed = parseMarkdown('$text본문');
    expect(parsed.frontmatter, {
      'id': 'x',
      'title': 'a: "b"',
      'tags': ['t1', 't2'],
    });
    expect(parsed.nodes.single.delta!.toPlainText(), '본문');
  });
}
