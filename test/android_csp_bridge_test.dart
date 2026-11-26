import 'dart:convert';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/android_csp_bridge.dart';
import 'package:anime/src/rules/csp_rule_support.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('TVBox importer keeps audited and unavailable CSP rules', () {
    final bundle = const RuleImporter().importFromText('''
      {
        "spider": "./jar/custom_spider.jar;md5;$qistCustomSpiderMd5",
        "sites": [
          {"key":"star","name":"Star","type":3,"api":"csp_Star","ext":"./json/star.json"},
          {"key":"nini","name":"NiNi","type":3,"api":"csp_NiNi"}
        ]
      }
    ''');

    final star = bundle.rules.where((rule) => rule.name == 'Star').toList();
    final nini = bundle.rules.where((rule) => rule.name == 'NiNi').toList();
    expect(star, hasLength(3));
    expect(nini, hasLength(3));
    expect(star.every((rule) => rule.engine == 'android-csp'), isTrue);
    expect(star.every((rule) => rule.canResolveNatively), isTrue);
    expect(star.every((rule) => rule.unsupportedReason == null), isTrue);
    expect(nini.every((rule) => rule.unsupportedReason != null), isTrue);
    expect(nini.every((rule) => !rule.canResolveNatively), isTrue);
  });

  test('relative CSP ext is pinned to the audited package commit', () {
    final raw = <String, dynamic>{
      'spider': './jar/custom_spider.jar;md5;$qistCustomSpiderMd5',
      'site': {
        'api': 'csp_Star',
        'ext': {'filter': './json/filter.json', 'token': ''},
      },
    };

    final decoded = jsonDecode(androidCspEncodedExt(raw)) as Map;
    expect(
      decoded['filter'],
      contains('f1ec5de1cb89fc0accfa2998dc5eccd5892efb1c/json/filter.json'),
    );
  });

  test('resolver completes CSP search detail player and media probe', () async {
    final bridge = _FakeCspBridge();
    final resolver = RulePlaybackResolver(
      cspBridge: bridge,
      client: MockClient((request) async {
        expect(request.url.host, 'media.example');
        return http.Response(
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXTINF:6,\n'
          'https://media.example/segment.ts\n'
          '#EXT-X-ENDLIST\n',
          200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }),
    );

    final lines = await resolver.resolveRule(
      rule: _cspRule(),
      subject: _subject,
      episode: _episode,
      verifyPlayable: false,
    );

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://media.example/video.m3u8');
    expect(
      bridge.calls,
      containsAllInOrder([
        'capabilities',
        'prepare',
        'initialize',
        'search',
        'detail',
        'player',
      ]),
    );
    expect(bridge.lastSite?.spiderMd5, qistCustomSpiderMd5);
    expect(bridge.lastSite?.api, 'csp_Star');
  });

  test(
    'unsupported platform or package yields no error playback row',
    () async {
      final bridge = _FakeCspBridge(platformSupported: false);
      final resolver = RulePlaybackResolver(cspBridge: bridge);
      final lines = await resolver.resolveRule(
        rule: _cspRule(),
        subject: _subject,
        episode: _episode,
      );
      expect(lines, isEmpty);
      expect(bridge.calls, isEmpty);

      final unknown = _cspRule().copyWith(
        rawConfig: {
          'spider': './jar/fan.txt;md5;8432d174d72d5b608ae1bcd16d966847',
          'site': {'key': 'guard', 'api': 'csp_AppSKGuard'},
        },
      );
      final supportedBridge = _FakeCspBridge();
      final unknownLines = await RulePlaybackResolver(
        cspBridge: supportedBridge,
      ).resolveRule(rule: unknown, subject: _subject, episode: _episode);
      expect(unknownLines, isEmpty);
      expect(supportedBridge.calls, isEmpty);
    },
  );
}

class _FakeCspBridge extends AndroidCspBridge {
  _FakeCspBridge({bool platformSupported = true})
    : super(platformSupported: platformSupported);

  final List<String> calls = [];
  AndroidCspSite? lastSite;

  @override
  Future<AndroidCspCapabilities> getCapabilities() async {
    calls.add('capabilities');
    return const AndroidCspCapabilities(
      packages: [
        AndroidCspPackageCapabilities(
          packageId: 'qist-custom-f1ec5de',
          artifactUrl: 'https://example.invalid/custom_spider.jar',
          md5: qistCustomSpiderMd5,
          sha256:
              '646c5449e06bceea84eac4f42341a887187c4f09cfcb038820418719a898669f',
          allowedApis: ['csp_Star'],
        ),
      ],
      supportsGuard: false,
      supportsDianshi: false,
    );
  }

  @override
  Future<AndroidCspPreparation> prepare(String spiderMd5) async {
    calls.add('prepare');
    return const AndroidCspPreparation(
      packageId: 'qist-custom-f1ec5de',
      md5: qistCustomSpiderMd5,
      sha256:
          '646c5449e06bceea84eac4f42341a887187c4f09cfcb038820418719a898669f',
      bytes: 266777,
      fromCache: true,
    );
  }

  @override
  Future<void> initialize(AndroidCspSite site) async {
    calls.add('initialize');
    lastSite = site;
  }

  @override
  Future<String> searchContent({
    required AndroidCspSite site,
    required String keyword,
    bool quick = false,
    String? page,
  }) async {
    calls.add('search');
    return '{"list":[{"vod_id":"vod-1","vod_name":"Target Show"}]}';
  }

  @override
  Future<String> detailContent({
    required AndroidCspSite site,
    required List<String> ids,
  }) async {
    calls.add('detail');
    return '{"list":[{"vod_id":"vod-1","vod_name":"Target Show",'
        '"vod_play_from":"direct","vod_play_url":"Episode 1\u0024play-1"}]}';
  }

  @override
  Future<String> playerContent({
    required AndroidCspSite site,
    required String id,
    String flag = '',
    List<String> vipFlags = const [],
  }) async {
    calls.add('player');
    return '{"parse":0,"url":"https://media.example/video.m3u8",'
        '"header":{"Referer":"https://media.example/"}}';
  }
}

RulePlugin _cspRule() => RulePlugin(
  id: 'csp-star',
  name: 'Star',
  version: '1',
  source: RuleSourceKind.tvbox,
  contentType: RuleContentType.series,
  engine: 'android-csp',
  updatedAt: DateTime(2026),
  qualityScore: 80,
  tags: const ['TVBox', 'Android CSP'],
  baseUrl: androidCspPinnedBase(qistCustomSpiderMd5),
  searchUrl: '',
  searchable: true,
  quickSearch: true,
  filterable: false,
  rawConfig: const {
    'spider': './jar/custom_spider.jar;md5;$qistCustomSpiderMd5',
    'site': {'key': 'star', 'api': 'csp_Star'},
  },
  permissionManifest: const RulePermissionManifest.untrusted(
    id: 'csp-star',
    name: 'Star',
    version: '1',
    engine: 'android-csp',
    contentTypes: ['series'],
    pageDomains: ['raw.githubusercontent.com'],
    mediaDomains: ['media.example'],
    customReferer: true,
  ),
);

const _subject = AnimeSubject(
  id: 1,
  title: 'Target Show',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: 'zh',
  region: 'CN',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 1,
);

const _episode = AnimeEpisode(
  id: 1,
  subjectId: 1,
  number: 1,
  title: 'Episode 1',
  airdate: null,
  duration: '',
  description: '',
);
