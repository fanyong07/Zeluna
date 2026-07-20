import 'dart:async';
import 'dart:convert';

import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/tvbox_xbpq_hydrator.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('hydrates same-origin relative XBPQ JSON and caches success', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      expect(
        request.url,
        Uri.parse('https://rules.example/catalog/XBPQ/奇优.json'),
      );
      expect(request.followRedirects, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return http.Response(
        jsonEncode(_completeConfig()),
        200,
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    });
    final hydrator = TvBoxXbpqHydrator(client: client);
    addTearDown(hydrator.close);
    final source = _source(
      ext: './XBPQ/奇优.json',
      headers: const {
        'User-Agent': 'Catalog UA',
        'Referer': 'https://rules.example/',
      },
    );

    final results = await Future.wait([
      hydrator.hydrateSource(source),
      hydrator.hydrateSource(source),
    ]);

    expect(requestCount, 1);
    for (final result in results) {
      expect(result.sites, hasLength(1));
      expect(result.sites.single.status, TvBoxXbpqHydrationStatus.hydrated);
      expect(result.sites.single.hasExecutableRule, isTrue);
      expect(result.executableRules, hasLength(1));
      expect(result.executableRules.single.engine.toLowerCase(), 'xbpq');
      expect(
        result.executableRules.single.id,
        startsWith('catalog:source:xbpq:'),
      );
      expect(result.executableRules.single.groupId, 'catalog:source:xbpq');
      expect(
        result.executableRules.single.requestHeaders,
        containsPair('User-Agent', 'Rule UA'),
      );
      expect(
        result.executableRules.single.requestHeaders,
        containsPair('Referer', 'https://rules.example/'),
      );
      expect(
        result.executableRules.single.requestHeaders,
        containsPair('X-Site', '1'),
      );
      expect(
        result.executableRules.single.executionStatus,
        RuleExecutionStatus.executable,
      );
      expect(
        result.sites.single.resolvedUrl,
        Uri.parse('https://rules.example/catalog/XBPQ/奇优.json'),
      );
      final rawSite = result.executableRules.single.rawConfig['site'] as Map;
      expect(rawSite['ext'], isA<Map>());
    }
  });

  test(
    'limits one source to two remote requests and releases failed slots',
    () async {
      var activeRequests = 0;
      var peakRequests = 0;
      var requestCount = 0;
      final gates = <Completer<void>>[];
      final secondStarted = Completer<void>();
      final fourthStarted = Completer<void>();
      final sixthStarted = Completer<void>();
      final hydrator = TvBoxXbpqHydrator(
        client: MockClient((request) async {
          requestCount++;
          activeRequests++;
          if (activeRequests > peakRequests) peakRequests = activeRequests;
          final gate = Completer<void>();
          gates.add(gate);
          if (requestCount == 2) secondStarted.complete();
          if (requestCount == 4) fourthStarted.complete();
          if (requestCount == 6) sixthStarted.complete();
          try {
            await gate.future;
            if (request.url.path.endsWith('/remote-0.json')) {
              throw StateError('simulated network failure');
            }
            return http.Response(
              jsonEncode(_completeConfig()),
              200,
              headers: {'content-type': 'application/json'},
            );
          } finally {
            activeRequests--;
          }
        }),
      );
      addTearDown(hydrator.close);
      final hydration = hydrator.hydrateSource(
        _sourceWithSites([
          for (var index = 0; index < 6; index++)
            _site('remote-$index', './remote-$index.json'),
        ]),
      );

      await secondStarted.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requestCount, 2);
      expect(activeRequests, 2);
      expect(peakRequests, 2);

      gates[0].complete();
      gates[1].complete();
      await fourthStarted.future.timeout(const Duration(seconds: 1));
      expect(requestCount, 4);
      expect(activeRequests, 2);
      expect(peakRequests, 2);

      gates[2].complete();
      gates[3].complete();
      await sixthStarted.future.timeout(const Duration(seconds: 1));
      expect(requestCount, 6);
      expect(activeRequests, 2);
      expect(peakRequests, 2);

      gates[4].complete();
      gates[5].complete();
      final result = await hydration.timeout(const Duration(seconds: 1));

      expect(activeRequests, 0);
      expect(peakRequests, 2);
      expect(
        result.sites
            .where((site) => site.status == TvBoxXbpqHydrationStatus.hydrated)
            .length,
        5,
      );
      expect(
        result.sites
            .where(
              (site) => site.status == TvBoxXbpqHydrationStatus.fetchFailed,
            )
            .length,
        1,
      );
    },
  );

  test('uses catalog baseUrl when importUrl is empty', () async {
    var requestCount = 0;
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((request) async {
        requestCount++;
        expect(
          request.url,
          Uri.parse('https://rules.example/catalog/fallback.json'),
        );
        return http.Response(
          jsonEncode(_completeConfig()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(hydrator.close);

    final result = await hydrator.hydrateSource(
      _source(
        ext: './fallback.json',
        importUrl: '',
        catalogBaseUrl: 'https://rules.example/catalog/tvbox.json',
      ),
    );

    expect(requestCount, 1);
    expect(result.sites.single.status, TvBoxXbpqHydrationStatus.hydrated);
    expect(result.executableRules, hasLength(1));
  });

  test('keeps incomplete inline XBPQ installed but non-executable', () async {
    var requestCount = 0;
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((_) async {
        requestCount++;
        return http.Response('unexpected', 500);
      }),
    );
    addTearDown(hydrator.close);
    final source = _source(
      ext: {'分类url': 'https://media.example/{cateId}/{catePg}', '分类': r'动漫$1'},
    );

    final result = await hydrator.hydrateSource(source);

    expect(requestCount, 0);
    expect(
      result.sites.single.status,
      TvBoxXbpqHydrationStatus.inlineIncomplete,
    );
    expect(result.rules, hasLength(1));
    expect(
      result.rules.single.executionStatus,
      RuleExecutionStatus.missingConfig,
    );
    expect(result.executableRules, isEmpty);
  });

  test('rejects executable references in inline XBPQ config', () async {
    var requestCount = 0;
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((_) async {
        requestCount++;
        return http.Response('unexpected', 500);
      }),
    );
    addTearDown(hydrator.close);

    final result = await hydrator.hydrateSource(
      _source(ext: {..._completeConfig(), 'script': './evil.js'}),
    );

    expect(requestCount, 0);
    expect(
      result.sites.single.status,
      TvBoxXbpqHydrationStatus.rejectedReference,
    );
    expect(result.rules, hasLength(1));
    expect(result.executableRules, isEmpty);
  });

  test(
    'rejects cross-origin, traversal, scripts and JAR before request',
    () async {
      var requestCount = 0;
      final hydrator = TvBoxXbpqHydrator(
        client: MockClient((_) async {
          requestCount++;
          return http.Response(jsonEncode(_completeConfig()), 200);
        }),
      );
      addTearDown(hydrator.close);
      final source = _sourceWithSites([
        _site('cross-origin', 'https://evil.example/rule.json'),
        _site('authority', '//evil.example/rule.json'),
        _site('traversal', '../rule.json'),
        _site('script', './rule.js'),
        _site('jar', './spider.jar'),
      ]);

      final result = await hydrator.hydrateSource(source);

      expect(requestCount, 0);
      expect(result.sites, hasLength(5));
      expect(result.sites.map((site) => site.status).toSet(), {
        TvBoxXbpqHydrationStatus.rejectedReference,
      });
      expect(result.executableRules, isEmpty);
    },
  );

  test(
    'isolates malformed percent escapes without aborting other sites',
    () async {
      var requestCount = 0;
      final hydrator = TvBoxXbpqHydrator(
        client: MockClient((request) async {
          requestCount++;
          expect(request.url.path, '/catalog/good.json');
          return http.Response(
            jsonEncode(_completeConfig()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(hydrator.close);

      final result = await hydrator.hydrateSource(
        _sourceWithSites([
          _site('bad-percent', './bad%zz.json'),
          _site('good', './good.json'),
        ]),
      );

      expect(requestCount, 1);
      expect(result.sites, hasLength(2));
      expect(
        result.sites.first.status,
        TvBoxXbpqHydrationStatus.rejectedReference,
      );
      expect(result.sites.last.status, TvBoxXbpqHydrationStatus.hydrated);
      expect(result.executableRules, hasLength(1));
    },
  );

  test('rejects private catalog and private hydrated endpoints', () async {
    var privateCatalogRequests = 0;
    final privateCatalogHydrator = TvBoxXbpqHydrator(
      client: MockClient((_) async {
        privateCatalogRequests++;
        return http.Response(jsonEncode(_completeConfig()), 200);
      }),
    );
    addTearDown(privateCatalogHydrator.close);
    final privateCatalog = _source(
      importUrl: 'http://127.0.0.1/catalog/tvbox.json',
      ext: './rule.json',
    );

    final privateCatalogResult = await privateCatalogHydrator.hydrateSource(
      privateCatalog,
    );

    expect(privateCatalogRequests, 0);
    expect(
      privateCatalogResult.sites.single.status,
      TvBoxXbpqHydrationStatus.rejectedReference,
    );

    final privateEndpointHydrator = TvBoxXbpqHydrator(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(
            _completeConfig(
              baseUrl: 'http://192.168.1.20/',
              searchUrl: 'http://192.168.1.20/search?wd={wd}',
            ),
          ),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(privateEndpointHydrator.close);

    final privateEndpointResult = await privateEndpointHydrator.hydrateSource(
      _source(ext: './private.json'),
    );

    expect(
      privateEndpointResult.sites.single.status,
      TvBoxXbpqHydrationStatus.invalidConfig,
    );
    expect(privateEndpointResult.executableRules, isEmpty);
  });

  test('blocks disguised local literals and allows public IPv6', () async {
    var requestCount = 0;
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((request) async {
        requestCount++;
        expect(request.url.host, '2606:4700:4700::1111');
        return http.Response(
          jsonEncode(_completeConfig()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(hydrator.close);

    for (final catalogUrl in const [
      'http://2130706433/catalog/tvbox.json',
      'http://0x7f000001/catalog/tvbox.json',
      'http://0177.0.0.1/catalog/tvbox.json',
      'http://[0:0:0:0:0:0:0:1]/catalog/tvbox.json',
      'http://[::ffff:7f00:1]/catalog/tvbox.json',
      'http://[fe80::1%25eth0]/catalog/tvbox.json',
    ]) {
      final blocked = await hydrator.hydrateSource(
        _source(importUrl: catalogUrl, ext: './rule.json'),
      );
      expect(
        blocked.sites.single.status,
        TvBoxXbpqHydrationStatus.rejectedReference,
        reason: catalogUrl,
      );
    }
    expect(requestCount, 0);

    final publicIpv6 = await hydrator.hydrateSource(
      _source(
        importUrl: 'https://[2606:4700:4700::1111]/catalog/tvbox.json',
        ext: './rule.json',
      ),
    );

    expect(requestCount, 1);
    expect(publicIpv6.sites.single.status, TvBoxXbpqHydrationStatus.hydrated);
    expect(publicIpv6.executableRules, hasLength(1));
  });

  test(
    'rejects non-JSON, executable references and incomplete remote config',
    () async {
      final responses = <String, http.Response>{
        '/catalog/html.json': http.Response(
          '<html>not json</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
        '/catalog/script.json': http.Response(
          jsonEncode({..._completeConfig(), 'script': './evil.js'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
        '/catalog/incomplete.json': http.Response(
          jsonEncode({'分类': r'动漫$1'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      };
      final hydrator = TvBoxXbpqHydrator(
        client: MockClient((request) async => responses[request.url.path]!),
      );
      addTearDown(hydrator.close);

      final result = await hydrator.hydrateSource(
        _sourceWithSites([
          _site('html', './html.json'),
          _site('script', './script.json'),
          _site('incomplete', './incomplete.json'),
        ]),
      );

      expect(result.executableRules, isEmpty);
      expect(
        result.sites.map((site) => site.status),
        containsAll([
          TvBoxXbpqHydrationStatus.fetchFailed,
          TvBoxXbpqHydrationStatus.fetchFailed,
          TvBoxXbpqHydrationStatus.invalidConfig,
        ]),
      );
    },
  );

  test(
    'caches failures and isolates timeout and oversized responses',
    () async {
      var failureRequests = 0;
      final failureHydrator = TvBoxXbpqHydrator(
        client: MockClient((_) async {
          failureRequests++;
          return http.Response('unavailable', 503);
        }),
      );
      addTearDown(failureHydrator.close);
      final source = _source(ext: './offline.json');

      final firstFailure = await failureHydrator.hydrateSource(source);
      final secondFailure = await failureHydrator.hydrateSource(source);

      expect(failureRequests, 1);
      expect(
        firstFailure.sites.single.status,
        TvBoxXbpqHydrationStatus.fetchFailed,
      );
      expect(
        secondFailure.sites.single.status,
        TvBoxXbpqHydrationStatus.fetchFailed,
      );

      final timeoutHydrator = TvBoxXbpqHydrator(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response(
            jsonEncode(_completeConfig()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(milliseconds: 5),
      );
      addTearDown(timeoutHydrator.close);
      final timeoutResult = await timeoutHydrator.hydrateSource(
        _source(ext: './timeout.json'),
      );
      expect(timeoutResult.sites.single.message, contains('超时'));
      expect(timeoutResult.executableRules, isEmpty);

      final oversizedHydrator = TvBoxXbpqHydrator(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(_completeConfig()),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        maxFileBytes: 32,
      );
      addTearDown(oversizedHydrator.close);
      final oversizedResult = await oversizedHydrator.hydrateSource(
        _source(ext: './large.json'),
      );
      expect(oversizedResult.sites.single.message, contains('读取上限'));
      expect(oversizedResult.executableRules, isEmpty);
    },
  );

  test('does not follow redirects', () async {
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example/rule.json'},
        );
      }),
    );
    addTearDown(hydrator.close);

    final result = await hydrator.hydrateSource(
      _source(ext: './redirect.json'),
    );

    expect(result.sites.single.status, TvBoxXbpqHydrationStatus.fetchFailed);
    expect(result.sites.single.message, contains('重定向'));
    expect(result.executableRules, isEmpty);
  });
}

VideoSource _source({
  required Object ext,
  String importUrl = 'https://rules.example/catalog/tvbox.json',
  String? catalogBaseUrl,
  Map<String, String> headers = const {},
}) {
  return _sourceWithSites(
    [_site('anime', ext)],
    importUrl: importUrl,
    catalogBaseUrl: catalogBaseUrl,
    headers: headers,
  );
}

VideoSource _sourceWithSites(
  List<Map<String, dynamic>> sites, {
  String importUrl = 'https://rules.example/catalog/tvbox.json',
  String? catalogBaseUrl,
  Map<String, String> headers = const {},
}) {
  return VideoSource(
    id: 'source:xbpq',
    name: '测试 XBPQ',
    kind: VideoSourceKind.tvBox,
    importUrl: importUrl,
    baseUrl: catalogBaseUrl ?? importUrl,
    headers: headers,
    rawConfig: {'sites': sites},
  );
}

Map<String, dynamic> _site(String key, Object ext) => {
  'key': key,
  'name': '$key 动漫',
  'type': 3,
  'api': 'csp_XBPQ',
  'searchable': 1,
  'ext': ext,
};

Map<String, dynamic> _completeConfig({
  String baseUrl = 'https://media.example/',
  String searchUrl = 'https://media.example/search?wd={wd}',
}) => {
  '请求头': {'User-Agent': 'Rule UA', 'X-Site': '1'},
  '主页url': baseUrl,
  '搜索url': searchUrl,
  '搜索数组': '<div&&</div>',
  '搜索标题': 'title="&&"',
  '搜索链接': 'href="&&"',
  '播放数组': '<section&&</section>',
  '播放列表': '<a&&/a>',
  '播放标题': '>&&<',
  '播放链接': 'href="&&"',
};
