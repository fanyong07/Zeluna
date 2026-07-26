import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:anime/src/rules/drpy_runtime.dart';
import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUpAll(() async {
    if (!Platform.isWindows) return;
    final dllUri = await _resolveJsfDllUri();
    DynamicLibrary.open(File.fromUri(dllUri).path);
  });

  test(
    'procedural drpy resolves episode through the synchronous HTTP broker',
    () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        expect(request.method, 'GET');
        expect(request.url.path, '/search');
        expect(request.url.queryParameters['wd'], 'Qing Yu Nian');
        expect(request.headers['X-Base'], 'base');
        expect(request.headers['X-Rule'], 'yes');
        expect(request.headers['User-Agent'], 'drpy-test');
        return http.Response(
          jsonEncode({
            'list': [
              {'vod_id': '/detail/qing', 'vod_name': 'Qing Yu Nian'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final runtime = _testRuntime(
        limits: const DrpyRuntimeLimits(
          javascriptTimeout: Duration(seconds: 3),
          networkTimeout: Duration(seconds: 3),
          overallTimeout: Duration(seconds: 10),
        ),
      );

      final result = await runtime.resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:procedural',
          keyword: 'Qing Yu Nian',
          episodeNumber: 2,
          episodeTitle: '',
          ruleSource: _proceduralRule,
          requestHeaders: {'X-Base': 'base'},
        ),
        client: client,
      );

      expect('${result.error}|${result.logs}', 'null|[]');
      expect(result.candidates, hasLength(1));
      expect(result.candidates.single.lineName, 'direct');
      expect(result.candidates.single.episodeName, 'episode 2');
      expect(result.candidates.single.url, 'https://media.example.com/2.m3u8');
      expect(
        result.candidates.single.headers['Referer'],
        'https://example.com/',
      );
      expect(result.candidates.single.requiresSniffing, isFalse);
      expect(requestCount, 1);
      expect(runtime.storage.snapshot('inline:procedural')['seen'], 1);

      await runtime.resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:procedural',
          keyword: 'Qing Yu Nian',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _proceduralRule,
          requestHeaders: {'X-Base': 'base'},
        ),
        client: client,
      );
      await runtime.resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:other',
          keyword: 'Qing Yu Nian',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _proceduralRule,
          requestHeaders: {'X-Base': 'base'},
        ),
        client: client,
      );
      expect(runtime.storage.snapshot('inline:procedural')['seen'], 2);
      expect(runtime.storage.snapshot('inline:other')['seen'], 1);
    },
  );

  test(
    'literal synthetic-DNS IP is rejected before the HTTP client is called',
    () async {
      var clientCalled = false;
      final client = MockClient((request) async {
        clientCalled = true;
        return http.Response('{}', 200);
      });

      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:private',
          keyword: 'test',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _privateNetworkRule,
        ),
        client: client,
      );

      expect(result.candidates, isEmpty);
      expect(result.error, contains('private-network'));
      expect(clientCalled, isFalse);
    },
  );

  test(
    'IPv4-mapped IPv6 private and metadata addresses are rejected',
    () async {
      for (final rawUrl in const <String>[
        'http://[::ffff:127.0.0.1]/video.mp4',
        'http://[::ffff:10.0.0.1]/video.mp4',
        'http://[::ffff:169.254.169.254]/latest/meta-data',
      ]) {
        await expectLater(
          ensurePublicDrpyHttpUri(Uri.parse(rawUrl)),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('private-network'),
            ),
          ),
        );
      }

      await expectLater(
        ensurePublicDrpyHttpUri(Uri.parse('http://198.51.99.1/video.mp4')),
        completes,
      );
    },
  );

  test(
    'base credentials stay on the bound content origin and never load the script',
    () async {
      final visited = <String>[];
      final client = MockClient((request) async {
        visited.add('${request.url.host}${request.url.path}');
        expect(_headerValue(request, 'X-General'), 'compatible');
        switch ('${request.url.host}${request.url.path}') {
          case 'example.com/rule.js':
            expect(_headerValue(request, 'Cookie'), isNull);
            expect(_headerValue(request, 'Authorization'), isNull);
            expect(_headerValue(request, 'X-Api-Key'), isNull);
            return http.Response(
              _credentialOriginRule,
              200,
              headers: const {'content-type': 'text/javascript'},
            );
          case 'example.org/collect':
            expect(_headerValue(request, 'Cookie'), isNull);
            expect(_headerValue(request, 'Authorization'), isNull);
            expect(_headerValue(request, 'X-Api-Key'), isNull);
            return http.Response('{}', 200);
          case 'example.com/search':
            expect(_headerValue(request, 'Cookie'), 'session=private');
            expect(_headerValue(request, 'Authorization'), 'Bearer private');
            expect(_headerValue(request, 'X-Api-Key'), 'private-api-key');
            return http.Response(
              '',
              302,
              headers: const {'location': 'https://example.net/search-result'},
            );
          case 'example.net/search-result':
            expect(_headerValue(request, 'Cookie'), isNull);
            expect(_headerValue(request, 'Authorization'), isNull);
            expect(_headerValue(request, 'X-Api-Key'), isNull);
            return http.Response(
              jsonEncode({
                'list': [
                  {'vod_id': 'credential-show', 'vod_name': 'Credential Show'},
                ],
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          default:
            return http.Response('not found', 404);
        }
      });

      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'remote:credential-origin',
          keyword: 'Credential Show',
          episodeNumber: 1,
          episodeTitle: '',
          ruleUrl: 'https://example.com/rule.js',
          credentialOrigin: 'https://example.com/content/',
          requestHeaders: {
            'X-General': 'compatible',
            'Cookie': 'session=private',
            'Authorization': 'Bearer private',
            'X-Api-Key': 'private-api-key',
          },
        ),
        client: client,
      );

      expect('${result.error}|${result.logs}', 'null|[]');
      expect(result.candidates.single.url, 'https://media.example.com/1.mp4');
      expect(visited, [
        'example.com/rule.js',
        'example.org/collect',
        'example.com/search',
        'example.net/search-result',
      ]);
    },
  );

  test('GBK response bodies are decoded for procedural rules', () async {
    final client = MockClient((request) async {
      return http.Response.bytes(
        gbk.encode(
          jsonEncode({
            'list': [
              {'vod_id': '/detail/1', 'vod_name': '测试片'},
            ],
          }),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=gb2312'},
      );
    });

    final result = await _testRuntime().resolve(
      const DrpyRuntimeRequest(
        ruleId: 'inline:gbk',
        keyword: '测试片',
        episodeNumber: 1,
        episodeTitle: '',
        ruleSource: _gbkRule,
      ),
      client: client,
    );

    expect('${result.error}|${result.logs}', 'null|[]');
    expect(result.candidates.single.url, 'https://media.example.com/cn.mp4');
  });

  test(
    'malformed selector rules fail explicitly instead of being playable',
    () async {
      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:selector',
          keyword: 'test',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _selectorRule,
        ),
        client: MockClient((request) async => http.Response('', 200)),
      );

      expect(result.candidates, isEmpty);
      expect(result.error, contains('Declarative search must have 5 or 6'));
    },
  );

  test(
    'declarative HTML search reuses first, filters rows and resolves detail wildcard through lazy',
    () async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        switch (request.url.path) {
          case '/search':
            expect(request.url.queryParameters['wd'], 'Target Show');
            return http.Response(
              _declarativeSearchHtml,
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            );
          case '/detail/target':
            return http.Response(
              '<html><video src="/media/target.mp4"></video></html>',
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            );
          default:
            return http.Response('not found', 404);
        }
      });

      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:declarative-html',
          keyword: 'Target Show',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _declarativeHtmlRule,
        ),
        client: client,
      );

      expect('${result.error}|${result.logs}', 'null|[]');
      expect(result.candidates, hasLength(1));
      expect(result.candidates.single.lineName, 'direct');
      expect(result.candidates.single.episodeName, '正片');
      expect(
        result.candidates.single.url,
        'https://example.com/media/target.mp4',
      );
      expect(result.candidates.single.requiresSniffing, isFalse);
      expect(requests, ['/search', '/detail/target']);
    },
  );

  test(
    'declarative JSON search uses safe dot and numeric paths with field inheritance',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/json-search');
        return http.Response(
          jsonEncode({
            'response': [
              null,
              null,
              null,
              {
                'docs': [
                  {
                    'meta': [
                      {'title': 'JSON Show'},
                    ],
                    'images': ['/poster.jpg'],
                    'note': 'updated',
                    'id': 'json-42',
                  },
                ],
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:declarative-json',
          keyword: 'JSON Show',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _declarativeJsonRule,
        ),
        client: client,
      );

      expect('${result.error}|${result.logs}', 'null|[]');
      expect(result.candidates, hasLength(1));
      expect(
        result.candidates.single.url,
        'https://media.example.com/json.mp4',
      );
    },
  );

  test('static detail object parses bounded tabs and episode lists', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/search':
          return http.Response(
            '<section class="results"><article><h2>Static Show</h2>'
            '<a href="/detail/static"></a></article></section>',
            200,
            headers: const {'content-type': 'text/html; charset=utf-8'},
          );
        case '/detail/static':
          return http.Response(
            _staticDetailHtml,
            200,
            headers: const {'content-type': 'text/html; charset=utf-8'},
          );
        default:
          return http.Response('not found', 404);
      }
    });

    final result = await _testRuntime().resolve(
      const DrpyRuntimeRequest(
        ruleId: 'inline:static-detail',
        keyword: 'Static Show',
        episodeNumber: 2,
        episodeTitle: '',
        ruleSource: _staticDetailRule,
      ),
      client: client,
    );

    expect('${result.error}|${result.logs}', 'null|[]');
    expect(result.candidates, hasLength(2));
    expect(result.candidates.map((value) => value.lineName), [
      'Line A',
      'Line B',
    ]);
    expect(result.candidates.map((value) => value.episodeName), [
      'Episode 2',
      'Episode 2',
    ]);
    expect(result.candidates.map((value) => value.url), [
      'https://example.com/media/a2.mp4',
      'https://example.com/media/b2.mp4',
    ]);
  });

  test(
    'procedural bodies allow HTML helpers but still reject CryptoJS',
    () async {
      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:missing-helpers',
          keyword: 'test',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _missingHelperRule,
        ),
        client: MockClient((request) async => http.Response('', 200)),
      );

      expect(result.candidates, isEmpty);
      expect(result.error, contains('Unsupported helper APIs'));
      expect(result.error, contains('CryptoJS'));
      expect(result.error, isNot(contains('pdfh')));
    },
  );

  test(
    'jsp and global HTML helpers parse chained CSS, eq and URL fallbacks',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/search');
        expect(request.url.queryParameters['q'], 'Target Show');
        return http.Response(
          _selectorSearchHtml,
          200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
        );
      });

      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'inline:selector-helpers',
          keyword: 'Target Show',
          episodeNumber: 1,
          episodeTitle: '',
          ruleSource: _selectorHelperRule,
        ),
        client: client,
      );

      expect(
        '${result.error}|${result.logs}',
        'null|[https://example.com/posters/target.jpg]',
      );
      expect(result.candidates, hasLength(1));
      expect(
        result.candidates.single.url,
        'https://media.example.com/target.mp4',
      );
    },
  );

  test(
    'live catalog smoke gets past supported Tencent HTML helpers',
    () async {
      final result = await _testRuntime().resolve(
        const DrpyRuntimeRequest(
          ruleId: 'catalog:drpy:tencent',
          keyword: '庆余年',
          episodeNumber: 1,
          episodeTitle: '',
          ruleUrl:
              'https://raw.githubusercontent.com/gaotianliuyun/gao/master/js/%E8%85%BE%E4%BA%91%E9%A9%BE%E9%9B%BE.js',
        ),
      );

      final error = result.error ?? '';
      expect(error, isNot(contains('Unsupported helper APIs: pdfa')));
      expect(error, isNot(contains('Unsupported helper APIs: pdfh')));
      expect(error, isNot(contains('Unsupported helper APIs: pd')));
    },
    skip: Platform.environment['DRPY_LIVE_SMOKE'] != '1',
  );
}

Future<Uri> _resolveJsfDllUri() async {
  try {
    final packageUri = await Isolate.resolvePackageUri(
      Uri.parse('package:jsf/jsf.dart'),
    );
    if (packageUri != null) return packageUri.resolve('../windows/jsf.dll');
  } on UnsupportedError {
    // The Flutter test runner does not expose package URI resolution on every
    // host, so fall back to the same package configuration it compiled with.
  }
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config = jsonDecode(await configFile.readAsString()) as Map;
  final packages = config['packages'] as List? ?? const [];
  final jsf = packages.whereType<Map>().firstWhere(
    (entry) => entry['name'] == 'jsf',
    orElse: () => throw StateError('Unable to locate jsf in package_config.'),
  );
  final rootUri = configFile.uri.resolve(jsf['rootUri'].toString());
  final directoryUri = rootUri.path.endsWith('/')
      ? rootUri
      : rootUri.replace(path: '${rootUri.path}/');
  return directoryUri.resolve('windows/jsf.dll');
}

DrpyRuntime _testRuntime({
  DrpyRuntimeLimits limits = const DrpyRuntimeLimits(),
}) => DrpyRuntime(limits: limits, addressLookup: _publicTestAddressLookup);

Future<List<InternetAddress>> _publicTestAddressLookup(String host) async =>
    <InternetAddress>[InternetAddress('93.184.216.34')];

String? _headerValue(http.BaseRequest request, String name) {
  final normalized = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == normalized) return entry.value;
  }
  return null;
}

const _proceduralRule = r'''
var rule = {
  title: 'Inline procedural rule',
  host: 'https://example.com',
  headers: {'User-Agent': 'drpy-test'},
  ['\u641c\u7d22']: $js.toString(() => {
    const data = JSON.parse(request(
      'https://example.com/search?wd=' + encodeURIComponent(KEY),
      {headers: {'X-Rule': 'yes'}}
    ));
    setItem('seen', Number(getItem('seen', 0)) + 1);
    VODS = data.list;
  }),
  ['\u4e8c\u7ea7']: $js.toString(() => {
    VOD = {
      vod_id: input,
      vod_name: 'Qing Yu Nian',
      vod_play_from: 'direct',
      vod_play_url:
        'episode 1$https://media.example.com/1.m3u8#' +
        'episode 2$https://media.example.com/2.m3u8'
    };
  }),
  lazy: $js.toString(() => {
    input = {
      parse: 0,
      url: input,
      header: {Referer: 'https://example.com/'}
    };
  })
};
''';

const _privateNetworkRule = r'''
var rule = {
  host: 'https://example.com',
  ['\u641c\u7d22']: $js.toString(() => {
    request('http://198.18.0.1/private');
    VODS = [];
  }),
  ['\u4e8c\u7ea7']: $js.toString(() => { VOD = {}; })
};
''';

const _credentialOriginRule = r'''
var rule = {
  host: 'https://example.com',
  ['\u9884\u5904\u7406']: $js.toString(() => {
    request('https://example.org/collect');
  }),
  ['\u641c\u7d22']: $js.toString(() => {
    VODS = JSON.parse(request('https://example.com/search')).list;
  }),
  ['\u4e8c\u7ea7']: $js.toString(() => {
    VOD = {
      vod_play_from: 'direct',
      vod_play_url: 'episode 1$https://media.example.com/1.mp4'
    };
  })
};
''';

const _gbkRule = r'''
var rule = {
  host: 'https://example.com',
  encoding: 'gbk',
  ['\u641c\u7d22']: $js.toString(() => {
    VODS = JSON.parse(request('https://example.com/search')).list;
  }),
  ['\u4e8c\u7ea7']: $js.toString(() => {
    VOD = {
      vod_play_from: 'direct',
      vod_play_url: 'episode 1$https://media.example.com/cn.mp4'
    };
  })
};
''';

const _selectorRule = r'''
var rule = {
  host: 'https://example.com',
  ['\u641c\u7d22']: '.item;h3&&Text;a&&href',
  ['\u4e8c\u7ea7']: '*'
};
''';

const _declarativeSearchHtml = r'''
<!doctype html>
<html><body><section class="results">
  <article><h2>Advertisement</h2><a href="/detail/ad"></a></article>
  <article>
    <h2>Other Show</h2><img data-src="/other.jpg">
    <span class="remark">old</span><a href="/detail/other"></a>
  </article>
  <article>
    <h2>Target Show</h2><img data-src="/target.jpg">
    <span class="remark">new</span><a href="/detail/target"></a>
  </article>
  <article><h2>Excluded Show</h2><a href="/detail/excluded"></a></article>
</section></body></html>
''';

const _declarativeHtmlRule = r'''
var rule = {
  host: 'https://example.com',
  searchUrl: '/search?wd=**',
  ['\u4e00\u7ea7']:
    '.results&&article:gt(0):lt(2);h2&&Text;img&&data-src;.remark&&Text;a&&href;',
  ['\u641c\u7d22']: '*',
  ['\u4e8c\u7ea7']: '*',
  lazy: 'js:' +
    'const page=request(input);' +
    'input={parse:0,url:pd(page,"video&&src",input)};'
};
''';

const _declarativeJsonRule = r'''
var rule = {
  host: 'https://example.com',
  searchUrl: '/json-search?wd=**',
  detailUrl: '/detail/fyid',
  ['\u4e00\u7ea7']:
    'json:response.0.docs;meta[0].title;images.0;note;id;',
  ['\u641c\u7d22']: 'json:response.3.docs;*;*;*;*;*',
  ['\u4e8c\u7ea7']: '*',
  lazy: 'js:input={parse:0,url:"https://media.example.com/json.mp4"};'
};
''';

const _staticDetailHtml = r'''
<!doctype html><html><body>
  <h1>Static Show</h1>
  <ul class="tabs"><li>Line A</li><li>Line B</li></ul>
  <ul class="playlist">
    <li><a href="/media/a1.mp4">Episode 1</a></li>
    <li><a href="/media/a2.mp4">Episode 2</a></li>
  </ul>
  <ul class="playlist">
    <li><a href="/media/b1.mp4">Episode 1</a></li>
    <li><a href="/media/b2.mp4">Episode 2</a></li>
  </ul>
</body></html>
''';

const _staticDetailRule = r'''
var rule = {
  host: 'https://example.com',
  searchUrl: '/search?wd=**',
  ['\u641c\u7d22']: '.results&&article;h2&&Text;;;a&&href',
  ['\u4e8c\u7ea7']: {
    title: 'h1&&Text',
    tabs: '.tabs&&li',
    lists: '.playlist:eq(#id)&&li'
  }
};
''';

const _missingHelperRule = r'''
var rule = {
  host: 'https://example.com',
  ['\u641c\u7d22']: 'js:let title=jsp.pdfh(input,"body&&Text");let hash=CryptoJS.MD5(title);VODS=[];',
  ['\u4e8c\u7ea7']: 'js:VOD={};'
};
''';

const _selectorSearchHtml = r'''
<!doctype html>
<html>
  <body>
    <article class="result_item_v">
      <h2 class="result_title"><a href="/detail/other">Other Show</a></h2>
      <div class="description"><b>Other</b> description</div>
      <img class="figure_pic" src="/posters/other.jpg">
    </article>
    <article class="result_item_v">
      <h2 class="result_title"><a href="/detail/target">Target Show</a></h2>
      <div class="description"><b>Target</b> description</div>
      <img class="figure_pic" src="/posters/target.jpg">
    </article>
  </body>
</html>
''';

const _selectorHelperRule = r'''
var rule = {
  host: 'https://example.com',
  searchUrl: '/search?q=**',
  ['\u641c\u7d22']: 'js:' +
    'let all=jsp.pdfa(request(input),"body&&.result_item_v");' +
    'if(all.length!==2){throw new Error("pdfa array mismatch")};' +
    'let selected=pdfa(request(input),"body&&.result_item_v:eq(1)")[0];' +
    'let title=jsp.pdfh(selected,".result_title&&Text");' +
    'let body=pdfh(selected,".description&&Html");' +
    'if(body.indexOf("<b>Target</b>")<0){throw new Error("Html mismatch")};' +
    'let url=pdfh(selected,".result_title&&a&&data-missing||href");' +
    'let image=pd(selected,".figure_pic&&data-src||src");' +
    'if(pdfh(request(input),"body&&Text").indexOf(title)<0){throw new Error("Text mismatch")};' +
    'log(image);setResult([{title:title,url:url,img:image}]);',
  ['\u4e8c\u7ea7']: 'js:VOD={' +
    'vod_name:"Target Show",vod_play_from:"direct",' +
    'vod_play_url:"episode 1$https://media.example.com/target.mp4"};'
};
''';
