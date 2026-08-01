import 'dart:convert';

import 'package:anime/src/rules/rule_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'raw URL importer does not prefilter file names or cloud-drive hosts',
    () async {
      var requestCount = 0;
      final importer = RuleImporter(
        client: MockClient((_) async {
          requestCount++;
          return http.Response.bytes(
            utf8.encode(_safeRuleJson),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      for (final extension in const ['jar', 'js', 'py', 'apk', 'zip']) {
        final bundle = await importer.importFromUrl(
          'https://raw.githubusercontent.com/example/rules/main/file.$extension?raw=1',
        );
        expect(bundle.rules, hasLength(1));
      }
      final cloudBundle = await importer.importFromUrl(
        'https://pan.quark.cn/s/example',
      );
      expect(cloudBundle.rules, hasLength(1));

      expect(requestCount, 6);
    },
  );

  test('raw URL importer accepts a small UTF-8 JSON rule', () async {
    final importer = RuleImporter(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['Accept'], contains('application/json'));
        return http.Response(
          _safeRuleJson,
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final bundle = await importer.importFromUrl(
      'https://raw.githubusercontent.com/example/rules/main/safe.json',
    );

    expect(bundle.rules, hasLength(1));
    expect(bundle.rules.single.name, '安全测试源');
  });

  test('rule import redirects cannot escape to a private address', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        '',
        302,
        headers: {'location': 'http://169.254.169.254/latest/meta-data'},
      );
    });
    final importer = RuleImporter(client: client);
    addTearDown(client.close);

    await expectLater(
      importer.importFromUrl('https://rules.example/start.json'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Private or special-purpose'),
        ),
      ),
    );
    expect(requests, 1);
  });

  test(
    'declared content length is rejected before reading response body',
    () async {
      var bodyListened = false;
      final importer = RuleImporter(
        maxFileBytes: 64,
        client: _StreamClient((_) async {
          final stream = Stream<List<int>>.multi((controller) {
            bodyListened = true;
            controller.add(utf8.encode(_safeRuleJson));
            controller.close();
          });
          return http.StreamedResponse(
            stream,
            200,
            headers: {
              'content-type': 'application/json',
              'content-length': '65',
            },
          );
        }),
      );

      await expectLater(
        importer.importFromUrl('https://example.com/rules.json'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('64 B'),
          ),
        ),
      );
      expect(bodyListened, isFalse);
    },
  );

  test(
    'streamed response is stopped when actual body exceeds the limit',
    () async {
      var deliveredChunks = 0;
      final importer = RuleImporter(
        maxFileBytes: 64,
        client: _StreamClient((_) async {
          final stream = Stream<List<int>>.multi((controller) {
            for (final chunk in [
              List<int>.filled(40, 0x20),
              List<int>.filled(30, 0x20),
              List<int>.filled(30, 0x20),
            ]) {
              deliveredChunks++;
              controller.add(chunk);
            }
            controller.close();
          });
          return http.StreamedResponse(
            stream,
            200,
            headers: {'content-type': 'text/plain'},
          );
        }),
      );

      await expectLater(
        importer.importFromUrl('https://example.com/rules.txt'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('64 B'),
          ),
        ),
      );
      expect(deliveredChunks, greaterThanOrEqualTo(2));
    },
  );

  test(
    'raw URL importer rejects binary MIME types and binary text bodies',
    () async {
      final binaryMimeImporter = RuleImporter(
        client: MockClient(
          (_) async => http.Response(
            'binary',
            200,
            headers: {
              'content-type': 'application/vnd.android.package-archive',
            },
          ),
        ),
      );
      await expectLater(
        binaryMimeImporter.importFromUrl('https://example.com/rules.json'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('内容类型'),
          ),
        ),
      );

      final binaryBodyImporter = RuleImporter(
        client: MockClient(
          (_) async => http.Response.bytes(
            [0x7b, 0x00, 0x7d],
            200,
            headers: {'content-type': 'text/plain'},
          ),
        ),
      );
      await expectLater(
        binaryBodyImporter.importFromUrl('https://example.com/rules.txt'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('二进制'),
          ),
        ),
      );
    },
  );

  test('rule importer preserves download protocols in raw config', () {
    const importer = RuleImporter();
    for (final link in const [
      'magnet:?xt=urn:btih:example',
      'ed2k://|file|example.mp4|123|hash|/',
      'thunder://example',
    ]) {
      final bundle = importer.importFromText(_ruleWithExtraLink(link));
      expect(
        (bundle.rules.single.rawConfig['resourceLinks'] as List).single,
        link,
      );
    }
  });

  test('rule importer preserves common cloud-drive share indexes', () {
    const importer = RuleImporter();
    for (final link in const [
      'https://www.alipan.com/s/example',
      'https://www.aliyundrive.com/s/example',
      'https://pan.quark.cn/s/example',
      'https://pan.baidu.com/s/example',
      'https://mypikpak.com/s/example',
    ]) {
      final bundle = importer.importFromText(_ruleWithExtraLink(link));
      expect(
        (bundle.rules.single.rawConfig['resourceLinks'] as List).single,
        link,
      );
    }
  });

  test('rule importer keeps multi-repository root aliases', () {
    const importer = RuleImporter();
    for (final key in const ['repositories', 'storeHouse', 'docks']) {
      final bundle = importer.importFromText(
        jsonEncode({
          key: [
            {'name': '递归仓库', 'url': 'https://example.com/store.json'},
          ],
        }),
      );
      expect(bundle.rules.single.engine, 'repository-link');
    }
  });

  test('rule importer accepts common lax TVBox JSON syntax', () {
    const importer = RuleImporter();
    final bundle = importer.importFromText('''
      \uFEFF// repository note
      {
        /* TVBox clients commonly allow comments and trailing commas. */
        "sites": [
          {
            "key": "json-api",
            "name": "TVBox
API",
            "type": 1,
            "api": "https://example.com/api.php/provide/vod/",
          },
        ],
      }
    ''');

    expect(bundle.rules, hasLength(3));
    expect(bundle.rules.first.engine, 'tvbox-json-api');
    expect(bundle.rules.first.baseUrl, contains('https://example.com/'));
  });
}

String _ruleWithExtraLink(String link) => jsonEncode({
  'name': '不安全规则',
  'baseUrl': 'https://example.com',
  'searchUrl': 'https://example.com/search?q=@keyword',
  'chapterRoads': '//ul',
  'chapterResult': '//a',
  'resourceLinks': [link],
});

const _safeRuleJson = '''
{
  "name": "安全测试仓库",
  "rules": [
    {
      "id": "safe-test",
      "name": "安全测试源",
      "engine": "native",
      "baseUrl": "https://example.com",
      "searchUrl": "https://example.com/search?q=@keyword",
      "chapterRoads": "//ul",
      "chapterResult": "//a"
    }
  ]
}
''';

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return handler(request);
  }
}
