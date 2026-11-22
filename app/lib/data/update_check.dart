import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Where new versions are published (GitHub Releases).
const releaseRepo = 'bloodmoon3929/damda';

/// A newer release than the running app.
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.pageUrl,
    this.downloadUrl,
  });

  /// e.g. `1.0.23`.
  final String version;

  /// The release page (notes and every file).
  final String pageUrl;

  /// This device's installer from that release, if there is one.
  final String? downloadUrl;
}

/// Asks GitHub for the latest release and returns it when it is newer
/// than [current] (`1.0.22`). Errors (offline, rate limit…) mean "no
/// update": this must never get in the way.
Future<AppUpdate?> checkForUpdate(String current, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(
          Uri.parse(
            'https://api.github.com/repos/$releaseRepo/releases/latest',
          ),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'damda-update-check',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String? ?? '').replaceFirst(
      RegExp('^v'),
      '',
    );
    if (compareVersions(tag, current) <= 0) return null;
    final assets = [
      for (final a in json['assets'] as List? ?? const [])
        if (a is Map) a,
    ];
    final suffix = installerSuffix();
    final asset = suffix == null
        ? null
        : assets.where((a) => '${a['name']}'.endsWith(suffix)).firstOrNull;
    return AppUpdate(
      version: tag,
      pageUrl:
          json['html_url'] as String? ??
          'https://github.com/$releaseRepo/releases/latest',
      downloadUrl: asset?['browser_download_url'] as String?,
    );
  } catch (e) {
    debugPrint('update check failed: $e');
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// The end of this platform's release file name (see the release workflow).
String? installerSuffix() {
  if (kIsWeb) return null;
  if (Platform.isAndroid) return '-android-arm64.apk';
  if (Platform.isWindows) return '-windows.zip';
  if (Platform.isMacOS) return '-macos.zip';
  if (Platform.isLinux) return '-linux-x64.tar.gz';
  return null;
}

/// Compares dotted versions number by number (`1.0.10` > `1.0.9`); a
/// build suffix (`+23`) is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split('+').first.split('.')) int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}
