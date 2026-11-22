/// "2일차" before "10일차": numbers inside compare as numbers, the rest
/// as text (case-insensitive, like a file explorer).
int naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final x = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final y = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final nx = int.tryParse(x[i]);
    final ny = int.tryParse(y[i]);
    final c = nx != null && ny != null
        ? nx.compareTo(ny)
        : x[i].compareTo(y[i]);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}
