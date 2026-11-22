/// A search box query with Obsidian-style operators
/// (docs/rea/obsidian.md 4): `title:`, `content:`, `path:`, `task:`,
/// `task-todo:`, `task-done:`. Values with spaces go in quotes:
/// `path:"여행 계획"`. Everything else is plain words (all must match).
class SearchQuery {
  SearchQuery._();

  final words = <String>[];
  final titles = <String>[];
  final contents = <String>[];
  final paths = <String>[];

  /// `task:` terms; `checked` null = any to-do, true/false = done / not done.
  final tasks = <({String text, bool? checked})>[];

  bool get isEmpty =>
      words.isEmpty &&
      titles.isEmpty &&
      contents.isEmpty &&
      paths.isEmpty &&
      tasks.isEmpty;

  /// Only plain words: the search box's usual title-first search.
  bool get isPlain =>
      titles.isEmpty && contents.isEmpty && paths.isEmpty && tasks.isEmpty;

  /// Terms that have to appear in the page's text.
  Iterable<String> get bodyTerms => [
    ...contents,
    for (final t in tasks)
      if (t.text.isNotEmpty) t.text,
  ];

  static final _part = RegExp(r'(?:([a-z-]+):)?(?:"([^"]*)"|(\S+))');

  static SearchQuery parse(String input) {
    final q = SearchQuery._();
    for (final m in _part.allMatches(input)) {
      final op = m[1];
      final value = (m[2] ?? m[3] ?? '').trim().toLowerCase();
      switch (op) {
        case 'title' || 'file':
          if (value.isNotEmpty) q.titles.add(value);
        case 'content' || 'line' || 'block':
          if (value.isNotEmpty) q.contents.add(value);
        case 'path':
          if (value.isNotEmpty) q.paths.add(value);
        case 'task':
          q.tasks.add((text: value, checked: null));
        case 'task-todo':
          q.tasks.add((text: value, checked: false));
        case 'task-done':
          q.tasks.add((text: value, checked: true));
        case null:
          if (value.isNotEmpty) q.words.add(value);
        default:
          // Unknown "x:" — just words.
          q.words.add('$op:$value');
      }
    }
    return q;
  }
}
