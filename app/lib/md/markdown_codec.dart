import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:yaml/yaml.dart';

import '../data/asset_repository.dart' show assetIdFromUrl;
import '../data/links.dart';
import '../editor/code_block.dart';
import '../editor/toggle_callout.dart';
import '../editor/math_block.dart' show MathBlockKeys;

/// One page <-> one `.md` file (Obsidian flavored), without touching the
/// database: links and attachments are resolved through callbacks, so the
/// same code serves export, import, the daily backup and (later) the CLI.
///
/// | here                    | .md                                  |
/// |-------------------------|--------------------------------------|
/// | page link               | `[[제목]]` (`[[폴더/제목\|제목]]` if names clash) |
/// | image / file attachment | `![[_assets/파일명]]`                 |
/// | inline / block math     | `$x$` / `$$ … $$`                     |
/// | code block              | ```` ```언어 ````                     |
/// | inline DB / album       | `[[DB 제목]]` on its own line         |
/// | id, icon, dates, props  | YAML frontmatter                      |

// ------------------------------------------------------------------ export

class MdExportContext {
  const MdExportContext({required this.linkTarget, required this.assetPath});

  /// Text inside `[[…]]` for a page id, or null when the page is gone.
  final String? Function(String pageId) linkTarget;

  /// Vault-relative path of an attachment (e.g. `_assets/a.png`).
  final String? Function(String assetId) assetPath;
}

String frontmatterToString(Map<String, Object?> fm) {
  final entries = fm.entries.where((e) => e.value != null).toList();
  if (entries.isEmpty) return '';
  final b = StringBuffer('---\n');
  for (final e in entries) {
    // JSON strings and lists are valid YAML, and quote everything safely.
    b.writeln('${e.key}: ${jsonEncode(e.value)}');
  }
  b.writeln('---');
  return b.toString();
}

String nodesToMarkdown(List<Node> nodes, MdExportContext ctx) {
  // Block by block, joined by blank lines (otherwise two paragraphs read
  // back as one); items of the same list stay together.
  const lists = {'bulleted_list', 'numbered_list', 'todo_list'};
  final b = StringBuffer();
  String? prevType;
  for (final n in nodes) {
    var text = _encode(_forExport(n.deepCopy(), ctx), ctx).trimRight();
    if (text.isEmpty) continue;
    // The stock encoder closes and reopens a style between two runs that
    // share it ("**`a`**** b**" for bold code then bold text): merge them.
    if (n.type != CodeBlockKeys.type) {
      text = text.replaceAll('****', '').replaceAll('~~~~', '');
    }
    if (prevType != null) {
      b.write(prevType == n.type && lists.contains(n.type) ? '\n' : '\n\n');
    }
    b.write(text);
    prevType = n.type;
  }
  return b.isEmpty ? '' : '$b\n';
}

String _encode(Node node, MdExportContext ctx) {
  final doc = Document.blank()..insert([0], [node]);
  return documentToMarkdown(
    doc,
    customParsers: [
      _ToggleParser(),
      _CalloutParser(),
      _MathParser(),
      _FileParser(ctx),
      _ImageParser(ctx),
      // Inline database / album blocks (see database_block.dart).
      _LinkedPageParser('database', 'databaseId', ctx),
      _LinkedPageParser('album', 'albumId', ctx),
      const CodeBlockNodeParser(),
    ],
  );
}

/// Page links become plain `[[…]]` text before the stock encoder runs.
Node _forExport(Node node, MdExportContext ctx) {
  final delta = node.delta;
  if (delta != null && delta.any((op) => op.attributes?[pageLinkKey] != null)) {
    final out = Delta();
    for (final op in delta) {
      final id = op.attributes?[pageLinkKey];
      if (op is TextInsert && id is String) {
        final title = op.attributes?[pageLinkTitleKey] as String? ?? '';
        final target = ctx.linkTarget(id) ?? title;
        final shown = title.isNotEmpty && title != target ? '|$title' : '';
        out.insert('[[$target$shown]]');
      } else if (op is TextInsert) {
        out.insert(op.text, attributes: op.attributes);
      }
    }
    node.updateAttributes({'delta': out.toJson()});
  }
  for (final child in node.children) {
    _forExport(child, ctx);
  }
  return node;
}

String _embed(String? path) => path == null ? '' : '![[$path]]';

String _suffix(Node node) => node.next == null ? '' : '\n';

/// 토글 → a list item (Markdown has no toggle), its content indented under.
class _ToggleParser extends NodeParser {
  @override
  String get id => ToggleBlockKeys.type;

  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final text = DeltaMarkdownEncoder().convert(node.delta ?? Delta());
    final kids = node.children.isEmpty || encoder == null
        ? ''
        : '\n${encoder.convertNodes(node.children.toList(), withIndent: true)}';
    return '- $text$kids${_suffix(node)}';
  }
}

/// 콜아웃 → Obsidian's callout `> [!note] …` (read back by [_QuoteParser]).
class _CalloutParser extends NodeParser {
  @override
  String get id => CalloutBlockKeys.type;

  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final text = DeltaMarkdownEncoder().convert(node.delta ?? Delta());
    final icon = node.attributes[CalloutBlockKeys.icon] as String? ?? '💡';
    final kind = switch (icon) {
      '⚠️' => 'warning',
      '✅' => 'success',
      '❗' => 'important',
      '📝' => 'note',
      _ => 'tip',
    };
    return '> [!$kind] ${text.replaceAll('\n', '\n> ')}${_suffix(node)}';
  }
}

class _MathParser extends NodeParser {
  @override
  String get id => MathBlockKeys.type;

  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final f = node.attributes[MathBlockKeys.formula] as String? ?? '';
    return '\$\$\n$f\n\$\$${_suffix(node)}';
  }
}

class _FileParser extends NodeParser {
  _FileParser(this.ctx);
  final MdExportContext ctx;

  @override
  String get id => 'file';

  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final id = assetIdFromUrl(node.attributes['url'] as String? ?? '');
    return '${_embed(id == null ? null : ctx.assetPath(id))}${_suffix(node)}';
  }
}

class _ImageParser extends NodeParser {
  _ImageParser(this.ctx);
  final MdExportContext ctx;

  @override
  String get id => ImageBlockKeys.type;

  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final url = node.attributes[ImageBlockKeys.url] as String? ?? '';
    final id = assetIdFromUrl(url);
    final text = id == null ? '![]($url)' : _embed(ctx.assetPath(id));
    return '$text${_suffix(node)}';
  }
}

class _LinkedPageParser extends NodeParser {
  _LinkedPageParser(this.id, this.key, this.ctx);

  @override
  final String id;
  final String key;
  final MdExportContext ctx;

  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final target = ctx.linkTarget(node.attributes[key] as String? ?? '');
    return '${target == null ? '' : '[[$target]]'}${_suffix(node)}';
  }
}

// ------------------------------------------------------------------ import

/// A parsed file before links and attachments are resolved.
class MdParsed {
  MdParsed(this.frontmatter, this.nodes);
  final Map<String, Object?> frontmatter;

  /// Unresolved: page links carry [wikiKey]; embeds and local images are
  /// image nodes with [embedScheme] / relative urls.
  final List<Node> nodes;
}

/// Delta attribute on text that came from `[[…]]` (value: the target).
const wikiKey = 'wiki';

/// Image url prefix for `![[…]]` embeds (value: the target, url-encoded).
const embedScheme = 'wiki-embed:';

MdParsed parseMarkdown(String text) {
  var body = text.startsWith('﻿') ? text.substring(1) : text;
  body = body.replaceAll('\r\n', '\n');
  final fm = <String, Object?>{};
  if (body.startsWith('---\n')) {
    final end = body.indexOf('\n---', 4);
    if (end > 0) {
      try {
        final y = loadYaml(body.substring(4, end));
        if (y is YamlMap) {
          for (final e in y.entries) {
            fm['${e.key}'] = _plain(e.value);
          }
        }
      } catch (_) {
        // Not YAML after all: keep it as text.
      }
      if (fm.isNotEmpty) {
        final next = body.indexOf('\n', end + 4);
        body = next < 0 ? '' : body.substring(next + 1);
      }
    }
  }
  Document parse(String text) => markdownToDocument(
    _preprocess(text),
    markdownParsers: [const _CodeParser(), const _QuoteParser()],
    inlineSyntaxes: [_WikiLinkSyntax()],
  );
  Document doc;
  try {
    doc = parse(body);
  } catch (_) {
    try {
      // The markdown package crashes on some footnotes ("[^1]"): keep
      // them as plain text.
      doc = parse(body.replaceAll('[^', r'\[^'));
    } catch (_) {
      // Still unreadable: one paragraph per line, nothing lost.
      return MdParsed(fm, [
        for (final line in body.split('\n')) paragraphNode(text: line),
      ]);
    }
  }
  return MdParsed(fm, [for (final n in doc.root.children) n.deepCopy()]);
}

Object? _plain(Object? v) => switch (v) {
  YamlList() => [for (final x in v) _plain(x)],
  YamlMap() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  _ => v,
};

/// Outside code fences: `$$ … $$` → a ```math fence, `![[x]]` → an image
/// with [embedScheme] (the stock parser then makes it its own block).
String _preprocess(String body) {
  final lines = body.split('\n');
  final out = <String>[];
  var inFence = false;
  var inMath = false;
  final embed = RegExp(r'!\[\[([^\]]+)\]\]');
  for (final line in lines) {
    final t = line.trim();
    if (!inMath && (t.startsWith('```') || t.startsWith('~~~'))) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    if (t == r'$$') {
      out.add(inMath ? '```' : '```math');
      inMath = !inMath;
      continue;
    }
    if (!inMath && t.startsWith(r'$$') && t.endsWith(r'$$') && t.length > 4) {
      out
        ..add('```math')
        ..add(t.substring(2, t.length - 2).trim())
        ..add('```');
      continue;
    }
    out.add(
      inMath
          ? line
          : _keepFootnotes(line).replaceAllMapped(
              embed,
              (m) =>
                  '\n\n![]($embedScheme${Uri.encodeComponent(m[1]!.split('|').first.trim())})\n\n',
            ),
    );
  }
  return out.join('\n');
}

/// Footnotes ("[^1]" and "[^1]: …") stay as written text: the markdown
/// package moves (or crashes on) footnote definitions, and their text was
/// lost. Inline code (`…`) is left alone (regexes like `[^0-9]`).
String _keepFootnotes(String line) {
  if (!line.contains('[^')) return line;
  final parts = line.split('`');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i].replaceAll('[^', r'\[^');
  }
  return parts.join('`');
}

/// `[[target]]`, `[[target|shown]]`, `[[target#heading]]`.
class _WikiLinkSyntax extends md.InlineSyntax {
  _WikiLinkSyntax()
    : super(r'\[\[([^\]\|#\n]+)(#[^\]\|\n]*)?(\|[^\]\n]+)?\]\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final target = match[1]!.trim();
    final shown = match[3]?.substring(1).trim();
    final el = md.Element('wiki', [md.Text(shown ?? target)]);
    el.attributes[wikiKey] = jsonEncode(target);
    parser.addNode(el);
    return true;
  }
}

/// `> …` with several paragraphs, lists or a table inside: one quote line
/// per paragraph, other blocks kept as they are (the stock parser glued
/// everything into one line).
class _QuoteParser extends CustomMarkdownParser {
  const _QuoteParser();

  @override
  List<Node> transform(
    md.Node element,
    List<CustomMarkdownParser> parsers, {
    MarkdownListType listType = MarkdownListType.unknown,
    int? startNumber,
  }) {
    if (element is! md.Element || element.tag != 'blockquote') return [];
    final out = <Node>[];
    // Obsidian callout: "> [!tip] text" → 콜아웃.
    final first = element.children?.firstOrNull;
    if (first is md.Element && first.tag == 'p') {
      final kind = RegExp(r'^\[!(\w+)\][+-]?\s*').firstMatch(first.textContent);
      if (kind != null) {
        final delta = DeltaMarkdownDecoder().convertNodes(first.children);
        final body = Delta()
          ..insert(delta.toPlainText().substring(kind[0]!.length).trim());
        final icon = switch (kind[1]!.toLowerCase()) {
          'warning' || 'caution' || 'danger' => '⚠️',
          'success' || 'check' || 'done' => '✅',
          'important' || 'bug' || 'error' => '❗',
          'note' || 'info' || 'abstract' => '📝',
          _ => '💡',
        };
        return [calloutNode(delta: body, icon: icon)];
      }
    }
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'p') {
        out.add(
          quoteNode(delta: DeltaMarkdownDecoder().convertNodes(child.children)),
        );
        continue;
      }
      for (final parser in parsers) {
        final nodes = parser.transform(child, parsers);
        if (nodes.isNotEmpty) {
          out.addAll(nodes);
          break;
        }
      }
    }
    return out;
  }
}

/// Fenced code (```lang) → code block; ```math → math block.
class _CodeParser extends CustomMarkdownParser {
  const _CodeParser();

  @override
  List<Node> transform(
    md.Node element,
    List<CustomMarkdownParser> parsers, {
    MarkdownListType listType = MarkdownListType.unknown,
    int? startNumber,
  }) {
    if (element is! md.Element || element.tag != 'pre') return [];
    final code = element.children?.whereType<md.Element>().firstOrNull;
    var text = code?.textContent ?? element.textContent;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    final cls = code?.attributes['class'] ?? '';
    final lang = cls.startsWith('language-') ? cls.substring(9) : '';
    if (lang == 'math') {
      return [
        Node(
          type: MathBlockKeys.type,
          attributes: {MathBlockKeys.formula: text},
        ),
      ];
    }
    return [codeNode(text: text, language: lang)];
  }
}

/// `[[kospi.csv]]`, `[[보고서.pdf]]`: a link to a file, not to a note
/// (note names may contain dots, e.g. "Isaac Sim 5.0 설치", so only a
/// short extension that isn't .md counts).
bool isFileTarget(String target) {
  final m = RegExp(r'\.([A-Za-z0-9]{1,5})$').firstMatch(target.trim());
  return m != null && m[1]!.toLowerCase() != 'md';
}

/// Replaces unresolved links and embeds (see [MdParsed]) using the
/// callbacks. [pageFor] returns the page a link points at, or null (the
/// text then stays as plain text); [embed] returns the node for an
/// attachment (image or file), or null to drop it. A link to a file
/// (`[[a.pdf]]`) keeps its text and gets the file attached after the line,
/// when [embed] finds it.
Future<List<Node>> resolveParsed(
  List<Node> nodes, {
  required Future<({String id, String title})?> Function(String target) pageFor,
  required Future<Node?> Function(String target, {required bool wiki}) embed,
  Future<Node?> Function(String target)? fileLink,
}) async {
  final out = <Node>[];
  for (final node in nodes) {
    final extra = <Node>[]; // files linked from this line
    if (node.type == ImageBlockKeys.type) {
      final url = node.attributes[ImageBlockKeys.url] as String? ?? '';
      final local = !url.contains('://') && !url.startsWith('data:');
      if (url.startsWith(embedScheme) || local) {
        final target = url.startsWith(embedScheme)
            ? Uri.decodeComponent(url.substring(embedScheme.length))
            : Uri.decodeFull(url);
        final wiki = url.startsWith(embedScheme);
        if (wiki && !isFileTarget(target)) {
          // ![[Note]] (a note, not a file): keep it as a link line.
          final page = await pageFor(target);
          out.add(
            page != null
                ? paragraphNode(delta: _linkDelta(page))
                : paragraphNode(text: target),
          );
          continue;
        }
        final replacement = await embed(target, wiki: wiki);
        if (replacement != null) out.add(replacement);
        continue;
      }
    }
    final delta = node.delta;
    if (delta != null &&
        delta.any(
          (op) =>
              op.attributes?[wikiKey] != null ||
              _mdLinkTarget(op.attributes?['href']) != null,
        )) {
      final d = Delta();
      for (final op in delta) {
        if (op is! TextInsert) continue;
        final attrs = op.attributes;
        final target =
            attrs?[wikiKey] as String? ?? _mdLinkTarget(attrs?['href']);
        if (target != null && isFileTarget(target)) {
          final file = fileLink == null ? null : await fileLink(target);
          if (file != null) extra.add(file);
          final rest = {...?attrs}..remove(wikiKey);
          d.insert(op.text, attributes: rest.isEmpty ? null : rest);
          continue;
        }
        final page = target == null ? null : await pageFor(target);
        if (page != null) {
          d.insert(
            pageLinkChar,
            attributes: {pageLinkKey: page.id, pageLinkTitleKey: page.title},
          );
        } else {
          final rest = attrs == null ? null : ({...attrs}..remove(wikiKey));
          d.insert(op.text, attributes: rest?.isEmpty ?? true ? null : rest);
        }
      }
      node.updateAttributes({'delta': d.toJson()});
    }
    final children = await resolveParsed(
      node.children.map((c) => c.deepCopy()).toList(),
      pageFor: pageFor,
      embed: embed,
      fileLink: fileLink,
    );
    out.add(
      Node(type: node.type, attributes: node.attributes, children: children),
    );
    out.addAll(extra);
  }
  return out;
}

Delta _linkDelta(({String id, String title}) page) => Delta()
  ..insert(
    pageLinkChar,
    attributes: {pageLinkKey: page.id, pageLinkTitleKey: page.title},
  );

/// `[text](other.md)` between notes counts as a page link.
String? _mdLinkTarget(Object? href) {
  if (href is! String || href.contains('://')) return null;
  final path = Uri.decodeFull(href.split('#').first);
  if (!path.toLowerCase().endsWith('.md')) return null;
  return path.substring(0, path.length - 3);
}
