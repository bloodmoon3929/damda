// Fractional indexing: string sort keys that always leave room in between,
// so inserting or moving one item never rewrites its siblings' keys.
// Keys are base-62 fractions in (0, 1) that never end in '0'.
// Port of the midpoint algorithm from David Greenspan's `fractional-indexing`.

const _digits =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Returns a key strictly between [a] and [b]. `null` means open-ended.
String keyBetween(String? a, String? b) {
  if (a != null && b != null && a.compareTo(b) >= 0) {
    throw ArgumentError('$a >= $b');
  }
  return _midpoint(a ?? '', b);
}

/// Returns [count] increasing keys strictly between [a] and [b].
List<String> keysBetween(String? a, String? b, int count) {
  final keys = <String>[];
  var lo = a;
  for (var i = 0; i < count; i++) {
    lo = keyBetween(lo, b);
    keys.add(lo);
  }
  return keys;
}

String _midpoint(String a, String? b) {
  if (b != null) {
    var n = 0;
    while (n < b.length && (n < a.length ? a[n] : '0') == b[n]) {
      n++;
    }
    if (n > 0) {
      return b.substring(0, n) +
          _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
    }
  }
  final digitA = a.isEmpty ? 0 : _digits.indexOf(a[0]);
  final digitB = b == null ? _digits.length : _digits.indexOf(b[0]);
  if (digitB - digitA > 1) {
    return _digits[((digitA + digitB) / 2).round()];
  }
  if (b != null && b.length > 1) {
    return b.substring(0, 1);
  }
  return _digits[digitA] + _midpoint(a.isEmpty ? '' : a.substring(1), null);
}

/// Assigns sort keys to an ordered list of items, reusing as many existing
/// keys as possible (the longest increasing run) so only moved/new items
/// get new keys. [existing] holds each item's previous key or null.
List<String> rebalanceKeys(List<String?> existing) {
  final keep = _longestIncreasing(existing);
  final result = List<String?>.from(existing);
  for (var i = 0; i < result.length; i++) {
    if (!keep.contains(i)) result[i] = null;
  }
  var i = 0;
  while (i < result.length) {
    if (result[i] != null) {
      i++;
      continue;
    }
    var j = i;
    while (j < result.length && result[j] == null) {
      j++;
    }
    final lo = i > 0 ? result[i - 1] : null;
    final hi = j < result.length ? result[j] : null;
    final fresh = keysBetween(lo, hi, j - i);
    for (var k = 0; k < fresh.length; k++) {
      result[i + k] = fresh[k];
    }
    i = j;
  }
  return result.cast<String>();
}

/// Indices of a longest strictly increasing subsequence of the non-null keys.
Set<int> _longestIncreasing(List<String?> keys) {
  final tails = <int>[]; // index into keys of the smallest tail per length
  final prev = List<int>.filled(keys.length, -1);
  for (var i = 0; i < keys.length; i++) {
    final key = keys[i];
    if (key == null) continue;
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keys[tails[mid]]!.compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final result = <int>{};
  var k = tails.isEmpty ? -1 : tails.last;
  while (k >= 0) {
    result.add(k);
    k = prev[k];
  }
  return result;
}
