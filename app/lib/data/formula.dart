/// Notion-style formula property: a small expression language.
///
///   prop("비용") * 1.1            arithmetic: + - * / %, parentheses
///   prop("이름") + " 님"          + joins text when either side is text
///   if(prop("완료"), "끝", "진행") comparisons: == != > < >= <=, and/or/not
///   round(x, 2) abs(x) min(a, b, ..) max(..) sum(..) length(s)
///   contains(s, "a") empty(x) concat(a, b, ..) today()
///   dateAdd(d, 3, "days") dateBetween(a, b, "days") year(d) month(d) day(d)
///   weekday(d)   — dates are "yyyy-MM-dd" text, so a formula can be a date
///   lookup("날짜 설정", "여행 시작일", "1일차 날짜") — a value from another
///   database (by its name, the item's name, the property's name)
///
/// [evaluateFormula] never throws; errors come back as [FormulaError].
library;

import 'dart:math' as math;

class FormulaError {
  const FormulaError(this.message);
  final String message;

  @override
  String toString() => '오류: $message';
}

/// Looks up `prop("name")` values; returns num, String, bool or null.
typedef PropLookup = Object? Function(String name);

/// Looks up `lookup("database", "item", "property")` in another database.
typedef ExternalLookup = Object? Function(
  String database,
  String item,
  String property,
);

/// Names of the databases [source] reads with `lookup(...)`.
Set<String> lookedUpDatabases(String source) => {
  for (final m in RegExp(r'lookup\(\s*"([^"]*)"').allMatches(source)) m[1]!,
};

Object? evaluateFormula(
  String source,
  PropLookup lookup, {
  ExternalLookup? external,
}) {
  if (source.trim().isEmpty) return null;
  try {
    final parser = _Parser(_tokenize(source), lookup, external);
    final value = parser.parseExpression();
    if (!parser.atEnd) throw const FormulaError('식이 끝나지 않았어요');
    return value;
  } on FormulaError catch (e) {
    return e;
  } catch (e) {
    return FormulaError('$e');
  }
}

/// Display form of a formula result.
String formatFormulaValue(Object? v) => switch (v) {
  null => '',
  FormulaError() => '$v',
  bool b => b ? '✓' : '✗',
  double d when d == d.roundToDouble() && d.abs() < 1e15 => '${d.toInt()}',
  double d => d.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), ''),
  _ => '$v',
};

// ---------------------------------------------------------------- lexer ----

enum _T { num, str, ident, op, lparen, rparen, comma, dot }

class _Tok {
  const _Tok(this.type, this.text);
  final _T type;
  final String text;
}

List<_Tok> _tokenize(String s) {
  final out = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c.trim().isEmpty) {
      i++;
    } else if (c == '.' &&
        !(i + 1 < s.length && RegExp(r'[0-9]').hasMatch(s[i + 1]))) {
      // `prop("x").length()`: a method call (Notion formula 2.0).
      out.add(const _Tok(_T.dot, '.'));
      i++;
    } else if (RegExp(r'[0-9.]').hasMatch(c)) {
      final m = RegExp(r'[0-9]*\.?[0-9]+').matchAsPrefix(s, i)!;
      out.add(_Tok(_T.num, m[0]!));
      i = m.end;
    } else if (c == '"' || c == "'") {
      final end = s.indexOf(c, i + 1);
      if (end < 0) throw const FormulaError('따옴표가 닫히지 않았어요');
      out.add(_Tok(_T.str, s.substring(i + 1, end)));
      i = end + 1;
    } else if (RegExp(r'[A-Za-z_가-힣]').hasMatch(c)) {
      final m = RegExp(r'[A-Za-z_가-힣][A-Za-z0-9_가-힣]*').matchAsPrefix(s, i)!;
      out.add(_Tok(_T.ident, m[0]!));
      i = m.end;
    } else if (c == '(') {
      out.add(const _Tok(_T.lparen, '('));
      i++;
    } else if (c == ')') {
      out.add(const _Tok(_T.rparen, ')'));
      i++;
    } else if (c == ',') {
      out.add(const _Tok(_T.comma, ','));
      i++;
    } else {
      final two = i + 1 < s.length ? s.substring(i, i + 2) : '';
      if (const ['==', '!=', '>=', '<=', '&&', '||'].contains(two)) {
        out.add(_Tok(_T.op, two));
        i += 2;
      } else if ('+-*/%<>!'.contains(c)) {
        out.add(_Tok(_T.op, c));
        i++;
      } else {
        throw FormulaError('알 수 없는 문자 "$c"');
      }
    }
  }
  return out;
}

// --------------------------------------------------------------- parser ----

class _Parser {
  _Parser(this.tokens, this.lookup, this.external);

  final List<_Tok> tokens;
  final PropLookup lookup;
  final ExternalLookup? external;
  var _i = 0;

  /// Names bound by `let` / `lets`, innermost last.
  final _scopes = <Map<String, Object?>>[];

  bool get atEnd => _i >= tokens.length;
  _Tok? get _peek => atEnd ? null : tokens[_i];

  bool _isOp(String op) =>
      _peek != null &&
      ((_peek!.type == _T.op && _peek!.text == op) ||
          (_peek!.type == _T.ident && _peek!.text == op));

  _Tok _expect(_T type, String what) {
    final t = _peek;
    if (t == null || t.type != type) throw FormulaError('$what 필요해요');
    _i++;
    return t;
  }

  Object? parseExpression() => _or();

  Object? _or() {
    var left = _and();
    while (_isOp('||') || _isOp('or')) {
      _i++;
      final right = _and();
      left = _truthy(left) || _truthy(right);
    }
    return left;
  }

  Object? _and() {
    var left = _compare();
    while (_isOp('&&') || _isOp('and')) {
      _i++;
      final right = _compare();
      left = _truthy(left) && _truthy(right);
    }
    return left;
  }

  Object? _compare() {
    final left = _sum();
    for (final op in const ['==', '!=', '>=', '<=', '>', '<']) {
      if (_isOp(op)) {
        _i++;
        final right = _sum();
        if (op == '==') return _eq(left, right);
        if (op == '!=') return !_eq(left, right);
        final c = _cmp(left, right);
        return switch (op) {
          '>' => c > 0,
          '<' => c < 0,
          '>=' => c >= 0,
          _ => c <= 0,
        };
      }
    }
    return left;
  }

  Object? _sum() {
    var left = _product();
    while (_isOp('+') || _isOp('-')) {
      final op = tokens[_i++].text;
      final right = _product();
      if (op == '+' && (left is String || right is String)) {
        left = '${formatFormulaValue(left)}${formatFormulaValue(right)}';
      } else {
        final a = _num(left), b = _num(right);
        left = op == '+' ? a + b : a - b;
      }
    }
    return left;
  }

  Object? _product() {
    var left = _unary();
    while (_isOp('*') || _isOp('/') || _isOp('%')) {
      final op = tokens[_i++].text;
      final a = _num(left), b = _num(_unary());
      if (op != '*' && b == 0) throw const FormulaError('0으로 나눌 수 없어요');
      left = switch (op) {
        '*' => a * b,
        '/' => a / b,
        _ => a % b,
      };
    }
    return left;
  }

  Object? _unary() {
    if (_isOp('-')) {
      _i++;
      return -_num(_unary());
    }
    if (_isOp('!') || _isOp('not')) {
      _i++;
      return !_truthy(_unary());
    }
    return _postfix(_primary());
  }

  /// `value.name(args)` is `name(value, args)`.
  Object? _postfix(Object? value) {
    while (_peek?.type == _T.dot) {
      _i++;
      final name = _expect(_T.ident, '"." 뒤에 함수 이름이').text;
      value = _call(name, receiver: (value,));
    }
    return value;
  }

  Object? _primary() {
    final t = _peek;
    if (t == null) throw const FormulaError('값이 필요해요');
    _i++;
    switch (t.type) {
      case _T.num:
        return double.parse(t.text);
      case _T.str:
        return t.text;
      case _T.lparen:
        final v = parseExpression();
        _expect(_T.rparen, '")"가');
        return v;
      case _T.ident:
        if (t.text == 'true') return true;
        if (t.text == 'false') return false;
        if (_peek?.type != _T.lparen) {
          // A name from `let`.
          for (final scope in _scopes.reversed) {
            if (scope.containsKey(t.text)) return scope[t.text];
          }
          throw FormulaError('"${t.text}"는 정의되지 않았어요 (let으로 정하거나 함수라면 "(" 필요)');
        }
        return _call(t.text);
      default:
        throw FormulaError('"${t.text}"는 여기 올 수 없어요');
    }
  }

  /// Moves past one argument without evaluating it (an untaken branch may
  /// not be computable, e.g. adding days to an empty date).
  void _skipExpression() {
    var depth = 0;
    while (!atEnd) {
      final t = _peek!;
      if (depth == 0 && (t.type == _T.comma || t.type == _T.rparen)) return;
      if (t.type == _T.lparen) depth++;
      if (t.type == _T.rparen) depth--;
      _i++;
    }
  }

  Object? _call(String name, {(Object?,)? receiver}) {
    _expect(_T.lparen, '"$name" 뒤에 "("가');
    // let(name, value, body) / lets(a, 1, b, 2, body) (formula 2.0).
    if (receiver == null && (name == 'let' || name == 'lets')) {
      final scope = <String, Object?>{};
      _scopes.add(scope);
      try {
        while (true) {
          // A name followed by "," and a value, or the body.
          final isBinding =
              _peek?.type == _T.ident &&
              _i + 1 < tokens.length &&
              tokens[_i + 1].type == _T.comma;
          if (!isBinding) break;
          final varName = tokens[_i].text;
          _i += 2;
          scope[varName] = parseExpression();
          _expect(_T.comma, '값 뒤에 ","가');
          if (name == 'let') break;
        }
        final body = parseExpression();
        _expect(_T.rparen, '")"가');
        return body;
      } finally {
        _scopes.removeLast();
      }
    }
    // if(cond, a, b) / ifs(c1, v1, c2, v2, …, else): only the chosen
    // branch is evaluated.
    if (name == 'if' || name == 'ifs') {
      Object? result;
      var decided = false;
      while (true) {
        if (decided) {
          _skipExpression();
        } else {
          final first = parseExpression();
          if (_peek?.type != _T.comma) {
            // The last argument: the "else" value.
            result = first;
            decided = true;
            break;
          }
          _i++;
          if (_truthy(first)) {
            result = parseExpression();
            decided = true;
          } else {
            _skipExpression();
          }
        }
        if (_peek?.type != _T.comma) break;
        _i++;
      }
      _expect(_T.rparen, '")"가');
      return result;
    }
    final args = <Object?>[?receiver?.$1];
    if (receiver != null && receiver.$1 == null) args.add(null);
    if (_peek?.type != _T.rparen) {
      args.add(parseExpression());
      while (_peek?.type == _T.comma) {
        _i++;
        args.add(parseExpression());
      }
    }
    _expect(_T.rparen, '")"가');
    Object? arg(int i) => i < args.length ? args[i] : null;
    switch (name) {
      case 'prop':
        final v = arg(0);
        if (v is! String) throw const FormulaError('prop("이름") 형태로 써 주세요');
        final value = lookup(v);
        if (value is FormulaError) throw value;
        return value;
      case 'lookup':
        final (db, item, prop) = (arg(0), arg(1), arg(2));
        if (db is! String || item is! String || prop is! String) {
          throw const FormulaError('lookup("데이터베이스", "항목 이름", "속성") 형태로 써 주세요');
        }
        final ext = external;
        if (ext == null) {
          throw const FormulaError('다른 데이터베이스를 아직 읽지 못했어요');
        }
        final value = ext(db, item, prop);
        if (value is FormulaError) throw value;
        return value;
      case 'round':
        final digits = args.length > 1 ? _num(arg(1)).toInt() : 0;
        final f = _pow10(digits);
        return (_num(arg(0)) * f).roundToDouble() / f;
      case 'abs':
        return _num(arg(0)).abs();
      case 'min' || 'max' || 'sum':
        final nums = args.map(_num).toList();
        if (nums.isEmpty) return null;
        return switch (name) {
          'min' => nums.reduce((a, b) => a < b ? a : b),
          'max' => nums.reduce((a, b) => a > b ? a : b),
          _ => nums.fold<double>(0, (a, b) => a + b),
        };
      case 'length':
        return formatFormulaValue(arg(0)).length.toDouble();
      case 'contains':
        return formatFormulaValue(arg(0)).contains(formatFormulaValue(arg(1)));
      case 'empty':
        final v = arg(0);
        return v == null || (v is String && v.isEmpty);
      case 'and':
        return args.every(_truthy);
      case 'or':
        return args.any(_truthy);
      case 'not':
        return !_truthy(arg(0));
      case 'replaceAll' || 'replace':
        final re = _regex(arg(1));
        final text = formatFormulaValue(arg(0));
        final to = formatFormulaValue(arg(2));
        return name == 'replace'
            ? text.replaceFirst(re, to)
            : text.replaceAll(re, to);
      case 'test':
        return _regex(arg(1)).hasMatch(formatFormulaValue(arg(0)));
      case 'toNumber':
        final v = arg(0);
        if (v is num) return v.toDouble();
        final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(formatFormulaValue(v));
        return m == null ? null : double.parse(m[0]!);
      case 'format':
        return formatFormulaValue(arg(0));
      case 'lower':
        return formatFormulaValue(arg(0)).toLowerCase();
      case 'upper':
        return formatFormulaValue(arg(0)).toUpperCase();
      case 'dateSubtract':
        final d = _date(arg(0));
        final n = -_num(arg(1)).round();
        final unit = formatFormulaValue(arg(2)).isEmpty
            ? 'days'
            : formatFormulaValue(arg(2));
        return _fmtDate(switch (unit) {
          'days' || 'day' || '일' => DateTime(d.year, d.month, d.day + n),
          'weeks' || 'week' || '주' => DateTime(d.year, d.month, d.day + 7 * n),
          'months' ||
          'month' ||
          '개월' ||
          '월' => DateTime(d.year, d.month + n, d.day),
          'years' || 'year' || '년' => DateTime(d.year + n, d.month, d.day),
          _ => throw FormulaError(
            '단위 "$unit"는 없어요 (days, weeks, months, years)',
          ),
        });
      case 'concat':
        return args.map(formatFormulaValue).join();
      case 'dateAdd':
        final d = _date(arg(0));
        final n = _num(arg(1)).round();
        final unit = formatFormulaValue(arg(2)).isEmpty
            ? 'days'
            : formatFormulaValue(arg(2));
        return _fmtDate(switch (unit) {
          'days' || 'day' || '일' => DateTime(d.year, d.month, d.day + n),
          'weeks' || 'week' || '주' => DateTime(d.year, d.month, d.day + 7 * n),
          'months' ||
          'month' ||
          '개월' ||
          '월' => DateTime(d.year, d.month + n, d.day),
          'years' || 'year' || '년' => DateTime(d.year + n, d.month, d.day),
          _ => throw FormulaError(
            '단위 "$unit"는 없어요 (days, weeks, months, years)',
          ),
        });
      case 'dateBetween':
        final a = _date(arg(0)), b = _date(arg(1));
        final unit = formatFormulaValue(arg(2)).isEmpty
            ? 'days'
            : formatFormulaValue(arg(2));
        final days = a.difference(b).inDays;
        return switch (unit) {
          'days' || 'day' || '일' => days.toDouble(),
          'weeks' || 'week' || '주' => (days ~/ 7).toDouble(),
          'months' ||
          'month' ||
          '개월' ||
          '월' => ((a.year - b.year) * 12 + a.month - b.month).toDouble(),
          'years' || 'year' || '년' => (a.year - b.year).toDouble(),
          _ => throw FormulaError(
            '단위 "$unit"는 없어요 (days, weeks, months, years)',
          ),
        };
      case 'year':
        return _date(arg(0)).year.toDouble();
      case 'month':
        return _date(arg(0)).month.toDouble();
      case 'day':
        return _date(arg(0)).day.toDouble();
      case 'weekday':
        // 1 = 월요일 … 7 = 일요일
        return _date(arg(0)).weekday.toDouble();
      case 'today':
        final n = DateTime.now();
        return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
            '${n.day.toString().padLeft(2, '0')}';
      case 'floor':
        return _num(arg(0)).floorToDouble();
      case 'ceil':
        return _num(arg(0)).ceilToDouble();
      case 'sqrt':
        return math.sqrt(_num(arg(0)));
      case 'pow':
        return math.pow(_num(arg(0)), _num(arg(1))).toDouble();
      case 'exp':
        return math.exp(_num(arg(0)));
      case 'ln':
        return math.log(_num(arg(0)));
      case 'log10':
        return math.log(_num(arg(0))) / math.ln10;
      case 'log2':
        return math.log(_num(arg(0))) / math.ln2;
      case 'sign':
        return _num(arg(0)).sign;
      case 'mod':
        final b = _num(arg(1));
        if (b == 0) throw const FormulaError('0으로 나눌 수 없어요');
        return _num(arg(0)) % b;
      case 'mean' || 'average':
        final nums = args.map(_num).toList();
        if (nums.isEmpty) return null;
        return nums.fold<double>(0, (a, b) => a + b) / nums.length;
      case 'median':
        final nums = args.map(_num).toList()..sort();
        if (nums.isEmpty) return null;
        final mid = nums.length ~/ 2;
        return nums.length.isOdd ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
      case 'trim':
        return formatFormulaValue(arg(0)).trim();
      case 'substring' || 'slice':
        final text = formatFormulaValue(arg(0));
        final from = _num(arg(1)).toInt().clamp(0, text.length);
        final to = args.length > 2
            ? _num(arg(2)).toInt().clamp(from, text.length)
            : text.length;
        return text.substring(from, to);
      case 'startsWith':
        return formatFormulaValue(arg(0))
            .startsWith(formatFormulaValue(arg(1)));
      case 'endsWith':
        return formatFormulaValue(arg(0)).endsWith(formatFormulaValue(arg(1)));
      case 'repeat':
        return formatFormulaValue(arg(0)) * _num(arg(1)).toInt().clamp(0, 1000);
      case 'padStart' || 'padEnd':
        final text = formatFormulaValue(arg(0));
        final width = _num(arg(1)).toInt();
        final pad = args.length > 2 ? formatFormulaValue(arg(2)) : ' ';
        return name == 'padStart'
            ? text.padLeft(width, pad)
            : text.padRight(width, pad);
      case 'match':
        return _regex(arg(1)).firstMatch(formatFormulaValue(arg(0)))?[0] ?? '';
      case 'toString':
        return formatFormulaValue(arg(0));
      case 'now':
        final n = DateTime.now();
        return '${_fmtDate(n)} ${n.hour.toString().padLeft(2, '0')}:'
            '${n.minute.toString().padLeft(2, '0')}';
      case 'formatDate':
        final d = _date(arg(0));
        var f = args.length > 1 ? formatFormulaValue(arg(1)) : 'YYYY-MM-DD';
        const days = ['월', '화', '수', '목', '금', '토', '일'];
        f = f
            .replaceAll('YYYY', '${d.year}')
            .replaceAll('MM', d.month.toString().padLeft(2, '0'))
            .replaceAll('DD', d.day.toString().padLeft(2, '0'))
            .replaceAll('M', '${d.month}')
            .replaceAll('D', '${d.day}')
            .replaceAll('ddd', days[d.weekday - 1]);
        return f;
      case 'date':
        return _date(arg(0)).day.toDouble();
      default:
        throw FormulaError('"$name" 함수는 없어요');
    }
  }

  static RegExp _regex(Object? pattern) {
    try {
      return RegExp(formatFormulaValue(pattern));
    } on FormatException {
      throw FormulaError('정규식이 올바르지 않아요: ${formatFormulaValue(pattern)}');
    }
  }

  static DateTime _date(Object? v) {
    final s = formatFormulaValue(v);
    final d = s.length >= 10 ? DateTime.tryParse(s.substring(0, 10)) : null;
    if (d == null) throw FormulaError('"$s"는 날짜가 아니에요 (예: 2027-01-18)');
    return d;
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static double _pow10(int n) {
    var r = 1.0;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }

  static double _num(Object? v) => switch (v) {
    null => 0,
    num n => n.toDouble(),
    bool b => b ? 1 : 0,
    String s =>
      double.tryParse(s.replaceAll(',', '')) ??
          (throw FormulaError('"$s"는 숫자가 아니에요')),
    _ => throw FormulaError('숫자가 아니에요'),
  };

  static bool _truthy(Object? v) => switch (v) {
    null => false,
    bool b => b,
    num n => n != 0,
    String s => s.isNotEmpty,
    _ => true,
  };

  static bool _eq(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return formatFormulaValue(a) == formatFormulaValue(b);
  }

  static int _cmp(Object? a, Object? b) {
    if ((a is num || a == null) && (b is num || b == null)) {
      return _num(a).compareTo(_num(b));
    }
    return formatFormulaValue(a).compareTo(formatFormulaValue(b));
  }
}
