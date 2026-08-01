import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/drpy_runtime.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUpAll(_preloadJsfForWindowsTests);

  test('TVBox drpy entries resolve relative and mirrored script URLs', () {
    const importer = RuleImporter();
    final bundle = importer.importFromText(
      jsonEncode({
        'sites': [
          {
            'key': 'relative',
            'name': 'Relative drpy',
            'type': 3,
            'api': './lib/drpy2.min.js',
            'ext': './js/source.js',
          },
          {
            'key': 'mirror',
            'name': 'Mirror drpy',
            'type': 3,
            'api': 'https://notabug.org/fantaiying/ext/raw/main/drpy2.min.js',
            'ext':
                'https://gh-proxy.net/https://raw.githubusercontent.com/fantaiying7/EXT/refs/heads/main/demo.js',
          },
        ],
      }),
      sourceUrl: 'https://example.com/config/box.json',
    );

    expect(bundle.rules, hasLength(6));
    expect(bundle.rules.every((rule) => rule.engine == 'drpy-js'), isTrue);
    expect(bundle.rules.every((rule) => rule.canResolveNatively), isTrue);
    final relative = bundle.rules.firstWhere(
      (rule) => (rule.rawConfig['site'] as Map)['key'] == 'relative',
    );
    expect(
      relative.rawConfig['runtimeUrl'],
      'https://example.com/config/lib/drpy2.min.js',
    );
    expect(
      relative.rawConfig['extUrl'],
      'https://example.com/config/js/source.js',
    );
    final mirror = bundle.rules.firstWhere(
      (rule) => (rule.rawConfig['site'] as Map)['key'] == 'mirror',
    );
    expect(
      mirror.rawConfig['runtimeUrl'],
      'https://raw.githubusercontent.com/fantaiying7/EXT/refs/heads/main/drpy2.min.js',
    );
    expect(
      mirror.rawConfig['extUrl'],
      'https://raw.githubusercontent.com/fantaiying7/EXT/refs/heads/main/demo.js',
    );
  });

  test('bundled catalog no longer ships client-side drpy sites', () {
    final catalog =
        jsonDecode(File('assets/data/sources_catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    final sources = (catalog['sources'] as List).whereType<Map>();
    var expectedSites = 0;
    var recognizedSites = 0;
    for (final rawSource in sources) {
      final source = rawSource.cast<String, dynamic>();
      final rawConfig = source['rawConfig'];
      if (rawConfig is! Map) continue;
      final sites = rawConfig['sites'];
      if (sites is! List) continue;
      final expected = sites
          .whereType<Map>()
          .where((site) {
            final api = site['api']?.toString() ?? '';
            return site['type']?.toString() == '3' &&
                RegExp(
                  r'drpy2(?:\.min)?\.js',
                  caseSensitive: false,
                ).hasMatch(api);
          })
          .toList(growable: false);
      expectedSites += expected.length;
      final bundle = const RuleImporter().importFromText(
        jsonEncode(rawConfig),
        sourceUrl: source['importUrl']?.toString() ?? '',
      );
      final importedSites = bundle.rules
          .where((rule) => rule.engine == 'drpy-js')
          .map((rule) => jsonEncode(rule.rawConfig['site']))
          .toSet();
      for (final site in expected) {
        expect(importedSites, contains(jsonEncode(site)));
        recognizedSites++;
      }
    }

    expect(catalog['totalSources'], 0);
    expect(sources, isEmpty);
    expect(expectedSites, 0);
    expect(recognizedSites, expectedSites);
  });

  test(
    'source bridge keeps different drpy scripts instead of deduplicating them',
    () {
      const source = VideoSource(
        id: 'source:drpy',
        name: 'drpy source',
        kind: VideoSourceKind.tvBox,
        importUrl: 'https://example.com/box.json',
        baseUrl: 'https://example.com/box.json',
        rawConfig: {
          'sites': [
            {
              'key': 'first',
              'name': 'First',
              'type': 3,
              'api': './lib/drpy2.min.js',
              'ext': './js/first.js',
            },
            {
              'key': 'second',
              'name': 'Second',
              'type': 3,
              'api': './lib/drpy2.min.js',
              'ext': './js/second.js',
            },
          ],
        },
      );

      final result = const SourceRuleBridge().build(
        const SourceCatalogState(totalSources: 1, sources: [source]),
      );

      expect(result.rules, hasLength(6));
      expect(result.rules.map((rule) => rule.rawConfig['extUrl']).toSet(), {
        'https://example.com/js/first.js',
        'https://example.com/js/second.js',
      });
    },
  );

  test(
    'resolver emits only the drpy candidate that passes the real media probe',
    () async {
      final rule = _withTestPermissions(
        const RuleImporter()
            .importFromText(
              jsonEncode({
                'sites': [
                  {
                    'key': 'integration',
                    'name': 'Integration drpy',
                    'type': 3,
                    'api': './lib/drpy2.min.js',
                    'ext': './rules/integration.js',
                  },
                ],
              }),
              sourceUrl: 'https://example.com/config/box.json',
            )
            .rules
            .first,
      );
      var deadProbeCount = 0;
      var goodProbeCount = 0;
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/config/rules/integration.js':
            return http.Response(
              _integrationRule,
              200,
              headers: const {'content-type': 'text/javascript; charset=utf-8'},
            );
          case '/api/search':
            return http.Response(
              jsonEncode({
                'list': [
                  {'vod_id': '/detail/item', 'vod_name': 'Probe Show'},
                ],
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          case '/media/dead-2.mp4':
            deadProbeCount++;
            return http.Response(
              '<html>expired</html>',
              200,
              headers: const {'content-type': 'text/html'},
            );
          case '/media/good-2.mp4':
            goodProbeCount++;
            expect(request.headers['Referer'], 'https://example.com/');
            expect(
              request.headers['Referer'],
              isNot('https://example.com/config/rules/integration.js'),
            );
            final bytes = _mp4Sample();
            return http.Response.bytes(
              bytes,
              206,
              headers: {
                'content-type': 'video/mp4',
                'content-range': 'bytes 0-${bytes.length - 1}/${bytes.length}',
                'content-length': '${bytes.length}',
              },
            );
          default:
            return http.Response('not found', 404);
        }
      });

      final lines =
          await RulePlaybackResolver(
            client: client,
            drpyRuntime: _testDrpyRuntime(),
          ).resolveRule(
            rule: rule,
            subject: _subject,
            episode: _episode,
            verifyPlayable: false,
          );

      expect(deadProbeCount, 1);
      expect(goodProbeCount, 1);
      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://example.com/media/good-2.mp4');
    },
  );

  test(
    'declarative selector search and detail wildcard reach a verified MP4 through lazy',
    () async {
      final rule = _importDrpyRule('selector-good.js');
      var detailRequests = 0;
      var mediaProbes = 0;
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/config/rules/selector-good.js':
            return http.Response(
              _selectorWildcardLazyRule,
              200,
              headers: const {'content-type': 'text/javascript; charset=utf-8'},
            );
          case '/search':
            return http.Response(
              '<main><article><h2>Selector Show</h2>'
              '<a href="/detail/good"></a></article></main>',
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            );
          case '/detail/good':
            detailRequests++;
            return http.Response(
              '<html><video src="/media/verified.mp4"></video></html>',
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            );
          case '/media/verified.mp4':
            mediaProbes++;
            final bytes = _mp4Sample();
            return http.Response.bytes(
              bytes,
              206,
              headers: {
                'content-type': 'video/mp4',
                'content-range': 'bytes 0-${bytes.length - 1}/${bytes.length}',
                'content-length': '${bytes.length}',
              },
            );
          default:
            return http.Response('not found', 404);
        }
      });

      final lines =
          await RulePlaybackResolver(
            client: client,
            drpyRuntime: _testDrpyRuntime(),
          ).resolveRule(
            rule: rule,
            subject: _selectorSubject,
            episode: _selectorEpisode,
            verifyPlayable: false,
          );

      expect(detailRequests, 1);
      expect(mediaProbes, 1);
      expect(lines, hasLength(1));
      expect(lines.single.url, 'https://example.com/media/verified.mp4');
      expect(lines.single.available, isTrue);
    },
  );

  test(
    'declarative detail wildcard never exposes an HTML page as a playback line',
    () async {
      final rule = _importDrpyRule('selector-html.js');
      var htmlProbes = 0;
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/config/rules/selector-html.js':
            return http.Response(
              _selectorWildcardHtmlRule,
              200,
              headers: const {'content-type': 'text/javascript; charset=utf-8'},
            );
          case '/search':
            return http.Response(
              '<main><article><h2>Selector Show</h2>'
              '<a href="/detail/not-video.html"></a></article></main>',
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            );
          case '/detail/not-video.html':
            htmlProbes++;
            return http.Response(
              '<html><body>detail page only</body></html>',
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            );
          default:
            return http.Response('not found', 404);
        }
      });

      final lines =
          await RulePlaybackResolver(
            client: client,
            drpyRuntime: _testDrpyRuntime(),
          ).resolveRule(
            rule: rule,
            subject: _selectorSubject,
            episode: _selectorEpisode,
            verifyPlayable: false,
          );

      expect(htmlProbes, 1);
      expect(lines, isEmpty);
    },
  );

  test(
    'resolver rejects drpy localhost, metadata and mapped IPv6 candidates before probing',
    () async {
      var clientCalled = false;
      final resolver = RulePlaybackResolver(
        client: MockClient((request) async {
          clientCalled = true;
          return http.Response.bytes(_mp4Sample(), 206);
        }),
        drpyRuntime: _FixedDrpyRuntime(const [
          DrpyPlaybackCandidate(
            lineName: 'localhost',
            episodeName: 'Episode 2',
            url: 'http://localhost/video.mp4',
          ),
          DrpyPlaybackCandidate(
            lineName: 'metadata',
            episodeName: 'Episode 2',
            url: 'http://169.254.169.254/latest/meta-data/video.mp4',
          ),
          DrpyPlaybackCandidate(
            lineName: 'mapped',
            episodeName: 'Episode 2',
            url: 'http://[::ffff:10.0.0.8]/video.mp4',
          ),
        ]),
      );

      final lines = await resolver.resolveRule(
        rule: _importDrpyRule('private-candidates.js'),
        subject: _subject,
        episode: _episode,
        verifyPlayable: false,
      );

      expect(lines, isEmpty);
      expect(clientCalled, isFalse);
    },
  );

  test('drpy HLS and DASH probes reject private child resources', () async {
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      switch (request.url.path) {
        case '/master.m3u8':
          return http.Response(
            '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\n'
            'http://[::ffff:10.0.0.9]/segment.ts\n#EXT-X-ENDLIST\n',
            206,
            headers: const {'content-type': 'application/vnd.apple.mpegurl'},
          );
        case '/manifest.mpd':
          return http.Response(
            '<?xml version="1.0"?><MPD><Period><AdaptationSet>'
            '<Representation id="v1" bandwidth="1000">'
            '<SegmentList><Initialization sourceURL="http://169.254.169.254/init.mp4"/>'
            '<SegmentURL media="http://10.0.0.9/chunk.m4s"/>'
            '</SegmentList></Representation></AdaptationSet></Period></MPD>',
            206,
            headers: const {'content-type': 'application/dash+xml'},
          );
        default:
          fail('private child request reached HTTP client: ${request.url}');
      }
    });
    final resolver = RulePlaybackResolver(
      client: client,
      drpyRuntime: _FixedDrpyRuntime(const [
        DrpyPlaybackCandidate(
          lineName: 'hls',
          episodeName: 'Episode 2',
          url: 'https://media.example.com/master.m3u8',
        ),
        DrpyPlaybackCandidate(
          lineName: 'dash',
          episodeName: 'Episode 2',
          url: 'https://media.example.com/manifest.mpd',
        ),
      ]),
    );

    final lines = await resolver.resolveRule(
      rule: _importDrpyRule('private-children.js'),
      subject: _subject,
      episode: _episode,
      verifyPlayable: false,
    );

    expect(lines, isEmpty);
    expect(requested, [
      'https://media.example.com/master.m3u8',
      'https://media.example.com/manifest.mpd',
    ]);
  });

  test(
    'public-only drpy marker survives force refresh and blocks a later private redirect',
    () async {
      var publicRequests = 0;
      var privateRequests = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'media.example.com') {
          publicRequests++;
          if (publicRequests == 1) {
            final bytes = _mp4Sample();
            return http.Response.bytes(
              bytes,
              206,
              headers: {
                'content-type': 'video/mp4',
                'content-range': 'bytes 0-${bytes.length - 1}/${bytes.length}',
                'content-length': '${bytes.length}',
              },
            );
          }
          return http.Response(
            '',
            302,
            headers: const {
              'location': 'http://[::ffff:10.0.0.10]/rebound.mp4',
            },
          );
        }
        privateRequests++;
        return http.Response.bytes(_mp4Sample(), 206);
      });
      final resolver = RulePlaybackResolver(
        client: client,
        drpyRuntime: _FixedDrpyRuntime(const [
          DrpyPlaybackCandidate(
            lineName: 'direct',
            episodeName: 'Episode 2',
            url: 'https://media.example.com/video.mp4',
          ),
        ]),
      );

      final initial = await resolver.resolveRule(
        rule: _importDrpyRule('revalidation.js'),
        subject: _subject,
        episode: _episode,
        verifyPlayable: false,
      );
      expect(initial.single.publicHttpOnly, isTrue);

      final refreshed = await resolver.verifyPlaybackLine(
        line: initial.single,
        forceRefresh: true,
      );

      expect(refreshed.available, isFalse);
      expect(refreshed.publicHttpOnly, isTrue);
      expect(publicRequests, 2);
      expect(privateRequests, 0);
    },
  );

  test('cross-origin drpy media does not inherit base credentials', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'media.example.com');
      expect(_headerValue(request, 'Cookie'), isNull);
      expect(_headerValue(request, 'Authorization'), isNull);
      expect(_headerValue(request, 'X-Api-Key'), isNull);
      expect(_headerValue(request, 'X-General'), 'compatible');
      expect(_headerValue(request, 'X-Candidate'), 'explicit');
      final bytes = _mp4Sample();
      return http.Response.bytes(
        bytes,
        206,
        headers: {
          'content-type': 'video/mp4',
          'content-length': '${bytes.length}',
        },
      );
    });
    final rule = _importDrpyRule('credential-media.js').copyWith(
      baseUrl: 'https://content.example.com/',
      requestHeaders: const {
        'Cookie': 'session=private',
        'Authorization': 'Bearer private',
        'X-Api-Key': 'private-key',
        'X-General': 'compatible',
      },
    );
    final resolver = RulePlaybackResolver(
      client: client,
      drpyRuntime: _FixedDrpyRuntime(const [
        DrpyPlaybackCandidate(
          lineName: 'direct',
          episodeName: 'Episode 2',
          url: 'https://media.example.com/video.mp4',
          headers: {'X-Candidate': 'explicit'},
        ),
      ]),
    );

    final lines = await resolver.resolveRule(
      rule: rule,
      subject: _subject,
      episode: _episode,
      verifyPlayable: false,
    );

    expect(lines, hasLength(1));
    expect(_headerValueFromMap(lines.single.headers, 'Cookie'), isNull);
    expect(_headerValueFromMap(lines.single.headers, 'Authorization'), isNull);
    expect(
      _headerValueFromMap(lines.single.headers, 'X-Candidate'),
      'explicit',
    );
  });
}

RulePlugin _importDrpyRule(String extName) {
  return _withTestPermissions(
    const RuleImporter()
        .importFromText(
          jsonEncode({
            'sites': [
              {
                'key': extName,
                'name': extName,
                'type': 3,
                'api': './lib/drpy2.min.js',
                'ext': './rules/$extName',
              },
            ],
          }),
          sourceUrl: 'https://example.com/config/box.json',
        )
        .rules
        .first,
  );
}

RulePlugin _withTestPermissions(RulePlugin rule) {
  return rule.copyWith(
    permissionManifest: RulePermissionManifest.untrusted(
      id: rule.id,
      name: rule.name,
      version: rule.version,
      engine: rule.engine,
      contentTypes: [rule.contentType.name],
      pageDomains: const [
        'example.com',
        'content.example.com',
        'raw.githubusercontent.com',
      ],
      mediaDomains: const [
        'example.com',
        'content.example.com',
        'media.example.com',
      ],
      cookiePolicy: RuleCookiePolicy.taskScoped,
      customReferer: true,
    ),
  );
}

Future<void> _preloadJsfForWindowsTests() async {
  if (!Platform.isWindows) return;
  final dllUri = await _resolveJsfDllUri();
  DynamicLibrary.open(File.fromUri(dllUri).path);
}

Future<Uri> _resolveJsfDllUri() async {
  try {
    final packageUri = await Isolate.resolvePackageUri(
      Uri.parse('package:jsf/jsf.dart'),
    );
    if (packageUri != null) return packageUri.resolve('../windows/jsf.dll');
  } on UnsupportedError {
    // See drpy_runtime_test.dart: Flutter test may disable this VM API.
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

Uint8List _mp4Sample() {
  final bytes = Uint8List(8 * 1024);
  bytes[3] = 24;
  bytes.setRange(4, 8, ascii.encode('ftyp'));
  return bytes;
}

DrpyRuntime _testDrpyRuntime() =>
    DrpyRuntime(addressLookup: _publicTestAddressLookup);

Future<List<InternetAddress>> _publicTestAddressLookup(String host) async =>
    <InternetAddress>[InternetAddress('93.184.216.34')];

String? _headerValue(http.BaseRequest request, String name) =>
    _headerValueFromMap(request.headers, name);

String? _headerValueFromMap(Map<String, String> headers, String name) {
  final normalized = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == normalized) return entry.value;
  }
  return null;
}

class _FixedDrpyRuntime extends DrpyRuntime {
  _FixedDrpyRuntime(this.fixedCandidates)
    : super(addressLookup: _publicTestAddressLookup);

  final List<DrpyPlaybackCandidate> fixedCandidates;

  @override
  Future<DrpyRuntimeResult> resolve(
    DrpyRuntimeRequest request, {
    http.Client? client,
  }) async => DrpyRuntimeResult(candidates: fixedCandidates);
}

const _integrationRule = r'''
var rule = {
  title: 'Integration',
  host: 'https://example.com',
  ['\u641c\u7d22']: $js.toString(() => {
    VODS = JSON.parse(request(
      'https://example.com/api/search?wd=' + encodeURIComponent(KEY)
    )).list;
  }),
  ['\u4e8c\u7ea7']: $js.toString(() => {
    VOD = {
      vod_name: 'Probe Show',
      vod_play_from: 'dead$$$direct',
      vod_play_url:
        'episode 1$/media/dead-1.mp4#episode 2$/media/dead-2.mp4$$$' +
        'episode 1$/media/good-1.mp4#episode 2$/media/good-2.mp4'
    };
  }),
  lazy: $js.toString(() => {
    input = {parse: 0, url: input};
  })
};
''';

const _selectorWildcardLazyRule = r'''
var rule = {
  host: 'https://example.com',
  searchUrl: '/search?wd=**',
  ['\u4e00\u7ea7']: 'main&&article;h2&&Text;;;a&&href',
  ['\u641c\u7d22']: '*',
  ['\u4e8c\u7ea7']: '*',
  lazy: 'js:' +
    'const page=request(input);' +
    'input={parse:0,url:pd(page,"video&&src",input)};'
};
''';

const _selectorWildcardHtmlRule = r'''
var rule = {
  host: 'https://example.com',
  searchUrl: '/search?wd=**',
  ['\u4e00\u7ea7']: 'main&&article;h2&&Text;;;a&&href',
  ['\u641c\u7d22']: '*',
  ['\u4e8c\u7ea7']: '*'
};
''';

const _subject = AnimeSubject(
  id: 1,
  title: 'Probe Show',
  originalTitle: 'Probe Show',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026',
  platform: 'TV',
  language: 'English',
  region: 'US',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 2,
);

const _episode = AnimeEpisode(
  id: 2,
  subjectId: 1,
  number: 2,
  title: 'Episode 2',
  airdate: null,
  duration: '',
  description: '',
);

const _selectorSubject = AnimeSubject(
  id: 2,
  title: 'Selector Show',
  originalTitle: 'Selector Show',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026',
  platform: 'TV',
  language: 'English',
  region: 'US',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 1,
);

const _selectorEpisode = AnimeEpisode(
  id: 1,
  subjectId: 2,
  number: 1,
  title: 'Episode 1',
  airdate: null,
  duration: '',
  description: '',
);
