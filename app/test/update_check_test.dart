import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notes/data/update_check.dart';

void main() {
  test('versions compare number by number', () {
    expect(compareVersions('1.0.10', '1.0.9'), 1);
    expect(compareVersions('1.0.22', '1.0.22+23'), 0);
    expect(compareVersions('1.1', '1.0.99'), 1);
    expect(compareVersions('1.0.21', '1.0.22'), -1);
  });

  test(
    'a newer release is reported with its page; older or errors are not',
    () async {
      MockClient answer(String tag, {int status = 200}) => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'tag_name': tag,
            'html_url': 'https://github.com/x/damda/releases/tag/$tag',
            'assets': [
              {
                'name': 'damda-1.0.23-windows.zip',
                'browser_download_url': 'https://example.com/w.zip',
              },
            ],
          }),
          status,
        ),
      );
      final update = await checkForUpdate('1.0.22', client: answer('v1.0.23'));
      expect(update?.version, '1.0.23');
      expect(update?.pageUrl, endsWith('/v1.0.23'));
      expect(await checkForUpdate('1.0.23', client: answer('v1.0.23')), isNull);
      expect(
        await checkForUpdate('1.0.22', client: answer('v1.0.23', status: 404)),
        isNull,
      );
    },
  );
}
