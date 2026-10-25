import 'dart:convert';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/bundled_live_action_rules.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test('live action rules execute natively on ${platform.name}', () {
      debugDefaultTargetPlatformOverride = platform;
      for (final rule in optionalLiveActionRules) {
        expect(rule.executionStatus.isExecutable, isTrue);
        expect(rule.requiresWebView, isFalse);
        expect(rule.engine, 'tvbox-json-api');
      }
    });
  }

  const repository = RulePluginRepository();
  for (final rule in optionalLiveActionRules) {
    test(
      '${rule.id} is a optional declarative movie/series rule, never enabled automatically',
      () {
        expect(rule.canResolveNatively, isTrue);
        expect(rule.requiresWebView, isFalse);
        expect(rule.requiresPrivateAuth, isFalse);
        expect(rule.rawConfig.keys, ['searchAction']);
        expect(['list', 'detail'], contains(rule.rawConfig['searchAction']));
        final defaults = repository.defaultState();
        expect(defaults.installedIds, isNot(contains(rule.id)));
        expect(defaults.enabledIds, isNot(contains(rule.id)));
        final state = defaults.copyWith(
          installedIds: {...defaults.installedIds, rule.id},
          enabledIds: {...defaults.enabledIds, rule.id},
        );
        for (final type in [RuleContentType.movie, RuleContentType.series]) {
          expect(
            repository.playbackRulesFor(state, type).map((r) => r.id),
            contains(rule.id),
          );
        }
        expect(
          repository
              .playbackRulesFor(state, RuleContentType.anime)
              .map((r) => r.id),
          isNot(contains(rule.id)),
        );
        final restored = RulePlugin.fromJson(rule.toJson());
        expect(
          restored.effectiveManifest.contentHash,
          rule.effectiveManifest.contentHash,
        );
        expect(restored.effectiveManifest.trustLevel, RuleTrustLevel.untrusted);
        expect(
          restored.effectiveManifest.mediaDomains,
          rule.effectiveManifest.mediaDomains,
        );
        expect(restored.supportedContentTypes, rule.supportedContentTypes);
        final manifest = rule.effectiveManifest;
        expect(manifest.javascript, isFalse);
        expect(manifest.webViewSniffing, isFalse);
        expect(manifest.cookiePolicy, RuleCookiePolicy.none);
        expect(manifest.cleartextHttp, isFalse);
        final policy = RuleUrlPolicy(manifest);
        for (final host in manifest.mediaDomains) {
          expect(host, isNot(contains('*')));
          expect(
            policy.allows(Uri.https(host, '/media'), RuleUrlPurpose.media),
            isTrue,
          );
          expect(
            policy.allows(Uri.https(host, '/page'), RuleUrlPurpose.page),
            isFalse,
          );
          expect(
            policy.allows(
              Uri.https('$host.attacker.test', '/media'),
              RuleUrlPurpose.media,
            ),
            isFalse,
          );
        }
        for (final host in [
          '127.0.0.1',
          '169.254.169.254',
          'unlisted.example',
        ]) {
          expect(
            policy.allows(Uri.https(host, '/media'), RuleUrlPurpose.media),
            isFalse,
          );
        }
      },
    );
  }

  test('list-only MacCMS search is followed by an ID detail lookup', () async {
    var searchCount = 0;
    var detailCount = 0;
    final resolver = RulePlaybackResolver(
      client: MockClient((request) async {
        final uri = request.url;
        if (uri.host == 'api.yzzy-api.com') {
          if (uri.queryParameters.containsKey('wd')) {
            searchCount++;
            expect(uri.queryParameters['ac'], 'list');
            return _json([
              {
                'vod_id': 'correct',
                'vod_name': '开端',
                'type_name': '国产剧',
                'vod_year': '2022',
              },
            ]);
          }
          detailCount++;
          expect(uri.queryParameters['ids'], 'correct');
          return _json([_entry('correct', '国产剧', '2022')]);
        }
        if (uri.path.endsWith('.m3u8')) {
          return http.Response(
            '#EXTM3U\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        final bytes = List<int>.filled(188 * 3, 0);
        for (var i = 0; i < 3; i++) {
          bytes[i * 188] = 0x47;
        }
        return http.Response.bytes(
          bytes,
          206,
          headers: {'content-type': 'video/mp2t'},
        );
      }),
    );
    final lines = await resolver.resolveRule(
      rule: optionalLiveActionRules.first,
      subject: _series,
      episode: _episode,
      verifyPlayable: false,
    );
    expect(lines.single.available, isTrue);
    expect(searchCount, 1);
    expect(detailCount, 1);
  });

  test('TVBox真人匹配排除同名电影、旧版剧及解说，选对年份和集号', () async {
    final paths = <String>[];
    final rule = optionalLiveActionRules.first;
    final resolver = RulePlaybackResolver(
      client: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.host == 'api.yzzy-api.com') {
          return _json([
            _entry('wrong-movie', '科幻片', '2022'),
            _entry('wrong-year', '国产剧', '2019'),
            _entry('commentary', '电影解说', '2022'),
            _entry('unknown', '', ''),
            _entry('correct', '国产剧', '2022'),
          ]);
        }
        expect(request.url.host, 'yzzy.play-cdn9.com');
        if (request.url.path.endsWith('.m3u8')) {
          return http.Response(
            '#EXTM3U\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        final bytes = List<int>.filled(188 * 3, 0);
        for (var i = 0; i < 3; i++) {
          bytes[188 * i] = 0x47;
        }
        return http.Response.bytes(
          bytes,
          206,
          headers: {'content-type': 'video/mp2t'},
        );
      }),
    );
    final lines = await resolver.resolveRule(
      rule: rule,
      subject: _series,
      episode: _episode,
      verifyPlayable: false,
    );
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://yzzy.play-cdn9.com/correct/2.m3u8');
    expect(
      paths.any((p) => p.contains('wrong') || p.contains('commentary')),
      isFalse,
    );
  });

  test('TVBox拒绝详情中换成同名电影，不向该媒体发送请求', () async {
    var mediaRequests = 0;
    final rule = optionalLiveActionRules.first;
    final resolver = RulePlaybackResolver(
      client: MockClient((request) async {
        if (request.url.host != 'api.yzzy-api.com') {
          mediaRequests++;
          return http.Response('', 404);
        }
        if (request.url.queryParameters.containsKey('ids')) {
          return _json([_entry('correct', '科幻片', '2022')]);
        }
        return _json([
          {'vod_id': 'correct', 'vod_name': '开端'},
        ]);
      }),
    );
    final lines = await resolver.resolveRule(
      rule: rule,
      subject: _series,
      episode: _episode,
      verifyPlayable: false,
    );
    expect(lines.every((l) => !l.available), isTrue);
    expect(mediaRequests, 0);
  });
}

http.Response _json(List<Map<String, dynamic>> items) => http.Response(
  jsonEncode({'list': items}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> _entry(String id, String type, String year) => {
  'vod_id': id,
  'vod_name': '开端',
  'type_name': type,
  'vod_year': year,
  'vod_play_from': '1080zyk',
  'vod_play_url':
      '第01集\$https://yzzy.play-cdn9.com/$id/1.m3u8#第02集\$https://yzzy.play-cdn9.com/$id/2.m3u8',
};
const _series = AnimeSubject(
  id: 991012,
  title: '开端',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2022-01-11',
  platform: 'TV',
  language: '',
  region: '',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 15,
  source: 'tmdb:tv',
);
const _episode = AnimeEpisode(
  id: 2,
  subjectId: 991012,
  number: 2,
  title: '第2集',
  airdate: null,
  duration: '',
  description: '',
);
