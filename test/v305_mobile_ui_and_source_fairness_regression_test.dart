import 'dart:convert';
import 'dart:typed_data';

import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/player/ui/playback_line_tile.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/shared_ui/app_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'PlaybackLineTile inside PlayerPage dark theme stays bright and readable in Light Mode',
    (tester) async {
      const line = PlaybackLine(
        id: 'line-visible',
        episodeId: 1,
        providerId: 'aggregate.maccms',
        providerName: '暴风资源',
        title: '第1集 · bfzym3u8',
        quality: '1080P',
        format: 'HLS',
        latency: Duration(milliseconds: 51),
        available: false,
        queried: true,
        queryLocation: 'vps',
        diagnosticStatus: PlaybackDiscoveryStatus.matchedNoEpisode,
      );

      final darkTheme = AnimeTheme.dark().copyWith(
        colorScheme: AnimeTheme.dark().colorScheme.copyWith(
          onSurface: AppColors.theaterInk,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AnimeTheme.light(),
          home: Theme(
            data: darkTheme,
            child: const Scaffold(
              backgroundColor: AppColors.theaterPanel,
              body: PlaybackLineTile(line: line),
            ),
          ),
        ),
      );

      final titleWidget = tester.widget<Text>(
        find.byKey(const ValueKey('line-name-line-visible')),
      );
      expect(titleWidget.style?.color, AppColors.theaterInk);
      expect(titleWidget.style!.color!.computeLuminance(), greaterThan(0.7));
    },
  );

  test(
    'legacy VPS full lookup recovers confirmed matched_no_episode sources alongside playable and search_miss rows',
    () async {
      final requestedEpisodes = <String>[];
      final repo = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://backend.example',
        client: MockClient((request) async {
          final ep = request.url.queryParameters['episode']!;
          requestedEpisodes.add(ep);
          if (ep == '27') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode([
                  {
                    'source': 'maccms:暴风资源',
                    'available': true,
                    'status': 'server_verified',
                    'diagnostic_status': 'server_verified',
                    'url': 'https://cdn.example/baofeng/27.m3u8',
                    'format': 'hls',
                  },
                  {
                    'source': 'maccms:光速',
                    'available': false,
                    'status': 'missing_episode',
                    'diagnostic_status': 'matched_no_episode',
                    'url': '',
                  },
                  {
                    'source': 'maccms:金鹰',
                    'available': false,
                    'status': 'missing_episode',
                    'diagnostic_status': 'matched_no_episode',
                    'url': '',
                  },
                  {
                    'source': 'maccms:非凡资源',
                    'available': false,
                    'status': 'not_found',
                    'diagnostic_status': 'search_miss',
                    'url': '',
                  },
                ]),
              ),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'source': 'maccms:暴风资源',
                  'available': true,
                  'status': 'server_verified',
                  'url': 'https://cdn.example/baofeng/2.m3u8',
                  'format': 'hls',
                },
                {
                  'source': 'maccms:光速',
                  'available': true,
                  'status': 'server_verified',
                  'url': 'https://cdn.example/guangsu/2.m3u8',
                  'format': 'hls',
                },
                {
                  'source': 'maccms:无关站点',
                  'available': true,
                  'status': 'server_verified',
                  'url': 'https://cdn.example/unrelated/2.m3u8',
                  'format': 'hls',
                },
              ]),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final lines = await repo.linesForEpisodeMode(
        _subject,
        _episode,
        expandAll: true,
      );
      expect(requestedEpisodes, ['27', '2']);
      final playableUrls = lines
          .where((l) => l.available)
          .map((l) => l.url)
          .toList();
      expect(
        playableUrls,
        unorderedEquals([
          'https://cdn.example/baofeng/27.m3u8',
          'https://cdn.example/guangsu/2.m3u8',
        ]),
      );
    },
  );

  test(
    'legacy VPS quick lookup still retries when 0 playable lines exist alongside search_miss rows, and skips when discovery is pending',
    () async {
      final quickCalls = <String>[];
      final repo = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://backend.example',
        client: MockClient((request) async {
          final ep = request.url.queryParameters['episode']!;
          quickCalls.add(ep);
          if (ep == '27') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode([
                  {
                    'source': 'maccms:光速',
                    'available': false,
                    'diagnostic_status': 'matched_no_episode',
                    'url': '',
                  },
                  {
                    'source': 'maccms:非凡资源',
                    'available': false,
                    'diagnostic_status': 'search_miss',
                    'url': '',
                  },
                ]),
              ),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'source': 'maccms:光速',
                  'available': true,
                  'status': 'server_verified',
                  'url': 'https://cdn.example/guangsu/2.m3u8',
                  'format': 'hls',
                },
              ]),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final lines = await repo.linesForEpisodeMode(
        _subject,
        _episode,
        expandAll: false,
      );
      expect(quickCalls, ['27', '2']);
      expect(
        lines.where((l) => l.available).single.url,
        'https://cdn.example/guangsu/2.m3u8',
      );

      var pendingCalls = 0;
      final pendingRepo = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://backend.example',
        client: MockClient((request) async {
          pendingCalls++;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'source': 'maccms:光速',
                  'available': false,
                  'diagnostic_status': 'matched_no_episode',
                  'url': '',
                },
              ]),
            ),
            200,
            headers: {
              'content-type': 'application/json',
              'x-zeluna-discovery': 'pending',
            },
          );
        }),
      );
      await pendingRepo.linesForEpisodeMode(
        _subject,
        _episode,
        expandAll: true,
      );
      expect(pendingCalls, 1);
    },
  );

  test(
    'sortPlaybackLinesForDisplay places playable and pending candidates ahead of fast missing-episode diagnostic rows',
    () {
      const missingFast = PlaybackLine(
        id: 'missing-fast',
        episodeId: 1,
        providerId: 'aggregate.maccms',
        providerName: '光速',
        title: '光速',
        quality: '',
        format: '',
        latency: Duration(milliseconds: 51),
        available: false,
        diagnosticStatus: PlaybackDiscoveryStatus.matchedNoEpisode,
      );
      const pendingProbe = PlaybackLine(
        id: 'pending-probe',
        episodeId: 1,
        providerId: 'aggregate.maccms',
        providerName: '待验证源',
        title: '线路1',
        quality: '1080P',
        format: 'HLS',
        url: 'https://cdn.example/probe.m3u8',
        latency: Duration(milliseconds: 600),
        requiresClientProbe: true,
        available: false,
        diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
      );
      const failedWithUrl = PlaybackLine(
        id: 'failed-url',
        episodeId: 1,
        providerId: 'rule:local',
        providerName: '本地规则',
        title: '线路1',
        quality: '1080P',
        format: 'HLS',
        url: 'https://cdn.example/failed.m3u8',
        latency: Duration(milliseconds: 800),
        available: false,
      );
      const readySlow = PlaybackLine(
        id: 'ready-slow',
        episodeId: 1,
        providerId: 'rule:local-ok',
        providerName: '本地可播',
        title: '线路1',
        quality: '1080P',
        format: 'HLS',
        url: 'https://cdn.example/ok.m3u8',
        latency: Duration(milliseconds: 1200),
        available: true,
      );

      final ordered = sortPlaybackLinesForDisplay([
        missingFast,
        failedWithUrl,
        pendingProbe,
        readySlow,
      ]);
      expect(ordered.map((l) => l.id), [
        'ready-slow',
        'pending-probe',
        'failed-url',
        'missing-fast',
      ]);
    },
  );

  test(
    'expanded rule lookup reserves WebView anime slots and round-robins across repositories fairly',
    () async {
      final repoARules = List.generate(
        30,
        (i) => _directRule(
          id: 'repoA:$i',
          name: 'RepoA $i',
          host: 'a-$i.example.com',
          groupId: 'repo:A',
          priority: 10 + i,
        ),
      );
      final repoBRules = List.generate(
        15,
        (i) => _directRule(
          id: 'repoB:$i',
          name: 'RepoB $i',
          host: 'b-$i.example.com',
          groupId: 'repo:B',
          priority: 50 + i,
        ),
      );
      final kazumiWebViewRules = List.generate(
        10,
        (i) => _webViewRule(
          id: 'kazumi:$i',
          name: 'Kazumi $i',
          host: 'k-$i.example.com',
          groupId: 'repo:kazumi',
          priority: 100 + i,
        ),
      );
      final allRules = [...repoARules, ...repoBRules, ...kazumiWebViewRules];
      final resolver = _RecordingResolver();
      final ids = allRules.map((r) => r.id).toSet();
      final state = RulePluginState(
        installedIds: ids,
        enabledIds: ids,
        customRules: allRules,
        approvedPermissionDigests: {
          for (final r in allRules)
            if (r.effectiveManifest.requiresApproval)
              r.id: r.effectiveManifest.permissionDigest,
        },
      );
      final repository = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: allRules),
        ruleState: state,
        resolver: resolver,
        cacheNamespace: 'v305-repo-fairness',
      );

      await repository.lineUpdatesForEpisode(_subject, _episode).toList();
      expect(resolver.calledIds.length, 24);
      final kazumiCount = resolver.calledIds
          .where((id) => id.startsWith('kazumi:'))
          .length;
      final repoACount = resolver.calledIds
          .where((id) => id.startsWith('repoA:'))
          .length;
      final repoBCount = resolver.calledIds
          .where((id) => id.startsWith('repoB:'))
          .length;
      expect(kazumiCount, 3);
      expect(repoACount, 11);
      expect(repoBCount, 10);
    },
  );

  test(
    'RulePlaybackResolver marks resolved lines with queryLocation=local and queried=true',
    () async {
      final rule = _directRule(
        id: 'custom:local-tvbox',
        name: '开源仓库规则',
        host: 'local-api.example',
        groupId: 'repo:community',
        priority: 10,
      );
      final client = MockClient((request) async {
        if (request.url.path == '/api.php/provide/vod') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'list': [
                  {
                    'vod_id': 1,
                    'vod_name': '青之箱 第二季',
                    'vod_play_from': '主线',
                    'vod_play_url': r'第2集$https://local-api.example/ep2.m3u8',
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/ep2.m3u8') {
          return http.Response(
            '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        if (request.url.path == '/seg0.ts') {
          final ts = Uint8List(376);
          ts[0] = 0x47;
          ts[188] = 0x47;
          return http.Response.bytes(
            ts,
            206,
            headers: {'content-type': 'video/mp2t'},
          );
        }
        return http.Response('not found', 404);
      });

      final lines = await RulePlaybackResolver(
        client: client,
      ).resolveRule(rule: rule, subject: _subject, episode: _episode);
      expect(lines, isNotEmpty);
      expect(lines.first.available, isTrue);
      expect(lines.first.queryLocation, 'local');
      expect(lines.first.queried, isTrue);
    },
  );
}

const _subject = AnimeSubject(
  id: 546078,
  title: '青之箱 第二季',
  originalTitle: 'アオのハコ 第2期',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-10-01',
  platform: 'TV',
  language: 'ja',
  region: 'JP',
  status: 'airing',
  categories: [],
  tags: [],
  totalEpisodes: 25,
  source: 'bangumi',
);

const _episode = AnimeEpisode(
  id: 546078027,
  subjectId: 546078,
  number: 27,
  seasonNumber: 2,
  seasonEpisodeNumber: 2,
  title: '憧憬',
  airdate: '2026-10-10',
  duration: '24:00',
  description: '',
);

RulePlugin _directRule({
  required String id,
  required String name,
  required String host,
  required String groupId,
  required int priority,
}) => RulePlugin(
  id: id,
  name: name,
  version: '1.0',
  source: RuleSourceKind.tvbox,
  contentType: RuleContentType.anime,
  engine: 'tvbox-json-api',
  updatedAt: DateTime.utc(2026, 11, 24),
  qualityScore: 75,
  tags: const ['TVBox', 'JSON API'],
  baseUrl: 'https://$host/api.php/provide/vod',
  searchUrl: 'https://$host/api.php/provide/vod',
  searchable: true,
  quickSearch: true,
  filterable: false,
  priority: priority,
  groupId: groupId,
);

RulePlugin _webViewRule({
  required String id,
  required String name,
  required String host,
  required String groupId,
  required int priority,
}) => RulePlugin(
  id: id,
  name: name,
  version: '1.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'animeko-web-selector',
  updatedAt: DateTime.utc(2026, 11, 24),
  qualityScore: 80,
  tags: const ['Animeko'],
  baseUrl: 'https://$host/',
  searchUrl: 'https://$host/search?wd={keyword}',
  searchable: true,
  quickSearch: false,
  filterable: false,
  requiresWebView: true,
  priority: priority,
  groupId: groupId,
  animeko: AnimekoWebSelectorConfig(
    searchUrl: 'https://$host/search?wd={keyword}',
    subjectFormatId: 'a',
    channelFormatId: 'index-grouped',
    subjectA: const AnimekoSubjectAConfig(selectLists: '.result a'),
    channelFlattened: const AnimekoChannelFlattenedConfig(
      selectEpisodeLists: '.playlist',
      selectEpisodesFromList: 'a',
      matchEpisodeSortFromName: r'(?<ep>\d+)',
    ),
    matchVideoUrl: r'(?<v>https?:\/\/.+\.(m3u8|mp4))',
  ),
);

class _RecordingResolver extends RulePlaybackResolver {
  final List<String> calledIds = <String>[];

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (!verifyPlayable) calledIds.add(rule.id);
    return const [];
  }
}
