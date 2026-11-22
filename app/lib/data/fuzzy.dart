/// Fuzzy title matching, ported from Obsidian's quick switcher
/// (`prepareFuzzySearch`, docs/rea/obsidian.md 1.11).
///
/// The query is split into tokens at spaces and punctuation; every Korean
/// (or other CJK) character and every punctuation mark is a token of its
/// own. The tokens are looked up in order; if that fails, the query
/// without spaces is matched letter by letter. Scores are at most 0, and
/// higher is better: few separate pieces, pieces starting at a word, a
/// tight span, an early first match and a short target win.
library;

class FuzzyMatch {
  const FuzzyMatch(this.score, this.ranges);

  final double score;

  /// Matched `[start, end)` character ranges in the target.
  final List<(int, int)> ranges;
}

FuzzyMatch? fuzzyMatch(String query, String target) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const FuzzyMatch(0, []);
  final t = target.toLowerCase();
  final ranges =
      _byTokens(_tokens(q), t) ?? _byLetters(q.replaceAll(' ', ''), t);
  if (ranges == null || ranges.isEmpty) return null;
  return FuzzyMatch(
    _score(ranges, target, q.replaceAll(' ', '').length),
    ranges,
  );
}

/// The [items] whose title matches [query], best first (stable for equal scores).
List<T> fuzzySort<T>(
  String query,
  Iterable<T> items,
  String Function(T) titleOf,
) {
  final scored = <(T, double, int)>[];
  var i = 0;
  for (final item in items) {
    final m = fuzzyMatch(query, titleOf(item));
    if (m != null) scored.add((item, m.score, i));
    i++;
  }
  scored.sort((a, b) {
    final c = b.$2.compareTo(a.$2);
    return c != 0 ? c : a.$3.compareTo(b.$3);
  });
  return [for (final s in scored) s.$1];
}

bool _isCjk(int c) =>
    (c >= 0xAC00 && c <= 0xD7A3) || // Hangul syllables
    (c >= 0x1100 && c <= 0x11FF) ||
    (c >= 0x3130 && c <= 0x318F) || // Hangul jamo
    (c >= 0x3040 && c <= 0x30FF) || // kana
    (c >= 0x4E00 && c <= 0x9FFF); // CJK ideographs

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c > 0x7F && !_isCjk(c);

List<String> _tokens(String q) {
  final out = <String>[];
  final word = StringBuffer();
  void flush() {
    if (word.isNotEmpty) out.add(word.toString());
    word.clear();
  }

  for (final c in q.runes) {
    if (c == 0x20) {
      flush();
    } else if (_isWordChar(c)) {
      word.writeCharCode(c);
    } else {
      flush();
      out.add(String.fromCharCode(c));
    }
  }
  flush();
  return out;
}

List<(int, int)>? _byTokens(List<String> tokens, String t) {
  final ranges = <(int, int)>[];
  var from = 0;
  for (final token in tokens) {
    final at = t.indexOf(token, from);
    if (at < 0) return null;
    ranges.add((at, at + token.length));
    from = at + token.length;
  }
  return _merge(ranges);
}

List<(int, int)>? _byLetters(String q, String t) {
  final ranges = <(int, int)>[];
  var from = 0;
  for (var i = 0; i < q.length; i++) {
    final at = t.indexOf(q[i], from);
    if (at < 0) return null;
    ranges.add((at, at + 1));
    from = at + 1;
  }
  return _merge(ranges);
}

List<(int, int)> _merge(List<(int, int)> ranges) {
  final out = <(int, int)>[];
  for (final r in ranges) {
    if (out.isNotEmpty && out.last.$2 == r.$1) {
      out[out.length - 1] = (out.last.$1, r.$2);
    } else {
      out.add(r);
    }
  }
  return out;
}

bool _wordStart(String s, int i) {
  if (i == 0) return true;
  final c = s.codeUnitAt(i), before = s.codeUnitAt(i - 1);
  if (_isCjk(c) || !_isWordChar(before)) return true;
  // camelCase
  final upper = c >= 0x41 && c <= 0x5A;
  final lowerBefore = before >= 0x61 && before <= 0x7A;
  return upper && lowerBefore;
}

double _score(List<(int, int)> ranges, String target, int queryLength) {
  final notAtWord = ranges.where((r) => !_wordStart(target, r.$1)).length;
  final span = ranges.last.$2 - ranges.first.$1;
  return -(ranges.length - 1) -
      notAtWord / 10 -
      (span - queryLength) / 100 -
      ranges.first.$1 / 1000 -
      target.length / 10000;
}
