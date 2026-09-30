import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'dart:convert';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'slow TVBox probes do not erase enumerated routes at the full-scan deadline',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'cdn.example.com') {
          if (request.url.path != '/0.m3u8' &&
              request.url.path != '/segment.ts') {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          return request.url.path.endsWith('.m3u8')
              ? _playableHls()
              : _playableSegment();
        }
        return http.Response(
          jsonEncode({
            'list': [
              {
                'vod_id': 7,
                'vod_name': _subject.title,
                'vod_play_from': List.generate(12, (i) => '线路$i').join(r'$$$'),
                'vod_play_url': List.generate(
                  12,
                  (i) => '第2集\$https://cdn.example.com/$i.m3u8',
                ).join(r'$$$'),
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final lines = await RulePlaybackResolver(
        client: client,
        timeout: const Duration(milliseconds: 80),
      ).resolveRule(rule: _jsonApiRule, subject: _subject, episode: _episode);
      expect(lines, hasLength(12));
      expect(lines.map((line) => line.id).toSet(), hasLength(12));
      expect(lines.any((line) => line.available), isTrue);
      expect(
        lines
            .where((line) => !line.available)
            .every((line) => line.url != null),
        isTrue,
      );
    },
  );

  test(
    'full rule stream lists every route even when the quick route is denied',
    () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'list': [
              {
                'vod_id': 7,
                'vod_name': _subject.title,
                'vod_play_from': List.generate(
                  12,
                  (i) => '未授权线路$i',
                ).join(r'$$$'),
                'vod_play_url': List.generate(
                  12,
                  (i) => '第2集\$https://unapproved.example/$i.m3u8',
                ).join(r'$$$'),
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      final state = RulePluginState(
        installedIds: {_jsonApiRule.id},
        enabledIds: {_jsonApiRule.id},
        approvedPermissionDigests: {
          _jsonApiRule.id: _jsonApiRule.effectiveManifest.permissionDigest,
        },
      );
      final repository = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: [_jsonApiRule]),
        ruleState: state,
        resolver: RulePlaybackResolver(client: client),
        cacheNamespace: 'full-denied-inventory',
      );
      final updates = await repository
          .lineUpdatesForEpisode(_subject, _episode)
          .toList();
      expect(updates.last.isComplete, isTrue);
      expect(updates.last.lines, hasLength(12));
      expect(updates.last.lines.every((line) => !line.available), isTrue);
    },
  );

  for (final sameUrl in [false, true]) {
    test(
      'full lookup preserves twelve TVBox routes, same URL=$sameUrl',
      () async {
        final client = MockClient((request) async {
          if (request.url.host == 'cdn.example.com') {
            return request.url.path.endsWith('.m3u8')
                ? _playableHls()
                : _playableSegment();
          }
          return http.Response(
            jsonEncode({
              'list': [
                {
                  'vod_id': 7,
                  'vod_name': _subject.title,
                  'vod_play_from': List.generate(
                    12,
                    (i) => '线路$i',
                  ).join(r'$$$'),
                  'vod_play_url': List.generate(
                    12,
                    (i) =>
                        '第2集\$https://cdn.example.com/${sameUrl ? 0 : i}.m3u8',
                  ).join(r'$$$'),
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        final lines = await RulePlaybackResolver(
          client: client,
        ).resolveRule(rule: _jsonApiRule, subject: _subject, episode: _episode);
        expect(lines, hasLength(12));
        expect(lines.map((line) => line.id).toSet(), hasLength(12));
      },
    );
  }
  test(
    'a denied TVBox media domain remains visible without being requested',
    () async {
      var forbiddenRequests = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'unapproved.example') forbiddenRequests++;
        return http.Response(
          jsonEncode({
            'list': [
              {
                'vod_id': 7,
                'vod_name': _subject.title,
                'vod_play_from': '未授权线路',
                'vod_play_url': r'第2集$https://unapproved.example/2.m3u8',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final lines = await RulePlaybackResolver(
        client: client,
      ).resolveRule(rule: _jsonApiRule, subject: _subject, episode: _episode);
      expect(forbiddenRequests, 0);
      expect(lines.single.available, isFalse);
      expect(lines.single.url, 'https://unapproved.example/2.m3u8');
      expect(lines.single.message, contains('未授权'));
    },
  );

  test(
    'TVBox JSON API resolves the requested episode into a playable line',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'cdn.example.com') {
          if (request.url.path.endsWith('.m3u8')) return _playableHls();
          return _playableSegment();
        }
        expect(request.url.host, 'api.example.com');
        expect(request.url.queryParameters['wd'], '测试番剧');
        return http.Response(
          '''
{
  "code": 1,
  "list": [
    {
      "vod_id": 7,
      "vod_name": "测试番剧",
      "vod_play_from": "直连",
      "vod_play_url": "第1集\$https://cdn.example.com/ep1.m3u8#第2集\$https://cdn.example.com/ep2.m3u8"
    }
  ]
}
''',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final resolver = RulePlaybackResolver(client: client);

      final lines = await resolver.resolveRule(
        rule: _jsonApiRule,
        subject: _subject,
        episode: _episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://cdn.example.com/ep2.m3u8');
      expect(lines.single.providerName, '测试 JSON 源');
      expect(lines.single.format, 'HLS');
    },
  );
}

http.Response _playableHls() => http.Response(
  '#EXTM3U\n#EXTINF:10.0,\nsegment.ts\n#EXT-X-ENDLIST\n',
  200,
  headers: {'content-type': 'application/vnd.apple.mpegurl'},
);

http.Response _playableSegment() {
  final bytes = List<int>.filled(188 * 2, 0);
  bytes[0] = 0x47;
  bytes[188] = 0x47;
  return http.Response.bytes(
    bytes,
    206,
    headers: {'content-type': 'video/mp2t'},
  );
}

final _jsonApiRule = RulePlugin(
  id: 'custom:tvbox:json',
  name: '测试 JSON 源',
  version: '1.0',
  source: RuleSourceKind.tvbox,
  contentType: RuleContentType.anime,
  engine: 'tvbox-json-api',
  updatedAt: DateTime(2026, 7, 13),
  qualityScore: 80,
  tags: const ['TVBox', 'JSON API'],
  baseUrl: 'https://api.example.com/api.php/provide/vod',
  searchUrl: 'https://api.example.com/api.php/provide/vod',
  searchable: true,
  quickSearch: true,
  filterable: false,
  permissionManifest: const RulePermissionManifest.untrusted(
    id: 'custom:tvbox:json',
    name: '测试 JSON 源',
    version: '1.0',
    engine: 'tvbox-json-api',
    contentTypes: ['anime'],
    pageDomains: ['api.example.com'],
    mediaDomains: ['cdn.example.com'],
    customReferer: true,
  ),
);

const _subject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全12集',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '番剧')],
  totalEpisodes: 12,
);

const _episode = AnimeEpisode(
  id: 102,
  subjectId: 1,
  number: 2,
  title: '第二集',
  airdate: '2026-01-08',
  duration: '24:00',
  description: '第二集',
);
