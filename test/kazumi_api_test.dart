import 'package:anime/src/rules/kazumi_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'API capabilities reject private credentials and unsupported methods',
    () {
      for (final request in [
        {'method': 'POST', 'url': 'https://example.com/search'},
        {
          'url': 'https://example.com/search',
          'headers': {'Authorization': 'fixture'},
        },
        {'url': 'https://user:fixture@example.com/search'},
        {
          'url': 'https://example.com/search',
          'body': {'script': 'fixture'},
        },
      ]) {
        expect(supportsKazumiApi({'request': request}), isFalse);
      }
    },
  );
  test('API interpolation encodes path and query exactly once', () {
    final uri = kazumiApiUri(
      {
        'request': {
          'url': 'https://example.com/@source',
          'query': {'wd': '@keyword'},
        },
      },
      {'source': 'a/b', 'keyword': '败犬 & test'},
    );
    expect(uri.pathSegments, ['a/b']);
    expect(uri.queryParameters['wd'], '败犬 & test');
  });
  test('JSON selection is bounded and rejects executable selectors', () {
    final data = {
      'list': List.generate(2000, (i) => {'id': i}),
    };
    expect(kazumiJsonNodes(data, r'$.list[*].id'), hasLength(1000));
    expect(kazumiJsonValue(data, r'$.list[0].id'), '0');
    expect(kazumiJsonNodes(data, r'$.list[?(@.id > 1)]'), isEmpty);
    expect(kazumiJsonNodes(data, r'$..id'), isEmpty);
  });
}
